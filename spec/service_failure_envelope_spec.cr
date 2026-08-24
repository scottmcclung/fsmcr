require "./spec_helper"

# Service#send's failure envelope and observer independence.
#
# Two structural guarantees are pinned here, both the synchronous parallels of
# guarantees AsyncService already keeps (see spec/async_service_spec.cr):
#
#   1. The failure envelope covers planning. Guards run inside plan,
#      and planning is part of the step, so a guard that raises must
#      surface as a Failed snapshot on the returning path rather than propagating raw:
#      where a value comes back, failure is in the value. The
#      Failed snapshot carries the guard's exception and the unchanged id, exactly like
#      a raising callback.
#
#   2. Observer firing is independent. on_transition fires first on a successful step,
#      then on_event_processed. on_event_processed is
#      guaranteed to fire after EVERY step, so an on_transition that
#      raises must not skip it. This is the synchronous interpreter, so there is a
#      calling fiber to receive an observer failure and no lifecycle to poison (unlike
#      AsyncService). The design-consistent surfacing, keeping the
#      first exception authoritative (the rule AsyncService's fire_observers follows),
#      is: both observers fire, then send re-raises the FIRST observer exception.
#
# On a failed step the returning path already carries the recorded exception, so an
# on_event_processed handler that itself raises while handling a Failed snapshot is
# discarded and the first recorded exception wins. That case is
# covered in spec/on_event_processed_spec.cr and is not duplicated here.
describe "Service#send failure envelope and observer independence" do
  describe "a guard that raises" do
    it "returns a Failed snapshot carrying the guard's exception instead of propagating raw" do
      ctx : TurnContext = TurnContext.new
      boom : Exception = Exception.new("guard raised")

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") do |s|
          # The guard runs inside plan. Planning is part
          # of the step, so a raising guard must be caught by send's failure envelope
          # and surfaced as a Failed value, not propagated raw.
          s.on_event("north", "clearing") { |t| t.guard { |_e, _c| raise boom } }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)

      # The returning path surfaces failure as a value, not a raise.
      result : FSM::State = service.send("north")

      result.status.should eq FSM::Status::Failed
      result.error.should eq boom
      # The step never committed, so the pointer stays at "cave".
      result.id.should eq "cave"
      service.current_state.id.should eq "cave"
    end

    it "fires on_event_processed with the Failed snapshot and not on_transition" do
      ctx : TurnContext = TurnContext.new
      boom : Exception = Exception.new("guard raised")
      captured : FSM::State? = nil
      transition_fired : Bool = false

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") { |t| t.guard { |_e, _c| raise boom } }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
        observers.on_transition { |_snapshot| transition_fired = true }
        observers.on_event_processed { |snapshot| captured = snapshot }
      end

      service.send("north")

      # Once planning is inside the envelope, a raising guard is a failed step: it
      # fires on_event_processed with the Failed snapshot and does not fire
      # on_transition, because no transition completed.
      snapshot : FSM::State? = captured
      snapshot.should be_a(FSM::State)
      if snapshot
        snapshot.status.should eq FSM::Status::Failed
        snapshot.error.should eq boom
        snapshot.id.should eq "cave"
      end

      transition_fired.should be_false
    end
  end

  describe "an on_transition observer that raises on a successful step" do
    it "still fires on_event_processed, keeps the transition committed, and re-raises the first exception" do
      ctx : TurnContext = TurnContext.new
      transition_error : Exception = Exception.new("on_transition raised on a successful step")
      captured : FSM::State? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
        observers.on_transition { |_snapshot| raise transition_error }
        observers.on_event_processed { |snapshot| captured = snapshot }
      end

      # The first observer exception reaches the caller: this is the
      # sync interpreter, where a calling fiber receives the failure.
      expect_raises(Exception, "on_transition raised on a successful step") do
        service.send("north")
      end

      # The step committed before observers fired, so the pointer moved even though
      # on_transition then raised.
      service.current_state.id.should eq "clearing"

      # on_event_processed still fired after on_transition raised, and received the
      # accurate committed snapshot (it fires after every step).
      snapshot : FSM::State? = captured
      snapshot.should be_a(FSM::State)
      if snapshot
        snapshot.id.should eq "clearing"
        snapshot.status.should eq FSM::Status::Success
      end
    end

    it "fires both observers and re-raises the first (on_transition) exception when both raise" do
      ctx : TurnContext = TurnContext.new
      transition_error : Exception = Exception.new("on_transition raised first")
      processed_error : Exception = Exception.new("on_event_processed raised second")
      processed_fired : Bool = false

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
        observers.on_transition { |_snapshot| raise transition_error }
        observers.on_event_processed do |_snapshot|
          processed_fired = true
          raise processed_error
        end
      end

      # on_transition fires first, so its exception is the first one and remains
      # authoritative (the rule AsyncService's fire_observers follows); the later
      # on_event_processed exception is discarded.
      expect_raises(Exception, "on_transition raised first") do
        service.send("north")
      end

      # on_event_processed fired despite on_transition raising first.
      processed_fired.should be_true
      service.current_state.id.should eq "clearing"
    end
  end

  describe "an on_event_processed observer that raises on a successful step" do
    # Pins existing behavior: with a clean on_transition, an on_event_processed handler
    # that raises on a non-failed (here successful-transition) step runs unguarded and
    # its exception propagates out of send. This mirrors the blocked-step case already
    # covered in spec/on_event_processed_spec.cr and is the single successful-step case
    # the design leaves propagating.
    it "propagates the on_event_processed exception out of send, transition committed" do
      ctx : TurnContext = TurnContext.new
      processed_error : Exception = Exception.new("on_event_processed raised on success")
      transition_fired : Bool = false

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
        observers.on_transition { |_snapshot| transition_fired = true }
        observers.on_event_processed { |_snapshot| raise processed_error }
      end

      expect_raises(Exception, "on_event_processed raised on success") do
        service.send("north")
      end

      # on_transition ran cleanly before on_event_processed raised, and the step
      # committed.
      transition_fired.should be_true
      service.current_state.id.should eq "clearing"
    end
  end
end

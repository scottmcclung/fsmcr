require "./spec_helper"

# The on_event_processed observer (design section 9, section 10.3 step 20, D19).
#
# on_event_processed is registered on the interpreter and fires after EVERY send,
# regardless of outcome: a successful transition, a guard-blocked event, or an
# unknown event. It is the "after every step" half of the pair whose "on change"
# half is on_transition, which fires only when a transition actually occurred
# (design section 9). A consumer writes state back to an entity after any event with
# on_event_processed and relocates an entity only on a real change with on_transition.
#
# The handler receives the State snapshot the step produced (design section 10.3 step
# 20): the new state on success, the unchanged state on a blocked or unknown event,
# and the Failed snapshot on a step where a callback raised. Per D15 the snapshot does
# not signal which of the three transition outcomes occurred; outcome discrimination
# is deliberately not part of the handler's payload.
#
# On a failed step (a callback raised, design section 11) on_transition does NOT fire,
# because no transition completed, while on_event_processed DOES fire and receives the
# Failed snapshot (D19). An observer that itself raises while handling a failed step is
# an edge case the design defines by the invariant that the first exception is the one
# already recorded in the snapshot (design section 9): the observer's own exception
# does not replace the callback exception the snapshot already carries.
#
# Observers are registered through the builder block interpret yields, which hands the
# block an ObserverRegistrar (src/fsm/observer_registrar.cr). The handlers are copied
# once into the service and the registrar is sealed before interpret returns, so a
# live service has no observer setter (design section 5).
describe "on_event_processed" do
  it "fires after a successful transition, receiving the new-state snapshot" do
    ctx : TurnContext = TurnContext.new
    captured : FSM::State? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    # The call-site block parameter is left bare; Crystal rejects a type annotation
    # there. The captured value is typed as FSM::State? above.
    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_event_processed { |snapshot| captured = snapshot }
    end

    service.send("north")

    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      # The handler receives the snapshot the step produced (step 20): the new state.
      snapshot.id.should eq "clearing"
      snapshot.status.should eq FSM::Status::Success
    end
  end

  it "fires after a blocked event, receiving the unchanged-state snapshot" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    captured : FSM::State? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("too steep") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_event_processed { |snapshot| captured = snapshot }
    end

    service.send("north")

    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      # A blocked event moved nowhere, so the snapshot carries the unchanged id
      # (design section 3.3, step 14).
      snapshot.id.should eq "cave"
    end
  end

  it "fires after an unknown event, receiving the unchanged-state snapshot" do
    ctx : TurnContext = TurnContext.new
    captured : FSM::State? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |_e, c| c.say("no such way") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_event_processed { |snapshot| captured = snapshot }
    end

    service.send("xyzzy")

    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      # An unknown event moved nowhere, so the snapshot carries the unchanged id.
      snapshot.id.should eq "cave"
    end
  end

  it "fires after every send, across blocked, unknown, and successful outcomes" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    fire_count : Int32 = 0

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("too steep") }
        s.on_unknown_event { |_e, c| c.say("no such way") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_event_processed { |_snapshot| fire_count += 1 }
    end

    service.send("north") # blocked: guard rejects while rope is not secured
    service.send("xyzzy") # unknown: no transition registered for this event
    ctx.rope_secured = true
    service.send("north") # successful: the guard now passes

    # One fire per send, regardless of outcome (design section 9).
    fire_count.should eq 3
    service.current_state.should eq "clearing"
  end

  it "fires on_event_processed but not on_transition for a blocked event" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    processed_fired : Bool = false
    transition_fired : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("too steep") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_transition { |_snapshot| transition_fired = true }
      observers.on_event_processed { |_snapshot| processed_fired = true }
    end

    service.send("north")

    # "after every step" fires on a blocked event; "on change" does not, because
    # nothing changed (design section 9).
    processed_fired.should be_true
    transition_fired.should be_false
  end

  it "fires on_event_processed but not on_transition for an unknown event" do
    ctx : TurnContext = TurnContext.new
    processed_fired : Bool = false
    transition_fired : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |_e, c| c.say("no such way") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_transition { |_snapshot| transition_fired = true }
      observers.on_event_processed { |_snapshot| processed_fired = true }
    end

    service.send("xyzzy")

    processed_fired.should be_true
    transition_fired.should be_false
  end

  it "fires both observers on a successful transition, on_transition before on_event_processed" do
    ctx : TurnContext = TurnContext.new
    order : Array(String) = [] of String

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      # Registered on_event_processed first to show the firing order is fixed by the
      # step-20 sequence (on_transition, then on_event_processed), not by registration
      # order (design section 10.3 step 20).
      observers.on_event_processed { |_snapshot| order << "processed" }
      observers.on_transition { |_snapshot| order << "transition" }
    end

    service.send("north")

    order.should eq ["transition", "processed"]
  end

  it "fires on_event_processed with the Failed snapshot on a failed step, and not on_transition" do
    ctx : TurnContext = TurnContext.new
    boom : Exception = Exception.new("entry callback raised")
    captured : FSM::State? = nil
    transition_fired : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") do |s|
        # Entering "clearing" raises, so the step fails part-way and never commits
        # (design section 11): the state pointer stays at "cave".
        s.on_entry { |_e, _c| raise boom }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_transition { |_snapshot| transition_fired = true }
      observers.on_event_processed { |snapshot| captured = snapshot }
    end

    # The returning path surfaces failure as a value, not a raise (design section 11).
    result : FSM::State = service.send("north")

    result.status.should eq FSM::Status::Failed
    result.error.should eq boom
    # The state pointer did not move (design section 11).
    result.id.should eq "cave"

    # on_event_processed fired and received the Failed snapshot (D19).
    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      snapshot.status.should eq FSM::Status::Failed
      snapshot.error.should eq boom
      snapshot.id.should eq "cave"
    end

    # on_transition did not fire, because no transition completed (D19).
    transition_fired.should be_false
  end

  it "keeps the first recorded exception when the observer itself raises on a failed step" do
    ctx : TurnContext = TurnContext.new
    callback_error : Exception = Exception.new("entry callback raised")
    observer_error : Exception = Exception.new("observer raised")
    captured : FSM::State? = nil
    transition_fired : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") do |s|
        s.on_entry { |_e, _c| raise callback_error }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_transition { |_snapshot| transition_fired = true }
      # The observer captures the snapshot it was handed, then raises. Per design
      # section 9 the first exception (the callback's) is the one already recorded in
      # the snapshot, so the observer's own exception must not replace it, and the
      # returning path must still hand back the Failed value rather than raising
      # observer_error (design section 11).
      observers.on_event_processed do |snapshot|
        captured = snapshot
        raise observer_error
      end
    end

    result : FSM::State = service.send("north")

    # The recorded failure is the first exception, not the observer's.
    result.status.should eq FSM::Status::Failed
    result.error.should eq callback_error
    result.id.should eq "cave"

    # The snapshot the observer received already carried the first exception.
    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      snapshot.error.should eq callback_error
    end

    transition_fired.should be_false
  end

  it "propagates the observer's own exception out of send on a non-failed (blocked) step" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    observer_error : Exception = Exception.new("observer raised on blocked")

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("too steep") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      # A blocked step is a successful transaction that moved nowhere (design section
      # 3.3), so its snapshot status is Success. fire_event_processed runs the observer
      # unguarded on a non-failed snapshot, so an exception it raises propagates out of
      # send rather than being discarded. This asymmetry with the failed-step branch,
      # which discards the observer's exception so the first recorded one wins (design
      # section 9), is intentional and matches on_transition's pre-existing behavior.
      observers.on_event_processed { |_snapshot| raise observer_error }
    end

    expect_raises(Exception, "observer raised on blocked") do
      service.send("north")
    end
  end

  it "turns a raising on_blocked handler into a Failed step: on_event_processed sees it, on_transition does not" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    handler_error : Exception = Exception.new("on_blocked raised")
    captured : FSM::State? = nil
    transition_fired : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        # The Blocked action is an ordinary planned action, so a raising on_blocked
        # handler fails the step part-way like any other callback (design section 10.2
        # step 15, step 17->19). The step never commits, so the pointer stays at "cave".
        s.on_blocked("north") { |_e, _c, _blocked| raise handler_error }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_transition { |_snapshot| transition_fired = true }
      observers.on_event_processed { |snapshot| captured = snapshot }
    end

    # send's begin/rescue wraps every planned action, including the Blocked one, so the
    # raising handler surfaces as a Failed value rather than a raise (design section 11).
    result : FSM::State = service.send("north")

    result.status.should eq FSM::Status::Failed
    result.error.should eq handler_error
    # The state pointer did not move (design section 11).
    result.id.should eq "cave"

    # on_event_processed fired and received that same Failed snapshot (D19).
    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      snapshot.status.should eq FSM::Status::Failed
      snapshot.error.should eq handler_error
      snapshot.id.should eq "cave"
    end

    # on_transition did not fire, because no transition completed (D19).
    transition_fired.should be_false
  end
end

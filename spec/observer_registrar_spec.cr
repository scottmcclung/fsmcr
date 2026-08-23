require "./spec_helper"

# Observers registered by construction (design section 9, section 10.3 step 20,
# D19, fsmcr-erl).
#
# The mutable registration setters Service#on_transition and Service#on_event_processed
# are gone. A live service has no observer setter. Instead Service.interpret takes an
# optional builder block and yields an observer registrar. Observers are collected in
# the registrar during the block and copied once into the service at construction, the
# same build-then-seal idiom the Machine and State builders use (design section 4,
# section 5): a partially-built thing is registered inside the block and frozen at the
# end, so no caller can mutate observers on the live interpreter.
#
#     service = FSM::Service.interpret(machine, "idle", ctx) do |observers|
#       observers.on_event_processed { |snapshot| entity.write_back(snapshot) }
#       observers.on_transition { |snapshot| audit.record(snapshot.id) }
#     end
#
# The firing contract is unchanged from the setter era (design section 9, D19): on_transition
# fires only on a completed transition; on_event_processed fires after every step regardless
# of outcome and receives the snapshot the step produced; on_transition runs before
# on_event_processed on success; on a failed step on_transition is silent and on_event_processed
# receives the Failed snapshot; an observer that raises on a failed step is discarded so the
# first exception (already in the snapshot) wins; an observer that raises on a non-failed step
# propagates out of send. These specs prove observers wired through the registrar honor that
# contract, and pin the registrar-specific behavior: registration through the block, the
# no-block overload, last-wins within the block, and the registrar going inert after interpret
# returns.
#
# Inert-after-return precedent (design section 5): StateDefinition and Transition raise
# SealedStateError from every builder method once the machine seals them. The registrar follows
# the same precedent. Once interpret has copied the observers and returned, calling on_transition
# or on_event_processed on the escaped registrar raises SealedStateError.
describe "Service observer registrar" do
  it "fires an on_event_processed observer registered through the block after a successful transition" do
    ctx : TurnContext = TurnContext.new
    captured : FSM::State? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_event_processed { |snapshot| captured = snapshot }
    end

    service.send("north")

    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      # The observer receives the snapshot the step produced (step 20): the new state.
      snapshot.id.should eq "clearing"
      snapshot.status.should eq FSM::Status::Success
    end
  end

  it "fires an on_transition observer registered through the block only on a completed transition" do
    ctx : TurnContext = TurnContext.new
    captured : FSM::State? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      observers.on_transition { |snapshot| captured = snapshot }
    end

    service.send("north")

    snapshot : FSM::State? = captured
    snapshot.should be_a(FSM::State)
    if snapshot
      snapshot.id.should eq "clearing"
      snapshot.status.should eq FSM::Status::Success
    end
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

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") do |s|
        s.on_entry { |_e, _c| raise callback_error }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      # The observer raises while handling the failed step. Per design section 9 the
      # first exception (the callback's) is already recorded in the snapshot, so the
      # observer's own exception must be discarded and the returning path must still
      # hand back the Failed value rather than raising observer_error (design section 11).
      observers.on_event_processed { |_snapshot| raise observer_error }
    end

    result : FSM::State = service.send("north")

    # The recorded failure is the first exception, not the observer's.
    result.status.should eq FSM::Status::Failed
    result.error.should eq callback_error
    result.id.should eq "cave"
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
      # 3.3), so its snapshot status is Success. The observer runs unguarded on a
      # non-failed snapshot, so an exception it raises propagates out of send rather
      # than being discarded (design section 9).
      observers.on_event_processed { |_snapshot| raise observer_error }
    end

    expect_raises(Exception, "observer raised on blocked") do
      service.send("north")
    end
  end

  it "constructs a service with no observers when interpret is called without a block" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    # The no-block overload constructs a working service that registers no observers.
    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)

    result : FSM::State = service.send("north")

    result.id.should eq "clearing"
    result.status.should eq FSM::Status::Success
    service.current_state.should eq "clearing"
  end

  it "keeps the last registration when the same observer is registered twice within the block" do
    ctx : TurnContext = TurnContext.new
    first_fired : Bool = false
    second_fired : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      # A single slot per observer: the last registration within the block wins, the
      # same last-write-wins semantics the state builder uses for on_entry and on_exit
      # (src/fsm/state_definition.cr).
      observers.on_event_processed { |_snapshot| first_fired = true }
      observers.on_event_processed { |_snapshot| second_fired = true }
    end

    service.send("north")

    first_fired.should be_false
    second_fired.should be_true
  end

  it "makes the registrar inert after interpret returns, raising SealedStateError like a sealed builder" do
    ctx : TurnContext = TurnContext.new
    registrar : FSM::ObserverRegistrar? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    # Escape the registrar out of the block to reach it after interpret has copied the
    # observers and returned.
    FSM::Service(TurnContext).interpret(machine, "cave", ctx) do |observers|
      registrar = observers
    end

    escaped : FSM::ObserverRegistrar? = registrar
    escaped.should be_a(FSM::ObserverRegistrar)
    if escaped
      # Mirroring StateDefinition and Transition, whose builder methods raise
      # SealedStateError once the machine seals them (design section 5). The registrar
      # is frozen when interpret returns, so late registration through the escaped
      # reference cannot mutate the live service's observers.
      expect_raises(FSM::SealedStateError) do
        escaped.on_transition { |_snapshot| }
      end
      expect_raises(FSM::SealedStateError) do
        escaped.on_event_processed { |_snapshot| }
      end
    end
  end
end

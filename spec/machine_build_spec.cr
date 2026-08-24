require "./spec_helper"

# Construction is a machine-scoped builder (design section 4, D2):
#   Machine(T).build(id) { |m| m.state("id") { |s| ... } }
# replacing the old array-of-states form (`Machine.create(id, states)`), which no
# longer exists. `m.state` infers `T` from the enclosing builder, so `T` is named
# once per machine, and no partially-built state escapes the block as a loose local.
# At the end of the block the builder validates that every transition target names
# an existing state, then seals every definition and transition.
#
# Duplicate-state-id detection (fsmcr-dy7): no two states share an id, so registering
# m.state("cave") twice raises DuplicateStateError rather than silently overwriting the
# first definition (design section 4).
describe "Machine(T).build" do
  it "returns a Machine(T) carrying the given id and its states" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("worker") do |m|
      m.state("idle") { |s| s.on_event("start", "running") }
      m.state("running") { |s| s.on_event("stop", "idle") }
    end

    machine.id.should eq "worker"
    machine.states.keys.should contain "idle"
    machine.states.keys.should contain "running"
  end

  it "returns a copy from #states so the internal definition cannot be mutated through it" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("worker") do |m|
      m.state("idle") { |s| s.on_event("start", "running") }
      m.state("running") { |s| s.on_event("stop", "idle") }
    end

    copy : Hash(String, FSM::StateDefinition(FSM::Context)) = machine.states
    copy.delete("idle")

    machine.states.keys.should contain "idle"
  end

  it "raises MissingTargetStateError when a transition targets a state that does not exist" do
    expect_raises(FSM::MissingTargetStateError) do
      FSM::Machine(FSM::Context).build("test_machine") do |m|
        m.state("state1") { |s| s.on_event("event1", "undefined_state") }
      end
    end
  end

  it "raises DuplicateStateError when two states share an id, naming the duplicated id" do
    # No two states share an id: the second m.state("idle") raises rather than
    # silently overwriting the first, whose transitions would otherwise be discarded
    # (design section 4). The message names the duplicated id so the caller can find
    # the offending registration.
    error : FSM::DuplicateStateError = expect_raises(FSM::DuplicateStateError) do
      FSM::Machine(FSM::Context).build("worker") do |m|
        m.state("idle") { |s| s.on_event("start", "running") }
        m.state("idle") { |s| s.on_event("halt", "running") }
        m.state("running") { |s| s.on_event("stop", "idle") }
      end
    end

    message : String? = error.message
    message.should_not be_nil
    if message
      message.should contain "idle"
    end
  end

  it "raises a DuplicateStateError that is a StateMachineError" do
    # DuplicateStateError follows the errors.cr idiom: it descends from
    # StateMachineError, so a caller rescuing the library's base error catches it
    # alongside MissingTargetStateError and InvalidInitialStateError.
    error : FSM::StateMachineError = expect_raises(FSM::StateMachineError) do
      FSM::Machine(FSM::Context).build("worker") do |m|
        m.state("idle") { |s| }
        m.state("idle") { |s| }
      end
    end

    error.should be_a FSM::DuplicateStateError
  end

  it "raises at the duplicate m.state call rather than deferring to the end of the block" do
    # Design section 4 says registering m.state("cave") twice raises, i.e. the raise
    # is the act of the second registration, not a deferred finish-time validation.
    # A later state block therefore never runs: if the duplicate raised, control left
    # the build block before reaching it, so the flag stays false. A finish-time check
    # would run every block first and the flag would be true.
    reached_later_block : Bool = false

    expect_raises(FSM::DuplicateStateError) do
      FSM::Machine(FSM::Context).build("worker") do |m|
        m.state("idle") { |s| }
        m.state("idle") { |s| }
        m.state("running") do |s|
          reached_later_block = true
          s.on_event("stop", "idle")
        end
      end
    end

    reached_later_block.should be_false
  end

  it "is unaffected by unique ids: both states are present and functional" do
    # A build whose state ids are all unique registers every definition and runs
    # normally; the duplicate-id check does not disturb it.
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("worker") do |m|
      m.state("idle") { |s| s.on_event("start", "running") }
      m.state("running") { |s| s.on_event("stop", "idle") }
    end

    machine.states.keys.should contain "idle"
    machine.states.keys.should contain "running"

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "idle", FSM::Context.new)
    service.send("start")
    service.matches?("running").should be_true
    service.send("stop")
    service.matches?("idle").should be_true
  end

  it "builds over an arbitrary domain type T and threads it to a guard" do
    ctx : TurnContext = TurnContext.new(rope_secured: true)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") do |t|
          t.guard { |_event, c| c.rope_secured }
        end
      end
      m.state("clearing") { |s| s.on_event("south", "cave") }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    service.current_state.id.should eq "clearing"
  end

  it "does not treat state ids as shared across separate Machine.build calls" do
    # Each Machine.build call uses its own builder with its own id registry, so the
    # same state id may appear in two independent machines without either build
    # raising DuplicateStateError (fsmcr-dy7).
    first : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("a") do |m|
      m.state("idle") { |s| s.on_event("start", "idle") }
    end
    second : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("b") do |m|
      m.state("idle") { |s| s.on_event("start", "idle") }
    end

    first.states.keys.should contain "idle"
    second.states.keys.should contain "idle"
  end

  it "does not depend on a state block's final expression to register the state" do
    # The builder must register the state regardless of what the block returns,
    # so a block ending in a non-state value still yields a working definition.
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("go", "state2")
        "not a state"
      end
      m.state("state2") { |s| nil }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new)
    service.send("go")

    service.matches?("state2").should be_true
  end
end

# Service(T).interpret validates the initial state against the sealed machine
# (design section 10.2, step 5).
describe "Service(T).interpret" do
  it "raises InvalidInitialStateError when the initial state is not in the machine" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| }
      m.state("state2") { |s| }
    end

    expect_raises(FSM::InvalidInitialStateError) do
      FSM::Service(FSM::Context).interpret(machine, "invalid_state", FSM::Context.new)
    end
  end
end

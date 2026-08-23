require "./spec_helper"

# Construction is a machine-scoped builder (design section 4, D2):
#   Machine(T).build(id) { |m| m.state("id") { |s| ... } }
# replacing the old array-of-states form (`Machine.create(id, states)`), which no
# longer exists. `m.state` infers `T` from the enclosing builder, so `T` is named
# once per machine, and no partially-built state escapes the block as a loose local.
# At the end of the block the builder validates that every transition target names
# an existing state, then seals every definition and transition.
#
# The type of the yielded builder `m` is left unannotated: design section 4 names
# the construction path but not the builder's own type, so annotating it here would
# invent surface the implementer has not been given. That is flagged as an open
# question for the implementer.
#
# Out of scope here: duplicate-state-id detection is tracked separately as fsmcr-dy7.
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

    service.current_state.should eq "clearing"
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

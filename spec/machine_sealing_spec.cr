require "./spec_helper"

# Group 3: sealing after build.
#
# Once Machine.create consumes a state, the definition is shared and must not be
# mutable. Calling a builder method on a consumed state, or on a state handed
# back by Service#send, must raise. Sealing is idempotent: the same states array
# may build more than one machine.
describe "machine sealing" do
  it "raises when on_event is called on a state after the machine consumes it" do
    state : FSM::State = FSM::State.create("state1")
    FSM::Machine.create("test_machine", [state])

    expect_raises(FSM::SealedStateError) do
      state.on_event("go", "state1")
    end
  end

  it "raises when the block form of on_event is called on a state after the machine consumes it" do
    state : FSM::State = FSM::State.create("state1")
    FSM::Machine.create("test_machine", [state])

    expect_raises(FSM::SealedStateError) do
      state.on_event("go", "state1") { |transition| transition }
    end
  end

  it "raises when on_entry is called on a state after the machine consumes it" do
    state : FSM::State = FSM::State.create("state1")
    FSM::Machine.create("test_machine", [state])

    expect_raises(FSM::SealedStateError) do
      state.on_entry { |event, context| }
    end
  end

  it "raises when on_exit is called on a state after the machine consumes it" do
    state : FSM::State = FSM::State.create("state1")
    FSM::Machine.create("test_machine", [state])

    expect_raises(FSM::SealedStateError) do
      state.on_exit { |event, context| }
    end
  end

  it "does not allow mutating the machine through a State returned by Service#send" do
    state1 : FSM::State = FSM::State.create("state1").on_event("go", "state2")
    state2 : FSM::State = FSM::State.create("state2")

    machine : FSM::Machine = FSM::Machine.create("test_machine", [state1, state2])
    service : FSM::Service = FSM::Service.interpret(machine, "state1")

    returned : FSM::State = service.send("go")

    expect_raises(FSM::SealedStateError) do
      returned.on_event("other", "state1")
    end
  end

  it "seals idempotently so the same states array can build a second machine" do
    states : Array(FSM::State) = [
      FSM::State.create("state1").on_event("go", "state2"),
      FSM::State.create("state2"),
    ]

    FSM::Machine.create("machine_a", states)
    second : FSM::Machine = FSM::Machine.create("machine_b", states)

    second.should be_a(FSM::Machine)
  end
end

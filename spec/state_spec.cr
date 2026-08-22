require "./spec_helper"

describe FSM::State do
  # A State is a class, so `Array#each` yields the shared object. Registering a
  # callback while iterating writes to the state stored in the array, and the
  # callback fires during a transition. These specs register entry and exit
  # callbacks through iteration and assert they actually fire.
  context "callbacks registered while iterating the states array" do
    it "fires an on_entry callback registered while iterating the states array" do
      entry_called : Bool = false

      states : Array(FSM::State) = [
        FSM::State.create("state1").on_event("go", "state2"),
        FSM::State.create("state2"),
      ]

      states.each do |state|
        if state.id == "state2"
          state.on_entry { |event, context| entry_called = true }
        end
      end

      machine : FSM::Machine = FSM::Machine.create("test_machine", states)
      service : FSM::Service = FSM::Service.interpret(machine, "state1")

      service.send("go")

      entry_called.should be_true
    end

    it "fires an on_exit callback registered while iterating the states array" do
      exit_called : Bool = false

      states : Array(FSM::State) = [
        FSM::State.create("state1").on_event("go", "state2"),
        FSM::State.create("state2"),
      ]

      states.each do |state|
        if state.id == "state1"
          state.on_exit { |event, context| exit_called = true }
        end
      end

      machine : FSM::Machine = FSM::Machine.create("test_machine", states)
      service : FSM::Service = FSM::Service.interpret(machine, "state1")

      service.send("go")

      exit_called.should be_true
    end
  end

  # State.create(id) { |s| ... } must always return a State, no matter what the
  # block's final expression evaluates to. The block's last expression is
  # deliberately not the state.
  context "block form of State.create" do
    it "returns the State when the block's last expression is a String" do
      state : FSM::State = FSM::State.create("state1") do |s|
        s.on_event("go", "state2")
        "not a state"
      end

      state.should be_a(FSM::State)
      state.id.should eq "state1"
    end

    it "returns the State when the block's last expression is nil" do
      state : FSM::State = FSM::State.create("state2") do |s|
        nil
      end

      state.should be_a(FSM::State)
      state.id.should eq "state2"
    end
  end
end

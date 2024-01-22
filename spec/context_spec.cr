require "./spec_helper"

describe FSM::Context do
  context "Initialization" do
    it "initializes with empty data when no initial data is provided" do
      machine = FSM::Machine.create("test_machine", [
        FSM::State.create("state1")
          .on_event("change", "state2")
          .on_exit { |event, context| context.data.should be_empty },
        FSM::State.create("state2"),
      ])
      service = FSM::Service.interpret(machine, "state1")
      service.send("change")
      service.current_state.should eq "state2"
    end

    it "initializes with provided initial data" do
      initial_data = {"key1" => "value1", "key2" => "value2"}

      machine = FSM::Machine.create("test_machine", [
        FSM::State.create("state1")
          .on_event("change", "state2")
          .on_exit do |event, context|
            context.get("key1").should eq "value1"
            context.get("key2").should eq "value2"
          end,
        FSM::State.create("state2"),
      ])
      service = FSM::Service.interpret(machine, "state1", initial_data)
      service.send("change")
      service.current_state.should eq "state2"
    end

    it "creates its own copy of the context data to avoid unintentional modification" do
      initial_data = {"key1" => "value1", "key2" => "value2"}

      machine = FSM::Machine.create("test_machine", [
        FSM::State.create("state1")
          .on_event("change", "state2")
          .on_exit do |event, context|
            context.get("key1").should eq "value1"
            context.get("key2").should eq "value2"
          end,
        FSM::State.create("state2"),
      ])
      service = FSM::Service.interpret(machine, "state1", initial_data)
      initial_data["key1"] = "some other value"
      service.send("change")
      service.current_state.should eq "state2"
    end
  end

  context "Getting and Setting Data" do
    it "sets and retrieves a value for a key" do
      machine = FSM::Machine.create("test_machine", [
        FSM::State.create("state1")
          .on_event("change", "state2")
          .on_exit { |event, context| context.set("key", "value") },
        FSM::State.create("state2")
          .on_entry { |event, context| context.get("key").should eq "value" },
      ])
      service = FSM::Service.interpret(machine, "state1")
      service.send("change")
      service.current_state.should eq "state2"
    end

    it "returns nil for a non-existent key" do
      machine = FSM::Machine.create("test_machine", [
        FSM::State.create("state1")
          .on_event("change", "state2")
          .on_exit { |event, context| context.set("key", "value") },
        FSM::State.create("state2")
          .on_entry { |event, context| context.get("nonexistent_key").should be_nil },
      ])
      service = FSM::Service.interpret(machine, "state1")
      service.send("change")
      service.current_state.should eq "state2"
    end
  end

  it "should not allow modification of the context data directly" do
    initial_data = {"key1" => "value1", "key2" => "value2"}

    machine = FSM::Machine.create("test_machine", [
      FSM::State.create("state1")
        .on_event("change", "state2")
        .on_exit do |event, context|
          context.data["key1"].should eq "value1"
          context.data["key1"] = "new_value"
        end,
      FSM::State.create("state2")
        .on_entry { |event, context| context.get("key1").should eq "value1" },
    ])
    service = FSM::Service.interpret(machine, "state1", initial_data)
    service.send("change")
    service.current_state.should eq "state2"
  end

  context "Modifying Data" do
    it "correctly modifies an existing value" do
      initial_data = {"key" => "initial"}

      machine = FSM::Machine.create("test_machine", [
        FSM::State.create("state1")
          .on_event("change", "state2")
          .on_exit do |event, context|
            context.modify("key") { |value| "#{value} modified" }
          end,
        FSM::State.create("state2")
          .on_entry { |event, context| context.get("key").should eq "initial modified" },
      ])
      service = FSM::Service.interpret(machine, "state1", initial_data)
      service.send("change")
      service.current_state.should eq "state2"
    end

    it "handles modification of a non-existent key gracefully" do
      machine = FSM::Machine.create("test_machine", [
        FSM::State.create("state1")
          .on_event("change", "state2")
          .on_exit do |event, context|
            context.modify("key") { |value| "#{value || "default"} modified" }
          end,
        FSM::State.create("state2")
          .on_entry { |event, context| context.get("key").should eq "default modified" },
      ])
      service = FSM::Service.interpret(machine, "state1")
      service.send("change")
      service.current_state.should eq "state2"
    end
  end
end

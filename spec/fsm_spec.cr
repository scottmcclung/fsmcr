require "./spec_helper"

describe FSM::Service do
  it "transitions to the initial state on creation" do
    states = [
      FSM::State.create("state1"),
      FSM::State.create("state2"),
      FSM::State.create("state3"),
    ]

    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")
    service.current_state.should eq "state1"
  end

  it "correctly transitions between states on valid events" do
    states = [
      FSM::State.create("state1").on_event("event1", "state2"),
      FSM::State.create("state2"),
    ]

    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")

    service.send("event1")

    service.current_state.should eq "state2"
  end

  it "does not transition on invalid events" do
    states = [
      FSM::State.create("state1").on_event("event1", "state2"),
      FSM::State.create("state2"),
    ]

    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")

    service.send("invalid_event")

    service.current_state.should eq "state1"
  end

  it "executes entry and exit actions during transitions" do
    entry_action_called = false
    exit_action_called = false

    state1 = FSM::State.create("state1")
      .on_event("event1", "state2")
      .on_exit { |event, context| exit_action_called = true }

    state2 = FSM::State.create("state2")
      .on_entry { |event, context| entry_action_called = true }

    states = [state1, state2]

    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")

    service.send("event1")

    entry_action_called.should eq true
    exit_action_called.should eq true
  end

  it "runs state change callback on transition" do
    state_change_callback_called = false

    states = [
      FSM::State.create("state1").on_event("event1", "state2"),
      FSM::State.create("state2"),
    ]

    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")

    service.subscribe { |new_state| state_change_callback_called = true }

    service.send("event1")

    state_change_callback_called.should eq true
  end

  it "executes transition callback on valid state change" do
    transition_callback_called = false

    state1 = FSM::State.create("state1")
      .on_event("event1", "state2") do |transition|
        transition.on { |event, context| transition_callback_called = true }
      end

    state2 = FSM::State.create("state2")

    states = [state1, state2]

    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")

    service.send("event1")

    transition_callback_called.should eq true
  end

  it "does not allow construction of a machine with an invalid initial state" do
    states = [
      FSM::State.create("state1"),
      FSM::State.create("state2"),
      FSM::State.create("state3"),
    ]

    expect_raises(Exception, "Expected states to include the initial state.  A state with id invalid_state was not found.") do
      machine = FSM::Machine.create("test_machine", states)
      FSM::Service.interpret(machine, "invalid_state")
    end
  end

  it "does not allow construction of a machine if a state transition targets a non-existant state" do
    states = [
      FSM::State.create("state1") do |s|
        # Event with an undefined target state
        s.on_event("event1", "undefined_state")
      end,
    ]

    expect_raises(Exception, "Invalid target state(s) found in state1 transitions.  Invalid target(s) found: [\"undefined_state\"]") do
      machine = FSM::Machine.create("test_machine", states)
    end
  end

  it "does not transition on events that the state should not respond to" do
    state1 = FSM::State.create("state1").on_event("event1", "state2")
    state2 = FSM::State.create("state2")

    states = [state1, state2]
    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")

    # Attempt to transition on an event not defined for the current state
    service.send("invalid_event")

    service.current_state.should eq "state1"
  end

  it "handles concurrent state changes gracefully" do
    states = [
      FSM::State.create("state1")
        .on_event("event1", "state2") do |transition|
          transition.on do |event, context|
            # Simulate a time-consuming operation during the transition
            sleep(1)
          end
        end,

      FSM::State.create("state2"),
    ]

    machine = FSM::Machine.create("test_machine", states)
    service = FSM::Service.interpret(machine, "state1")

    # Start transitioning to state2 in the background
    spawn { service.send("event1") }

    # Attempt another transition immediately
    service.send("event1")

    # Ensure that the second transition did not interfere with the first one
    service.current_state.should eq "state2"
  end

  context "concurrency test with complex FSM setup" do
    it "handles multiple threads invoking a variety of state transitions concurrently" do
      # Define 10 unique states
      states = 10.times.map { |i| FSM::State.create("state#{i}") }.to_a

      # Define at least 5 transitions for each state
      states.each_with_index do |state, i|
        5.times do |j|
          target_state_index = (i + j + 1) % 10 # Ensures a variety of target states
          state.on_event("event#{i}_to_#{target_state_index}", "state#{target_state_index}")
        end
      end

      # Initialize FSM
      machine = FSM::Machine.create("test_machine", states)
      service = FSM::Service.interpret(machine, states.first.id)

      threads = [] of Thread
      100.times do |i|
        threads << Thread.new do
          current_state_index = i % 10
          event_index = (i / 10) % 5
          event = "event#{current_state_index}_to_#{(current_state_index + event_index + 1) % 10}"
          service.send(event)
        end
      end

      threads.each(&.join)

      # No specific assertion as this test focuses on ensuring no race conditions or exceptions
      # The final state depends on the timing and order of thread execution which is non-deterministic
    end
  end
end

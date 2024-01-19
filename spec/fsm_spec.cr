require "./spec_helper"

describe FSM::Machine do
  it "transitions between states based on events" do
    state_machine = FSM::Machine.new

    # Configure possible states and transitions
    state_machine.add_transitions("Start", [
      FSM::Transition.new(event: "Trigger", to: "Middle"),
      FSM::Transition.new(event: "Reset", to: "Start"),
    ])

    state_machine.add_transitions("Middle", [
      FSM::Transition.new(event: "Complete", to: "End"),
      FSM::Transition.new(event: "Reset", to: "Start"),
    ])

    # Initial state
    current_state = "Start"

    # Trigger events
    current_state = state_machine.transition(current_state, "Trigger")
    current_state.should eq "Middle"

    current_state = state_machine.transition(current_state, "InvalidEvent")
    current_state.should eq "Middle" # Invalid event, stays in Middle

    current_state = state_machine.transition(current_state, "Reset")
    current_state.should eq "Start"

    current_state = state_machine.transition(current_state, "InvalidEvent")
    current_state.should eq "Start" # Invalid event, stays in Start
  end

  it "handles transitions for each state" do
    state_machine = FSM::Machine.new

    # Configure possible states and transitions
    state_machine.add_transitions("Start", [
      FSM::Transition.new(event: "Trigger", to: "Middle"),
      FSM::Transition.new(event: "Reset", to: "Start"),
    ])

    state_machine.add_transitions("Middle", [
      FSM::Transition.new(event: "Complete", to: "End"),
      FSM::Transition.new(event: "Reset", to: "Start"),
    ])

    # Verify transitions for "Start"
    transitions_start = state_machine.transitions["Start"]
    transitions_start.should_not be_nil
    transitions_start.size.should eq 2

    # Verify transitions for "Middle"
    transitions_middle = state_machine.transitions["Middle"]
    transitions_middle.should_not be_nil
    transitions_middle.size.should eq 2
  end
end

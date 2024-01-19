require "./spec_helper"

describe FSM::Machine do
  it "transitions between states based on events" do
    state_machine = FSM::Machine(Stage).new

    # Configure possible states and transitions
    state_machine.add_transitions(Stage::Start, [
      FSM::Transition(Stage).new(event: "Trigger", to: Stage::Middle),
      FSM::Transition(Stage).new(event: "Reset", to: Stage::Start),
    ])

    state_machine.add_transitions(Stage::Middle, [
      FSM::Transition(Stage).new(event: "Complete", to: Stage::End),
      FSM::Transition(Stage).new(event: "Reset", to: Stage::Start),
    ])

    # Initial state
    current_state = Stage::Start

    # Trigger events
    current_state = state_machine.transition(current_state, "Trigger")
    current_state.should eq Stage::Middle

    current_state = state_machine.transition(current_state, "InvalidEvent")
    current_state.should eq Stage::Middle # Invalid event, stays in Middle

    current_state = state_machine.transition(current_state, "Reset")
    current_state.should eq Stage::Start

    current_state = state_machine.transition(current_state, "InvalidEvent")
    current_state.should eq Stage::Start # Invalid event, stays in Start
  end

  it "handles transitions for each state" do
    state_machine = FSM::Machine(Stage).new

    # Configure possible states and transitions
    state_machine.add_transitions(Stage::Start, [
      FSM::Transition.new(event: "Trigger", to: Stage::Middle),
      FSM::Transition.new(event: "Reset", to: Stage::Start),
    ])

    state_machine.add_transitions(Stage::Middle, [
      FSM::Transition.new(event: "Complete", to: Stage::End),
      FSM::Transition.new(event: "Reset", to: Stage::Start),
    ])

    # Verify transitions for Stage::Start
    transitions_start = state_machine.transitions[Stage::Start]
    transitions_start.should_not be_nil
    transitions_start.size.should eq 2

    # Verify transitions for Stage::Middle
    transitions_middle = state_machine.transitions[Stage::Middle]
    transitions_middle.should_not be_nil
    transitions_middle.size.should eq 2
  end
end

enum Stage
  Start
  Middle
  End
end

require "./fsm/*"

module FSM
  # Struct to represent a transition
  struct Transition
    property event : String
    property to : String

    def initialize(@event : String, @to : String)
    end
  end

  # Define the Machine class
  class Machine
    # Initialize a Hash to store state transitions
    property transitions : Hash(String, Array(Transition)) = {} of String => Array(Transition)

    # Add transitions for a specific state
    def add_transitions(state, transitions)
      @transitions[state] = transitions
    end

    # Define a method to perform a transition
    def transition(current_state, event)
      transitions_for_state = @transitions[current_state]

      if transitions_for_state
        transition = transitions_for_state.find { |t| t.event == event }

        if transition
          puts "Transitioning from #{current_state} to #{transition.to}"
          return transition.to
        else
          puts "Invalid event '#{event}' for state #{current_state}"
          return current_state
        end
      else
        puts "Invalid state: #{current_state}"
        return current_state
      end
    end
  end
end

# # Example usage:

# # Create an instance of the FSM::Machine
# state_machine = FSM::Machine.new

# # Configure possible states and transitions
# state_machine.add_transitions("Start", [
#   FSM::Transition.new(event: "Trigger", to: "Middle"),
#   FSM::Transition.new(event: "Reset", to: "Start")
# ])

# state_machine.add_transitions("Middle", [
#   FSM::Transition.new(event: "Complete", to: "End"),
#   FSM::Transition.new(event: "Reset", to: "Start")
# ])

# # Initial state
# current_state = "Start"

# # Trigger events
# current_state = state_machine.transition(current_state, "Trigger") # Transition to Middle
# current_state = state_machine.transition(current_state, "Complete") # Invalid event, stays in Middle
# current_state = state_machine.transition(current_state, "Reset")    # Transition to Start (reset)
# current_state = state_machine.transition(current_state, "InvalidEvent") # Invalid event, stays in Start

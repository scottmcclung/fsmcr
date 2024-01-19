require "./fsm/*"

# See examples directory for an example of how to leverage the FSM in your app
module FSM
  # Struct to represent a transition
  struct Transition(T)
    property event : String
    property to : T

    def initialize(@event : String, @to : T)
    end
  end

  # Define the Machine class
  class Machine(T)
    # Initialize a Hash to store state transitions
    property transitions : Hash(T, Array(Transition(T))) = {} of T => Array(Transition(T))

    # Add transitions for a specific state
    def add_transitions(state : T, transitions : Array(Transition(T))) : self
      @transitions[state] = transitions
      self
    end

    # Define a method to perform a transition
    def transition(current_state : T, event : String) : T
      # No transition made if current state received is unrecognized.
      return current_state unless transitions_for_state = @transitions[current_state]

      # No transition made if the event received is not registered for the current_state
      return current_state unless transition = transitions_for_state.find { |t| t.event == event }

      # Transitions from current_state to transition.to
      transition.to
    end
  end
end

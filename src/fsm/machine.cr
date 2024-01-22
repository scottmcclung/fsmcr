module FSM
  # Represents a finite state machine.
  #
  # @property id [String] The unique identifier of the state machine.
  # @property states [Hash(String, State)] A collection of states associated with the state machine.
  # @property initial_state [State] The initial state of the state machine.
  # @property current_state [State] The current state of the state machine.
  class Machine
    # The unique identifier of the state machine.
    getter id : String

    # A collection of states associated with the state machine.
    getter states : Hash(String, State)

    # Create a new state machine with the given identifier, states, and initial state.
    #
    # @param id [String] The unique identifier of the state machine.
    # @param states [Array(State)] The states associated with the state machine.
    # @param context [Hash(String, Any)] Optional initial data to be registered in the context.
    # @yieldparam self [Machine] The machine instance to be configured.
    def self.create(id : String, states : Array(State))
      states_hash = states.map { |x| {x.id, x} }.to_h
      check_states(states_hash)
      new(id, states_hash)
    end

    # Create a new state machine with the given identifier, states, initial state, and execute a block to set up additional configurations.
    #
    # @param id [String] The unique identifier of the state machine.
    # @param states [Array(State)] The states associated with the state machine.
    # @param context [Hash(String, Any)] Optional initial data to be registered in the context.
    # @yieldparam self [Machine] The machine instance to be configured.
    def self.create(id : String, states : Array(State), &)
      machine = create(id, states)
      machine = yield machine || machine
    end

    # Initialize a new state machine with the given identifier, states, and initial state.
    #
    private def initialize(@id, @states); end

    protected def state_by_id(id : String)
      @states[id]?
    end

    # Static method to handle state transitions.
    #
    # @param states [Hash(String, State)] The states associated with the state machine.
    # @param current_state [State] The current state of the state machine.
    # @param event [String] The event triggering the transition.
    # @return [Tuple(Transition, State)] The transition and the new state after the transition.
    protected def transition(event : String, current_state : State)
      # No transition made if current state received is unrecognized.
      return {nil, current_state} unless state = states[current_state.id]?

      # No transition made if the event received is not registered for the current_state
      return {nil, current_state} unless transition = state.transition(event)

      # No transition made if the target defined on the transition doesn't exist
      return {nil, current_state} unless new_state = states[transition.target]?

      {transition, new_state}
    end

    # Validate that the initial state is present in the states collection and has valid target states.
    #
    # @param states_hash [Hash(String, State)] The states associated with the state machine.
    # @param initial [String] The identifier of the initial state.
    # @raise [InvalidInitialStateError] Raised if the initial state is not present or has invalid target states.
    private def self.check_states(states_by_id : Hash(String, State))
      states_by_id.each do |id, state|
        missing_states = state.all_target_states - states_by_id.keys
        raise MissingTargetStateError.new "Invalid target state(s) found in #{id} transitions.  Invalid target(s) found: #{missing_states} " if missing_states.present?
      end
    end
  end
end

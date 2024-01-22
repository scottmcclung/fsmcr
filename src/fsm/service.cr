module FSM
  class Service
    # The current state of the state machine.
    # TODO: Create context api and inject into callbacks
    @context : Context
    @current_state : State
    @machine : Machine

    @post_transition_callbacks : Nil | (State) ->

    # Mutex to synchronize state transitions
    @transition_mutex : Mutex = Mutex.new

    def current_state : String
      @current_state.id
    end

    private def initialize(@machine : Machine, @current_state : State, context : Hash(String, Any)?)
      @context = Context.new(context)
    end

    def self.interpret(machine : Machine, initial_state : String, context : Hash(String, Any)? = nil)
      current_state = machine.state_by_id(initial_state)
      raise InvalidInitialStateError.new "Expected states to include the initial state.  A state with id #{initial_state} was not found." if !current_state
      new(machine, current_state, context)
    end

    # Check if the state machine is in a specific state.
    #
    # @param state_id [String] The identifier of the state to check.
    # @return [Bool] True if the state machine is in the specified state, false otherwise.
    def matches?(state_id : String)
      state_id === @current_state.id
    end

    # Register a callback to be executed when the state of the machine changes.
    #
    # @yieldparam state [State] The new state after the change.
    def on_transition(&block : (State) ->) : self
      @post_transition_callbacks = block
      self
    end

    # Run the state change callback with the given state.
    #
    # @param state [State] The new state after the change.
    private def run_post_transition_callbacks(state)
      @post_transition_callbacks.try &.call(state)
    end

    # Send an event to trigger a state transition.
    #
    # @param event [String] The event triggering the transition.
    # @return [State] The new state after the transition.
    def send(event : String) : State
      @transition_mutex.synchronize do
        transition, new_state = @machine.transition(event, @current_state)
        return @current_state if transition.nil?
        return @current_state unless transition.can_transition?(event, @context)

        # Run exit actions on current_state
        @current_state.run_exit_callbacks(event, @context)

        # Run transition actions
        transition.run_callbacks(event, @context)

        # Run entry actions on new_state
        new_state.run_entry_callbacks(event, @context)

        @current_state = new_state

        # Run the callback for state changes
        self.run_post_transition_callbacks(@current_state)

        @current_state
      end
    end
  end
end

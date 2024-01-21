require "./fsm/*"

# See examples directory for an example of how to leverage the FSM in your app

# The Finite State Machine (FSM) module provides a framework for modeling and implementing finite state machines.
#
# It includes classes for creating and managing state machines, states, transitions, and associated context.
# States define the different conditions or modes that a system can be in, transitions define how the system moves
# from one state to another in response to events, and a context is used to carry information across state transitions.
module FSM
  alias Any = Nil |
              Bool |
              Int32 |
              Int64 |
              Float32 |
              Float64 |
              String |
              Array(Any) |
              Hash(String, Any)

  # Represents a finite state machine.
  #
  # @property id [String] The unique identifier of the state machine.
  # @property states [Hash(String, State)] A collection of states associated with the state machine.
  # @property initial_state [State] The initial state of the state machine.
  # @property current_state [State] The current state of the state machine.
  class Machine
    # Mutex to synchronize state transitions
    @transition_mutex : Mutex = Mutex.new

    @state_change_action : Nil | (State) ->

    # The unique identifier of the state machine.
    getter id : String

    # A collection of states associated with the state machine.
    getter states : Hash(String, State)

    # The initial state of the state machine.
    getter initial_state : State

    # The current state of the state machine.
    getter current_state : State

    # TODO: Create context api and inject into callbacks
    property context : Context

    # Create a new state machine with the given identifier, states, and initial state.
    #
    # @param id [String] The unique identifier of the state machine.
    # @param states [Array(State)] The states associated with the state machine.
    # @param initial [String] The identifier of the initial state.
    # @param context [Hash(String, Any)] Optional initial data to be registered in the context.
    # @yieldparam self [Machine] The machine instance to be configured.
    def self.create(id : String, states : Array(State), initial : String, context : Hash(String, Any)? = nil)
      states_hash = states.map { |x| {x.id, x} }.to_h
      validate_states(states_hash, initial)
      new(id, states_hash, states_hash[initial], context)
    end

    # Create a new state machine with the given identifier, states, initial state, and execute a block to set up additional configurations.
    #
    # @param id [String] The unique identifier of the state machine.
    # @param states [Array(State)] The states associated with the state machine.
    # @param initial [String] The identifier of the initial state.
    # @param context [Hash(String, Any)] Optional initial data to be registered in the context.
    # @yieldparam self [Machine] The machine instance to be configured.
    def self.create(id : String, states : Array(State), initial : String, context : Hash(String, Any)? = nil, &)
      machine = create(id, states, initial, context)
      yield machine
      machine
    end

    # Static method to handle state transitions.
    #
    # @param states [Hash(String, State)] The states associated with the state machine.
    # @param current_state [State] The current state of the state machine.
    # @param event [String] The event triggering the transition.
    # @return [Tuple(Transition, State)] The transition and the new state after the transition.
    protected def self.transition(states : Hash(String, State), current_state : State, event : String)
      # No transition made if current state received is unrecognized.
      return {nil, current_state} unless state = states[current_state.id]?

      # No transition made if the event received is not registered for the current_state
      return {nil, current_state} unless transition = state.transition(event)

      # No transition made if the target defined on the transition doesn't exist
      return {nil, current_state} unless new_state = states[transition.target]?

      {transition, new_state}
    end

    # Initialize a new state machine with the given identifier, states, and initial state.
    #
    private def initialize(@id, @states, @initial_state, context : Hash(String, Any)?)
      @current_state = @initial_state
      @context = Context.new(context)
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
    def on_state_change(&block : (State) ->)
      @state_change_action = block
    end

    # Run the state change callback with the given state.
    #
    # @param state [State] The new state after the change.
    def run_new_state_action(state)
      @state_change_action.try &.call(state)
    end

    # Send an event to trigger a state transition.
    #
    # @param event [String] The event triggering the transition.
    # @return [State] The new state after the transition.
    def send(event : String) : State
      @transition_mutex.synchronize do
        transition, new_state = Machine.transition(states, @current_state, event)
        return @current_state if transition.nil?
        return @current_state if new_state === @current_state
        return @current_state unless new_state.can_transition(event, @context)

        # Run exit actions on current_state
        @current_state.run_exit_actions(event, @context)

        # Run transition actions
        transition.run_actions(event, @context)

        # Run entry actions on new_state
        new_state.run_entry_actions(event, @context)

        # Run the callback for state changes
        self.run_new_state_action(new_state)

        @current_state = new_state
      end
    end

    # Validate that the initial state is present in the states collection and has valid target states.
    #
    # @param states_hash [Hash(String, State)] The states associated with the state machine.
    # @param initial [String] The identifier of the initial state.
    # @raise [InvalidInitialStateError] Raised if the initial state is not present or has invalid target states.
    private def self.validate_states(states_by_id : Hash(String, State), initial : String)
      raise InvalidInitialStateError.new "Expected states to include the initial state.  A state with id #{initial} was not found." if !states_by_id.has_key?(initial)
      states_by_id.each do |id, state|
        missing_states = state.all_target_states - states_by_id.keys
        raise MissingTargetStateError.new "Invalid target state(s) found in #{id} transitions.  Invalid target(s) found: #{missing_states} " if missing_states.present?
      end
    end
  end

  # Represents a state within the finite state machine.
  #
  # @property id [String] The unique identifier of the state.
  # @property transitions [Hash(String, Transition)] A collection of transitions associated with the state.
  # @property entry_actions [Callable(String, Context)?] Optional callback to be executed when entering the state.
  # @property exit_actions [Callable(String, Context)?] Optional callback to be executed when exiting the state.
  class State
    # The unique identifier of the state.
    getter id : String

    # A collection of transitions associated with the state.
    @transitions : Hash(String, Transition) = {} of String => Transition

    # Optional callback to be executed when entering the state.
    @entry_actions : Nil | (String, Context) ->

    # Optional callback to be executed when exiting the state.
    @exit_actions : Nil | (String, Context) ->

    # Create a new state with the given identifier.
    #
    # @param id [String] The unique identifier of the state.
    def self.create(id : String)
      new(id)
    end

    # Create a new state with the given identifier and execute a block to set up additional configurations.
    #
    # @param id [String] The unique identifier of the state.
    # @yieldparam self [State] The state instance to be configured.
    def self.create(id : String, &)
      state = new(id)
      yield state
      state
    end

    # Initialize a new state with the given identifier.
    #
    private def initialize(@id); end

    # Compare two states for equality based on their identifiers.
    #
    # @param other [State] The state to compare with.
    def ==(other : State)
      self.id === other.id
    end

    # Register a new action to be fired when entering this state.
    #
    # @yieldparam event [String] The event triggering the entry action.
    # @yieldparam context [Context] The context associated with the state machine.
    def on_entry(&block : (String, Context) ->)
      @entry_actions = block
    end

    # Register a new transition from this state to another state.
    #
    # @param event [String] The event triggering the transition.
    # @param target [String] The target state after the transition.
    def on_event(event : String, target : String)
      @transitions[event] = Transition.new(event, target)
    end

    # Register a new transition with a callback to be executed when the transition is made.
    #
    # @param event [String] The event triggering the transition.
    # @param target [String] The target state after the transition.
    # @yieldparam event [String] The event triggering the transition.
    # @yieldparam context [Context] The context associated with the state machine.
    def on_event(event : String, target : String, &block : (String, Context) ->)
      @transitions[event] = Transition.new(event, target, &block)
    end

    # Register a new action to be fired when exiting this state.
    #
    # @yieldparam event [String] The event triggering the exit action.
    # @yieldparam context [Context] The context associated with the state machine.
    def on_exit(&block : (String, Context) ->)
      @exit_actions = block
    end

    # Get a list of all target states reachable through transitions from this state.
    #
    def all_target_states
      @transitions.map { |k, v| v.target }.uniq
    end

    # If this state responds to the given event, return the registered transition.
    #
    # @param event [String] The event triggering the transition.
    # @return [Transition, Nil] The registered transition or nil if the event is not valid.
    protected def transition(event : String)
      @transitions[event]?
    end

    # Check if the state can transition based on registered guards.
    #
    # @param event [String] The event triggering the transition.
    # @param context [Context] The context associated with the state machine.
    # @return [Bool] True if the state can transition, false otherwise.
    protected def can_transition(event, context)
      return true
    end

    # Execute any actions registered to be fired when entering this state.
    #
    # @param event [String] The event triggering the entry actions.
    # @param context [Context] The context associated with the state machine.
    protected def run_entry_actions(event, context)
      @entry_actions.try &.call(event, context)
    end

    # Execute any actions registered to be fired when exiting this state.
    #
    # @param event [String] The event triggering the exit actions.
    # @param context [Context] The context associated with the state machine.
    protected def run_exit_actions(event, context)
      @exit_actions.try &.call(event, context)
    end
  end

  # Represents a transition from one state to another triggered by an event.
  #
  # @property event [String] The event that triggers the transition.
  # @property target [String] The target state after the transition.
  # @property actions [Callable(String, Context)?] Optional callback to be executed during the transition.
  private class Transition
    # The event that triggers the transition.
    getter event : String

    # The target state after the transition.
    getter target : String

    # Optional callback to be executed during the transition.
    getter actions : Nil | (String, Context) ->

    protected def initialize(@event, @target); end

    protected def initialize(@event, @target, &block : (String, Context) ->)
      @actions = block
    end

    # Execute any actions registered to be fired during the transition.
    #
    # @param event [String] The event triggering the transition.
    # @param context [Context] The context associated with the state machine.
    protected def run_actions(event, context)
      @actions.try &.call(event, context)
    end
  end

  # Represents the "extended" context associated with the finite state machine.
  class Context
    # Mutex for thread safety
    @mutex : Mutex = Mutex.new

    # Internal data storage
    @data : Hash(String, Any) = {} of String => Any

    # Create a new context with optional initial data.
    #
    # @param initial_data [Hash(String, Any)] Optional initial data to be registered in the context.
    def initialize(initial_data = {} of String => Any)
      @data.merge!(initial_data) if initial_data
    end

    # Get the value associated with a key from the context.
    #
    # @param key [String] The key to retrieve.
    # @return [Any] The value associated with the key.
    def get(key : String) : Any
      @mutex.synchronize { @data[key] }
    end

    # Set the value associated with a key in the context.
    #
    # @param key [String] The key to set.
    # @param value [Any] The value to associate with the key.
    def set(key : String, value : Any)
      @mutex.synchronize { @data[key] = value }
    end

    # Modify the value associated with a key in the context using a block.
    #
    # @param key [String] The key to modify.
    # @yieldparam current_value [Any] The current value associated with the key.
    # @return [Any] The modified value.
    def modify(key : String, &block : (Any) -> Any)
      @mutex.synchronize do
        current_value = @data[key]
        modified_value = block.call(current_value)
        @data[key] = modified_value
        modified_value
      end
    end
  end

  class StateMachineError < Exception; end

  class InvalidInitialStateError < StateMachineError; end

  class MissingTargetStateError < StateMachineError; end
end

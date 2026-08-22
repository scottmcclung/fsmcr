module FSM
  # Represents a state within the finite state machine.
  #
  # State is a class with reference semantics: a machine and any caller holding
  # the same State observe one shared object. Once a machine consumes a state via
  # Machine.create, the state is sealed and its builder methods raise
  # SealedStateError, keeping a shared definition immutable after build.
  #
  # @property id [String] The unique identifier of the state.
  # @property transitions [Hash(String, Transition)] A collection of transitions associated with the state.
  # @property entry_callbacks [Callable(String, Context)?] Optional callback to be executed when entering the state.
  # @property exit_callbacks [Callable(String, Context)?] Optional callback to be executed when exiting the state.
  # @property sealed [Bool] Whether the state has been consumed by a machine and is now immutable.
  class State
    # The unique identifier of the state.
    getter id : String

    # A collection of transitions associated with the state.
    @transitions : Hash(String, Transition) = {} of String => Transition

    # Optional callbacks to be executed when entering the state.
    @entry_callbacks : Nil | (String, Context) ->

    # Optional callbacks to be executed when exiting the state.
    @exit_callbacks : Nil | (String, Context) ->

    # Whether this state has been consumed by a machine and is now immutable.
    @sealed : Bool = false

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

    # Hash by identifier so states equal under `==` are also hash-equal.
    def_hash id

    # Register a new callback to be fired when entering this state.
    #
    # @yieldparam event [String] The event triggering the entry callback.
    # @yieldparam context [Context] The context associated with the state machine.
    # @raise [SealedStateError] Raised if the state has been sealed by a machine.
    def on_entry(&block : (String, Context) ->) : self
      raise SealedStateError.new "Cannot register an entry callback on state #{@id} after it has been sealed by a machine." if @sealed
      @entry_callbacks = block
      self
    end

    # Register a new transition from this state to another state.
    #
    # @param event [String] The event triggering the transition.
    # @param target [String] The target state after the transition.
    # @raise [SealedStateError] Raised if the state has been sealed by a machine.
    def on_event(event : String, target : String) : self
      raise SealedStateError.new "Cannot register a transition on state #{@id} after it has been sealed by a machine." if @sealed
      @transitions[event] = Transition.new(event, target)
      self
    end

    # Register a new transition with a callback to be executed when the transition is made.
    #
    # @param event [String] The event triggering the transition.
    # @param target [String] The target state after the transition.
    # @yieldparam event [String] The event triggering the transition.
    # @yieldparam context [Context] The context associated with the state machine.
    # @raise [SealedStateError] Raised if the state has been sealed by a machine.
    def on_event(event : String, target : String, &) : self
      raise SealedStateError.new "Cannot register a transition on state #{@id} after it has been sealed by a machine." if @sealed
      transition = Transition.new(event, target)
      @transitions[event] = yield transition || transition
      self
    end

    # Register new callbacks to be fired when exiting this state.
    #
    # @yieldparam event [String] The event triggering the exit callbacks.
    # @yieldparam context [Context] The context associated with the state machine.
    # @raise [SealedStateError] Raised if the state has been sealed by a machine.
    def on_exit(&block : (String, Context) ->) : self
      raise SealedStateError.new "Cannot register an exit callback on state #{@id} after it has been sealed by a machine." if @sealed
      @exit_callbacks = block
      self
    end

    # Get a list of all target states reachable through transitions from this state.
    #
    def all_target_states : Array(String)
      @transitions.map { |k, v| v.target }.uniq
    end

    # If this state responds to the given event, return the registered transition.
    #
    # @param event [String] The event triggering the transition.
    # @return [Transition, Nil] The registered transition or nil if the event is not valid.
    protected def transition(event : String) : Transition?
      @transitions[event]?
    end

    # Mark this state as consumed by a machine, preventing further mutation.
    # Sealing is idempotent: sealing an already-sealed state is a no-op.
    protected def seal : Nil
      @sealed = true
    end

    # Check if the state can transition based on registered guards.
    #
    # @param event [String] The event triggering the transition.
    # @param context [Context] The context associated with the state machine.
    # @return [Bool] True if the state can transition, false otherwise.
    protected def can_transition(event, context) : Bool
      return true
    end

    # Execute any callbacks registered to be fired when entering this state.
    #
    # @param event [String] The event triggering the entry callbacks.
    # @param context [Context] The context associated with the state machine.
    protected def run_entry_callbacks(event, context)
      @entry_callbacks.try &.call(event, context)
    end

    # Execute any callbacks registered to be fired when exiting this state.
    #
    # @param event [String] The event triggering the exit callbacks.
    # @param context [Context] The context associated with the state machine.
    protected def run_exit_callbacks(event, context)
      @exit_callbacks.try &.call(event, context)
    end
  end
end

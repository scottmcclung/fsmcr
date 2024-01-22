module FSM
  # Represents a transition from one state to another triggered by an event.
  #
  # @property event [String] The event that triggers the transition.
  # @property target [String] The target state after the transition.
  # @property callbacks [Callable(String, Context)?] Optional callback to be executed during the transition.
  struct Transition
    # Optional callback to be executed during the transition.
    @callbacks : Nil | (String, Context) ->

    # Optional callbacks to be executed before the transition.
    @guards : Nil | (String, Context) ->

    # The event that triggers the transition.
    getter event : String

    # The target state after the transition.
    getter target : String

    protected def initialize(@event, @target); end

    protected def initialize(@event, @target, &block : (String, Context) ->)
      @callbacks = block
    end

    # Execute any callbacks registered to be fired during the transition.
    #
    # @param event [String] The event triggering the transition.
    # @param context [Context] The context associated with the state machine.
    protected def run_callbacks(event, context)
      @callbacks.try &.call(event, context)
    end

    protected def can_transition?(event, context) : Bool
      return true if @guards.nil?
      !!@guards.try &.call(event, context)
    end

    def on(&block : (String, Context) ->) : self
      @callbacks = block
      self
    end

    def guard(&block : (String, Context) ->) : self
      @guards = block
      self
    end
  end
end

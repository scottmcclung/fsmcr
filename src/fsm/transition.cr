module FSM
  # A transition from one state to another on an event (design section 5, D16).
  #
  # Transition(T) is a class, not a struct, with the same lifecycle as
  # StateDefinition: the builder creates it, mutates it during build via `on` and
  # `guard`, and it is read-only forever afterward while shared across every
  # interpreter. Making it a class means the builder mutates one shared object
  # rather than a copy, which is why registering a guard and a callback on the
  # yielded transition takes effect (design section 5). `event` and `target` are
  # set at construction and never change; the only mutable surface is `on` and
  # `guard`, which raise SealedStateError once the machine seals it.
  class Transition(T)
    getter event : String
    getter target : String

    @callback : ((String, T) ->)? = nil
    @guard : ((String, T) -> Bool)? = nil

    # Whether this transition is internal (design section 9.1). An internal
    # self-transition suppresses exit and entry in the plan's action list, running
    # only the transition callback; the default is external. Definition state, set
    # during build like a guard or callback, and frozen at seal (decision C,
    # section 5).
    @internal : Bool = false

    # Whether the owning machine has sealed this transition (design section 5).
    @sealed : Bool = false

    protected def initialize(@event : String, @target : String)
    end

    # Register the transition callback fired during the transition (design section
    # 9).
    def on(&block : (String, T) ->) : self
      raise SealedStateError.new "Cannot register a transition callback on the #{@event} transition after it has been sealed by a machine." if @sealed
      @callback = block
      self
    end

    # Register the guard predicate that must return true for this transition to be
    # selected (design section 6).
    def guard(&block : (String, T) -> Bool) : self
      raise SealedStateError.new "Cannot register a guard on the #{@event} transition after it has been sealed by a machine." if @sealed
      @guard = block
      self
    end

    # Mark this transition internal (design section 9.1). Chainable, so it reads as
    # `t.internal.on { ... }`. Raises once sealed, like `on` and `guard`, because
    # the internal flag is definition state and sealing means what you built is what
    # runs (decision C, section 5).
    def internal : self
      raise SealedStateError.new "Cannot mark the #{@event} transition internal after it has been sealed by a machine." if @sealed
      @internal = true
      self
    end

    # Whether this transition is internal (design section 9.1, section 10.2 step
    # 15).
    protected def internal? : Bool
      @internal
    end

    # Whether this transition's guard passes in the given context. A transition
    # without a guard always passes (design section 6, step 12-13).
    protected def passes_guard?(event : String, context : T) : Bool
      guard : ((String, T) -> Bool)? = @guard
      return true if guard.nil?
      guard.call(event, context)
    end

    # The transition callback as a real proc, a no-op when none is registered, so
    # the plan's action list is positional regardless of registration (decision B,
    # design section 10.2 step 15).
    protected def callback : (String, T) ->
      @callback || ->(_event : String, _context : T) { }
    end

    # Seal this transition (design section 5). Idempotent.
    protected def seal : Nil
      @sealed = true
    end
  end
end

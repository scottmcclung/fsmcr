module FSM
  # A state in the machine definition (design section 3, D13). Renamed from the
  # old `State` now that `State` names the runtime snapshot (design section 3.3).
  #
  # StateDefinition(T) is generic over the caller's context type T, which guards
  # and callbacks receive directly. It is a class with reference semantics: the
  # builder creates it, mutates it during build, and the machine shares one sealed
  # object across every interpreter and fiber (design section 5). Once sealed, its
  # builder methods raise SealedStateError, which is what keeps a shared definition
  # immutable after build (design section 12.1).
  class StateDefinition(T)
    getter id : String

    # Single transition per event, matching the resolution logic as it stands
    # today. Multiple transitions per event (Hash(String, Array(Transition(T))))
    # is design section 6 and lands with fsmcr-bfn.3.
    @transitions : Hash(String, Transition(T)) = {} of String => Transition(T)

    @entry_callback : ((String, T) ->)? = nil
    @exit_callback : ((String, T) ->)? = nil

    # Whether the owning machine has sealed this definition (design section 5).
    @sealed : Bool = false

    # Protected, mirroring Transition#initialize, so the T = Nil rejection in
    # Machine.build cannot be bypassed by a direct StateDefinition(Nil).new call
    # from outside the FSM module (design section 3.1, D5). The Builder constructs
    # definitions from inside the module.
    protected def initialize(@id : String)
    end

    # Register a callback fired when this state is entered (design section 9).
    def on_entry(&block : (String, T) ->) : self
      raise SealedStateError.new "Cannot register an entry callback on state #{@id} after it has been sealed by a machine." if @sealed
      @entry_callback = block
      self
    end

    # Register a callback fired when this state is exited (design section 9).
    def on_exit(&block : (String, T) ->) : self
      raise SealedStateError.new "Cannot register an exit callback on state #{@id} after it has been sealed by a machine." if @sealed
      @exit_callback = block
      self
    end

    # Register a transition from this state to a target on an event (design
    # section 4). The single-transition form used when no guard or transition
    # callback is needed.
    def on_event(event : String, target : String) : self
      raise SealedStateError.new "Cannot register a transition on state #{@id} after it has been sealed by a machine." if @sealed
      @transitions[event] = Transition(T).new(event, target)
      self
    end

    # Register a transition and yield it so a guard or transition callback can be
    # attached (design section 4). Because Transition(T) is a class, the yielded
    # object is the same one the machine keeps and the interpreter reads at
    # runtime (design section 5, D16).
    def on_event(event : String, target : String, &) : self
      raise SealedStateError.new "Cannot register a transition on state #{@id} after it has been sealed by a machine." if @sealed
      transition : Transition(T) = Transition(T).new(event, target)
      yield transition
      @transitions[event] = transition
      self
    end

    # The distinct target states reachable from this state, used by the builder to
    # validate that every target names an existing state (design section 4).
    def all_target_states : Array(String)
      @transitions.values.map(&.target).uniq
    end

    # The transition registered for an event, or nil if the event is unrecognized
    # here (design section 10.2, step 10).
    protected def transition(event : String) : Transition(T)?
      @transitions[event]?
    end

    # Seal this definition and every transition it owns (design section 5).
    # Idempotent: sealing an already-sealed definition is a no-op.
    protected def seal : Nil
      @sealed = true
      @transitions.each_value(&.seal)
    end

    protected def run_entry_callback(event : String, context : T) : Nil
      @entry_callback.try &.call(event, context)
    end

    protected def run_exit_callback(event : String, context : T) : Nil
      @exit_callback.try &.call(event, context)
    end
  end
end

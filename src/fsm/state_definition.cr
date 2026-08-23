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

    # Multiple transitions per event, distinguished by guards (design section 6,
    # D3). Each on_event for the same event appends, and resolution walks the array
    # in registration order (design section 6, step 12). A guardless transition
    # registered before others for the same event makes them unreachable, and a
    # guardless fallback and a future on_blocked handler for the same event are
    # mutually exclusive (design section 6, section 13.2, D11).
    @transitions : Hash(String, Array(Transition(T))) = {} of String => Array(Transition(T))

    @entry_callback : ((String, T) ->)? = nil
    @exit_callback : ((String, T) ->)? = nil

    # Per-event blocked handlers, keyed by event (design section 9, section 13.3,
    # D12). A handler fires when the event has candidate transitions but every guard
    # rejected. The keying is per event because different blocked events want
    # different messages; on_unknown_event is state-wide by contrast (design
    # section 9, D10). The handler receives the event, the context, and the
    # Array(String) of blocked target ids so it never re-runs a guard predicate.
    @blocked_callbacks : Hash(String, (String, T, Array(String)) ->) = {} of String => (String, T, Array(String)) ->

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

    # Register a handler fired when the event has candidate transitions but every
    # guard rejected (design section 9, section 13.3, D12). It is keyed per event
    # and does not fire for an unknown event or when any transition succeeds. The
    # handler receives the blocked target ids so it can give a specific reason
    # without re-evaluating any guard (design section 9). Registering a second
    # handler for the same event replaces the first (last write wins, the same
    # semantics as on_entry and on_exit).
    def on_blocked(event : String, &block : (String, T, Array(String)) ->) : self
      raise SealedStateError.new "Cannot register a blocked handler on state #{@id} after it has been sealed by a machine." if @sealed
      @blocked_callbacks[event] = block
      self
    end

    # Register a transition from this state to a target on an event (design
    # section 4, section 6). Calling on_event repeatedly for one event appends,
    # building the ordered candidate list resolution walks (design section 6).
    def on_event(event : String, target : String) : self
      raise SealedStateError.new "Cannot register a transition on state #{@id} after it has been sealed by a machine." if @sealed
      append_transition(Transition(T).new(event, target))
      self
    end

    # Register a transition and yield it so a guard, transition callback, or the
    # internal flag can be attached (design section 4, section 9.1). Because
    # Transition(T) is a class, the yielded object is the same one the machine keeps
    # and the interpreter reads at runtime (design section 5, D16).
    def on_event(event : String, target : String, &) : self
      raise SealedStateError.new "Cannot register a transition on state #{@id} after it has been sealed by a machine." if @sealed
      transition : Transition(T) = Transition(T).new(event, target)
      yield transition
      append_transition(transition)
      self
    end

    # Append a transition to its event's candidate list, preserving registration
    # order (design section 6, step 12).
    private def append_transition(transition : Transition(T)) : Nil
      (@transitions[transition.event] ||= [] of Transition(T)) << transition
    end

    # The distinct target states reachable from this state, used by the builder to
    # validate that every target names an existing state (design section 4).
    def all_target_states : Array(String)
      @transitions.values.flatten.map(&.target).uniq
    end

    # Resolve the outcome for an event in this context (design section 6, section
    # 10.2 steps 10-13). An unregistered event is EventNotRecognized; otherwise the
    # candidates are walked in registration order and the first whose guard passes
    # wins (a guardless transition always passes), stopping evaluation; if every
    # candidate rejects, the outcome is TransitionsBlocked.
    protected def resolve(event : String, context : T) : TransitionFound(T) | TransitionsBlocked | EventNotRecognized
      candidates : Array(Transition(T))? = @transitions[event]?
      return EventNotRecognized.new if candidates.nil?

      # Collect the target of each rejected candidate as it is walked, in
      # registration order, so a blocked outcome carries what was blocked without a
      # second guard pass (design section 9, D12). This array is freshly allocated on
      # every resolve call and nothing mutates it after this loop; the TransitionsBlocked
      # outcome getter and the Blocked action's closure share the same instance by
      # design.
      blocked : Array(String) = [] of String
      candidates.each do |transition|
        return TransitionFound(T).new(transition) if transition.passes_guard?(event, context)
        blocked << transition.target
      end

      TransitionsBlocked.new(blocked)
    end

    # Seal this definition and every transition it owns (design section 5).
    # Idempotent: sealing an already-sealed definition is a no-op.
    protected def seal : Nil
      @sealed = true
      @transitions.each_value(&.each(&.seal))
    end

    # The exit callback as a real proc, a no-op when none is registered, so the
    # plan's action list is positional regardless of registration (decision B,
    # design section 10.2 step 15).
    protected def exit_callback : (String, T) ->
      @exit_callback || ->(_event : String, _context : T) { }
    end

    # The entry callback as a real proc, a no-op when none is registered (decision
    # B, design section 10.2 step 15).
    protected def entry_callback : (String, T) ->
      @entry_callback || ->(_event : String, _context : T) { }
    end

    # The blocked handler registered for an event, or nil when none is registered
    # (design section 10.2 step 15). `plan` uses its presence to decide whether a
    # blocked outcome emits a Blocked action or an empty action list.
    protected def blocked_callback(event : String) : ((String, T, Array(String)) ->)?
      @blocked_callbacks[event]?
    end
  end
end

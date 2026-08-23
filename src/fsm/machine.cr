module FSM
  # The immutable, sealed machine definition (design section 1, section 5).
  #
  # A machine is built once by a machine-scoped builder, then shared across any
  # number of interpreters and fibers. It resolves transitions and answers state
  # lookups; it never executes user callbacks (design section 10.6). Construction
  # goes only through `build`; the old array-of-states `Machine.create` form is
  # gone (design section 4, D2).
  #
  # T is the caller's context type. T = Nil is unsupported: a contextless caller
  # uses FSM::Context (design section 3.1, D5). `build` rejects Machine(Nil) at
  # compile time with a diagnostic naming FSM::Context.
  class Machine(T)
    getter id : String

    @states : Hash(String, StateDefinition(T))

    protected def initialize(@id : String, @states : Hash(String, StateDefinition(T)))
    end

    # Build a machine with a machine-scoped builder (design section 4, D2). The
    # yielded builder registers states; at the end of the block it validates every
    # transition target and seals every definition, then returns the immutable
    # machine.
    def self.build(id : String, &) : Machine(T)
      {% if T == Nil %}
        {% raise "Machine(Nil) is unsupported: T = Nil has no context object. Use FSM::Context as T for a contextless machine (design section 3.1, D5)." %}
      {% end %}
      builder : Builder(T) = Builder(T).new(id)
      yield builder
      builder.finish
    end

    # A shallow copy of the states, so callers cannot add, delete, or replace
    # entries in the machine's internal definition (design section 5). The
    # StateDefinition values are shared but sealed, so the definition stays
    # immutable. Internal code reads @states directly.
    def states : Hash(String, StateDefinition(T))
      @states.dup
    end

    protected def state_by_id(id : String) : StateDefinition(T)?
      @states[id]?
    end

    # Resolve the transition for an event from the current state (design section
    # 10.2, steps 9-14). Single transition per event, matching today's logic;
    # multiple transitions and the plan/apply split are design section 6-7 and
    # land with fsmcr-bfn.3. Returns the selected transition and the destination
    # definition, or nil and the unchanged definition when nothing matches.
    protected def transition(event : String, current : StateDefinition(T)) : Tuple(Transition(T)?, StateDefinition(T))
      return {nil, current} unless transition = current.transition(event)
      return {nil, current} unless new_state = @states[transition.target]?

      {transition, new_state}
    end
  end
end

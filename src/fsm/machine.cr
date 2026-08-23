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

    # The pure core (design section 7, section 10.2 steps 9-16, D7). Selects the
    # transition, evaluates guards, resolves the destination, and computes the
    # ordered action list. It executes nothing; the interpreter runs the actions.
    #
    # D7: protected. `plan`, Plan, Action, and ActionKind are internal, not public
    # API. Both interpreters and the library's own specs reach it from inside the
    # FSM namespace; a caller outside cannot.
    protected def plan(state : StateDefinition(T), event : String, context : T) : Plan(T)
      outcome : TransitionFound(T) | TransitionsBlocked | EventNotRecognized = state.resolve(event, context)

      case outcome
      in TransitionFound
        transition : Transition(T) = outcome.transition
        # The target is validated at build (design section 4), so the lookup exists.
        target : StateDefinition(T) = @states[transition.target]
        Plan(T).new(outcome, target, transition_actions(state, transition, target))
      in TransitionsBlocked
        # Step 14: destination is the unchanged current state. Empty action list in
        # this issue; the Blocked action needs an on_blocked handler (fsmcr-bfn.4,
        # design section 10.2 step 15).
        Plan(T).new(outcome, state, [] of Action(T))
      in EventNotRecognized
        # Step 14: destination is the unchanged current state. Empty action list in
        # this issue; the UnknownEvent action needs an on_unknown_event handler
        # (fsmcr-bfn.5, design section 10.2 step 15).
        Plan(T).new(outcome, state, [] of Action(T))
      end
    end

    # The ordered action list for a found transition (design section 10.2 step 15).
    # External (the default) emits Exit(source), Transition, Entry(target); an
    # internal self-transition suppresses Exit and Entry and emits Transition only
    # (design section 9.1). Decision A: the Transition action carries the target
    # state id; the design fixes the kind order but leaves the middle action's
    # state_id to the implementer.
    private def transition_actions(source : StateDefinition(T), transition : Transition(T), target : StateDefinition(T)) : Array(Action(T))
      return [Action(T).new(ActionKind::Transition, target.id, transition.callback)] if transition.internal?

      [
        Action(T).new(ActionKind::Exit, source.id, source.exit_callback),
        Action(T).new(ActionKind::Transition, target.id, transition.callback),
        Action(T).new(ActionKind::Entry, target.id, target.entry_callback),
      ]
    end
  end
end

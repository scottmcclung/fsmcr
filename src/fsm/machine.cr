module FSM
  # The immutable, sealed machine definition.
  #
  # A machine is built once by a machine-scoped builder, then shared across any
  # number of interpreters and fibers. It resolves transitions and answers state
  # lookups; it never executes user callbacks. Construction
  # goes only through `build`; the old array-of-states `Machine.create` form is
  # gone.
  #
  # T is the caller's context type. T = Nil is unsupported: a contextless caller
  # uses FSM::Context. `build` rejects Machine(Nil) at
  # compile time with a diagnostic naming FSM::Context.
  class Machine(T)
    getter id : String

    @states : Hash(String, StateDefinition(T))

    protected def initialize(@id : String, @states : Hash(String, StateDefinition(T)))
    end

    # Build a machine with a machine-scoped builder. The
    # yielded builder registers states; at the end of the block it validates every
    # transition target and seals every definition, then returns the immutable
    # machine.
    def self.build(id : String, &) : Machine(T)
      {% if T == Nil %}
        {% raise "Machine(Nil) is unsupported: T = Nil has no context object. Use FSM::Context as T for a contextless machine." %}
      {% end %}
      builder : Builder(T) = Builder(T).new(id)
      yield builder
      builder.finish
    end

    # A shallow copy of the states, so callers cannot add, delete, or replace
    # entries in the machine's internal definition. The
    # StateDefinition values are shared but sealed, so the definition stays
    # immutable. Internal code reads @states directly.
    def states : Hash(String, StateDefinition(T))
      @states.dup
    end

    protected def state_by_id(id : String) : StateDefinition(T)?
      @states[id]?
    end

    # The pure core. Selects the
    # transition, evaluates guards, resolves the destination, and computes the
    # ordered action list. It executes nothing; the interpreter runs the actions.
    #
    # Protected. `plan`, Plan, Action, and ActionKind are internal, not public
    # API. Both interpreters and the library's own specs reach it from inside the
    # FSM namespace; a caller outside cannot.
    protected def plan(state : StateDefinition(T), event : String, context : T) : Plan(T)
      outcome : TransitionFound(T) | TransitionsBlocked | EventNotRecognized = state.resolve(event, context)

      case outcome
      in TransitionFound
        transition : Transition(T) = outcome.transition
        # The target is validated at build, so the lookup exists.
        target : StateDefinition(T) = @states[transition.target]
        Plan(T).new(outcome, target, transition_actions(state, transition, target))
      in TransitionsBlocked
        # The destination is the unchanged current state, and the actions are a
        # single Blocked action when the state has a handler for this event, else an
        # empty list. The action carries the blocked target
        # ids resolution already collected, so the blocked path never re-runs a
        # guard.
        Plan(T).new(outcome, state, blocked_actions(state, event, outcome.blocked))
      in EventNotRecognized
        # The destination is the unchanged current state, and the actions are a
        # single UnknownEvent action when the state has an unknown-event handler, else
        # an empty list, which preserves today's silent no-op.
        Plan(T).new(outcome, state, unknown_event_actions(state))
      end
    end

    # The action list for an unrecognized event. A
    # single UnknownEvent action when the state registered an unknown-event handler,
    # else empty. The action's state_id is the unchanged current state.
    # Its callback closes over the state-wide handler so the interpreter's
    # (String, T) -> action shape invokes it directly.
    private def unknown_event_actions(state : StateDefinition(T)) : Array(Action(T))
      handler : ((String, T) ->)? = state.unknown_event_callback
      return [] of Action(T) if handler.nil?

      callback : (String, T) -> = ->(fired_event : String, context : T) do
        handler.call(fired_event, context)
      end
      [Action(T).new(ActionKind::UnknownEvent, state.id, callback)]
    end

    # The action list for a blocked event. A single
    # Blocked action when the state registered a handler for the event, else empty.
    # The action's state_id is the unchanged current state. Its callback
    # closes over the blocked target ids so the interpreter's (String, T) -> action
    # shape invokes the 3-arg handler without re-evaluating any guard.
    private def blocked_actions(state : StateDefinition(T), event : String, blocked : Array(String)) : Array(Action(T))
      handler : ((String, T, Array(String)) ->)? = state.blocked_callback(event)
      return [] of Action(T) if handler.nil?

      callback : (String, T) -> = ->(fired_event : String, context : T) do
        handler.call(fired_event, context, blocked)
      end
      [Action(T).new(ActionKind::Blocked, state.id, callback)]
    end

    # The ordered action list for a found transition.
    # External (the default) emits Exit(source), Transition, Entry(target); an
    # internal self-transition suppresses Exit and Entry and emits Transition only.
    # The kind order is fixed, but the middle action's state_id is left to the
    # implementation; this implementation has the Transition action carry the target
    # state id.
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

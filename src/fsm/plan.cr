module FSM
  # The internal core's decision types.
  #
  # `Machine#plan` computes a Plan: an outcome, a destination definition, and an
  # ordered list of tagged actions. It executes nothing. Actions are tagged with an
  # ActionKind rather than being bare procs so an interpreter can log, filter, or
  # reorder them, and so an internal spec can assert on the decision without running
  # it.
  #
  # ActionKind, Action, and Plan are internal, not public API. `plan` is
  # protected, which is what keeps them off the surface; they are marked :nodoc:
  # rather than made private because Crystal has no per-type privacy for top-level
  # types in a module.

  # :nodoc:
  #
  # The kind of effect an Action represents. Blocked is emitted
  # by `plan` when the state has an on_blocked handler for the event. UnknownEvent is
  # emitted by `plan` when the state has an on_unknown_event handler for the event.
  enum ActionKind
    Exit
    Transition
    Entry
    Blocked
    UnknownEvent
  end

  # :nodoc:
  #
  # One tagged effect in a plan. `callback` is always a real proc
  # (a no-op when no callback is registered) so the action list shape is positional
  # regardless of which callbacks exist.
  struct Action(T)
    getter kind : ActionKind
    getter state_id : String
    getter callback : (String, T) ->

    # Protected so Action cannot be constructed from outside the FSM namespace.
    # In-namespace callers such as Machine#transition_actions still build it.
    protected def initialize(@kind : ActionKind, @state_id : String, @callback : (String, T) ->)
    end
  end

  # :nodoc:
  #
  # The result of planning one step. Holds
  # the outcome union inline (no TransitionResult alias), the destination
  # definition, and the ordered action list. Nothing has executed when a Plan is
  # returned.
  struct Plan(T)
    getter outcome : TransitionFound(T) | TransitionsBlocked | EventNotRecognized
    getter next_state : StateDefinition(T)
    getter actions : Array(Action(T))

    # Protected so Plan cannot be constructed from outside the FSM namespace.
    # In-namespace callers such as Machine#plan still build it.
    protected def initialize(
      @outcome : TransitionFound(T) | TransitionsBlocked | EventNotRecognized,
      @next_state : StateDefinition(T),
      @actions : Array(Action(T)),
    )
    end
  end
end

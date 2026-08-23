module FSM
  # The internal core's decision types (design section 7, section 10.2, D7).
  #
  # `Machine#plan` computes a Plan: an outcome, a destination definition, and an
  # ordered list of tagged actions. It executes nothing. Actions are tagged with an
  # ActionKind rather than being bare procs so an interpreter can log, filter, or
  # reorder them, and so an internal spec can assert on the decision without running
  # it (design section 7).
  #
  # ActionKind, Action, and Plan are internal, not public API (D7). `plan` is
  # protected, which is what keeps them off the surface; they are marked :nodoc:
  # rather than made private because Crystal has no per-type privacy for top-level
  # types in a module (D7).

  # :nodoc:
  #
  # The kind of effect an Action represents (design section 7). Blocked is emitted
  # by `plan` when the state has an on_blocked handler for the event (fsmcr-bfn.4,
  # design section 10.2 step 15). UnknownEvent exists now but `plan` does not emit
  # it until the on_unknown_event handler lands (fsmcr-bfn.5).
  enum ActionKind
    Exit
    Transition
    Entry
    Blocked
    UnknownEvent
  end

  # :nodoc:
  #
  # One tagged effect in a plan (design section 7). `callback` is always a real proc
  # (a no-op when no callback is registered) so the action list shape is positional
  # per the section 10.2 step 15 table regardless of which callbacks exist.
  struct Action(T)
    getter kind : ActionKind
    getter state_id : String
    getter callback : (String, T) ->

    # Protected so Action cannot be constructed from outside the FSM namespace
    # (D7). In-namespace callers such as Machine#transition_actions still build it.
    protected def initialize(@kind : ActionKind, @state_id : String, @callback : (String, T) ->)
    end
  end

  # :nodoc:
  #
  # The result of planning one step (design section 7, section 10.2 step 16). Holds
  # the outcome union inline (D3, no TransitionResult alias), the destination
  # definition, and the ordered action list. Nothing has executed when a Plan is
  # returned.
  struct Plan(T)
    getter outcome : TransitionFound(T) | TransitionsBlocked | EventNotRecognized
    getter next_state : StateDefinition(T)
    getter actions : Array(Action(T))

    # Protected so Plan cannot be constructed from outside the FSM namespace (D7).
    # In-namespace callers such as Machine#plan still build it.
    protected def initialize(
      @outcome : TransitionFound(T) | TransitionsBlocked | EventNotRecognized,
      @next_state : StateDefinition(T),
      @actions : Array(Action(T)),
    )
    end
  end
end

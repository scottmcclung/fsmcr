module FSM
  # The three outcomes a step over a state can produce.
  #
  # They form a union so consuming code can match exhaustively with `case ... in`:
  #
  #   TransitionFound(T) | TransitionsBlocked | EventNotRecognized
  #
  # There is no `TransitionResult` alias: Crystal has no parameterized type aliases,
  # so the union is written inline wherever it appears. An abstract-struct base
  # was rejected because it gives no exhaustiveness.
  #
  # These types are internal, not public API: `plan` is protected, so in practice
  # only the interpreters and the library's own specs observe an outcome. They are
  # marked :nodoc: rather than made private because Crystal has no per-type privacy
  # for top-level types in a module.

  # :nodoc:
  #
  # A transition was selected: its guard passed, or it was guardless. Carries the
  # chosen transition so the machine can resolve the destination and build the
  # action list.
  struct TransitionFound(T)
    getter transition : Transition(T)

    # Protected so the outcome cannot be constructed from outside the FSM
    # namespace. In-namespace callers such as StateDefinition#resolve build it.
    protected def initialize(@transition : Transition(T))
    end
  end

  # :nodoc:
  #
  # The event is registered on the state but every candidate guard rejected it.
  # Deliberately not generic: it carries no T, so parameterizing it would force
  # TransitionsBlocked(T).new purely to satisfy inference.
  #
  # `blocked` holds the target state ids of every candidate that rejected, in
  # registration order, collected while resolution walked the candidates. The
  # Blocked action's callback closes over these ids so an on_blocked handler can name
  # what was blocked without re-evaluating any guard. Re-running a guard predicate to
  # discover what was blocked is the double-evaluation regression this design
  # prevents. The ids are strings, so carrying them does not make the outcome generic.
  struct TransitionsBlocked
    getter blocked : Array(String)

    # Protected so the outcome cannot be constructed from outside the FSM
    # namespace. In-namespace callers such as StateDefinition#resolve build it.
    protected def initialize(@blocked : Array(String))
    end
  end

  # :nodoc:
  #
  # No transition is registered for the event on this state. Deliberately not
  # generic, for the same reason as TransitionsBlocked.
  struct EventNotRecognized
    # Protected so the outcome cannot be constructed from outside the FSM
    # namespace. In-namespace callers such as StateDefinition#resolve build it.
    protected def initialize
    end
  end
end

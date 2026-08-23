module FSM
  # The three outcomes a step over a state can produce (design section 6, D3).
  #
  # They form a union so consuming code can match exhaustively with `case ... in`:
  #
  #   TransitionFound(T) | TransitionsBlocked | EventNotRecognized
  #
  # There is no `TransitionResult` alias: Crystal has no parameterized type aliases,
  # so the union is written inline wherever it appears (D3). An abstract-struct base
  # was rejected because it gives no exhaustiveness (design section 6).
  #
  # These types are internal, not public API: `plan` is protected (design section 7,
  # D7), so in practice only the interpreters and the library's own specs observe an
  # outcome. They are marked :nodoc: rather than made private because Crystal has no
  # per-type privacy for top-level types in a module (D7).

  # :nodoc:
  #
  # A transition was selected: its guard passed, or it was guardless (design section
  # 6, steps 12-13). Carries the chosen transition so the machine can resolve the
  # destination and build the action list.
  struct TransitionFound(T)
    getter transition : Transition(T)

    # Protected so the outcome cannot be constructed from outside the FSM
    # namespace (D7). In-namespace callers such as StateDefinition#resolve build it.
    protected def initialize(@transition : Transition(T))
    end
  end

  # :nodoc:
  #
  # The event is registered on the state but every candidate guard rejected it
  # (design section 6, step 13). Deliberately not generic: it carries no T, so
  # parameterizing it would force TransitionsBlocked(T).new purely to satisfy
  # inference (design section 6).
  struct TransitionsBlocked
    # Protected so the outcome cannot be constructed from outside the FSM
    # namespace (D7). In-namespace callers such as StateDefinition#resolve build it.
    protected def initialize
    end
  end

  # :nodoc:
  #
  # No transition is registered for the event on this state (design section 6, step
  # 11). Deliberately not generic, for the same reason as TransitionsBlocked.
  struct EventNotRecognized
    # Protected so the outcome cannot be constructed from outside the FSM
    # namespace (D7). In-namespace callers such as StateDefinition#resolve build it.
    protected def initialize
    end
  end
end

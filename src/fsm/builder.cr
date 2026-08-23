module FSM
  # The machine-scoped builder yielded by Machine(T).build (design section 4, D2).
  #
  # `state` infers T from the enclosing builder, so T is named once per machine.
  # A partially-built StateDefinition never escapes the block as a loose local:
  # the builder registers it internally and seals it at the end of the block, which
  # is what closes the window in which a caller could hold an unsealed state
  # (design section 4). At the end of the block `finish` validates every transition
  # target, seals every definition, and returns the immutable machine.
  #
  # Duplicate-state-id detection is a separate concern (fsmcr-dy7) and is not
  # implemented here.
  class Builder(T)
    @id : String
    @states : Hash(String, StateDefinition(T))

    def initialize(@id : String)
      @states = {} of String => StateDefinition(T)
    end

    # Register a state, yielding its definition so transitions and callbacks can be
    # attached (design section 4). The definition is registered regardless of what
    # the block returns.
    def state(id : String, &) : StateDefinition(T)
      definition : StateDefinition(T) = StateDefinition(T).new(id)
      yield definition
      @states[id] = definition
      definition
    end

    # Validate targets, seal, and return the immutable machine (design section 4,
    # section 10.1 steps 2-4).
    protected def finish : Machine(T)
      validate_targets
      @states.each_value(&.seal)
      Machine(T).new(@id, @states)
    end

    # Every transition target must name a state that exists (design section 4).
    # Because this runs at build and sealing prevents post-build mutation, a
    # missing target can never surface at runtime.
    private def validate_targets : Nil
      @states.each do |id, definition|
        missing : Array(String) = definition.all_target_states - @states.keys
        raise MissingTargetStateError.new "Invalid target state(s) found in #{id} transitions. Invalid target(s) found: #{missing}" unless missing.empty?
      end
    end
  end
end

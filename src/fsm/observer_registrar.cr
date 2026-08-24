module FSM
  # Collects a Service's observers during construction, then goes inert.
  #
  # Service.interpret yields one registrar to its builder block. The block registers
  # observers into it, interpret copies them once into the Service, and interpret
  # seals the registrar. This is the build-then-seal idiom the Machine and State
  # builders use: a partially-built thing is registered
  # inside the block and frozen at the end, so no caller can mutate observers on the
  # live interpreter.
  #
  # Both observers hold a single slot: the latest registration within the block
  # replaces the previous one, the same last-write-wins semantics StateDefinition
  # uses for on_entry and on_exit. The captured blocks are typed `State ->`; State is
  # the runtime snapshot, which carries no generic parameter, so the registrar is not
  # generic over T.
  #
  # Once interpret has copied the observers and returned, the registrar is sealed and
  # its registration methods raise SealedStateError, mirroring StateDefinition and
  # Transition, whose builder methods raise once the machine seals them. An escaped
  # registrar reference cannot mutate the live service's
  # observers.
  #
  # Sealing happens only on the successful path. If the setup block raises, interpret
  # never reaches seal, and the registrar is discarded unsealed with no live object
  # escaping the failed call. This matches Machine.build, which also abandons a
  # half-built definition when its block raises rather than returning it.
  #
  # Sealing guards post-construction misuse, not intra-block leaks. The registrar
  # holds no internal lock, so a block that leaks the registrar to another fiber
  # during construction is outside the guarantee, consistent with the project's stance
  # that concurrency safety comes from sealing and single-owner access after
  # construction, not from guarding intra-build escapes.
  class ObserverRegistrar
    @on_transition : (State ->)? = nil
    @on_event_processed : (State ->)? = nil
    @sealed : Bool = false

    protected def initialize
    end

    # Register the observer fired only when a transition actually occurred.
    # Single-slot: the latest registration replaces the previous
    # one. Raises once interpret has sealed the registrar.
    def on_transition(&block : State ->) : self
      raise SealedStateError.new "Cannot register an on_transition observer after interpret has sealed the registrar." if @sealed
      @on_transition = block
      self
    end

    # Register the observer fired after every step, regardless of outcome.
    # Single-slot: the latest registration replaces the previous one. Raises once
    # interpret has sealed the registrar.
    def on_event_processed(&block : State ->) : self
      raise SealedStateError.new "Cannot register an on_event_processed observer after interpret has sealed the registrar." if @sealed
      @on_event_processed = block
      self
    end

    # The collected on_transition observer, or nil when none was registered. Read
    # once by interpret to copy the handler into the Service.
    protected def on_transition_handler : (State ->)?
      @on_transition
    end

    # The collected on_event_processed observer, or nil when none was registered.
    # Read once by interpret to copy the handler into the Service.
    protected def on_event_processed_handler : (State ->)?
      @on_event_processed
    end

    # Seal the registrar so later registration through an escaped reference raises.
    # Idempotent.
    protected def seal : Nil
      @sealed = true
    end
  end
end

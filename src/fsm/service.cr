module FSM
  # The synchronous interpreter (design section 8.1, section 10.2).
  #
  # Service(T) serializes by lock: many fibers may execute the machine's code, one
  # at a time, queueing on @transition_mutex (design section 12.2). It holds the
  # shared immutable machine, the caller's context, and one cached State snapshot.
  #
  # D18: the snapshot is the interpreter's only position field. Service derives the
  # current StateDefinition from `snapshot.id` when it needs to plan, rather than
  # holding both a snapshot and a definition and keeping them in step.
  #
  # Scope note (fsmcr-crj): `current_state` and `send` changing their public return
  # to the snapshot is a later issue. In this issue `current_state` returns the
  # current state id and `matches?` compares against it, preserving today's
  # observable position contract.
  class Service(T)
    @machine : Machine(T)
    @context : T
    # D18: the cached snapshot is the sole record of where the interpreter is.
    @state : State
    @transition_mutex : Mutex = Mutex.new
    @on_transition : (State ->)? = nil

    protected def initialize(@machine : Machine(T), @state : State, @context : T)
    end

    # Interpret the machine from an initial state (design section 10.2, steps 5-6).
    # Validates the initial state against the sealed machine and builds the initial
    # snapshot: the initial id, Success, and no error.
    def self.interpret(machine : Machine(T), initial_state : String, context : T) : Service(T)
      raise InvalidInitialStateError.new "Expected states to include the initial state. A state with id #{initial_state} was not found." unless machine.state_by_id(initial_state)
      new(machine, State.new(id: initial_state, status: Status::Success, error: nil), context)
    end

    # The current state id (design section 8.1). Reads the cached snapshot's id.
    # Locked under @transition_mutex because @state is a 3-field struct snapshot
    # that `send` replaces as a whole: a parallel reader can tear it mid-write,
    # unlike the old single-reference position field. The lock is what makes the
    # interpreter's own state advance atomically (design section 12.3, point 2).
    def current_state : String
      @transition_mutex.synchronize { @state.id }
    end

    # Sugar for `current_state == state_id` (design section 8.1). Locked for the
    # same torn-read reason as `current_state` (design section 12.3, point 2).
    def matches?(state_id : String) : Bool
      @transition_mutex.synchronize { @state.id == state_id }
    end

    # Register an observer fired only when a transition actually occurred (design
    # section 9). The payload is the snapshot; its exact shape is settled under
    # fsmcr-crj.
    def on_transition(&block : State ->) : self
      @on_transition = block
      self
    end

    # Send an event, blocking until it is applied, and return the resulting
    # snapshot (design section 10.3). Guards run inside the critical section
    # (design section 10.7).
    def send(event : String) : State
      @transition_mutex.synchronize do
        # Step 8: derive the current definition from the cached snapshot id (D18).
        definition : StateDefinition(T)? = @machine.state_by_id(@state.id)
        # The snapshot id always came from the machine, so the definition exists.
        return @state unless definition

        # Steps 9-16: the pure core decides; it runs nothing.
        plan : Plan(T) = @machine.plan(definition, event, @context)

        # Step 17: run each action in order. The only place user callback code runs.
        # A blocked or unrecognized event has an empty action list in this issue, so
        # nothing runs (design section 10.2 step 15).
        plan.actions.each(&.callback.call(event, @context))

        # Step 18: commit by replacing the cached snapshot (D18). next_state is the
        # target on TransitionFound and the unchanged current state otherwise.
        @state = State.new(id: plan.next_state.id, status: Status::Success, error: nil)

        # Step 20: fire on_transition only when a transition actually occurred
        # (design section 9). Blocked and unrecognized events do not fire it.
        @on_transition.try(&.call(@state)) if plan.outcome.is_a?(TransitionFound)

        @state
      end
    end
  end
end

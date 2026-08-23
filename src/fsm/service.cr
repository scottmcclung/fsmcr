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
    @on_event_processed : (State ->)? = nil

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

    # Register an observer fired after every step, regardless of outcome: a
    # successful transition, a guard-blocked event, an unknown event, or a failed
    # step (design section 9, D19). The handler receives the snapshot the step
    # produced (design section 10.3 step 20); it carries no outcome discrimination
    # (D15). Single-slot like on_transition: the latest registration replaces the
    # previous handler and self is returned so registration chains.
    #
    # Warning: the observer runs inside send while @transition_mutex is held, so
    # calling send from the observer (or from on_transition) re-enters the mutex and
    # raises a recursive-lock error. Cascading events by queueing and draining after
    # commit is a separate, unbuilt feature; today the observer must not call send.
    def on_event_processed(&block : State ->) : self
      @on_event_processed = block
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
        transitioned : Bool = false
        begin
          plan.actions.each(&.callback.call(event, @context))

          # Step 18: commit by replacing the cached snapshot (D18). next_state is
          # the target on TransitionFound and the unchanged current state otherwise.
          @state = State.new(id: plan.next_state.id, status: Status::Success, error: nil)
          transitioned = plan.outcome.is_a?(TransitionFound)
        rescue ex
          # Step 19: a callback raised, so the commit is never reached and the state
          # pointer stays where it was (design section 11). The snapshot records the
          # unchanged id, Failed, and the exception that stopped the step.
          @state = State.new(id: @state.id, status: Status::Failed, error: ex)
        end

        # Step 20: on_transition fires only when a transition actually completed
        # (design section 9, D19); a blocked, unrecognized, or failed step does not
        # fire it. on_event_processed fires after every step and receives the
        # snapshot step 18 or 19 produced. on_transition runs first on success.
        @on_transition.try(&.call(@state)) if transitioned
        fire_event_processed(@state)

        @state
      end
    end

    # Fire the after-every-step observer with the snapshot the step produced. The
    # two branches are asymmetric on what happens when the observer itself raises.
    #
    # On a failed step the snapshot already carries the first exception (design
    # section 9), so an observer that raises must not replace it and must not turn
    # the returning path into a raise (design section 11): the observer's exception
    # is discarded and the first recorded exception wins. The bare rescue discards
    # it with no logging or trace; that silence is deliberate (design section 9).
    #
    # On a non-failed step (status Success, covering a successful transition, a
    # blocked event, and an unknown event) there is no recorded exception, so the
    # observer runs unguarded and an exception it raises propagates out of send,
    # consistent with on_transition's pre-existing behavior.
    private def fire_event_processed(snapshot : State) : Nil
      handler : (State ->)? = @on_event_processed
      return unless handler

      if snapshot.status.failed?
        begin
          handler.call(snapshot)
        rescue
          # The observer's own exception is discarded, not logged (design section 9).
        end
      else
        handler.call(snapshot)
      end
    end
  end
end

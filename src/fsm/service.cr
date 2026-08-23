module FSM
  # The synchronous interpreter (design section 8.1, section 10.2).
  #
  # Service(T) serializes by lock: many fibers may execute the machine's code, one
  # at a time, queueing on @transition_mutex (design section 12.2). It holds the
  # shared immutable machine, the caller's context, and one cached State snapshot.
  #
  # Section 12's serialization contract, as it lands here: @transition_mutex covers
  # interpreter state only, that is @state and the observers read alongside it. The
  # machine definition is safe to share without the lock because it is sealed and
  # immutable after build (design section 12.3, point 1). T is the caller's
  # responsibility; the library guarantees nothing about a context shared across
  # interpreters or fibers (design section 12.3, point 3). AsyncService(T) serializes
  # the same interpreter state by fiber ownership instead of a lock: exactly one fiber
  # ever runs the machine's code (design section 12.2).
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
    include ObserverFiring

    @machine : Machine(T)
    @context : T
    # D18: the cached snapshot is the sole record of where the interpreter is.
    @state : State
    @transition_mutex : Mutex = Mutex.new
    # Observers are copied once from the ObserverRegistrar at construction and never
    # rewritten afterward (design section 9, section 10.3 step 20, D19). There is no
    # setter on a live service; a partially-built registrar is frozen when interpret
    # returns, the same build-then-seal idiom the Machine and State builders use
    # (design section 4, section 5).
    @on_transition : (State ->)?
    @on_event_processed : (State ->)?

    protected def initialize(@machine : Machine(T), @state : State, @context : T, @on_transition : (State ->)? = nil, @on_event_processed : (State ->)? = nil)
    end

    # Interpret the machine from an initial state, registering no observers (design
    # section 10.2, steps 5-6). Validates the initial state against the sealed
    # machine and builds the initial snapshot: the initial id, Success, and no error.
    def self.interpret(machine : Machine(T), initial_state : String, context : T) : Service(T)
      new(machine, build_initial_state(machine, initial_state), context)
    end

    # Interpret the machine and register observers through a builder block (design
    # section 10.2, section 9). The block receives an ObserverRegistrar; it registers
    # on_transition and on_event_processed handlers into it. The handlers are copied
    # once into this service and the registrar is sealed before interpret returns, so
    # no caller can mutate observers on the live interpreter (design section 5). This
    # mirrors how the Machine and State builders seal at the end of their block
    # (design section 4).
    def self.interpret(machine : Machine(T), initial_state : String, context : T, & : ObserverRegistrar ->) : Service(T)
      initial : State = build_initial_state(machine, initial_state)
      registrar : ObserverRegistrar = ObserverRegistrar.new
      yield registrar
      service : Service(T) = new(
        machine,
        initial,
        context,
        registrar.on_transition_handler,
        registrar.on_event_processed_handler,
      )
      registrar.seal
      service
    end

    # Validate the initial state against the sealed machine and build the initial
    # snapshot both interpret overloads start from: the initial id, Success, and no
    # error (design section 10.2, steps 5-6). Raises InvalidInitialStateError when the
    # machine has no state with that id.
    private def self.build_initial_state(machine : Machine(T), initial_state : String) : State
      raise InvalidInitialStateError.new "Expected states to include the initial state. A state with id #{initial_state} was not found." unless machine.state_by_id(initial_state)
      State.new(id: initial_state, status: Status::Success, error: nil)
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

    # Send an event, blocking until it is applied, and return the resulting
    # snapshot (design section 10.3). Guards run inside the critical section
    # (design section 10.7).
    def send(event : String) : State
      @transition_mutex.synchronize do
        # Step 8: derive the current definition from the cached snapshot id (D18).
        definition : StateDefinition(T)? = @machine.state_by_id(@state.id)
        # The snapshot id always came from the machine, so the definition exists.
        return @state unless definition

        # Steps 9-19: the pure core decides and the interpreter applies. plan is
        # inside this rescue because guards run inside plan (design section 10.2 step
        # 12) and planning is part of the step, so a guard that raises must surface as
        # a Failed snapshot on the returning path exactly like a raising callback
        # (design section 11: "where a value comes back, failure is in the value"). If
        # plan were called outside the rescue, a raising guard would propagate raw
        # instead of being enveloped.
        #
        # Widening the rescue over plan is deliberate. Guards are user code that runs
        # inside plan, and per design section 11 the library does not distinguish a
        # raising guard from a library defect inside plan: both surface as a Failed
        # snapshot on the returning path.
        transitioned : Bool = false
        begin
          # Steps 9-16: the pure core decides; it runs nothing.
          plan : Plan(T) = @machine.plan(definition, event, @context)

          # Step 17: run each action in order. The only place user callback code runs.
          # A blocked or unrecognized event has an empty action list in this issue, so
          # nothing runs (design section 10.2 step 15).
          plan.actions.each(&.callback.call(event, @context))

          # Step 18: commit by replacing the cached snapshot (D18). next_state is
          # the target on TransitionFound and the unchanged current state otherwise.
          @state = State.new(id: plan.next_state.id, status: Status::Success, error: nil)
          transitioned = plan.outcome.is_a?(TransitionFound)
        rescue ex
          # Step 19: a guard or callback raised, so the commit is never reached and the
          # state pointer stays where it was (design section 11). The snapshot records
          # the unchanged id, Failed, and the exception that stopped the step.
          @state = State.new(id: @state.id, status: Status::Failed, error: ex)
        end

        # Step 20: fire the observers copied from the ObserverRegistrar at
        # construction (design section 9, D19). fire_observers returns the first
        # observer exception, or nil.
        #
        # Warning: both observers run here while @transition_mutex is held, so
        # calling send from an observer re-enters the mutex and raises a
        # recursive-lock error. Cascading events by queueing and draining after
        # commit is a separate, unbuilt feature; today an observer must not call send.
        observer_error : Exception? = fire_observers(@state, transitioned)

        # Re-raise the first observer exception to the caller. Service is synchronous:
        # the calling fiber is present to receive the raise, and Service has no
        # lifecycle to poison (design section 9, section 11). This is the deliberate
        # divergence from AsyncService, which records the observer exception in its
        # lifecycle and returns the snapshot because no calling fiber is waiting on the
        # owning fiber (design section 8.2, section 11). The re-raise unwinds through
        # synchronize's ensure, which releases @transition_mutex, so the lock covers
        # only interpreter state and a raising observer never leaves it held (design
        # section 12). The transition already committed at step 18, so the raise does
        # not undo it.
        raise observer_error if observer_error

        @state
      end
    end
  end
end

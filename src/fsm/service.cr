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
  # When T carries its own lock, that lock nests inside @transition_mutex, never the
  # reverse: guards and callbacks receive the context directly and only reach its lock
  # while @transition_mutex is already held; an observer reaches it only if a caller's
  # closure captures the context externally, which still runs under the same lock. The
  # order is transition-mutex-before-context-mutex on every internal path. A caller who
  # calls send while holding a context lock the step's callbacks will want inverts that
  # order and can deadlock (design section 12.7).
  #
  # D18: the snapshot is the interpreter's only position field. Service derives the
  # current StateDefinition from `snapshot.id` when it needs to plan, rather than
  # holding both a snapshot and a definition and keeping them in step. `current_state`
  # returns that cached snapshot, and `matches?` compares against its id (design
  # section 8.1).
  class Service(T)
    include ObserverFiring

    @machine : Machine(T)
    @context : T
    # D18: the cached snapshot is the sole record of where the interpreter is.
    @state : State
    @transition_mutex : Mutex = Mutex.new
    # The fiber currently holding @transition_mutex, or nil when the lock is free
    # (design section 8.1, section 10.4, fsmcr-999). This is how send, current_state, and
    # matches? tell a reentrant call (a callback on the same service calling in, same
    # fiber, mutex already held) from a fresh cross-fiber call.
    #
    # Written only inside the synchronize block: set to the owning fiber on entry,
    # cleared to nil in the ensure before the lock releases. Read without the lock at the
    # top of send, current_state, and matches?, because a reentrant call cannot re-acquire
    # the checked mutex (Crystal raises "Can't lock mutex recursively"), so the read must
    # happen without it.
    #
    # It is an Atomic, not a plain ivar, and that is the section 12 argument. The unlocked
    # reader runs on a different worker thread from the writer, so it needs a happens-before
    # edge to the write. A plain ivar has none: it would rely on hardware cache coherency
    # to make the write visible, which the Crystal memory model does not promise. Atomic
    # .set/.get carry acquire/release ordering, which supplies that edge. The atomic closes
    # the visibility gap; it is the identity-write discipline that rules out false positives.
    # A fiber only ever stores its own identity, and only under the lock, so for
    # `.get.same?(current)` to hold, some fiber must have written the calling fiber's
    # identity, and only the calling fiber writes that. A non-owner therefore never reads its
    # own identity (no false positive) and falls through to synchronize exactly as before, so
    # cross-fiber serialization is unchanged. The owner running a callback reads back the
    # value it just wrote, since no other fiber can overwrite it without the lock the owner
    # holds (no false negative).
    @owner_fiber : Atomic(Fiber?) = Atomic(Fiber?).new(nil)
    # Events queued by callbacks (or observers) during a step, drained FIFO after the
    # step commits (design section 10.3 step 21, section 10.4). Touched only by whichever
    # fiber currently owns the mutex: a reentrant push runs on the owner fiber, and the
    # drain runs on the owner fiber, so it needs no lock of its own. This mirrors
    # AsyncService's @cascade (src/fsm/async_service.cr).
    @pending : Deque(String) = Deque(String).new
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

    # The cached State snapshot (design section 3.3, section 8.1, D18). One type
    # describes the runtime value everywhere it is read; `current_state.id` gives the
    # string when that is what is wanted. State is an immutable value, so returning it
    # leaks no mutability back into the interpreter.
    #
    # Locked under @transition_mutex because @state is a 3-field struct snapshot that
    # `send` replaces as a whole: a parallel reader can tear it mid-write. The lock is
    # what makes the interpreter's own state advance atomically (design section 12.3,
    # point 2).
    #
    # A callback of this same service calls on the owner fiber, which already holds
    # the mutex; re-acquiring the checked mutex would raise "Can't lock mutex
    # recursively", so the whole outer transition would fall into the failure envelope.
    # The owner instead reads @state directly, no lock: @state is written only by the
    # owner fiber while it holds the lock, so the owner reading its own writes is safe,
    # and per section 11 an entry callback reading here sees the OLD, pre-commit
    # snapshot. Non-owner fibers take the locked path unchanged.
    def current_state : State
      current : Fiber = Fiber.current
      owner : Fiber? = @owner_fiber.get
      return @state if owner && owner.same?(current)
      @transition_mutex.synchronize { @state }
    end

    # Sugar for `current_state.id == state_id` (design section 8.1). Locked for the
    # same torn-read reason as `current_state` (design section 12.3, point 2), and
    # takes the same owner-fiber fast path so a reentrant callback does not deadlock
    # on the checked mutex.
    def matches?(state_id : String) : Bool
      current : Fiber = Fiber.current
      owner : Fiber? = @owner_fiber.get
      return @state.id == state_id if owner && owner.same?(current)
      @transition_mutex.synchronize { @state.id == state_id }
    end

    # Send an event, blocking until it is applied, and return the resulting
    # snapshot (design section 10.3). Guards run inside the critical section
    # (design section 10.7).
    #
    # A send called from inside a callback of this same service is reentrant: it runs
    # on the fiber that already holds @transition_mutex, so it cannot re-acquire the
    # checked mutex (design section 10.4). Instead it queues the event and returns the
    # CURRENT committed snapshot, the state the interpreter is committed to at the
    # moment of the call. During a step the commit has not happened yet (design section
    # 10.3 step 18 runs after the callbacks), so an entry callback's reentrant send
    # observes the OLD state (design section 11). The queued event drains after the
    # current step commits, in the outer send's drain loop below.
    def send(event : String) : State
      current : Fiber = Fiber.current
      owner : Fiber? = @owner_fiber.get
      if owner && owner.same?(current)
        @pending.push(event)
        return @state
      end

      @transition_mutex.synchronize do
        @owner_fiber.set(current)
        begin
          # Step 8-20: run the outer event's own step. Its snapshot is the value send
          # returns (design section 10.5 step 22: "the State snapshot built at step
          # 19"), captured before the drain, mirroring AsyncService replying in
          # process_event ahead of drain_cascades (src/fsm/async_service.cr).
          snapshot : State
          transitioned : Bool
          snapshot, transitioned = apply_event(event)

          # Step 20: fire the observers copied from the ObserverRegistrar at
          # construction (design section 9, D19). fire_observers returns the first
          # observer exception, or nil.
          observer_error : Exception? = fire_observers(snapshot, transitioned)

          # An observer raised on the outer step. Re-raise to the calling fiber after
          # the observers fired, without draining: the abort loses any event a callback
          # or observer queued this step (design-silent decision 4, fsmcr-1uo scope
          # note). Service is synchronous, so the calling fiber is present to receive
          # the raise and Service has no lifecycle to poison, unlike AsyncService which
          # records the exception in its lifecycle (design section 9, section 11). The
          # raise unwinds through the ensure and synchronize, releasing the lock; the
          # transition already committed at step 18, so the raise does not undo it.
          raise observer_error if observer_error

          # Step 21: drain the queue only when the outer step committed. A failed outer
          # step halts here exactly as a failed drained step halts the drain below
          # (design section 10.3 step 21).
          drain unless snapshot.status.failed?

          snapshot
        ensure
          # Clear before the lock releases so the next owner starts clean. On a normal
          # return @pending is already empty; on an aborted drain or a raising observer
          # it holds the lost events, which are discarded here (design-silent decisions
          # 3 and 4).
          @pending.clear
          @owner_fiber.set(nil)
        end
      end
    end

    # Drain events queued by callbacks (or observers) during a step, FIFO, each looping
    # back through the full step sequence (design section 10.3 step 21, section 10.4).
    # A drained event's own callbacks may queue further events, appended to @pending and
    # drained in turn, so the loop settles a whole cascade before returning.
    #
    # A drained step whose callback or guard raises yields a Failed snapshot (the
    # existing failure envelope); the drain HALTS there and events still queued are lost
    # (design-silent decision 3, mirroring AsyncService's drain_cascades). A drained
    # step whose observer raises aborts the drain and re-raises to the outer send after
    # that event's observers fired, also losing events still queued (design-silent
    # decision 4, fsmcr-1uo scope note). The two are mutually exclusive: on a failed step
    # fire_observers returns nil (design section 9), so an observer exception can only
    # arise on a committed step.
    private def drain : Nil
      while event = @pending.shift?
        snapshot : State
        transitioned : Bool
        snapshot, transitioned = apply_event(event)

        observer_error : Exception? = fire_observers(snapshot, transitioned)
        raise observer_error if observer_error

        return if snapshot.status.failed?
      end
    end

    # Run one event's step: plan, apply the actions, and commit or record the failure
    # (design section 10.3 steps 8-19). Returns the committed snapshot and whether a
    # transition actually completed. Mirrors AsyncService#apply (src/fsm/async_service.cr).
    #
    # plan is inside the rescue because guards run inside plan (design section 10.2 step
    # 12) and planning is part of the step, so a guard that raises must surface as a
    # Failed snapshot on the returning path exactly like a raising callback (design
    # section 11: "where a value comes back, failure is in the value"). Widening the
    # rescue over plan is deliberate: the library does not distinguish a raising guard
    # from a library defect inside plan; both surface as a Failed snapshot.
    private def apply_event(event : String) : {State, Bool}
      # Step 8: derive the current definition from the cached snapshot id (D18).
      definition : StateDefinition(T)? = @machine.state_by_id(@state.id)
      # The snapshot id always came from the machine, so the definition exists.
      return {@state, false} unless definition

      transitioned : Bool = false
      begin
        # Steps 9-16: the pure core decides; it runs nothing.
        plan : Plan(T) = @machine.plan(definition, event, @context)

        # Step 17: run each action in order. The only place user callback code runs.
        # A blocked or unrecognized event has an empty action list in this issue, so
        # nothing runs (design section 10.2 step 15).
        plan.actions.each(&.callback.call(event, @context))

        # Step 18: commit by replacing the cached snapshot (D18). next_state is the
        # target on TransitionFound and the unchanged current state otherwise.
        @state = State.new(id: plan.next_state.id, status: Status::Success, error: nil)
        transitioned = plan.outcome.is_a?(TransitionFound)
      rescue ex
        # Step 19: a guard or callback raised, so the commit is never reached and the
        # state pointer stays where it was (design section 11). The snapshot records
        # the unchanged id, Failed, and the exception that stopped the step.
        @state = State.new(id: @state.id, status: Status::Failed, error: ex)
      end

      {@state, transitioned}
    end
  end
end

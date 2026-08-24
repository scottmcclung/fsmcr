module FSM
  # :nodoc:
  #
  # One event handed to the owning fiber. A post
  # carries no reply (`reply` is nil); a send carries a capacity-1 reply channel the
  # owning fiber sends the step's State snapshot back on.
  # Not generic over T: the event is a String and the reply is a State, which carries
  # no context.
  private struct EventMessage
    getter event : String
    getter reply : Channel(State)?

    def initialize(@event : String, @reply : Channel(State)? = nil)
    end
  end

  # :nodoc:
  #
  # A synchronous stop request. It travels through the same
  # mailbox as events, so events already queued ahead of it drain before the async
  # service stops. `ack` is signalled once the owning fiber has recorded the stop,
  # which is what makes #stop synchronous.
  private struct StopMessage
    getter ack : Channel(Nil)

    def initialize(@ack : Channel(Nil))
    end
  end

  # :nodoc:
  private alias Message = EventMessage | StopMessage

  # :nodoc:
  #
  # An unbounded FIFO mailbox with one blocking consumer and many non-blocking
  # producers. `post` must return immediately, so producers never block on a full buffer the way a fixed
  # Channel would; the queue grows instead. The single owning fiber blocks in
  # `receive` when the queue is empty and a producer wakes it. `close` followed by
  # draining lets the owning fiber reject anything still queued at shutdown without a
  # producer ever deadlocking on a reply that will not come.
  private class Mailbox
    @items : Deque(Message) = Deque(Message).new
    @mutex : Mutex = Mutex.new
    @closed : Bool = false
    # Set only while the consumer sleeps on an empty, open queue. A producer clears
    # it and signals it once, so the capacity-1 send never blocks.
    @waiter : Channel(Nil)? = nil

    # Enqueue a message and wake a sleeping consumer. Raises Channel::ClosedError
    # once the mailbox is closed, which is how a post or send after shutdown learns
    # to give up rather than wait forever.
    def send(message : Message) : Nil
      waiter : Channel(Nil)? = nil
      @mutex.synchronize do
        raise Channel::ClosedError.new if @closed
        @items.push(message)
        waiter = @waiter
        @waiter = nil
      end
      w : Channel(Nil)? = waiter
      w.send(nil) if w
    end

    # Take the next message, blocking the calling (owning) fiber while the queue is
    # empty and open. Returns nil once the mailbox is closed and drained, which ends
    # the owning fiber's shutdown drain.
    def receive : Message?
      loop do
        waiter : Channel(Nil)? = nil
        @mutex.synchronize do
          item : Message? = @items.shift?
          return item if item
          return nil if @closed
          waiter = Channel(Nil).new(1)
          @waiter = waiter
        end
        w : Channel(Nil)? = waiter
        w.receive if w
      end
    end

    # Close the mailbox so later sends raise. Idempotent. Only the owning fiber calls
    # this, at shutdown, so no consumer is ever sleeping when it runs.
    def close : Nil
      waiter : Channel(Nil)? = nil
      @mutex.synchronize do
        return if @closed
        @closed = true
        waiter = @waiter
        @waiter = nil
      end
      w : Channel(Nil)? = waiter
      w.send(nil) if w
    end
  end

  # :nodoc:
  #
  # The interpreter's own health, distinct from State#status.
  # State#status describes one transaction; this describes whether the owning fiber
  # is still draining the mailbox.
  private enum Lifecycle
    Running
    Stopped
    Errored
  end

  # The fiber-and-mailbox interpreter.
  #
  # AsyncService(T) is a second interpreter beside Service(T), not a replacement. It
  # serializes by ownership: exactly one fiber ever executes the machine's code, and
  # other fibers reach it only by putting a message in the mailbox. This is the
  # load-bearing difference from Service, which serializes by lock.
  # The three separable concerns land here as follows:
  # the machine definition is immutable after build and safe to share (sealing); the
  # interpreter's own state advances atomically because only the owning fiber touches
  # it; and nothing is guaranteed about T, which is the caller's responsibility.
  # Service arranges the second concern with a per-instance
  # mutex over interpreter state; AsyncService arranges it by fiber ownership instead.
  #
  # Planning happens on the owning fiber. This is the purity contract:
  # a guard reads context T while planning, and a guard on the owning fiber never sees
  # a T some other fiber is mutating mid-plan, because the owning fiber is the only one
  # that ever runs the machine's code. Purity is what the library asks of a guard;
  # ownership is what the interpreter supplies.
  #
  # `post` is fire-and-forget and returns immediately; `send` blocks the CALLING
  # fiber, not a thread, and reads the reply off a channel. The
  # rule that comes with that: post from inside a callback, send from outside. A send
  # from inside a callback of the same instance deadlocks, because it would be waiting
  # on itself; post from inside a callback remains safe. See
  # #send.
  #
  # AsyncService exposes no `context` getter. Reads go through `send` on the
  # owning fiber, which is the one place structural enforcement of context isolation
  # is available. That absence is deliberate and is why no such method appears below.
  class AsyncService(T)
    include ObserverFiring

    @machine : Machine(T)
    @context : T
    # The interpreter's only position field, mutated only by the owning fiber.
    @state : State
    @on_transition : (State ->)?
    @on_event_processed : (State ->)?

    # The unbounded inbox external fibers push to and the owning fiber drains.
    @mailbox : Mailbox = Mailbox.new
    # Events a callback posts while running on the owning fiber. They are drained within
    # the current step, ahead of the next external
    # message, so a cascade settles before an event queued from outside is handled,
    # mirroring Service's drain of pending events. Touched only by the
    # owning fiber, so it needs no lock.
    @cascade : Deque(String) = Deque(String).new

    # Lifecycle and the poisoning exception are written by the owning fiber and read
    # by any caller, so they are guarded. The machine's own state (@state) needs no
    # such guard because only the owning fiber ever touches it.
    @lifecycle : Lifecycle = Lifecycle::Running
    @error : Exception? = nil
    @lifecycle_mutex : Mutex = Mutex.new

    # The owning fiber. A post checks Fiber.current against it to tell a cascade
    # (from inside a callback) from an external post.
    @fiber : Fiber

    # Constructed only through `start`. Protected so the fiber-ownership setup cannot
    # be bypassed by a direct AsyncService(T).new call from outside the FSM namespace.
    # The owning fiber starts last, once every field it reads is
    # set, so it never observes a half-built async service even under real parallelism.
    # (T = Nil needs no guard here: Machine(Nil).build already fails at compile time
    # upstream, so no AsyncService(Nil) can be constructed to reach this point.)
    protected def initialize(@machine : Machine(T), @context : T, @state : State, @on_transition : (State ->)? = nil, @on_event_processed : (State ->)? = nil)
      @fiber = spawn(name: "fsm-async-service") { run }
    end

    # Start an async service interpreting the machine from an initial state,
    # registering no observers. The name pairs with
    # `stop` and the lifecycle predicates and avoids colliding with Crystal's builtin
    # fiber `spawn`. The owning fiber and mailbox are private; the caller drives
    # the async service only through post, send, and stop.
    def self.start(machine : Machine(T), initial : String, context : T) : AsyncService(T)
      new(machine, context, build_initial_state(machine, initial))
    end

    # Start an async service and register observers through a builder block. The block
    # receives an ObserverRegistrar, mirroring
    # Service.interpret: on_transition and on_event_processed handlers are copied
    # once into the async service and the registrar is sealed before start returns.
    def self.start(machine : Machine(T), initial : String, context : T, & : ObserverRegistrar ->) : AsyncService(T)
      registrar : ObserverRegistrar = ObserverRegistrar.new
      yield registrar
      service : AsyncService(T) = new(
        machine,
        context,
        build_initial_state(machine, initial),
        registrar.on_transition_handler,
        registrar.on_event_processed_handler,
      )
      registrar.seal
      service
    end

    # Validate the initial state against the sealed machine and build the initial
    # snapshot both start overloads start from: the initial id, Success, and no error.
    # Raises InvalidInitialStateError when the machine
    # has no state with that id, mirroring Service.build_initial_state. Without this
    # guard a wrong id yields an interpreter whose apply never finds a definition and so
    # never advances, holding Success forever.
    private def self.build_initial_state(machine : Machine(T), initial : String) : State
      raise InvalidInitialStateError.new "Expected states to include the initial state. A state with id #{initial} was not found." unless machine.state_by_id(initial)
      State.new(id: initial, status: Status::Success, error: nil)
    end

    # Enqueue an event to the mailbox and return immediately. Fire-and-forget: the work
    # happens on the owning fiber.
    #
    # A post from inside a callback is the safe direction: it is
    # detected as running on the owning fiber and queued as a cascade, drained within
    # the current step. A post from any other fiber goes to the mailbox.
    #
    # A callback that raises under post poisons the async service:
    # post has already returned, so there is no snapshot to hand back and the failure
    # is recorded in the interpreter instead. A post into a stopped or errored async
    # service is dropped silently, because there is no return value to carry a refusal.
    def post(event : String) : Nil
      if Fiber.current == @fiber
        @cascade.push(event)
        return
      end

      return unless running?
      @mailbox.send(EventMessage.new(event, nil))
    rescue Channel::ClosedError
      # The async service stopped or errored between the running? check and the
      # enqueue; the post is dropped silently.
    end

    # Enqueue an event and block the CALLING fiber until the owning fiber replies with
    # the State snapshot built for the step. A callback that raises under send yields a
    # Failed snapshot returned
    # as a value; no exception crosses the reply channel.
    #
    # Send from outside a callback only. A send from inside a callback of the same
    # instance deadlocks: the callback runs on the owning fiber, and the reply it waits
    # on can only be produced by that same owning fiber, so it waits on itself forever.
    # From inside a callback, post instead. A cross-fiber send made
    # while holding a context lock the owning fiber's callback wants is the same deadlock
    # seen through that lock, since the caller blocks on the reply while the callback
    # blocks on the lock.
    #
    # A send into a stopped or errored async service short-circuits before touching
    # the mailbox and returns a Failed snapshot as a value: the
    # owning fiber is no longer draining, so enqueuing and waiting for a reply would
    # deadlock. An errored async service returns the recorded poisoning exception; a
    # stopped one returns a StoppedError.
    def send(event : String) : State
      return refused_snapshot unless running?

      reply : Channel(State) = Channel(State).new(1)
      begin
        @mailbox.send(EventMessage.new(event, reply))
      rescue Channel::ClosedError
        return refused_snapshot
      end
      reply.receive
    end

    # Stop the async service and return once it has stopped.
    # Synchronous: `stopped?` is deterministically true after this returns. The stop
    # request travels through the mailbox behind any events already queued, so those
    # events drain before it stops; nothing queued after the stop is processed. On an
    # async service that has already stopped or errored the mailbox is closed, and
    # stop returns without effect.
    def stop : Nil
      ack : Channel(Nil) = Channel(Nil).new(1)
      begin
        @mailbox.send(StopMessage.new(ack))
      rescue Channel::ClosedError
        return
      end
      ack.receive
    end

    # Whether the owning fiber is still draining the mailbox.
    # A separate concept from State#status, which describes one transaction.
    def running? : Bool
      @lifecycle_mutex.synchronize { @lifecycle.running? }
    end

    # Whether the async service was stopped through #stop.
    def stopped? : Bool
      @lifecycle_mutex.synchronize { @lifecycle.stopped? }
    end

    # Whether a callback raised under post and poisoned the async service. An errored
    # async service has stopped draining its
    # mailbox.
    def errored? : Bool
      @lifecycle_mutex.synchronize { @lifecycle.errored? }
    end

    # The exception that errored the async service, or nil when it has not errored.
    # This is the exception a callback raised under post,
    # recorded because post has no return value to carry the failure back.
    def error : Exception?
      @lifecycle_mutex.synchronize { @error }
    end

    # The owning fiber's loop. It drains the mailbox one message
    # at a time; being the only fiber that runs the machine's code is what serializes
    # the interpreter. It exits on a stop request or when a post
    # poisons the async service, then rejects anything still queued so no waiting
    # caller hangs.
    private def run : Nil
      loop do
        message : Message? = @mailbox.receive
        break if message.nil?

        case message
        in StopMessage
          mark_stopped
          message.ack.send(nil)
          break
        in EventMessage
          break unless step(message)
        end
      end
      shutdown
    end

    # Process one external message, then drain any cascades it queued. Returns whether
    # the owning fiber should keep
    # draining; false once a post has poisoned the async service.
    private def step(message : EventMessage) : Bool
      return false unless process_event(message.event, message.reply)
      drain_cascades
    end

    # Drain cascade events queued by callbacks on the owning fiber. Each is a post, so a
    # failure among them poisons the async service
    # and stops the drain, matching a top-level post.
    private def drain_cascades : Bool
      while event = @cascade.shift?
        unless process_event(event, nil)
          @cascade.clear
          return false
        end
      end
      true
    end

    # Plan, apply, and fire observers for one event, then reply if it was a send.
    # Returns whether the owning fiber
    # should keep draining.
    #
    # Two failure shapes are handled here. A transaction failure (a guard or callback
    # raised, so the snapshot is Failed) under a no-reply event (post or cascade) is
    # poisoning, so the async service is marked errored BEFORE on_event_processed
    # fires: that observer can signal a waiting fiber, and the fiber must never observe
    # the async service as still running after the poisoning step.
    # The same transaction failure under send is NOT poisoning; its Failed snapshot
    # returns as a value on the reply channel and the async service keeps draining.
    #
    # An observer failure is different. When an observer raises on a committed
    # (successful or blocked) step it is an interpreter-level failure, not a
    # transaction failure, so it poisons the async service under BOTH post and send.
    # The step committed, so under send the accurate committed snapshot is still
    # returned as the value and no exception crosses the reply channel; the caller sees
    # the poisoning through errored?/error. mark_errored runs before the reply so the
    # caller cannot observe the async service as still running after receiving the
    # snapshot.
    private def process_event(event : String, reply : Channel(State)?) : Bool
      snapshot : State
      transitioned : Bool
      snapshot, transitioned = apply(event)

      if reply.nil? && snapshot.status.failed?
        # A post or cascade transaction failed: poison first, then fire the after-
        # every-step observer. on_transition does not fire on a
        # failed step, and an exception the observer itself raises is discarded so the
        # first recorded exception stays authoritative.
        mark_errored(snapshot.error)
        fire_observers(snapshot, transitioned)
        return false
      end

      observer_error : Exception? = fire_observers(snapshot, transitioned)
      if observer_error
        # An observer raised on a committed step. Poison before replying so the caller
        # observes the errored condition once the reply arrives.
        mark_errored(observer_error)
      end
      reply.send(snapshot) if reply

      # The committed snapshot has already gone back to a waiting sender; the async
      # service stops draining because the observer poisoned it.
      return false if observer_error

      true
    end

    # Run the plan's actions and commit, or record a failure. Runs only on the owning
    # fiber, so @state needs no lock. Returns the
    # committed snapshot and whether a transition actually completed.
    private def apply(event : String) : {State, Bool}
      definition : StateDefinition(T)? = @machine.state_by_id(@state.id)
      # The snapshot id always came from the machine: start validates the initial id
      # through build_initial_state and every later id is a transition target the
      # machine resolved, so the definition exists.
      return {@state, false} unless definition

      transitioned : Bool = false
      begin
        # Guards run inside plan, so planning is inside
        # the same rescue as the callbacks. A guard that raises produces a Failed
        # snapshot exactly like a raising callback, and the commit is never reached.
        # If plan were called outside this rescue, a raising
        # guard would escape the owning fiber, kill it, and hang every waiting caller.
        # Widening the rescue over plan is deliberate. Guards are user code that runs
        # inside plan, and the library does not distinguish a
        # raising guard from a library defect inside plan: both surface as a Failed
        # snapshot on the returning path.
        plan : Plan(T) = @machine.plan(definition, event, @context)
        plan.actions.each(&.callback.call(event, @context))
        @state = State.new(id: plan.next_state.id, status: Status::Success, error: nil)
        transitioned = plan.outcome.is_a?(TransitionFound)
      rescue ex
        # A guard or callback raised, so the commit is never reached and the state
        # pointer stays where it was.
        @state = State.new(id: @state.id, status: Status::Failed, error: ex)
      end

      {@state, transitioned}
    end

    # Close the mailbox and reject anything still queued. A
    # closed mailbox makes later posts and sends give up instead of waiting, and any
    # message already buffered is rejected here so its sender never hangs.
    private def shutdown : Nil
      @mailbox.close
      while message = @mailbox.receive
        reject(message)
      end
    end

    # Refuse one queued message after the async service stopped draining. A send is
    # answered with a Failed snapshot value; a post is dropped; a racing stop is
    # acknowledged.
    private def reject(message : Message) : Nil
      case message
      in StopMessage
        message.ack.send(nil)
      in EventMessage
        reply : Channel(State)? = message.reply
        reply.send(refused_snapshot) if reply
      end
    end

    # The Failed snapshot a send receives when the async service is no longer running.
    # An errored async service reports the recorded poisoning
    # exception; a stopped one reports a StoppedError, since a clean stop has no
    # exception of its own and a Failed snapshot must carry one.
    # @state is read under the lifecycle lock for visibility of the owning fiber's last
    # commit; the async service is no longer running, so no concurrent write to @state
    # can occur.
    private def refused_snapshot : State
      @lifecycle_mutex.synchronize do
        recorded : Exception? = @error
        reason : Exception = recorded || StoppedError.new("The async service has stopped and accepts no further events.")
        State.new(id: @state.id, status: Status::Failed, error: reason)
      end
    end

    private def mark_errored(err : Exception?) : Nil
      @lifecycle_mutex.synchronize do
        @lifecycle = Lifecycle::Errored
        @error = err
      end
    end

    private def mark_stopped : Nil
      @lifecycle_mutex.synchronize do
        @lifecycle = Lifecycle::Stopped
      end
    end
  end
end

require "./spec_helper"

# The fiber-and-mailbox interpreter, AsyncService(T) (design section 8.2, section
# 10.5, section 11; D6, D7, D19).
#
# AsyncService is a SECOND interpreter beside Service, not a replacement. It
# serializes by ownership: exactly one fiber ever executes the machine's code, and
# other fibers reach it only by putting a message in the mailbox (design section
# 12.2). `post` is fire-and-forget and returns immediately; `send` blocks the CALLING
# fiber, not a thread, and reads the reply off a channel (design section 8.2). Both
# plan on the owning fiber, which the concurrency contract requires (design section
# 12.3).
#
# Two behaviors the design left open (section 15) are DECIDED here and documented at
# their specs below: what an errored or stopped async service does with a new event,
# and what happens when an observer itself raises while handling a failed step.

# A context whose callbacks record into a log and can drive the async service that
# owns it. Holding the reference is how a callback posts a follow-up event from inside
# a transition (design section 10.5 step 17): the callback receives (event, context),
# so the async service must be reachable through the context. The reference is set
# after start, which is safe because callbacks run only once an event is processed,
# well after construction.
class AsyncServiceLog
  getter log : Array(String) = [] of String
  property async_service : FSM::AsyncService(AsyncServiceLog)? = nil

  def record(message : String) : Nil
    @log << message
  end
end

# A context whose single field is written only by callbacks on the owning fiber. No
# lock of its own: under AsyncService the owning fiber is the sole writer, so none is
# needed. `steps` counts how many transition callbacks have run, which lets a spec
# assert an errored or stopped async service processed nothing further.
class AsyncServiceSteps
  property steps : Int32 = 0

  def bump : Nil
    @steps += 1
  end
end

describe "FSM::AsyncService" do
  describe "start and lifecycle" do
    it "is running after start, before any event" do
      ctx : AsyncServiceSteps = AsyncServiceSteps.new

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("idle") { |s| s.on_event("go", "busy") }
        m.state("busy") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "idle", context: ctx)

      # The lifecycle condition is the interpreter's own health, separate from
      # State#status (design section 8.2). A fresh async service is running, not
      # stopped, not errored.
      service.running?.should be_true
      service.stopped?.should be_false
      service.errored?.should be_false
      service.error.should be_nil

      service.stop
    end

    # start validates the initial state against the sealed machine, mirroring
    # Service(T).interpret (design section 10.2, step 5). Without this a wrong id
    # produces an interpreter that never advances.
    it "raises InvalidInitialStateError when the initial state is not in the machine" do
      ctx : AsyncServiceSteps = AsyncServiceSteps.new

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("idle") { |s| s.on_event("go", "busy") }
        m.state("busy") { |s| }
      end

      expect_raises(FSM::InvalidInitialStateError) do
        FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "nonexistent", context: ctx)
      end
    end
  end

  describe "send" do
    it "returns the snapshot built for the step (design section 10.5 step 22)" do
      ctx : AsyncServiceSteps = AsyncServiceSteps.new

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") { |t| t.on { |_e, c| c.bump } }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      # send runs the plan on the owning fiber and hands back the State snapshot the
      # step produced: the new id and Success (design section 10.5 step 22).
      result : FSM::State = service.send("north")
      result.id.should eq "clearing"
      result.status.should eq FSM::Status::Success
      result.error.should be_nil

      service.stop
    end

    it "returns a Success snapshot that moved nowhere for a blocked event" do
      ctx : TurnContext = TurnContext.new(rope_secured: false)

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
          s.on_blocked("north") { |_e, c, _blocked| c.say("too steep") }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(TurnContext) = FSM::AsyncService(TurnContext).start(machine, initial: "cave", context: ctx)

      # A guard-blocked event is a successful transaction that moved nowhere (design
      # section 3.3): Success, unchanged id.
      result : FSM::State = service.send("north")
      result.status.should eq FSM::Status::Success
      result.id.should eq "cave"

      service.stop
    end

    it "blocks the calling fiber, not the thread, while other fibers keep running" do
      # A deterministic handshake proves the calling fiber is suspended, not the
      # worker thread: while fiber A is blocked inside send, the main fiber runs,
      # observes A has not yet returned, and only then releases A. The callback runs
      # on the OWNING fiber, so a channel it waits on parks the owning fiber; A stays
      # parked on the reply channel; the main fiber is free to make progress. If send
      # blocked a thread rather than a fiber, the main fiber could not run here.
      ready : Channel(Nil) = Channel(Nil).new
      resume : Channel(Nil) = Channel(Nil).new
      ctx : AsyncServiceSteps = AsyncServiceSteps.new

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") do |t|
            t.on do |_e, c|
              c.bump
              ready.send(nil)
              resume.receive
            end
          end
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      a_returned : Bool = false
      a_result : FSM::State? = nil
      done : Channel(Nil) = Channel(Nil).new

      spawn do
        a_result = service.send("north")
        a_returned = true
        done.send(nil)
      end

      # The callback is now mid-flight on the owning fiber, so A is parked in send.
      # The timeout keeps a broken or unimplemented interpreter from hanging the
      # suite: if the callback never runs, the example fails instead of blocking
      # forever.
      select
      when ready.receive
        # proceed
      when timeout(5.seconds)
        fail "send never reached its callback; blocking-fiber semantics unverified"
      end
      # The main fiber ran while A is blocked. A cannot have returned yet, because the
      # callback is still waiting on `resume`.
      a_returned.should be_false

      resume.send(nil)
      select
      when done.receive
        # proceed
      when timeout(5.seconds)
        fail "send never returned after the callback was released"
      end

      a_returned.should be_true
      snapshot : FSM::State? = a_result
      snapshot.should be_a(FSM::State)
      if snapshot
        snapshot.id.should eq "clearing"
        snapshot.status.should eq FSM::Status::Success
      end

      service.stop
    end
  end

  describe "post" do
    it "enqueues events and processes them in order; a later send flushes the queue" do
      # Three posts advance a chain in FIFO order. A trailing send sits behind the
      # posts in the same mailbox, so by the time its reply returns every post has
      # already been processed (design section 10.5): the ordering is observable
      # without any sleep. on_transition records each committed state.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      order : Array(String) = [] of String

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("chain") do |m|
        m.state("s0") { |s| s.on_event("go", "s1") }
        m.state("s1") { |s| s.on_event("go", "s2") }
        m.state("s2") { |s| s.on_event("go", "s3") }
        m.state("s3") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "s0", context: ctx) do |observers|
        observers.on_transition { |snapshot| order << snapshot.id }
      end

      service.post("go")
      service.post("go")
      service.post("go")

      # "go" is unknown in s3, so this send moves nowhere but still flushes the queue
      # ahead of it. Its reply establishes happens-before with the owning fiber's
      # writes to `order`.
      flush : FSM::State = service.send("go")
      flush.id.should eq "s3"

      order.should eq ["s1", "s2", "s3"]

      service.stop
    end

    it "posts from inside a callback, cascading on the same mailbox (design section 10.5 step 17)" do
      # A post from inside a callback pushes to the same mailbox, so the drain simply
      # continues (design section 10.5 step 17). Entering "armed" posts "trip", which
      # the machine handles as a further transition to "sprung". post-from-callback is
      # the safe direction from inside a callback; send-from-callback would deadlock
      # the async service on itself (design section 8.2) and is asserted nowhere on
      # purpose.
      ctx : AsyncServiceLog = AsyncServiceLog.new

      machine : FSM::Machine(AsyncServiceLog) = FSM::Machine(AsyncServiceLog).build("trap") do |m|
        m.state("idle") { |s| s.on_event("arm", "armed") }
        m.state("armed") do |s|
          s.on_entry do |_e, c|
            c.record("armed")
            service_ref : FSM::AsyncService(AsyncServiceLog)? = c.async_service
            service_ref.post("trip") if service_ref
          end
          s.on_event("trip", "sprung")
        end
        m.state("sprung") do |s|
          s.on_entry { |_e, c| c.record("sprung") }
        end
      end

      service : FSM::AsyncService(AsyncServiceLog) = FSM::AsyncService(AsyncServiceLog).start(machine, initial: "idle", context: ctx)
      ctx.async_service = service

      service.post("arm")

      # A send for an event "arm" is unknown in the final state, but it flushes the
      # cascade queued ahead of it and returns the state the machine settled in.
      settled : FSM::State = service.send("arm")
      settled.id.should eq "sprung"
      ctx.log.should eq ["armed", "sprung"]

      service.stop
    end
  end

  describe "context isolation (D6)" do
    it "exposes no context accessor; reads go through send on the owning fiber" do
      # Structural guarantee (design section 8.2, D6): AsyncService has no `context`
      # getter. A line such as `service.context` does not compile, so the guarantee
      # cannot be asserted at runtime; it is enforced by the API's absence and covered
      # here behaviorally. The only way to learn what the context said is to send an
      # event and read the returned snapshot: the guard below runs against the context
      # on the OWNING fiber during send, and the snapshot is how its decision reaches
      # the caller. The async service never hands its T out.
      ctx : TurnContext = TurnContext.new(rope_secured: false)

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
          s.on_blocked("north") { |_e, c, _blocked| c.say("too steep") }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(TurnContext) = FSM::AsyncService(TurnContext).start(machine, initial: "cave", context: ctx)

      # The guard is consulted on the owning fiber; the caller learns the outcome only
      # as a snapshot value, never by reading the context.
      blocked : FSM::State = service.send("north")
      blocked.id.should eq "cave"

      # Mutating the retained reference is the caller's own doing (D6 does not stop a
      # caller keeping the reference it passed to start); the next send re-consults it
      # on the owning fiber.
      ctx.rope_secured = true
      moved : FSM::State = service.send("north")
      moved.id.should eq "clearing"

      service.stop
    end
  end

  describe "error handling under send (design section 11)" do
    it "returns a Failed snapshot as a value; no exception crosses the reply channel" do
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      boom : Exception = Exception.new("entry raised")

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") do |s|
          s.on_entry { |_e, _c| raise boom }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      # send catches the exception and hands back a Failed snapshot; it does not raise
      # (design section 11). The pointer did not move, so id is the unchanged state.
      result : FSM::State = service.send("north")
      result.status.should eq FSM::Status::Failed
      result.error.should eq boom
      result.id.should eq "cave"

      service.stop
    end

    it "stays running after a failed send; only post errors the async service (design section 11)" do
      # A callback raising under send surfaces as a value, so the async service is not
      # poisoned: unlike post, send has a reply channel to carry the failure. The
      # async service keeps draining and a later send succeeds.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      boom : Exception = Exception.new("entry raised")

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing")
          s.on_event("look", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
        m.state("clearing") do |s|
          s.on_entry { |_e, _c| raise boom }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      failed : FSM::State = service.send("north")
      failed.status.should eq FSM::Status::Failed

      # Not errored, still running: the failure went back as a value.
      service.errored?.should be_false
      service.running?.should be_true

      # A subsequent send is processed normally.
      ok : FSM::State = service.send("look")
      ok.status.should eq FSM::Status::Success
      ctx.steps.should eq 1

      service.stop
    end
  end

  describe "error handling under post (design section 11)" do
    it "marks the async service errored, records the exception, and stops draining the mailbox" do
      # post has already returned by the time the callback runs, so there is no
      # snapshot to hand back. The async service catches the exception, marks itself
      # errored, records it, and stops draining (design section 11). Events posted
      # after the poisoning one are never processed, so the second transition's
      # callback never runs and `steps` stays at 0.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      boom : Exception = Exception.new("post callback raised")
      processed : Channel(FSM::State) = Channel(FSM::State).new(1)

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing")
          s.on_event("linger", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
        m.state("clearing") do |s|
          s.on_entry { |_e, _c| raise boom }
        end
      end

      # on_event_processed fires on the failed step and signals the test fiber, so no
      # sleep is needed to know the poisoning step has been handled (D19).
      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_event_processed { |snapshot| processed.send(snapshot) }
      end

      # The poisoning post, then two posts that would each bump if drained.
      service.post("north")
      service.post("linger")
      service.post("linger")

      failed_snapshot : FSM::State = processed.receive
      failed_snapshot.status.should eq FSM::Status::Failed
      failed_snapshot.error.should eq boom
      failed_snapshot.id.should eq "cave"

      service.errored?.should be_true
      service.running?.should be_false
      service.stopped?.should be_false
      service.error.should eq boom

      # Draining stopped at the poisoning event, so neither "linger" was processed.
      ctx.steps.should eq 0
    end

    it "fires on_event_processed with the Failed snapshot but not on_transition (D19)" do
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      boom : Exception = Exception.new("post callback raised")
      processed : Channel(FSM::State) = Channel(FSM::State).new(1)
      transition_fired : Bool = false

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") do |s|
          s.on_entry { |_e, _c| raise boom }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_transition { |_snapshot| transition_fired = true }
        observers.on_event_processed { |snapshot| processed.send(snapshot) }
      end

      service.post("north")

      snapshot : FSM::State = processed.receive
      # "after every step" includes the failed step (D19); "on change" excludes it,
      # because no transition completed.
      snapshot.status.should eq FSM::Status::Failed
      snapshot.error.should eq boom
      transition_fired.should be_false
    end

    it "keeps the first recorded exception when the observer itself raises on the failed step (D19)" do
      # DECIDED HERE (design section 9, section 15): an observer that raises while
      # handling a failed step does not overwrite the failure the snapshot already
      # carries. The first exception is the callback's, recorded before the observer
      # ran. The observer's own exception is discarded, matching how Service treats a
      # raising on_event_processed on a failed step: the recorded exception wins, and
      # the observer's exception must not become the async service's recorded error.
      # This keeps post's failure reporting single-sourced and mirrors the
      # returning-path rule that the first exception is authoritative (design section
      # 9).
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      callback_error : Exception = Exception.new("post callback raised")
      observer_error : Exception = Exception.new("observer raised")
      handled : Channel(Nil) = Channel(Nil).new(1)

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") do |s|
          s.on_entry { |_e, _c| raise callback_error }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_event_processed do |_snapshot|
          handled.send(nil)
          raise observer_error
        end
      end

      service.post("north")
      handled.receive

      service.errored?.should be_true
      # The recorded exception is the callback's, not the observer's.
      service.error.should eq callback_error
    end

    it "poisons the async service when an observer raises on a non-failed step under post (design section 11, section 15)" do
      # DECIDED HERE (design section 11, section 15): an observer that raises on a
      # SUCCESSFUL step poisons the async service. An observer exception on a committed
      # step is an interpreter-level failure, not a transaction failure, so it poisons
      # under BOTH post and send. Under post there is no caller to receive it, so the
      # failure follows the no-return rule: "where nothing comes back, failure is in the
      # interpreter" (design section 11). Letting it escape the owning fiber would kill
      # that fiber and silently stop the mailbox draining, the worst available failure
      # mode (design section 11). So the async service records the observer's exception
      # as its error and stops draining, exactly as a raising post callback would. Under
      # send the same observer exception also poisons the async service, but the step
      # committed so the accurate snapshot is still returned as the value; the caller
      # sees the poisoning through errored?/error (covered by the on_transition specs
      # below). This is distinct from a transaction failure under send, which returns a
      # Failed value and keeps the async service running (the failed-send spec above).
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      observer_error : Exception = Exception.new("observer raised on a successful step")

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_event_processed { |_snapshot| raise observer_error }
      end

      # The post succeeds (cave -> clearing) but its on_event_processed observer
      # raises, poisoning the async service.
      service.post("north")

      # A following send is refused as a value. The owning fiber stopped draining after
      # the poisoning step, so this send is answered with the recorded failure whether
      # it short-circuits on the errored condition or is rejected from the mailbox.
      # Reaching a refused reply establishes happens-before with the poisoning, so the
      # lifecycle assertions below are not racy.
      refused : FSM::State = service.send("north")
      refused.status.should eq FSM::Status::Failed
      refused.error.should eq observer_error

      service.errored?.should be_true
      service.running?.should be_false
      # The observer's exception is what poisoned the async service, since no callback
      # raised.
      service.error.should eq observer_error
    end
  end

  describe "guard raising (design section 10.2 step 12, section 11)" do
    it "returns a Failed snapshot carrying the guard's exception under send and stays usable" do
      # Guards run inside plan, which the owning fiber calls inside the same rescue as
      # the callbacks. A guard that raises therefore produces a Failed snapshot exactly
      # like a raising callback, returned as a value on the reply channel; the async
      # service is not poisoned and a later send still works. The send is driven from a
      # child fiber behind a timeout so a regression that lets the guard exception
      # escape the owning fiber fails this example instead of hanging the suite.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      boom : Exception = Exception.new("guard raised")

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") { |t| t.guard { |_e, _c| raise boom } }
          s.on_event("look", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      reply : Channel(FSM::State) = Channel(FSM::State).new(1)
      spawn { reply.send(service.send("north")) }

      result : FSM::State? = nil
      select
      when snapshot = reply.receive
        result = snapshot
      when timeout(5.seconds)
        fail "send hung after a guard raised; the guard exception escaped the owning fiber"
      end

      failed : FSM::State? = result
      failed.should be_a(FSM::State)
      if failed
        failed.status.should eq FSM::Status::Failed
        failed.error.should eq boom
        failed.id.should eq "cave"
      end

      # The failure came back as a value, so the async service is not poisoned.
      service.errored?.should be_false
      service.running?.should be_true

      # A subsequent send is processed normally on the still-live owning fiber.
      ok : FSM::State = service.send("look")
      ok.status.should eq FSM::Status::Success
      ctx.steps.should eq 1

      service.stop
    end

    it "marks the async service errored and records the exception when a guard raises under post" do
      # A guard raising under post is a transaction failure with no reply channel, so
      # it poisons the async service exactly like a raising post callback (design
      # section 11). on_event_processed fires on the failed step and signals the test
      # behind a timeout, so a regression that hangs the owning fiber fails here rather
      # than blocking the suite.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      boom : Exception = Exception.new("guard raised")
      processed : Channel(FSM::State) = Channel(FSM::State).new(1)

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") { |t| t.guard { |_e, _c| raise boom } }
          s.on_event("linger", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_event_processed { |snapshot| processed.send(snapshot) }
      end

      service.post("north")
      service.post("linger")

      captured : FSM::State? = nil
      select
      when snapshot = processed.receive
        captured = snapshot
      when timeout(5.seconds)
        fail "the poisoning post never reached on_event_processed; the guard exception hung the owning fiber"
      end

      failed : FSM::State? = captured
      failed.should be_a(FSM::State)
      if failed
        failed.status.should eq FSM::Status::Failed
        failed.error.should eq boom
        failed.id.should eq "cave"
      end

      service.errored?.should be_true
      service.running?.should be_false
      service.error.should eq boom

      # Draining stopped at the poisoning event, so the queued "linger" never ran.
      ctx.steps.should eq 0
    end
  end

  describe "observer raising on a committed step (design section 9, section 11)" do
    it "still fires on_event_processed and poisons under post when on_transition raises on a successful step" do
      # An on_transition observer that raises must not skip on_event_processed: section
      # 9 guarantees on_event_processed fires after every step. The step committed, so
      # the observer failure is interpreter-level and poisons the async service under
      # post. A following send is refused as a value, establishing happens-before with
      # the poisoning so the lifecycle assertions are not racy.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      transition_error : Exception = Exception.new("on_transition raised on a successful step")
      processed : Channel(FSM::State) = Channel(FSM::State).new(1)

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing")
          s.on_event("linger", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_transition { |_snapshot| raise transition_error }
        observers.on_event_processed { |snapshot| processed.send(snapshot) }
      end

      service.post("north")

      # on_event_processed still fired even though on_transition raised first, and it
      # received the accurate Success snapshot for the committed step.
      captured : FSM::State? = nil
      select
      when snapshot = processed.receive
        captured = snapshot
      when timeout(5.seconds)
        fail "on_event_processed did not fire after on_transition raised"
      end
      processed_snapshot : FSM::State? = captured
      processed_snapshot.should be_a(FSM::State)
      if processed_snapshot
        processed_snapshot.id.should eq "clearing"
        processed_snapshot.status.should eq FSM::Status::Success
      end

      refused : FSM::State = service.send("linger")
      refused.status.should eq FSM::Status::Failed
      refused.error.should eq transition_error

      service.errored?.should be_true
      service.running?.should be_false
      service.error.should eq transition_error

      # Draining stopped at the poisoning step, so the queued "linger" never ran.
      ctx.steps.should eq 0
    end

    it "returns the accurate Success snapshot under send but poisons when on_transition raises" do
      # Under send the committed step's snapshot is returned as the value even though
      # on_transition raised; no exception crosses the reply channel. The observer
      # failure still poisons the async service, and mark_errored runs before the reply
      # so reading errored?/error after send is not racy. on_event_processed still fired.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      transition_error : Exception = Exception.new("on_transition raised on a successful step")
      processed : Array(FSM::State) = [] of FSM::State

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_transition { |_snapshot| raise transition_error }
        observers.on_event_processed { |snapshot| processed << snapshot }
      end

      result : FSM::State = service.send("north")
      result.id.should eq "clearing"
      result.status.should eq FSM::Status::Success
      result.error.should be_nil

      # on_event_processed still fired, receiving the accurate committed snapshot.
      processed.size.should eq 1
      processed.first.id.should eq "clearing"

      # The observer failure poisoned the async service; the reply carried no exception.
      service.errored?.should be_true
      service.running?.should be_false
      service.error.should eq transition_error
    end
  end

  describe "stop drains queued events (design section 8.2, section 10.5)" do
    it "processes an event posted before stop before stop returns" do
      # StopMessage rides the same FIFO mailbox behind an earlier post, so the post is
      # fully processed before the owning fiber reaches the stop and acks it. stop is
      # synchronous, so once it returns the callback has already run.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("look", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      service.post("look")
      service.stop

      ctx.steps.should eq 1
      service.stopped?.should be_true
    end

    it "does not process an event posted after stop" do
      # A post after stop finds the async service no longer running and is dropped
      # silently, so its callback never runs.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("look", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      service.stop
      service.post("look")

      ctx.steps.should eq 0
      service.stopped?.should be_true
    end
  end

  describe "observers on a successful transition (design section 9, D19)" do
    it "fires on_transition then on_event_processed with the new-state snapshot" do
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      order : Array(String) = [] of String
      captured : FSM::State? = nil

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_event_processed do |snapshot|
          captured = snapshot
          order << "processed"
        end
        observers.on_transition { |_snapshot| order << "transition" }
      end

      # send returns only after the step's observers have run on the owning fiber, so
      # reading `order` and `captured` after the reply is safe.
      service.send("north")

      order.should eq ["transition", "processed"]
      snapshot : FSM::State? = captured
      snapshot.should be_a(FSM::State)
      if snapshot
        snapshot.id.should eq "clearing"
        snapshot.status.should eq FSM::Status::Success
      end

      service.stop
    end

    it "fires on_event_processed but not on_transition for a blocked event" do
      ctx : TurnContext = TurnContext.new(rope_secured: false)
      processed_fired : Bool = false
      transition_fired : Bool = false

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
          s.on_blocked("north") { |_e, c, _blocked| c.say("too steep") }
        end
        m.state("clearing") { |s| }
      end

      service : FSM::AsyncService(TurnContext) = FSM::AsyncService(TurnContext).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_transition { |_snapshot| transition_fired = true }
        observers.on_event_processed { |_snapshot| processed_fired = true }
      end

      service.send("north")

      processed_fired.should be_true
      transition_fired.should be_false

      service.stop
    end
  end

  describe "stop (design section 8.2)" do
    it "reports stopped and refuses further events after stop" do
      # DECIDED HERE (design section 8.2, section 11, section 15): a stopped async
      # service, like an errored one, accepts no further events. post is dropped
      # silently, because post has no reply channel and there is nothing to report on.
      # send returns a Failed snapshot rather than blocking forever on a fiber that has
      # stopped draining, following the returning-path rule that failure comes back as
      # a value where a value comes back (design section 11). The concrete exception a
      # stopped-service send carries is left to the implementer; the contract asserted
      # here is Failed status, a non-nil error, and no processing.
      #
      # stop is treated as synchronous: it returns once the async service has stopped,
      # so `stopped?` is deterministically true afterward. Whether stop drains events
      # already queued before returning is deliberately NOT asserted here; see the
      # handoff notes for that open question.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("look", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx)

      # One successful step before stop confirms the async service was live.
      before : FSM::State = service.send("look")
      before.status.should eq FSM::Status::Success
      ctx.steps.should eq 1

      service.stop

      service.stopped?.should be_true
      service.running?.should be_false
      service.errored?.should be_false

      # post after stop is dropped silently: no processing, no raise.
      service.post("look")

      # send after stop returns a Failed value and does not process the event.
      after : FSM::State = service.send("look")
      after.status.should eq FSM::Status::Failed
      after.error.should_not be_nil

      # Neither post-stop event ran a callback.
      ctx.steps.should eq 1
    end
  end

  describe "errored async service incoming events (design section 15)" do
    it "drops a post silently and returns the recorded failure from a send" do
      # DECIDED HERE (design section 11, section 15): an errored async service refuses
      # events, and the manner of refusal follows the return-shape rule that governs
      # the whole library (design section 11): "where a value comes back, failure is in
      # the value; where nothing comes back, failure is in the interpreter."
      #
      #   - post has no reply channel, so it is DROPPED SILENTLY. The interpreter has
      #     already recorded the poisoning exception and its errored condition, which
      #     is where a no-return failure lives; a loud raise on the caller's fiber
      #     would contradict post returning immediately regardless of outcome.
      #   - send has a reply channel, so it REFUSES AS A VALUE: it returns a Failed
      #     snapshot carrying the recorded exception, without processing the event and
      #     without blocking on a fiber that has stopped draining.
      #
      # "Refuse loudly by raising" was rejected because it splits post's contract and
      # duplicates a failure the interpreter already holds. Returning the recorded
      # exception from send tells the caller exactly what poisoned the async service.
      ctx : AsyncServiceSteps = AsyncServiceSteps.new
      boom : Exception = Exception.new("post callback raised")
      processed : Channel(FSM::State) = Channel(FSM::State).new(1)

      machine : FSM::Machine(AsyncServiceSteps) = FSM::Machine(AsyncServiceSteps).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing")
          s.on_event("linger", "cave") { |t| t.internal.on { |_e, c| c.bump } }
        end
        m.state("clearing") do |s|
          s.on_entry { |_e, _c| raise boom }
        end
      end

      service : FSM::AsyncService(AsyncServiceSteps) = FSM::AsyncService(AsyncServiceSteps).start(machine, initial: "cave", context: ctx) do |observers|
        observers.on_event_processed { |snapshot| processed.send(snapshot) }
      end

      service.post("north")
      processed.receive
      service.errored?.should be_true

      # post into an errored async service is dropped: no processing, no raise.
      service.post("linger")

      # send into an errored async service returns the recorded failure as a value.
      refused : FSM::State = service.send("linger")
      refused.status.should eq FSM::Status::Failed
      refused.error.should eq boom

      # Neither post-error event ran a callback.
      ctx.steps.should eq 0
    end
  end
end

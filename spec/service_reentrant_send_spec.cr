require "./spec_helper"

# Reentrant Service#send: calling send from inside a callback of the same service
# (design section 8.1, section 10.3 step 21, section 10.4; fsmcr-999).
#
# The design mandates queue-and-drain. A callback that calls send does NOT recurse
# (section 10.4): the event is queued and processed at step 21, after the current
# transition has committed, with each drained event looping back to step 8 through the
# full step sequence (section 10.3 step 21). Re-entering @transition_mutex is exactly
# what the alternative would do, and Crystal's checked mutex raises "Can't lock mutex
# recursively" there, which is why queue-and-drain is the design (issue fsmcr-999).
#
# The service reference is closed over a local (`svc`) that is nil while the machine
# builds and is assigned right after interpret returns. A callback proc captures the
# variable by reference, so by the time a callback runs during send, `svc` holds the
# live service. This is the only way a build-time callback can reach the service that
# does not exist until interpret; it introduces no production helper.
#
# DESIGN-SILENT DECISIONS ENCODED HERE (each stated at its example):
#
#   1. The INNER (reentrant) send's return value. The design defines no reply for a
#      queued event (section 10.5 step 22 covers only the drained loop, not the queued
#      caller). Decision: the inner send returns the interpreter's CURRENT cached
#      snapshot, the state it is committed to at the moment of the call, because the
#      queued event has not been applied and no post-application snapshot exists yet.
#      Rationale: Service#send must return a State by signature; returning the current
#      snapshot is the one truthful value available and never fabricates a state that is
#      not real; it mirrors the async precedent where a from-inside enqueue (post)
#      returns without the applied result. During an on_entry the committed state is
#      still the old one (section 11), so the inner send observes that old id.
#
#   2. The OUTER send's return value. Section 10.5 step 22 returns "the State snapshot
#      built at step 19", the outer event's OWN step, and AsyncService sends that reply
#      in process_event BEFORE drain_cascades runs. Decision: the outer send returns the
#      outer event's own committed snapshot, not the final post-drain state. After send
#      returns, current_state reflects the final drained state.
#
#   3. A transaction failure (a callback raises) during the drain HALTS the drain, and
#      events still queued are lost. The design is silent for Service here; the choice
#      mirrors AsyncService's drain_cascades, which clears the cascade and stops on a
#      failed cascade step (src/fsm/async_service.cr). Service has no lifecycle to
#      poison, so the failure is recorded in the snapshot/@state rather than errored,
#      but the halt carries over. The outer send still returns its own committed
#      snapshot; the drained failure surfaces only in current_state.
#
#   4. An observer exception during the drain aborts the drain before later events run
#      and re-raises from the outer send after that event's observers fired; events
#      still queued are lost (fsmcr-1uo scope note, issue fsmcr-999 NOTES). This one is
#      settled by the scope note rather than invented here.
#
#   5. Events queued during the OUTER step are discarded when the outer step itself
#      fails or its observer raises. The drain runs only when the outer step committed
#      (send: `drain unless snapshot.status.failed?`), and a raising outer observer
#      re-raises before the drain is reached, so in both cases the drain never runs and
#      the ensure clears @pending, dropping whatever a callback queued this step. This is
#      the symmetric counterpart of decisions 3 and 4 for the drained steps: a step whose
#      transaction fails, or whose observer raises, halts the cascade and loses events
#      still queued. Here the failing step is the OUTER one, so nothing drains at all.
describe "Service#send reentrant from a callback (queue-and-drain, design section 10.3 step 21, 10.4)" do
  describe "queue-and-drain instead of deadlock" do
    it "does not deadlock or raise, and drives the machine to the final drained state" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          # Entering "b" fires a follow-up event on the same service. Per section 10.4
          # this does not recurse: it queues and drains after this transition commits.
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            inner.send("next") if inner
          end
          s.on_event("next", "settled")
        end
        m.state("settled") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      result : FSM::State = service.send("go")

      # The reentrant send did not surface a deadlock; the step succeeded (section 10.4).
      result.status.should eq FSM::Status::Success
      # The queued "next" drained after "go" committed, so the machine ends at "settled"
      # (section 10.3 step 21).
      service.current_state.id.should eq "settled"
    end

    # The same queue-and-drain path reached from a transition callback (t.on) rather
    # than an entry callback. Both run during step 17, so both queue identically.
    it "queues an event fired from a transition callback (t.on), draining after commit" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") do |s|
          s.on_event("go", "b") do |t|
            # The transition callback runs during step 17, before the commit; a send
            # here queues and drains after commit exactly like an entry callback.
            t.on do |_e, _c|
              inner : FSM::Service(TurnContext)? = svc
              inner.send("next") if inner
            end
          end
        end
        m.state("b") { |s| s.on_event("next", "settled") }
        m.state("settled") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      result : FSM::State = service.send("go")

      result.status.should eq FSM::Status::Success
      service.current_state.id.should eq "settled"
    end

    # The queued event runs AFTER the current callback fully returns and the transition
    # commits, not recursively mid-callback (section 10.4). The log order is the
    # observable evidence: "b" finishes entering before "settled" is entered.
    it "commits the current transition fully before the queued event's step runs" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, c|
            c.say("enter-b-start")
            inner : FSM::Service(TurnContext)? = svc
            inner.send("next") if inner
            # If the send recursed, "enter-b-end" would not be reached before "settled"
            # is entered. Queue-and-drain reaches it first (section 10.4).
            c.say("enter-b-end")
          end
          s.on_event("next", "settled")
        end
        m.state("settled") { |s| s.on_entry { |_e, c| c.say("enter-settled") } }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      service.send("go")

      # The current transition into "b" runs to completion, then the queued "next"
      # drains and enters "settled" (section 10.3 step 21, section 10.4).
      ctx.log.should eq ["enter-b-start", "enter-b-end", "enter-settled"]
    end
  end

  describe "the outer send's return value (design-silent decision 2, section 10.5 step 22)" do
    it "returns the outer event's own committed snapshot, not the final drained state" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            inner.send("next") if inner
          end
          s.on_event("next", "settled")
        end
        m.state("settled") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      result : FSM::State = service.send("go")

      # Decision 2: the return value is the snapshot built for the OUTER event's own
      # step (section 10.5 step 22, "the State snapshot built at step 19"), captured
      # before the drain runs, matching AsyncService replying in process_event ahead of
      # drain_cascades.
      result.id.should eq "b"
      result.status.should eq FSM::Status::Success

      # The drain still ran to completion, so the interpreter now sits at the final
      # drained state even though the returned snapshot is the outer event's own.
      service.current_state.id.should eq "settled"
    end
  end

  describe "the inner reentrant send's return value (design-silent decision 1)" do
    it "returns the interpreter's current snapshot; the queued event is not yet applied" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      captured_inner : FSM::State? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            captured_inner = inner.send("next") if inner
          end
          s.on_event("next", "settled")
        end
        m.state("settled") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      service.send("go")

      # Decision 1: the inner send returns the interpreter's current committed snapshot.
      # It ran inside "b".on_entry during the go transition, and per section 11 an entry
      # callback reading current state sees the OLD state, so the id is still "a" and the
      # queued "next" has not been applied. The status is Success: nothing failed, the
      # event was merely queued.
      snapshot : FSM::State? = captured_inner
      snapshot.should be_a(FSM::State)
      if snapshot
        snapshot.status.should eq FSM::Status::Success
        snapshot.id.should eq "a"
      end
    end
  end

  describe "FIFO ordering and multi-level cascade (section 10.3 step 21)" do
    # Multiple events queued from one callback drain in the order they were queued.
    it "drains multiple events queued by one callback in FIFO order" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          # Two events queued in order; step 21 drains them FIFO, so "first" is applied
          # before "second". Each is an internal self-transition on "b" (design section
          # 13.4, step-15 table "same state, internal flag"): only the transition callback
          # runs and the state stays at "b", so both drained events run their callbacks in
          # queued order without a cross-state move.
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            if inner
              inner.send("first")
              inner.send("second")
            end
          end
          s.on_event("first", "b") { |t| t.internal.on { |_e, c| c.say("first") } }
          s.on_event("second", "b") { |t| t.internal.on { |_e, c| c.say("second") } }
        end
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      service.send("go")

      ctx.log.should eq ["first", "second"]
    end

    # A drained event's callback may queue further events; those drain in order
    # after it, each looping back through the full step sequence (section 10.3 step 21).
    it "drains events queued by a drained event's callback (multi-level cascade), in order" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, c|
            c.say("b")
            inner : FSM::Service(TurnContext)? = svc
            inner.send("to_c") if inner
          end
          s.on_event("to_c", "c")
        end
        m.state("c") do |s|
          # A drained event ("to_c") whose own callback queues a further event ("to_d").
          s.on_entry do |_e, c|
            c.say("c")
            inner : FSM::Service(TurnContext)? = svc
            inner.send("to_d") if inner
          end
          s.on_event("to_d", "d")
        end
        m.state("d") { |s| s.on_entry { |_e, c| c.say("d") } }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      service.send("go")

      # b commits, then to_c drains and enters c, then to_d drains and enters d
      # (section 10.3 step 21, each drained event looping back to step 8).
      ctx.log.should eq ["b", "c", "d"]
      service.current_state.id.should eq "d"
    end
  end

  describe "observers fire once per drained event (section 10.3 step 20-21, D19)" do
    # Each drained event loops back through the full step sequence, so observers fire
    # once PER event: the outer "go" step and the drained "next" step here, giving two
    # successful transitions and two after-every-step fires.
    it "fires on_transition and on_event_processed once for each drained event" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      transition_count : Int32 = 0
      processed_count : Int32 = 0

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            inner.send("next") if inner
          end
          s.on_event("next", "settled")
        end
        m.state("settled") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx) do |observers|
        observers.on_transition { |_snapshot| transition_count += 1 }
        observers.on_event_processed { |_snapshot| processed_count += 1 }
      end
      svc = service

      service.send("go")

      # Two transitions completed (go and next), each firing both observers once.
      transition_count.should eq 2
      processed_count.should eq 2
    end
  end

  describe "a transaction failure during the drain (design-silent decision 3; AsyncService cascade precedent)" do
    # A drained event whose callback raises yields a Failed snapshot for that step
    # (the 1uo envelope), and the drain HALTS, so a later queued event is lost. The
    # outer send still returns its own committed snapshot.
    it "halts the drain when a drained event's callback raises, losing later queued events" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      boom : Exception = Exception.new("drained entry raised")

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          # Queue two events. e1 drains first and fails in "c".on_entry; per decision 3
          # the drain halts there, so e2 (to "d") never runs.
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            if inner
              inner.send("e1")
              inner.send("e2")
            end
          end
          s.on_event("e1", "c")
          s.on_event("e2", "d")
        end
        m.state("c") { |s| s.on_entry { |_e, _c| raise boom } }
        m.state("d") { |s| s.on_entry { |_e, c| c.say("entered-d") } }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      # The outer "go" step committed and its own snapshot is a value, not a raise: a
      # drained-event failure does not propagate out of the outer send (decision 2).
      result : FSM::State = service.send("go")
      result.status.should eq FSM::Status::Success
      result.id.should eq "b"

      # e1 failed to enter "c", so the pointer stayed at "b"; the drain then halted, so
      # e2 never ran and "d" was never entered (decision 3, AsyncService cascade halt).
      service.current_state.id.should eq "b"
      ctx.log.should_not contain "entered-d"
    end
  end

  describe "an observer exception during the drain (design-silent decision 4; fsmcr-1uo scope note)" do
    # An observer that raises on an earlier drained event aborts the drain before
    # later events run, and the exception re-raises from the outer send after that
    # event's observers fired. Events still queued are lost.
    it "aborts the drain and re-raises from the outer send, losing later queued events" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      observer_error : Exception = Exception.new("observer raised during drain")

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            if inner
              inner.send("e1")
              inner.send("e2")
            end
          end
          s.on_event("e1", "c")
          s.on_event("e2", "d")
        end
        m.state("c") { |s| }
        m.state("d") { |s| s.on_entry { |_e, c| c.say("entered-d") } }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx) do |observers|
        # Fires on every step. It stays quiet for the outer "go" step (id "b") and the
        # only step whose snapshot id is "c" is the drained e1 step, where it raises.
        observers.on_event_processed do |snapshot|
          raise observer_error if snapshot.id == "c"
        end
      end
      svc = service

      # The observer exception on the earlier drained event (e1) re-raises from the
      # outer send after that event's observers fired (scope note).
      expect_raises(Exception, "observer raised during drain") do
        service.send("go")
      end

      # e1 committed into "c" before its observer raised (section 10.3 step 18 precedes
      # step 20), so the pointer is at "c"; the drain aborted, so e2 never ran and "d"
      # was never entered.
      service.current_state.id.should eq "c"
      ctx.log.should_not contain "entered-d"
    end
  end

  describe "reentrant current_state and matches? from a callback (owner-fiber fast path)" do
    # A callback of the same service calls current_state and matches? on the owner fiber,
    # which already holds @transition_mutex. Re-acquiring the checked mutex would raise
    # "Can't lock mutex recursively", and that raise would drop the whole outer transition
    # into the failure envelope. The owner-fiber fast path returns from the cached @state
    # without locking, so the reads succeed and the transition still commits. Per section
    # 11 a callback reading the interpreter's current state mid-step sees the OLD,
    # pre-commit state, so the readings taken here are the state the machine is leaving,
    # not "b". Both call sites run at step 17 before the commit at step 18, mirroring how
    # the queue-and-drain specs above check the entry-callback and transition-callback
    # paths separately.

    it "reads the pre-commit state from a transition callback (t.on) without deadlocking, and still commits" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      seen_current : FSM::State? = nil
      seen_matches_a : Bool? = nil
      seen_matches_b : Bool? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") do |s|
          s.on_event("go", "b") do |t|
            # The transition callback runs at step 17, before the commit. current_state and
            # matches? take the owner-fiber fast path here instead of deadlocking.
            t.on do |_e, _c|
              inner : FSM::Service(TurnContext)? = svc
              if inner
                seen_current = inner.current_state
                seen_matches_a = inner.matches?("a")
                seen_matches_b = inner.matches?("b")
              end
            end
          end
        end
        m.state("b") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      result : FSM::State = service.send("go")

      # The reentrant reads did not deadlock: the outer step committed successfully rather
      # than falling into the failure envelope.
      result.status.should eq FSM::Status::Success
      result.id.should eq "b"
      service.current_state.id.should eq "b"

      # The mid-step reads saw the pre-commit state "a" (section 11): during the transition
      # callback the commit has not happened yet, so the interpreter is still on "a".
      seen_current.should_not be_nil
      if snapshot = seen_current
        snapshot.id.should eq "a"
        snapshot.status.should eq FSM::Status::Success
      end
      seen_matches_a.should eq true
      seen_matches_b.should eq false
    end

    it "reads the pre-commit state from an entry callback without deadlocking, and still commits" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      seen_current : FSM::State? = nil
      seen_matches_a : Bool? = nil
      seen_matches_b : Bool? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            if inner
              # Mid-step reads, before the commit at step 18. The owner-fiber fast path
              # returns the cached @state without touching the mutex.
              seen_current = inner.current_state
              seen_matches_a = inner.matches?("a")
              seen_matches_b = inner.matches?("b")
            end
          end
        end
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      result : FSM::State = service.send("go")

      result.status.should eq FSM::Status::Success
      result.id.should eq "b"
      service.current_state.id.should eq "b"

      # Per section 11 an entry callback reading the current state sees the OLD state, so
      # the readings taken during "b".on_entry are still "a", the state being left.
      seen_current.should_not be_nil
      if snapshot = seen_current
        snapshot.id.should eq "a"
        snapshot.status.should eq FSM::Status::Success
      end
      seen_matches_a.should eq true
      seen_matches_b.should eq false
    end
  end

  describe "outer-step events discarded when the outer step fails (design-silent decision 5)" do
    # Decision 5: an event a callback queues during the OUTER step is discarded when that
    # step fails. A transition callback queues "next" via reentrant send, then the entry
    # callback of the target raises, so the outer step is Failed. The drain runs only on a
    # committed outer step (send: `drain unless snapshot.status.failed?`), so it never
    # runs, and the ensure clears @pending. The queued "next" is dropped, and because
    # @pending is cleared a later send drains cleanly rather than replaying the stale
    # event. This is the outer-step counterpart of decisions 3 and 4.
    it "drops an event queued in a failing outer step and leaves @pending clean for the next send" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      boom : Exception = Exception.new("entry raised in outer step")

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") do |s|
          # The transition callback runs at step 17 before the commit; it queues "next".
          # The entry callback of "b" then raises, so the outer step fails and never drains.
          s.on_event("go", "b") do |t|
            t.on do |_e, _c|
              inner : FSM::Service(TurnContext)? = svc
              inner.send("next") if inner
            end
          end
          s.on_event("recover", "recovered")
        end
        m.state("b") { |s| s.on_entry { |_e, _c| raise boom } }
        # If "next" were ever applied, it would move the machine to "leaked" and log. It
        # is applicable only from "recovered", so a stale pending "next" surviving into the
        # recover send's drain would surface as a move to "leaked".
        m.state("recovered") do |s|
          s.on_event("next", "leaked") { |t| t.on { |_e, c| c.say("leaked-next-applied") } }
        end
        m.state("leaked") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      # The outer "go" step failed in "b".on_entry, so the pointer stayed at "a" and the
      # snapshot is Failed. The drain never ran, so the queued "next" was discarded.
      result : FSM::State = service.send("go")
      result.status.should eq FSM::Status::Failed
      result.id.should eq "a"
      service.current_state.id.should eq "a"

      # A subsequent send works normally: the ensure cleared @pending, so "recover" commits
      # to "recovered" and the drain that follows it finds no stale "next" to replay.
      recovered : FSM::State = service.send("recover")
      recovered.status.should eq FSM::Status::Success
      recovered.id.should eq "recovered"
      service.current_state.id.should eq "recovered"
      ctx.log.should_not contain "leaked-next-applied"
    end
  end

  # Runaway drain: a callback that queues its own event unconditionally would drain
  # forever. The design mandates no cycle or depth guard (section 10.3 step 21 and 10.4
  # describe an unbounded drain and section 15 lists no such guard), so none is invented
  # here. This behavior is documented rather than specced: an executable spec would spin
  # forever. If a bound is ever wanted it must be added to the design and specced
  # deliberately (issue fsmcr-999 scope: "do NOT invent one").
  pending "a callback that unconditionally queues its own event drains without a cycle or depth guard (documented, not executed)"
end

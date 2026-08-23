require "./spec_helper"
require "wait_group"

# Serialization by fiber ownership under real parallel contention (design section
# 8.2, section 12.2; fsmcr-9ct, fsmcr-bfn.7).
#
# spec_helper resizes the default execution context to more than one worker, so the
# fibers spawned below run on separate worker threads at the same time. AsyncService
# serializes differently from Service: not by a lock many fibers queue on, but by
# ownership: exactly one fiber ever executes the machine's code (design section
# 12.2). Many fibers post and send concurrently; the owning fiber drains the mailbox
# one message at a time.
#
# The detector below is built to fail if that ownership were bypassed, in the spirit
# of the Service contention specs (fsmcr-9ct). Its counter has no lock of its own and
# its increment is a read-yield-write, so the update window spans a full scheduler
# handoff. Under correct ownership the read-yield-write runs only on the OWNING fiber;
# the yield hands the slot to other fibers, but those fibers only enqueue messages,
# they never run the increment, so no update is ever lost. If an implementation ran a
# post or send on the CALLING fiber instead of the owning one, many fibers would run
# the increment at once, the yield would interleave two read-modify-write cycles, and
# increments would be clobbered, so the final count would fall short. FSM::Context is
# avoided on purpose: its internal lock would serialize the field access and mask a
# bypassed ownership (design section 12.5).

# A context whose counter has no lock of its own; the only thing that can serialize
# concurrent increments is the async service's single owning fiber. The
# read-yield-write widens the read-modify-write window to a full scheduler handoff.
class AsyncServiceRacyCounter
  property counter : Int32 = 0

  def increment_racy : Nil
    current : Int32 = @counter
    Fiber.yield
    @counter = current + 1
  end
end

describe "FSM::AsyncService under real parallel contention" do
  it "serializes posts by ownership so no callback increment is lost" do
    ctx : AsyncServiceRacyCounter = AsyncServiceRacyCounter.new

    # A self-transition on "tick" keeps the machine in "counting" and runs the
    # transition callback once per event (design section 9.1, external default).
    machine : FSM::Machine(AsyncServiceRacyCounter) = FSM::Machine(AsyncServiceRacyCounter).build("counter") do |m|
      m.state("counting") do |s|
        s.on_event("tick", "counting") do |t|
          t.on { |_event, c| c.increment_racy }
        end
      end
    end

    service : FSM::AsyncService(AsyncServiceRacyCounter) = FSM::AsyncService(AsyncServiceRacyCounter).start(machine, initial: "counting", context: ctx)

    fiber_count : Int32 = 200
    posts_per_fiber : Int32 = 50
    total : Int32 = fiber_count * posts_per_fiber

    # A raising fiber logs to stderr instead of failing the spec runner, so collect
    # any exception directly and assert the collection is empty.
    errors : Array(Exception) = [] of Exception
    report_mutex : Mutex = Mutex.new
    wait_group : WaitGroup = WaitGroup.new(fiber_count)

    fiber_count.times do
      spawn do
        posts_per_fiber.times { service.post("tick") }
      rescue ex
        report_mutex.synchronize { errors << ex }
      ensure
        wait_group.done
      end
    end

    wait_group.wait

    # Every post is now enqueued. A trailing send sits behind all of them in the same
    # mailbox, so its reply returns only once the whole backlog has drained (design
    # section 10.5). "flush" is unregistered in "counting", so it moves nowhere and
    # increments nothing; it exists only to establish that the drain completed.
    flush : FSM::State = service.send("flush")
    flush.id.should eq "counting"

    errors.should be_empty
    service.errored?.should be_false

    # Under ownership every increment lands, so exactly `total` increments occur.
    # Bypass the single owning fiber and concurrent read-yield-write increments
    # clobber one another, leaving the counter short of `total`.
    ctx.counter.should eq total

    service.stop
  end

  it "serializes a concurrent mix of posts and sends by ownership" do
    ctx : AsyncServiceRacyCounter = AsyncServiceRacyCounter.new

    machine : FSM::Machine(AsyncServiceRacyCounter) = FSM::Machine(AsyncServiceRacyCounter).build("counter") do |m|
      m.state("counting") do |s|
        s.on_event("tick", "counting") do |t|
          t.on { |_event, c| c.increment_racy }
        end
      end
    end

    service : FSM::AsyncService(AsyncServiceRacyCounter) = FSM::AsyncService(AsyncServiceRacyCounter).start(machine, initial: "counting", context: ctx)

    fiber_count : Int32 = 120
    posts_per_fiber : Int32 = 20
    sends_per_fiber : Int32 = 20
    total : Int32 = fiber_count * (posts_per_fiber + sends_per_fiber)

    errors : Array(Exception) = [] of Exception
    non_success : Array(FSM::State) = [] of FSM::State
    report_mutex : Mutex = Mutex.new
    wait_group : WaitGroup = WaitGroup.new(fiber_count)

    fiber_count.times do
      spawn do
        posts_per_fiber.times { service.post("tick") }
        sends_per_fiber.times do
          # send blocks THIS fiber until the owning fiber replies; other fibers keep
          # running on other workers. Every reply is a Success snapshot that moved
          # nowhere (the self-transition).
          snapshot : FSM::State = service.send("tick")
          report_mutex.synchronize { non_success << snapshot } unless snapshot.status.success?
        end
      rescue ex
        report_mutex.synchronize { errors << ex }
      ensure
        wait_group.done
      end
    end

    wait_group.wait

    # All sends are processed and all posts enqueued; the trailing send drains any
    # posts still queued behind the last send.
    flush : FSM::State = service.send("flush")
    flush.id.should eq "counting"

    errors.should be_empty
    non_success.should be_empty
    service.errored?.should be_false

    # One increment per post and per send, none lost, because one fiber ran them all.
    ctx.counter.should eq total

    service.stop
  end
end

require "./spec_helper"
require "wait_group"

# Genuine cross-thread contention on a single Service instance's send path
# (design section 8.1, section 10.7, section 12.2; fsmcr-9ct).
#
# spec_helper resizes the default execution context to more than one worker, so the
# fibers spawned below run on separate worker threads at the same time. That is the
# precondition these specs need: without it the scheduler runs one fiber to
# completion before the next, Service#send never overlaps another Service#send, and
# @transition_mutex is never contended, so a missing lock would go undetected.
#
# Each detector is built to fail if @transition_mutex is removed from Service#send.
# Two mechanics make the failure reliable rather than a coin-flip:
#
#   1. Every callback contains a Fiber.yield. The transition callback runs at step
#      17 of the lifecycle, inside the critical section (design section 10.7). When
#      the mutex is present the fiber keeps the lock across the yield, so no other
#      send body can interleave and the operation still completes correctly. When the
#      mutex is absent the yield hands a whole scheduler slot to another fiber on
#      another worker thread in the middle of the read-modify-write, which is exactly
#      the interleaving a lock exists to prevent.
#
#   2. The contexts carry plain fields with no lock of their own, so the interpreter's
#      mutex is the only thing that can serialize the work. FSM::Context is avoided on
#      purpose: its internal lock would serialize each field access and mask a missing
#      Service mutex (design section 12.5).

# A domain context (the generic T) whose counter has no lock of its own. The only
# thing that can serialize concurrent increments is Service#@transition_mutex. The
# read-yield-write widens the read-modify-write window to a full scheduler handoff:
# under the lock the increment still lands (the lock is held across the yield),
# without the lock a second fiber reads the same value and the later write clobbers
# the earlier one, losing an update.
class SharedCounter
  property counter : Int32 = 0

  def increment_racy : Nil
    current : Int32 = @counter
    Fiber.yield
    @counter = current + 1
  end
end

# A domain context that records whether two send bodies were ever inside the
# transition callback at the same time. On entry it checks the flag another fiber
# would have set; under mutual exclusion the flag is always false there, so
# `overlaps` stays 0. Without the lock the yield leaves the flag set while another
# fiber enters, and that fiber records the overlap.
class OverlapDetector
  getter overlaps : Int32 = 0
  @inside : Bool = false

  def enter_and_yield : Nil
    @overlaps += 1 if @inside
    @inside = true
    Fiber.yield
    @inside = false
  end
end

describe "FSM::Service under real parallel contention" do
  it "serializes send bodies so no callback increment is lost" do
    ctx : SharedCounter = SharedCounter.new

    # A self-transition on "tick" keeps the machine in "counting" and runs the
    # transition callback once per send (design section 9.1, external default).
    machine : FSM::Machine(SharedCounter) = FSM::Machine(SharedCounter).build("counter") do |m|
      m.state("counting") do |s|
        s.on_event("tick", "counting") do |t|
          t.on { |_event, ctx| ctx.increment_racy }
        end
      end
    end

    service : FSM::Service(SharedCounter) = FSM::Service(SharedCounter).interpret(machine, "counting", ctx)

    fiber_count : Int32 = 200
    sends_per_fiber : Int32 = 50
    total : Int32 = fiber_count * sends_per_fiber

    # Fiber#run logs an unhandled fiber exception to stderr instead of propagating
    # it to the spec runner, so a raising send would otherwise leave the spec green.
    # Collect exceptions and any non-Success snapshot and assert on them directly.
    errors : Array(Exception) = [] of Exception
    non_success : Array(FSM::State) = [] of FSM::State
    report_mutex : Mutex = Mutex.new
    wait_group : WaitGroup = WaitGroup.new(fiber_count)

    fiber_count.times do
      spawn do
        sends_per_fiber.times do
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

    errors.should be_empty
    non_success.should be_empty

    # With the mutex every increment is serialized, so exactly `total` increments
    # land. Remove the mutex and concurrent read-yield-write increments clobber one
    # another, so the counter falls short of `total`.
    ctx.counter.should eq total
    service.current_state.id.should eq "counting"
  end

  it "never runs two send bodies at the same time" do
    ctx : OverlapDetector = OverlapDetector.new

    machine : FSM::Machine(OverlapDetector) = FSM::Machine(OverlapDetector).build("overlap") do |m|
      m.state("running") do |s|
        s.on_event("step", "running") do |t|
          t.on { |_event, ctx| ctx.enter_and_yield }
        end
      end
    end

    service : FSM::Service(OverlapDetector) = FSM::Service(OverlapDetector).interpret(machine, "running", ctx)

    fiber_count : Int32 = 200
    sends_per_fiber : Int32 = 50

    errors : Array(Exception) = [] of Exception
    error_mutex : Mutex = Mutex.new
    wait_group : WaitGroup = WaitGroup.new(fiber_count)

    fiber_count.times do
      spawn do
        sends_per_fiber.times { service.send("step") }
      rescue ex
        error_mutex.synchronize { errors << ex }
      ensure
        wait_group.done
      end
    end

    wait_group.wait

    errors.should be_empty

    # The transition callback is the critical section. Under the mutex no two run at
    # once, so no fiber ever sees the flag already set. Without the mutex the yield
    # keeps the flag set while other fibers enter, and they record the overlap.
    ctx.overlaps.should eq 0
  end

  it "keeps the interpreter consistent and raises nothing while many fibers drive a ring of states" do
    # A ten-state ring where every state advances to the next on "advance". Different
    # fibers read and commit @state concurrently. This is a robustness check that the
    # suite runs green under real parallelism (design section 12): no torn read of the
    # cached snapshot crashes a step, every send returns a Success snapshot, and the
    # interpreter always sits in one of the ring's states. It is not a lost-update
    # detector; the two specs above are.
    state_count : Int32 = 10

    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("ring") do |m|
      state_count.times do |i|
        next_index : Int32 = (i + 1) % state_count
        m.state("s#{i}") { |s| s.on_event("advance", "s#{next_index}") }
      end
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "s0", FSM::Context.new)

    valid_ids : Set(String) = Set(String).new
    state_count.times { |i| valid_ids << "s#{i}" }

    fiber_count : Int32 = 100
    sends_per_fiber : Int32 = 50

    errors : Array(Exception) = [] of Exception
    non_success : Array(FSM::State) = [] of FSM::State
    report_mutex : Mutex = Mutex.new
    wait_group : WaitGroup = WaitGroup.new(fiber_count)

    fiber_count.times do
      spawn do
        sends_per_fiber.times do
          snapshot : FSM::State = service.send("advance")
          report_mutex.synchronize { non_success << snapshot } unless snapshot.status.success?
        end
      rescue ex
        report_mutex.synchronize { errors << ex }
      ensure
        wait_group.done
      end
    end

    wait_group.wait

    errors.should be_empty
    non_success.should be_empty
    valid_ids.should contain(service.current_state.id)
  end
end

require "./spec_helper"
require "wait_group"

# Specs for FSM::Context#get / #set / #modify (design section 3.2, section 12.5).
#
# FSM::Context is the hash-and-mutex bucket the library ships as one selectable T
# (design section 3.2). It stores FSM::Any values behind a mutex and exposes
# get/set/modify. These specs pin the CURRENT contract of those three methods.
#
# Missing-key behavior is pinned to KeyError throughout. Design section 3.2 names the
# missing-key KeyError as a rough edge to fix, and fsmcr-54d will add non-raising
# accessors (fetch/has_key?/delete). Until then these specs pin what the code does
# today, not what it will do forever.
#
# Values come back as the FSM::Any union (get returns Any, modify's block receives
# Any). Comparisons against a literal need no cast, but arithmetic on a returned value
# does: FSM::Any includes Nil and Bool, which have no `+`, so a caller must narrow with
# `is_a?` before doing math. The modify blocks below narrow that way rather than using
# `.as`.

describe FSM::Context do
  describe "#get" do
    it "returns the value a prior #set stored" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("greeting", "hello")

      ctx.get("greeting").should eq("hello")
    end

    it "raises KeyError for a key that was never set" do
      # Pins the CURRENT contract (design section 3.2). Hash#[] raises KeyError on a
      # missing key and #get forwards that through the mutex. fsmcr-54d will add a
      # non-raising accessor; until then a missing key raises.
      ctx : FSM::Context = FSM::Context.new

      expect_raises(KeyError) { ctx.get("missing") }
    end
  end

  describe "#set" do
    it "stores a value that #get then returns" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("count", 7)

      ctx.get("count").should eq(7)
    end

    it "overwrites an existing value" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("count", 1)
      ctx.set("count", 2)

      ctx.get("count").should eq(2)
    end

    it "returns the value it stored" do
      # Pins the CURRENT contract: set evaluates to the value assigned, mirroring
      # Hash#[]= which returns its right-hand side.
      ctx : FSM::Context = FSM::Context.new

      ctx.set("count", 42).should eq(42)
    end
  end

  describe "#modify" do
    it "applies the block to the current value and stores the result" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("n", 10)

      ctx.modify("n") do |v|
        current : Int32 = v.is_a?(Int32) ? v : raise "expected Int32 for \"n\", got #{v.class}"
        current * 2
      end

      ctx.get("n").should eq(20)
    end

    it "returns the modified value" do
      # Pins the CURRENT contract: modify evaluates to the block's result, the same
      # value it stored.
      ctx : FSM::Context = FSM::Context.new
      ctx.set("n", 10)

      result : FSM::Any = ctx.modify("n") do |v|
        current : Int32 = v.is_a?(Int32) ? v : raise "expected Int32 for \"n\", got #{v.class}"
        current + 5
      end

      result.should eq(15)
    end

    it "raises KeyError when the key was never set and never calls the block" do
      # Pins the CURRENT contract (design section 3.2). modify reads @data[key] before
      # calling the block, so a missing key raises KeyError and the block never runs.
      ctx : FSM::Context = FSM::Context.new
      called : Bool = false

      expect_raises(KeyError) do
        ctx.modify("missing") do |v|
          called = true
          v
        end
      end

      called.should be_false
    end

    # The compound read-modify-write atomicity contract (design section 12.5).
    #
    # Section 12.5 is explicit: `ctx.set("n", ctx.get("n") + 1)` races even with the
    # mutex, because it is two separately locked operations with an unlocked gap, while
    # `ctx.modify("n") { |v| v + 1 }` does not, because the read, the block, and the
    # write all happen under one lock hold.
    #
    # spec_helper resizes the default execution context to more than one worker, so the
    # fibers below run on separate worker threads at the same time. Without that resize
    # the scheduler would run each fiber to completion before the next and the mutex
    # would never be contended, so a missing lock would go undetected.
    #
    # Detector power. Each modify block does read -> Fiber.yield -> write, the same
    # widening trick service_concurrency_spec.cr uses. Because modify holds its mutex
    # across block.call, the yield hands off a scheduler slot WHILE the lock is held:
    # any other fiber entering modify blocks on the mutex and cannot observe the stale
    # value, so every increment lands and the final count is exactly `total`, on every
    # run. Were modify instead non-atomic -- read the value, release the lock, call the
    # block, re-acquire to write -- the yield would let another worker's fiber read the
    # same current value, and the later write would clobber the earlier one, losing
    # updates reliably at this fiber and iteration count. So the spec asserts the exact
    # total (deterministic under the correct implementation) and that same assertion
    # falls short under a non-atomic modify. This is not a might-catch race: the yield
    # forces the interleaving a lock exists to prevent on every iteration.
    describe "atomicity under real parallelism" do
      it "loses zero updates when many fibers increment the same key" do
        ctx : FSM::Context = FSM::Context.new
        ctx.set("n", 0)

        fiber_count : Int32 = 200
        increments_per_fiber : Int32 = 50
        total : Int32 = fiber_count * increments_per_fiber

        # Fiber#run logs an unhandled fiber exception to stderr instead of failing the
        # spec runner, so a raising modify would otherwise leave the spec green. Collect
        # exceptions and assert on them directly.
        errors : Array(Exception) = [] of Exception
        error_mutex : Mutex = Mutex.new
        wait_group : WaitGroup = WaitGroup.new(fiber_count)

        fiber_count.times do
          spawn do
            increments_per_fiber.times do
              ctx.modify("n") do |v|
                current : Int32 = v.is_a?(Int32) ? v : raise "expected Int32 for \"n\", got #{v.class}"
                Fiber.yield
                current + 1
              end
            end
          rescue ex
            error_mutex.synchronize { errors << ex }
          ensure
            wait_group.done
          end
        end

        wait_group.wait

        errors.should be_empty
        ctx.get("n").should eq(total)
      end
    end
  end
end

require "./spec_helper"
require "wait_group"

# Specs for FSM::Context#get / #set / #modify.
#
# FSM::Context is the hash-and-mutex bucket the library ships as one selectable T.
# It stores FSM::Any values behind a mutex and exposes
# get/set/modify. These specs pin the CURRENT contract of those three methods.
#
# Missing-key behavior for get/modify stays pinned to KeyError: the missing-key KeyError
# is a rough edge, but the existing get/modify contract is left
# raising on purpose. Non-raising accessors are added alongside them: get?, fetch,
# has_key?, and delete. The specs below the get/set/modify block pin that new surface.
# Each new method is mutex-synchronized like the existing three.
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
      # Pins the CURRENT contract. Hash#[] raises KeyError on a
      # missing key and #get forwards that through the mutex. #get? is the
      # non-raising accessor; #get itself keeps raising.
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
      # Pins the CURRENT contract. modify reads @data[key] before
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

    # The compound read-modify-write atomicity contract.
    #
    # The atomicity contract is explicit: `ctx.set("n", ctx.get("n") + 1)` races even with the
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

  # get? is the non-raising getter. The missing-key KeyError is the rough edge get?
  # remedies. Where get forwards
  # Hash#[] and raises on a missing key, get? forwards Hash#[]? and returns nil for it.
  describe "#get?" do
    it "returns the value a prior #set stored" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("greeting", "hello")

      ctx.get?("greeting").should eq("hello")
    end

    it "returns nil for a key that was never set instead of raising" do
      # The contrast with #get, which raises KeyError on the same missing key. get? is
      # the non-raising accessor.
      ctx : FSM::Context = FSM::Context.new

      ctx.get?("missing").should be_nil
    end

    it "returns nil for a stored nil, the same value it returns for an absent key" do
      # The wrinkle to pin explicitly. FSM::Any INCLUDES Nil (src/fsmcr.cr), so a key whose
      # stored value is nil and a key that was never set both come back nil from get?.
      # get? alone cannot tell the two apart; has_key? is the disambiguator, pinned in
      # the pairing spec below.
      ctx : FSM::Context = FSM::Context.new
      ctx.set("maybe", nil)

      ctx.get?("maybe").should be_nil
      ctx.get?("absent").should be_nil
    end

    it "distinguishes a stored nil from an absent key only when paired with has_key?" do
      # The disambiguation contract. get? returns nil for both cases; has_key? is what
      # separates "present and nil" from "absent". A caller that must tell them apart
      # pairs the two.
      ctx : FSM::Context = FSM::Context.new
      ctx.set("maybe", nil)

      # Present and nil: get? is nil, has_key? is true.
      ctx.get?("maybe").should be_nil
      ctx.has_key?("maybe").should be_true

      # Absent: get? is nil, has_key? is false.
      ctx.get?("absent").should be_nil
      ctx.has_key?("absent").should be_false
    end
  end

  # fetch(key, default) is the fetch-with-default accessor. It
  # returns the stored value when present and the supplied default when absent, and it
  # never mutates the context: a defaulted lookup does not store the default.
  describe "#fetch" do
    it "returns the stored value when the key is present" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("count", 7)

      ctx.fetch("count", 0).should eq(7)
    end

    it "returns the default when the key is absent" do
      ctx : FSM::Context = FSM::Context.new

      ctx.fetch("missing", 99).should eq(99)
    end

    it "returns a value typed as FSM::Any when the default is itself an Any member" do
      # Pins what type comes back. Hash#fetch(key, default) yields V | typeof(default);
      # with V == FSM::Any and a default that is itself an Any member (Int32 here), the
      # union collapses back to FSM::Any, so the result assigns to an FSM::Any local.
      ctx : FSM::Context = FSM::Context.new

      result : FSM::Any = ctx.fetch("missing", 0)
      result.should eq(0)
    end

    it "does not store the default, so a later #get still raises and #has_key? stays false" do
      # The non-mutating contract. fetch reads through the default; it does not write it.
      # After a defaulted lookup the key is still absent: #get raises KeyError and
      # #has_key? reports false.
      ctx : FSM::Context = FSM::Context.new

      ctx.fetch("missing", 0).should eq(0)

      ctx.has_key?("missing").should be_false
      expect_raises(KeyError) { ctx.get("missing") }
    end
  end

  # has_key? is the presence test. It reports whether a key is
  # present regardless of the stored value, which is what lets get? and a stored nil be
  # told apart.
  describe "#has_key?" do
    it "is true after a #set" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("greeting", "hello")

      ctx.has_key?("greeting").should be_true
    end

    it "is false for a key that was never set" do
      ctx : FSM::Context = FSM::Context.new

      ctx.has_key?("missing").should be_false
    end

    it "is true when the stored value is nil, distinguishing presence from absence" do
      # Presence is about the key, not the value. A key whose value is nil is present,
      # so has_key? is true even though get? on it returns nil (the
      # FSM::Any-includes-Nil wrinkle).
      ctx : FSM::Context = FSM::Context.new
      ctx.set("maybe", nil)

      ctx.has_key?("maybe").should be_true
    end

    it "is false after the key is deleted" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("greeting", "hello")
      ctx.delete("greeting")

      ctx.has_key?("greeting").should be_false
    end
  end

  # delete removes a key from the context. Its return value follows
  # Crystal's Hash#delete convention.
  describe "#delete" do
    it "removes the key so #has_key? is false afterward" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("greeting", "hello")

      ctx.delete("greeting")

      ctx.has_key?("greeting").should be_false
    end

    it "makes a subsequent #get raise KeyError for the removed key" do
      ctx : FSM::Context = FSM::Context.new
      ctx.set("greeting", "hello")

      ctx.delete("greeting")

      expect_raises(KeyError) { ctx.get("greeting") }
    end

    it "returns the removed value when the key was present" do
      # delete mirrors Crystal's Hash#delete, which returns the value that was removed.
      # Context wraps a Hash, so matching Hash#delete keeps the bucket's surface
      # consistent with the type it is.
      ctx : FSM::Context = FSM::Context.new
      ctx.set("count", 42)

      ctx.delete("count").should eq(42)
    end

    it "returns nil when the key was absent" do
      # The other half of the Hash#delete convention: deleting a key that is not there
      # returns nil rather than raising. This makes delete safe to call unconditionally.
      ctx : FSM::Context = FSM::Context.new

      ctx.delete("missing").should be_nil
    end
  end

  # Concurrent set/delete/has_key? traffic on one shared context under real parallelism.
  # This is a robustness/smoke check in the style of
  # the ring test in service_concurrency_spec.cr, not a lost-update detector: it asserts
  # that the shared @data Hash survives concurrent structural mutation from many worker
  # threads without crashing or corrupting, and reaches a deterministic final state.
  #
  # spec_helper resizes the default execution context to more than one worker, so the
  # fibers below mutate the one underlying Hash from separate worker threads at the same
  # time. A Hash mutated structurally (set grows it, delete shrinks it) from two threads
  # without a lock can crash on a concurrent rehash or corrupt its buckets. The mutex
  # every Context method holds is the only thing serializing that
  # structural churn here.
  #
  # Determinism. Each fiber owns a distinct key "k#{i}", so no two fibers ever contend
  # for the same key and every per-key assertion is exact: right after a set the key is
  # present, right after a delete it is absent, on every run. Every fiber's loop ends on
  # a delete, so once all fibers finish the context holds none of the keys. The
  # assertions are therefore deterministic under the correct implementation, with no
  # coin-flip race: the parallelism stresses the shared structure, the ownership keeps
  # the observable outcome fixed.
  describe "concurrent set/delete/has_key? under real parallelism" do
    it "survives structural churn from many fibers and ends with every key absent" do
      ctx : FSM::Context = FSM::Context.new

      fiber_count : Int32 = 200
      cycles_per_fiber : Int32 = 50

      # Fiber#run logs an unhandled fiber exception to stderr instead of failing the spec
      # runner, so a crashing set/delete would otherwise leave the spec green. Collect
      # exceptions and any per-fiber invariant violation and assert on them directly.
      errors : Array(Exception) = [] of Exception
      violations : Array(String) = [] of String
      report_mutex : Mutex = Mutex.new
      wait_group : WaitGroup = WaitGroup.new(fiber_count)

      fiber_count.times do |i|
        key : String = "k#{i}"
        spawn do
          cycles_per_fiber.times do
            ctx.set(key, i)
            # Widen the window between the two structural mutations so a missing lock has
            # a full scheduler slot to interleave another worker's set or delete, the same
            # widening trick the atomicity detector above uses.
            Fiber.yield
            present_after_set : Bool = ctx.has_key?(key)
            ctx.delete(key)
            present_after_delete : Bool = ctx.has_key?(key)

            unless present_after_set && !present_after_delete
              report_mutex.synchronize do
                violations << "#{key}: present_after_set=#{present_after_set} present_after_delete=#{present_after_delete}"
              end
            end
          end
        rescue ex
          report_mutex.synchronize { errors << ex }
        ensure
          wait_group.done
        end
      end

      wait_group.wait

      errors.should be_empty
      violations.should be_empty

      # Every fiber's last act on its key is a delete, so once all fibers finish no key
      # remains. Checked per key because Context exposes presence, not size.
      fiber_count.times do |i|
        ctx.has_key?("k#{i}").should be_false
      end
    end
  end
end

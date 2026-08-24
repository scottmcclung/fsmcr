require "./spec_helper"
require "wait_group"

# Service(T) is the synchronous interpreter. These
# specs build a machine with `Machine(T).build` and run it with
# `Service(T).interpret`, exercising the interpreter's behavioral surface.
#
# Note: `current_state` returns the cached `State`
# snapshot, so these specs read the id off it with `current_state.id`, and
# `matches?` compares against that id. The `on_transition` observer payload is
# settled elsewhere, so these specs only assert that it fires, never on its
# argument.
describe FSM::Service do
  it "reports the initial state id on creation" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| }
      m.state("state2") { |s| }
      m.state("state3") { |s| }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new)
    service.current_state.id.should eq "state1"
  end

  it "transitions between states on a recognized event" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("event1", "state2") }
      m.state("state2") { |s| }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new)
    service.send("event1")

    service.current_state.id.should eq "state2"
  end

  it "does not transition on an unrecognized event" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("event1", "state2") }
      m.state("state2") { |s| }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new)
    service.send("invalid_event")

    service.current_state.id.should eq "state1"
  end

  it "runs entry and exit callbacks during a transition, passing the context" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("event1", "state2")
        s.on_exit { |_event, c| c.say("exited state1") }
      end
      m.state("state2") do |s|
        s.on_entry { |_event, c| c.say("entered state2") }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "state1", ctx)
    service.send("event1")

    ctx.log.should contain "exited state1"
    ctx.log.should contain "entered state2"
  end

  it "fires the on_transition observer when a transition occurs" do
    observer_fired : Bool = false

    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("event1", "state2") }
      m.state("state2") { |s| }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new) do |observers|
      observers.on_transition { |_snapshot| observer_fired = true }
    end

    service.send("event1")

    observer_fired.should be_true
  end

  it "runs the transition callback registered with t.on" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("event1", "state2") do |t|
          t.on { |_event, c| c.say("transitioned") }
        end
      end
      m.state("state2") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "state1", ctx)
    service.send("event1")

    ctx.log.should contain "transitioned"
  end

  it "completes the transition and runs every callback when a guard passes" do
    ctx : TurnContext = TurnContext.new(rope_secured: true)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("event1", "state2") do |t|
          t.guard { |_event, c| c.rope_secured }
          t.on { |_event, c| c.say("transitioned") }
        end
        s.on_exit { |_event, c| c.say("exited") }
      end
      m.state("state2") do |s|
        s.on_entry { |_event, c| c.say("entered") }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "state1", ctx)
    service.send("event1")

    service.current_state.id.should eq "state2"
    ctx.log.should contain "exited"
    ctx.log.should contain "transitioned"
    ctx.log.should contain "entered"
  end

  it "blocks the transition and runs no callbacks when a guard rejects" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    observer_fired : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("event1", "state2") do |t|
          t.guard { |_event, c| c.rope_secured }
          t.on { |_event, c| c.say("transitioned") }
        end
        s.on_exit { |_event, c| c.say("exited") }
      end
      m.state("state2") do |s|
        s.on_entry { |_event, c| c.say("entered") }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "state1", ctx) do |observers|
      observers.on_transition { |_snapshot| observer_fired = true }
    end

    service.send("event1")

    service.current_state.id.should eq "state1"
    ctx.log.should be_empty
    observer_fired.should be_false
  end

  it "answers matches? against the current state id" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("event1", "state2") }
      m.state("state2") { |s| }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new)

    service.matches?("state1").should be_true
    service.matches?("state2").should be_false

    service.send("event1")

    service.matches?("state2").should be_true
  end

  it "serializes concurrent senders so a slow transition still lands in its target" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("event1", "state2") do |t|
          t.on do |_event, _context|
            # A time-consuming step during the transition, holding the mutex.
            sleep(1.second)
          end
        end
      end
      m.state("state2") { |s| }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new)

    # Start transitioning to state2 in the background, then send again immediately.
    spawn { service.send("event1") }
    service.send("event1")

    service.current_state.id.should eq "state2"
  end

  context "concurrency test with complex FSM setup" do
    it "handles many fibers invoking a variety of state transitions" do
      machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
        10.times do |i|
          m.state("state#{i}") do |s|
            5.times do |j|
              target_state_index : Int32 = (i + j + 1) % 10 # a variety of target states
              s.on_event("event#{i}_to_#{target_state_index}", "state#{target_state_index}")
            end
          end
        end
      end

      service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state0", FSM::Context.new)

      # spec_helper resizes the default execution context to more than one worker,
      # so these 100 fibers now run under genuine parallelism and
      # contend on Service#@transition_mutex rather than running one at a time.
      # This verifies the spawn/WaitGroup fiber lifecycle and 100 concurrent send
      # calls completing without raising or hanging. The purpose-built detectors
      # that fail when the mutex is removed live in service_concurrency_spec.cr.
      valid_state_ids : Set(String) = Set(String).new
      10.times { |i| valid_state_ids << "state#{i}" }

      # Fiber#run logs unhandled fiber exceptions to stderr instead of
      # propagating them to the spec runner, so a failing send would otherwise
      # leave the spec green. Collect exceptions and assert on them directly.
      errors : Array(Exception) = [] of Exception
      error_mutex : Mutex = Mutex.new

      fiber_count : Int32 = 100
      wait_group : WaitGroup = WaitGroup.new(fiber_count)
      fiber_count.times do |i|
        spawn do
          current_state_index : Int32 = i % 10
          event_index : Int32 = (i // 10) % 5
          event : String = "event#{current_state_index}_to_#{(current_state_index + event_index + 1) % 10}"
          service.send(event)
        rescue ex
          error_mutex.synchronize { errors << ex }
        ensure
          wait_group.done
        end
      end

      wait_group.wait

      errors.should be_empty

      # The machine only ever moves along defined transitions, so the current
      # state is always one of the ten valid ids.
      valid_state_ids.should contain(service.current_state.id)
    end
  end
end

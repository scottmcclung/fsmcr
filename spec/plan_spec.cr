require "./spec_helper"
require "./support/plan_probe"

# The pure core: plan and the action list (design section 7, section 10.2 steps
# 9-16, D7).
#
# `plan(state, event, context) : Plan(T)` selects the transition, evaluates guards,
# and computes an ordered action list. It executes NOTHING. Actions are tagged with
# an ActionKind rather than being bare procs, so an interpreter (or a spec) can
# inspect the decision without running it.
#
#   enum ActionKind { Exit; Transition; Entry; Blocked; UnknownEvent }
#   struct Action(T) { kind : ActionKind; state_id : String; callback : (String, T) -> }
#   struct Plan(T)   { outcome; next_state : StateDefinition(T); actions : Array(Action(T)) }
#
# Action table (design section 10.2 step 15):
#   TransitionFound, different state          -> [Exit(current), Transition, Entry(next)]
#   TransitionFound, same state, external     -> the same three (see self_transition_spec)
#   TransitionFound, same state, internal     -> [Transition] only (see self_transition_spec)
#   TransitionsBlocked                        -> empty when no on_blocked handler
#   EventNotRecognized                        -> empty when no on_unknown_event handler
#
# TransitionsBlocked is empty here because no on_blocked handler is registered for
# the event; see spec/on_blocked_spec.cr for the handler-registered case where plan
# emits a Blocked action (fsmcr-bfn.4). EventNotRecognized is empty here because no
# on_unknown_event handler is registered on the state; see
# spec/on_unknown_event_spec.cr for the handler-registered case where plan emits an
# UnknownEvent action (fsmcr-bfn.5). Only the emptiness of the action list is
# asserted here.
describe "plan" do
  it "emits Exit(current), Transition, Entry(next) for a transition to a different state" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit:cave") }
        s.on_event("north", "clearing") { |t| t.on { |_e, c| c.say("transition") } }
      end
      m.state("clearing") do |s|
        s.on_entry { |_e, c| c.say("entry:clearing") }
      end
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    plan.actions.map(&.kind).should eq [
      FSM::ActionKind::Exit,
      FSM::ActionKind::Transition,
      FSM::ActionKind::Entry,
    ]

    plan.next_state.id.should eq "clearing"

    # The Exit action names the state being left; the Entry action names the state
    # being entered (design section 7). The Transition action's state_id is left
    # unasserted; the design fixes the kind order but not what state_id the middle
    # action carries.
    plan.actions[0].state_id.should eq "cave"
    plan.actions[2].state_id.should eq "clearing"
  end

  it "wires each action's callback to the matching registered callback, in order" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit:cave") }
        s.on_event("north", "clearing") { |t| t.on { |_e, c| c.say("transition") } }
      end
      m.state("clearing") do |s|
        s.on_entry { |_e, c| c.say("entry:clearing") }
      end
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # plan ran nothing (asserted for purity below); running the carried callbacks
    # here, in the order plan chose, proves each Action.callback holds the right
    # proc and that the order matches Exit -> Transition -> Entry.
    plan.actions.each do |action|
      action.callback.call("north", ctx)
    end

    ctx.log.should eq ["exit:cave", "transition", "entry:clearing"]
  end

  it "runs no callbacks while planning" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit:cave") }
        s.on_event("north", "clearing") { |t| t.on { |_e, c| c.say("transition") } }
      end
      m.state("clearing") do |s|
        s.on_entry { |_e, c| c.say("entry:clearing") }
      end
    end

    FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # plan decides; it never executes (design section 7). No exit, transition, or
    # entry callback ran, so the side-channel log stays empty.
    ctx.log.should be_empty
  end

  it "returns equivalent plans when called twice with the same inputs" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit:cave") }
        s.on_event("north", "clearing") { |t| t.on { |_e, c| c.say("transition") } }
      end
      m.state("clearing") do |s|
        s.on_entry { |_e, c| c.say("entry:clearing") }
      end
    end

    first : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)
    second : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # Purity means planning is repeatable: the same inputs produce the same decision.
    first.actions.map(&.kind).should eq second.actions.map(&.kind)
    first.next_state.id.should eq second.next_state.id

    # And planning twice still ran nothing.
    ctx.log.should be_empty
  end

  it "produces an empty action list for TransitionsBlocked" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit:cave") }
        s.on_event("north", "clearing") { |t| t.guard { |_e, _c| false } }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # The Blocked action needs an on_blocked handler for the event; this state
    # registers none, so the list is empty (design section 10.2 step 15). See
    # spec/on_blocked_spec.cr for the handler-registered case.
    plan.actions.should be_empty
    # The destination for a blocked step is the unchanged current state (step 14).
    plan.next_state.id.should eq "cave"
  end

  it "produces an empty action list for EventNotRecognized" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit:cave") }
        s.on_event("north", "clearing")
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "xyzzy", ctx)

    # The UnknownEvent action needs an on_unknown_event handler for the event; this
    # state registers none, so the list is empty (design section 10.2 step 15). See
    # spec/on_unknown_event_spec.cr for the handler-registered case.
    plan.actions.should be_empty
    # Destination for an unrecognized event is the unchanged current state (step 14).
    plan.next_state.id.should eq "cave"
  end

  it "defines all five ActionKind variants" do
    # All five variants exist. plan emits Blocked when the state has an on_blocked
    # handler (fsmcr-bfn.4) and UnknownEvent when the state has an on_unknown_event
    # handler (fsmcr-bfn.5); see the respective specs (design section 7).
    kinds : Array(FSM::ActionKind) = [
      FSM::ActionKind::Exit,
      FSM::ActionKind::Transition,
      FSM::ActionKind::Entry,
      FSM::ActionKind::Blocked,
      FSM::ActionKind::UnknownEvent,
    ]
    kinds.uniq.size.should eq 5
  end
end

# `plan` is protected and not public API (design section 7, D7). A caller outside
# the FSM namespace cannot reach it. This compiles a tiny program that calls `plan`
# from the top level and asserts the compile fails naming a protected-visibility
# error. It is the D7 counterpart to nil_context_spec's compile probe.
describe "plan visibility" do
  it "is not callable from outside the FSM namespace" do
    program : String = <<-CRYSTAL
      require "../src/fsm"
      machine = FSM::Machine(FSM::Context).build("m") do |mb|
        mb.state("a") { |s| s.on_event("go", "a") }
      end
      definition = machine.states["a"]
      machine.plan(definition, "go", FSM::Context.new)
      CRYSTAL

    tmp : String = File.join(__DIR__, "plan_visibility_probe_#{Process.pid}.cr")
    File.write(tmp, program)

    output : IO::Memory = IO::Memory.new
    status : Process::Status = Process.run(
      "crystal",
      ["build", "--no-codegen", tmp],
      output: output,
      error: output,
    )
    File.delete(tmp)

    status.success?.should be_false
    output.to_s.should contain "protected"
  end
end

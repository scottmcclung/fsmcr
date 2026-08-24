require "./spec_helper"
require "./support/plan_probe"

# Self-transitions.
#
# A self-transition is EXTERNAL by default: it runs exit, then the transition
# callback, then entry, exactly as a transition to any other state would. INTERNAL
# is opt-in per transition via `t.internal` in the config block, which suppresses
# exit and entry and runs only the transition callback.
#
# Whether exit and entry appear is a property of `plan` (assert on the action list),
# and it is also observable end-to-end through Service (the existing send path).
describe "self-transitions" do
  it "runs exit, transition, entry for an external self-transition (plan)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit") }
        s.on_entry { |_e, c| c.say("entry") }
        # External is the default; no `t.internal`.
        s.on_event("look", "cave") { |t| t.on { |_e, c| c.say("transition") } }
      end
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "look", ctx)

    plan.actions.map(&.kind).should eq [
      FSM::ActionKind::Exit,
      FSM::ActionKind::Transition,
      FSM::ActionKind::Entry,
    ]
    plan.next_state.id.should eq "cave"
  end

  it "runs only the transition callback for an internal self-transition (plan)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit") }
        s.on_entry { |_e, c| c.say("entry") }
        # Internal is opt-in per transition.
        s.on_event("look", "cave") { |t| t.internal.on { |_e, c| c.say("transition") } }
      end
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "look", ctx)

    plan.actions.map(&.kind).should eq [FSM::ActionKind::Transition]
    plan.next_state.id.should eq "cave"
  end

  it "runs exit, transition, entry in order for an external self-transition (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit") }
        s.on_entry { |_e, c| c.say("entry") }
        s.on_event("look", "cave") { |t| t.on { |_e, c| c.say("transition") } }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("look")

    ctx.log.should eq ["exit", "transition", "entry"]
    service.current_state.id.should eq "cave"
  end

  it "suppresses exit and entry for an internal self-transition (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_exit { |_e, c| c.say("exit") }
        s.on_entry { |_e, c| c.say("entry") }
        s.on_event("look", "cave") { |t| t.internal.on { |_e, c| c.say("transition") } }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("look")

    ctx.log.should eq ["transition"]
    service.current_state.id.should eq "cave"
  end
end

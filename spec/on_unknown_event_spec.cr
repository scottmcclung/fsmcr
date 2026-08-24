require "./spec_helper"
require "./support/plan_probe"

# The state-wide on_unknown_event handler.
#
# `s.on_unknown_event { |event, context| ... }` fires when the state has NO transition
# registered for the event at all, turning today's silent no-op into an observable hook.
# It is state-wide: one handler per state, catching every unregistered event. The
# asymmetry with per-event on_blocked is intentional, because "this event means nothing
# here" is about events you did not register, and anticipating those individually is a
# contradiction.
#
# It does NOT fire for a blocked event (transitions exist but every guard rejected, which
# is on_blocked territory), and it does NOT fire when a transition succeeds. The handler
# receives the event name and the context, matching the
# (event, context) shape of on_entry and on_exit; there are no blocked target ids to pass
# because no transition was registered.
#
# Where an unknown step is observed: `plan` emits a single UnknownEvent action for the
# event when a handler is registered, else an empty action list (the `EventNotRecognized`
# case). The interpreter runs that action like any other, so
# on_unknown_event fires end-to-end through Service#send. These specs assert on both
# layers, mirroring on_blocked_spec: the pure core (the UnknownEvent action in the plan)
# and the end-to-end path (Service running it).
describe "on_unknown_event" do
  # --- The pure core: the UnknownEvent action in the plan ---

  it "emits a single UnknownEvent action for an unregistered event when a handler is registered" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |_e, c| c.say("unknown") }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "xyzzy", ctx)

    # A registered handler turns the empty unknown-event action list (see plan_spec) into a
    # single UnknownEvent action carrying the unchanged current state id.
    plan.actions.map(&.kind).should eq [FSM::ActionKind::UnknownEvent]
    plan.actions[0].state_id.should eq "cave"

    # The destination for an unknown step is the unchanged current state.
    plan.next_state.id.should eq "cave"
  end

  it "runs the on_unknown_event handler with the event name only when the UnknownEvent action runs" do
    ctx : TurnContext = TurnContext.new
    seen_event : String? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |event, _ctx| seen_event = event }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "xyzzy", ctx)

    # Purity: planning decides but runs nothing, so the handler has not fired yet.
    seen_event.should be_nil

    # Running the UnknownEvent action's callback is what fires the handler. It receives the
    # event name that was not recognized.
    plan.actions[0].callback.call("xyzzy", ctx)

    seen_event.should eq "xyzzy"
  end

  it "emits no UnknownEvent action for an unknown event when no handler is registered" do
    ctx : TurnContext = TurnContext.new

    # A state with a transition but no on_unknown_event handler. Sending an unregistered
    # event must produce no action (empty when no handler is registered), preserving
    # today's silent no-op.
    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "xyzzy", ctx)

    # The existing result shape still holds: EventNotRecognized outcome, empty action list,
    # unchanged destination.
    plan.outcome.should be_a(FSM::EventNotRecognized)
    plan.actions.should be_empty
    plan.next_state.id.should eq "cave"
  end

  it "emits no UnknownEvent action for a found transition even when a handler is registered" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |_e, c| c.say("unknown") }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # The event is registered and its guardless transition passes, so the outcome is
    # TransitionFound and the action list is the ordinary Exit, Transition, Entry with no
    # UnknownEvent action.
    plan.actions.map(&.kind).should eq [
      FSM::ActionKind::Exit,
      FSM::ActionKind::Transition,
      FSM::ActionKind::Entry,
    ]
  end

  it "emits no UnknownEvent action for a blocked event even when a handler is registered" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        # "north" IS registered but its guard rejects, so the outcome is TransitionsBlocked,
        # which on_unknown_event never fires for. That is on_blocked territory.
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_unknown_event { |_e, c| c.say("unknown") }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    plan.outcome.should be_a(FSM::TransitionsBlocked)
    plan.actions.should be_empty
    plan.next_state.id.should eq "cave"
  end

  # --- End-to-end through the synchronous interpreter ---

  it "fires on_unknown_event when the state has no transition for the event (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |event, c| c.say("You can't #{event} here.") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("xyzzy")

    ctx.log.should eq ["You can't xyzzy here."]
    # An unknown step is a step that moved nowhere.
    service.current_state.id.should eq "cave"
  end

  it "does not fire on_unknown_event when a transition succeeds (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |_e, c| c.say("unknown") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    ctx.log.should be_empty
    service.current_state.id.should eq "clearing"
  end

  it "does not fire on_unknown_event for a blocked event (Service)" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_unknown_event { |_e, c| c.say("unknown") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    # "north" is registered but its guard rejected: that is a blocked event, not an unknown
    # one, so on_unknown_event stays silent.
    ctx.log.should be_empty
    service.current_state.id.should eq "cave"
  end

  it "fires on_unknown_event but not on_blocked for an unknown event, and vice versa for a blocked event (Service)" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked north") }
        s.on_unknown_event { |_e, c| c.say("unknown event") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)

    # An unknown event fires on_unknown_event only, never on_blocked.
    service.send("xyzzy")
    ctx.log.should eq ["unknown event"]

    # A blocked event fires on_blocked only, never on_unknown_event.
    service.send("north")
    ctx.log.should eq ["unknown event", "blocked north"]
  end

  it "passes the correct event name to the handler (Service)" do
    ctx : TurnContext = TurnContext.new
    seen_event : String? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |event, _ctx| seen_event = event }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("plugh")

    seen_event.should eq "plugh"
  end

  it "is state-wide: one handler catches every unregistered event (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        # A single handler, no event key, catching every unregistered event.
        s.on_unknown_event { |event, c| c.say("unknown: #{event}") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("xyzzy")
    service.send("plugh")

    ctx.log.should eq ["unknown: xyzzy", "unknown: plugh"]
    service.current_state.id.should eq "cave"
  end

  it "consults only the current state's handler, never another state's (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |_e, c| c.say("cave handler fired") }
      end
      m.state("clearing") do |s|
        # An unknown event here, but "clearing" registers no on_unknown_event. The handler on
        # "cave" must not fire while the interpreter is in "clearing" (one handler per
        # state).
        s.on_event("south", "cave")
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "clearing", ctx)
    service.send("xyzzy")

    ctx.log.should be_empty
    service.current_state.id.should eq "clearing"
  end

  it "remains a silent no-op for an unknown event with no handler registered (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("xyzzy")

    # No handler registered: the existing silent no-op behavior is unchanged. The
    # interpreter stayed put and no callback ran.
    ctx.log.should be_empty
    service.current_state.id.should eq "cave"
  end
end

require "./spec_helper"
require "./support/plan_probe"

# The per-event on_blocked handler (design section 9, section 13.3, D12).
#
# `s.on_blocked(event) { |event, context, blocked| ... }` fires when the state has
# at least one transition registered for the event and every candidate guard
# returned false. It is keyed per event: different blocked events want different
# messages. It does NOT fire for an unknown event (no transition registered at all),
# and it does NOT fire when any transition succeeds (design section 9).
#
# Payload (D12, design sections 9 and 15): the third block parameter `blocked`
# carries an Array(String) of the blocked target state ids. That lighter form is
# preferred over handing out the Transition objects, and it keeps Transition off the
# public surface. The point of passing what was blocked is that a handler can produce
# a specific reason WITHOUT re-running any guard predicate.
#
# Where a blocked step is observed: `plan` emits a single Blocked action for the
# event when a handler is registered, else an empty action list (design section 10.2
# step 15). The interpreter runs that action like any other, so on_blocked fires
# end-to-end through Service#send. These specs assert on both layers, mirroring
# self_transition_spec: the pure core (the Blocked action in the plan) and the
# end-to-end path (Service running it).
describe "on_blocked" do
  # --- The pure core: the Blocked action in the plan (design section 10.2 step 15) ---

  it "emits a single Blocked action for a registered event whose guards all reject when a handler is registered" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked") }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # A registered handler turns the empty blocked action list (see plan_spec) into a
    # single Blocked action carrying the unchanged current state id (design table
    # entry `Blocked(cave, "north")`).
    plan.actions.map(&.kind).should eq [FSM::ActionKind::Blocked]
    plan.actions[0].state_id.should eq "cave"

    # The destination for a blocked step is the unchanged current state (step 14).
    plan.next_state.id.should eq "cave"
  end

  it "runs the on_blocked handler with the event name and blocked target ids only when the Blocked action runs" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    seen_event : String? = nil
    seen_blocked : Array(String)? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") do |event, _ctx, blocked|
          seen_event = event
          seen_blocked = blocked
        end
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # Purity: planning decides but runs nothing, so the handler has not fired yet
    # (design section 7).
    seen_event.should be_nil
    seen_blocked.should be_nil

    # Running the Blocked action's callback is what fires the handler. It receives the
    # event name and the blocked target ids.
    plan.actions[0].callback.call("north", ctx)

    seen_event.should eq "north"
    seen_blocked.should eq ["clearing"]
  end

  it "emits no Blocked action for a blocked event that has no handler registered" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    # Two guarded events; a handler for only one of them. Sending the other blocked
    # event must produce no Blocked action (design section 10.2 step 15: empty when no
    # handler is registered).
    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_event("down", "shaft") { |t| t.guard { |_e, _c| false } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked north") }
      end
      m.state("clearing") { |s| }
      m.state("shaft") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "down", ctx)

    plan.actions.should be_empty
    plan.next_state.id.should eq "cave"
  end

  it "emits no Blocked action for a found transition even when a handler is registered for the event" do
    ctx : TurnContext = TurnContext.new(rope_secured: true)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked") }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # The guard passed, so the outcome is TransitionFound and the action list is the
    # ordinary Exit, Transition, Entry with no Blocked action.
    plan.actions.map(&.kind).should eq [
      FSM::ActionKind::Exit,
      FSM::ActionKind::Transition,
      FSM::ActionKind::Entry,
    ]
  end

  it "emits no Blocked action for an unknown event even when a handler is registered for other events" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked") }
      end
      m.state("clearing") { |s| }
    end

    # "xyzzy" has no transition registered, so the outcome is EventNotRecognized, which
    # on_blocked never fires for (design section 9).
    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "xyzzy", ctx)

    plan.actions.should be_empty
    plan.next_state.id.should eq "cave"
  end

  it "collects every blocked target id, in registration order, when several transitions on one event reject" do
    ctx : TurnContext = TurnContext.new
    seen_blocked : Array(String)? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") do |s|
        s.on_event("open", "opened") { |t| t.guard { |_e, _c| false } }
        s.on_event("open", "forced") { |t| t.guard { |_e, _c| false } }
        s.on_blocked("open") { |_e, _ctx, blocked| seen_blocked = blocked }
      end
      m.state("opened") { |s| }
      m.state("forced") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["door"], "open", ctx)
    plan.actions[0].callback.call("open", ctx)

    # Both candidates were blocked, so the handler receives both target ids in the
    # order they were registered (criterion 7).
    seen_blocked.should eq ["opened", "forced"]
  end

  # --- End-to-end through the synchronous interpreter (design section 10.3) ---

  it "fires on_blocked when the event is registered and every guard rejects (Service)" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("too steep without a rope") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    ctx.log.should eq ["too steep without a rope"]
    # A blocked step is a successful transaction that moved nowhere (design section 3.3).
    service.current_state.id.should eq "cave"
  end

  it "does not fire on_blocked for an unknown event (Service)" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("xyzzy")

    # No transition is registered for "xyzzy" at all, so on_blocked must stay silent
    # (design section 9). on_unknown_event is a separate handler (fsmcr-bfn.5).
    ctx.log.should be_empty
    service.current_state.id.should eq "cave"
  end

  it "does not fire on_blocked when a transition succeeds (Service)" do
    ctx : TurnContext = TurnContext.new(rope_secured: true)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    ctx.log.should be_empty
    service.current_state.id.should eq "clearing"
  end

  it "does not fire on_blocked on fallthrough where an earlier guard fails but a later one passes (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        # First candidate rejects, second candidate passes: the event is not blocked
        # because some transition succeeded (design section 9).
        s.on_event("north", "clearing") { |t| t.guard { |_e, _c| false } }
        s.on_event("north", "tunnel") { |t| t.guard { |_e, _c| true } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked") }
      end
      m.state("clearing") { |s| }
      m.state("tunnel") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    ctx.log.should be_empty
    service.current_state.id.should eq "tunnel"
  end

  it "passes the correct event name to the handler (Service)" do
    ctx : TurnContext = TurnContext.new
    seen_event : String? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("down", "shaft") { |t| t.guard { |_e, _c| false } }
        s.on_blocked("down") { |event, _ctx, _blocked| seen_event = event }
      end
      m.state("shaft") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("down")

    seen_event.should eq "down"
  end

  it "hands the handler the blocked target ids so it produces a reason without re-running the guard (Service)" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)
    # Counts every evaluation of the guard predicate. If the on_blocked path re-ran the
    # guard to work out why the event was blocked, this would climb past one. The
    # handler instead reads the blocked target ids and never touches the predicate.
    # This is the tge-teg double-evaluation regression (design section 9).
    guard_evaluations : Int32 = 0
    reason : String? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") do |t|
          t.guard do |_e, _c|
            guard_evaluations += 1
            false
          end
        end
        s.on_blocked("north") do |_event, _ctx, blocked|
          # A specific reason derived only from what was blocked, never from re-running
          # the guard predicate.
          reason = blocked.includes?("clearing") ? "too steep without a rope" : "you can't"
        end
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    # The guard ran once during planning and was not evaluated again by the on_blocked
    # path.
    guard_evaluations.should eq 1
    reason.should eq "too steep without a rope"
  end

  it "keys handlers per event, firing the one that matches the blocked event (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, _c| false } }
        s.on_event("down", "shaft") { |t| t.guard { |_e, _c| false } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("too steep without a rope") }
        s.on_blocked("down") { |_e, c, _blocked| c.say("it's too dark") }
      end
      m.state("clearing") { |s| }
      m.state("shaft") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)

    service.send("north")
    ctx.log.should eq ["too steep without a rope"]

    service.send("down")
    ctx.log.should eq ["too steep without a rope", "it's too dark"]
  end

  it "passes every blocked target id when multiple transitions are blocked (Service)" do
    ctx : TurnContext = TurnContext.new
    seen_blocked : Array(String)? = nil

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") do |s|
        s.on_event("open", "opened") { |t| t.guard { |_e, _c| false } }
        s.on_event("open", "forced") { |t| t.guard { |_e, _c| false } }
        s.on_blocked("open") { |_e, _ctx, blocked| seen_blocked = blocked }
      end
      m.state("opened") { |s| }
      m.state("forced") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "door", ctx)
    service.send("open")

    seen_blocked.should eq ["opened", "forced"]
  end

  it "is a no-op for a known-but-blocked event with no handler on a state that has one for another event (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, _c| false } }
        s.on_event("down", "shaft") { |t| t.guard { |_e, _c| false } }
        # A handler for "north" only. "down" is a known event whose guards reject, but
        # it has no handler, so a blocked "down" step does nothing.
        s.on_blocked("north") { |_e, c, _blocked| c.say("blocked north") }
      end
      m.state("clearing") { |s| }
      m.state("shaft") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("down")

    ctx.log.should be_empty
    service.current_state.id.should eq "cave"
  end

  it "consults only the current state's handler, never another state's (Service)" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, _c| false } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("cave handler fired") }
      end
      m.state("clearing") do |s|
        # A blocked event here, but "clearing" registers no on_blocked. The handler on
        # "cave" must not fire while the interpreter is in "clearing".
        s.on_event("south", "cave") { |t| t.guard { |_e, _c| false } }
      end
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "clearing", ctx)
    service.send("south")

    ctx.log.should be_empty
    service.current_state.id.should eq "clearing"
  end
end

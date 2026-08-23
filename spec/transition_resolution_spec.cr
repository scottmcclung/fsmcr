require "./spec_helper"
require "./support/plan_probe"

# Transition resolution and the outcome union (design section 6, D3).
#
# One event may have several transitions on a single state, distinguished by
# guards. `@transitions` becomes Hash(String, Array(Transition(T))) and the builder
# appends a transition each time `on_event` is called for the same event. A step
# over a state produces exactly one of three outcomes, which form a union so a
# consumer can match exhaustively (design section 6):
#
#   TransitionFound(T) | TransitionsBlocked | EventNotRecognized
#
# There is deliberately no `TransitionResult` type: Crystal has no parameterized
# type aliases, so the union is written inline wherever it appears. TransitionsBlocked
# and EventNotRecognized carry no T and are NOT generic.
#
# These specs observe the outcome through the pure core (`plan`) rather than an
# interpreter, because TransitionsBlocked and EventNotRecognized are not visible
# through Service's public position contract (a rejected event simply does not move).
describe "transition resolution" do
  it "carries the selected transition on TransitionFound" do
    ctx : TurnContext = TurnContext.new(rope_secured: true)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
      end
      m.state("clearing") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", ctx)

    # The subject is annotated with the full union so the exhaustiveness below is
    # honest. Crystal narrows a variable to its assigned value's static type; the
    # `outcome` getter is declared as the full union, so the annotation restates
    # that and the `case ... in` cannot narrow it away (design section 6).
    outcome : FSM::TransitionFound(TurnContext) | FSM::TransitionsBlocked | FSM::EventNotRecognized = plan.outcome

    case outcome
    in FSM::TransitionFound
      # Inside this branch `outcome` narrows to TransitionFound(TurnContext), so the
      # `transition` getter (design section 6) is reachable.
      outcome.transition.event.should eq "north"
      outcome.transition.target.should eq "clearing"
    in FSM::TransitionsBlocked
      fail "expected TransitionFound, got TransitionsBlocked"
    in FSM::EventNotRecognized
      fail "expected TransitionFound, got EventNotRecognized"
    end
  end

  it "matches all three outcome variants exhaustively" do
    ctx : TurnContext = TurnContext.new(rope_secured: true)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
      end
      m.state("clearing") { |s| }
    end

    # A guard that passes -> TransitionFound; the same guard rejecting ->
    # TransitionsBlocked; an event with no registered transition -> EventNotRecognized.
    found : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", TurnContext.new(rope_secured: true))
    blocked : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "north", TurnContext.new(rope_secured: false))
    unknown : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["cave"], "xyzzy", ctx)

    cases : Array(Tuple(FSM::Plan(TurnContext), String)) = [
      {found, "found"},
      {blocked, "blocked"},
      {unknown, "unknown"},
    ]

    cases.each do |pair|
      # Full-union annotation again: this is the exhaustive `case ... in` the
      # acceptance criteria require, and it must be checked against the whole union.
      outcome : FSM::TransitionFound(TurnContext) | FSM::TransitionsBlocked | FSM::EventNotRecognized = pair[0].outcome

      label : String = case outcome
      in FSM::TransitionFound    then "found"
      in FSM::TransitionsBlocked then "blocked"
      in FSM::EventNotRecognized then "unknown"
      end

      label.should eq pair[1]
    end
  end

  it "evaluates transitions in registration order and the first passing guard wins" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") do |s|
        # Two transitions on one event, distinguished by guards (design section 6,
        # section 13.2). Registration order is evaluation order.
        s.on_event("open", "opened") { |t| t.guard { |_e, _c| true } }
        s.on_event("open", "forced") { |t| t.guard { |_e, _c| true } }
      end
      m.state("opened") { |s| }
      m.state("forced") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["door"], "open", ctx)
    outcome : FSM::TransitionFound(TurnContext) | FSM::TransitionsBlocked | FSM::EventNotRecognized = plan.outcome

    case outcome
    in FSM::TransitionFound
      # The first registered transition wins even though both guards pass.
      outcome.transition.target.should eq "opened"
    in FSM::TransitionsBlocked
      fail "expected the first transition to win, got TransitionsBlocked"
    in FSM::EventNotRecognized
      fail "expected the first transition to win, got EventNotRecognized"
    end
  end

  it "stops evaluating once a guard passes, leaving later guards unrun" do
    ctx : TurnContext = TurnContext.new
    # Side-channel: this flag flips only if the second guard is evaluated. Because
    # the first guard passes and evaluation stops (design section 6), it must stay
    # false.
    second_guard_ran : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") do |s|
        s.on_event("open", "opened") { |t| t.guard { |_e, _c| true } }
        s.on_event("open", "forced") { |t| t.guard { |_e, _c| second_guard_ran = true } }
      end
      m.state("opened") { |s| }
      m.state("forced") { |s| }
    end

    FSM::PlanProbe.plan(machine, machine.states["door"], "open", ctx)

    second_guard_ran.should be_false
  end

  it "treats a guardless transition as always passing" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") do |s|
        s.on_event("open", "rattled") # no guard: always passes (design section 6)
      end
      m.state("rattled") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["door"], "open", ctx)
    outcome : FSM::TransitionFound(TurnContext) | FSM::TransitionsBlocked | FSM::EventNotRecognized = plan.outcome

    case outcome
    in FSM::TransitionFound
      outcome.transition.target.should eq "rattled"
    in FSM::TransitionsBlocked
      fail "a guardless transition can never be blocked"
    in FSM::EventNotRecognized
      fail "expected the guardless transition to be recognized"
    end
  end

  it "lets a guardless transition permanently shadow a later guarded one for the same event" do
    # The sharp edge (design section 6, section 13.2, D11): a guardless transition
    # registered before a guarded one for the same event makes the later one
    # unreachable. Its guard never runs and its target is never selected. This is
    # documented rather than rejected; build-time detection is deferred.
    ctx : TurnContext = TurnContext.new
    shadowed_guard_ran : Bool = false

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") do |s|
        s.on_event("open", "rattled")                                                       # guardless, registered first
        s.on_event("open", "opened") { |t| t.guard { |_e, _c| shadowed_guard_ran = true } } # unreachable
      end
      m.state("rattled") { |s| }
      m.state("opened") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["door"], "open", ctx)
    outcome : FSM::TransitionFound(TurnContext) | FSM::TransitionsBlocked | FSM::EventNotRecognized = plan.outcome

    case outcome
    in FSM::TransitionFound
      outcome.transition.target.should eq "rattled"
    in FSM::TransitionsBlocked
      fail "the guardless transition should have won"
    in FSM::EventNotRecognized
      fail "the guardless transition should have won"
    end

    shadowed_guard_ran.should be_false
  end

  it "yields TransitionsBlocked when the event is registered but every guard rejects" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") do |s|
        s.on_event("open", "opened") { |t| t.guard { |_e, _c| false } }
        s.on_event("open", "forced") { |t| t.guard { |_e, _c| false } }
      end
      m.state("opened") { |s| }
      m.state("forced") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["door"], "open", ctx)
    outcome : FSM::TransitionFound(TurnContext) | FSM::TransitionsBlocked | FSM::EventNotRecognized = plan.outcome

    case outcome
    in FSM::TransitionFound
      fail "every guard rejected, so no transition should be found"
    in FSM::TransitionsBlocked
      # The event is known here but every candidate guard returned false, so the
      # plan carries no actions to run.
      plan.actions.should be_empty
    in FSM::EventNotRecognized
      fail "the event is registered, so it is not unrecognized"
    end
  end

  it "yields EventNotRecognized when no transition is registered for the event" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("door") { |s| s.on_event("open", "opened") }
      m.state("opened") { |s| }
    end

    plan : FSM::Plan(TurnContext) = FSM::PlanProbe.plan(machine, machine.states["door"], "kick", ctx)
    outcome : FSM::TransitionFound(TurnContext) | FSM::TransitionsBlocked | FSM::EventNotRecognized = plan.outcome

    case outcome
    in FSM::TransitionFound
      fail "no transition is registered for 'kick'"
    in FSM::TransitionsBlocked
      fail "no transition is registered for 'kick', so it is not merely blocked"
    in FSM::EventNotRecognized
      # No transition is registered for the event, so the plan carries no actions.
      plan.actions.should be_empty
    end
  end
end

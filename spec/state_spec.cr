require "./spec_helper"

# Transition(T) is a class (design section 5, D16). Its mutable surface is exactly
# `on` and `guard`; `event` and `target` are set at construction and never change.
# Because it is a class, the builder mutates one shared object rather than a copy,
# so a guard or callback registered on the yielded transition during build is the
# same registration the interpreter reads at runtime. These specs cover that
# behaviorally through the interpreter.
describe FSM::Transition do
  it "exposes the event and target it was constructed with" do
    captured : FSM::Transition(TurnContext)? = nil

    FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| captured = t }
      end
      m.state("clearing") { |s| }
    end

    if transition = captured
      transition.event.should eq "north"
      transition.target.should eq "clearing"
    else
      fail "expected the builder to yield the transition"
    end
  end

  it "carries a guard registered on the shared object into the interpreter, blocking when it rejects" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") do |t|
          t.guard { |_event, c| c.rope_secured }
        end
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    service.current_state.id.should eq "cave"
  end

  it "carries a guard registered on the shared object into the interpreter, passing when it accepts" do
    ctx : TurnContext = TurnContext.new(rope_secured: true)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") do |t|
          t.guard { |_event, c| c.rope_secured }
        end
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    service.send("north")

    service.current_state.id.should eq "clearing"
  end
end

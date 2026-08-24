require "./spec_helper"

# Sealing after build (design section 5, D13 and D16).
#
# After `Machine(T).build` returns, every StateDefinition(T) and every
# Transition(T) it owns is sealed and shared, so mutating them must raise
# SealedStateError. A sealed StateDefinition is reached through `Machine#states`
# (its values are the shared sealed objects, not copies). A sealed Transition is
# reached by capturing the object the builder yields, which is the same object the
# machine keeps because Transition(T) is a class (design section 5, D16).
describe "machine sealing" do
  it "raises when on_event is called on a sealed StateDefinition" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("go", "state1") }
    end

    sealed : FSM::StateDefinition(FSM::Context) = machine.states["state1"]

    expect_raises(FSM::SealedStateError) do
      sealed.on_event("go", "state1")
    end
  end

  it "raises when the block form of on_event is called on a sealed StateDefinition" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("go", "state1") }
    end

    sealed : FSM::StateDefinition(FSM::Context) = machine.states["state1"]

    expect_raises(FSM::SealedStateError) do
      sealed.on_event("go", "state1") { |t| }
    end
  end

  it "raises when on_entry is called on a sealed StateDefinition" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| }
    end

    sealed : FSM::StateDefinition(FSM::Context) = machine.states["state1"]

    expect_raises(FSM::SealedStateError) do
      sealed.on_entry { |_event, _context| }
    end
  end

  it "raises when on_exit is called on a sealed StateDefinition" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| }
    end

    sealed : FSM::StateDefinition(FSM::Context) = machine.states["state1"]

    expect_raises(FSM::SealedStateError) do
      sealed.on_exit { |_event, _context| }
    end
  end

  it "raises when on_blocked is called on a sealed StateDefinition" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("go", "state1") { |t| t.guard { |_event, _context| false } } }
    end

    sealed : FSM::StateDefinition(FSM::Context) = machine.states["state1"]

    expect_raises(FSM::SealedStateError) do
      sealed.on_blocked("go") { |_event, _context, _blocked| }
    end
  end

  it "raises when on_unknown_event is called on a sealed StateDefinition" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") { |s| s.on_event("go", "state1") }
    end

    sealed : FSM::StateDefinition(FSM::Context) = machine.states["state1"]

    expect_raises(FSM::SealedStateError) do
      sealed.on_unknown_event { |_event, _context| }
    end
  end

  it "raises when Transition#on is called after the machine seals the transition" do
    captured : FSM::Transition(FSM::Context)? = nil

    FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("go", "state1") { |t| captured = t }
      end
    end

    if transition = captured
      expect_raises(FSM::SealedStateError) do
        transition.on { |_event, _context| }
      end
    else
      fail "expected the builder to yield the transition"
    end
  end

  it "raises when Transition#guard is called after the machine seals the transition" do
    captured : FSM::Transition(FSM::Context)? = nil

    FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("go", "state1") { |t| captured = t }
      end
    end

    if transition = captured
      expect_raises(FSM::SealedStateError) do
        transition.guard { |_event, _context| true }
      end
    else
      fail "expected the builder to yield the transition"
    end
  end

  # Decision C (fsmcr-bfn.3): the internal flag is definition state, so marking a
  # transition internal after seal must raise like `on` and `guard` do. Sealing
  # means what you built is what runs (design section 5, section 9.1).
  it "raises when Transition#internal is called after the machine seals the transition" do
    captured : FSM::Transition(FSM::Context)? = nil

    FSM::Machine(FSM::Context).build("test_machine") do |m|
      m.state("state1") do |s|
        s.on_event("go", "state1") { |t| captured = t }
      end
    end

    if transition = captured
      expect_raises(FSM::SealedStateError) do
        transition.internal
      end
    else
      fail "expected the builder to yield the transition"
    end
  end
end

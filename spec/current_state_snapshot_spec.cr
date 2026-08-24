require "./spec_helper"

# `current_state` returns the cached `State` snapshot, not a state id.
# One type describes the runtime value
# everywhere it is read: `interpret` builds the initial snapshot, every step replaces
# it, and `current_state` hands back whichever snapshot the last committed step
# produced. `current_state.id` gives the string when that is what is wanted, and
# `matches?(id)` still compares the id.
#
# The cached snapshot is the same immutable value `send` returns:
# after a step, `current_state` equals the snapshot the
# same `send` call handed back. On a failed step the snapshot carries the unchanged id,
# `Failed`, and the exception; after a later successful step it
# carries the new id and `Success` again, because every step replaces the cache.
describe "Service#current_state returns the cached State snapshot" do
  describe "the initial snapshot interpret produces" do
    it "reports the initial id, Success, and no error" do
      machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("world") do |m|
        m.state("idle") { |s| s.on_event("start", "running") }
        m.state("running") { |s| }
      end

      service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "idle", FSM::Context.new)

      # interpret builds State(id: "idle", status: Success, error: nil).
      # current_state returns that cached snapshot.
      snapshot : FSM::State = service.current_state
      snapshot.id.should eq "idle"
      snapshot.status.should eq FSM::Status::Success
      snapshot.error.should be_nil
    end
  end

  describe "the snapshot after a successful transition" do
    it "is the same value send returns: new id, Success, no error" do
      machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("world") do |m|
        m.state("idle") { |s| s.on_event("start", "running") }
        m.state("running") { |s| }
      end

      service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "idle", FSM::Context.new)
      result : FSM::State = service.send("start")

      # A committed transition replaces the cache with State(id: "running", Success, nil).
      # current_state returns exactly that snapshot, the
      # same value send handed back.
      result.id.should eq "running"
      result.status.should eq FSM::Status::Success
      result.error.should be_nil
      service.current_state.should eq result
    end
  end

  describe "the snapshot after a failed step" do
    it "carries the unchanged id, Failed, and the exception, and current_state returns it" do
      ctx : TurnContext = TurnContext.new
      boom : Exception = Exception.new("entry raised")

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") { |s| s.on_event("north", "clearing") }
        m.state("clearing") { |s| s.on_entry { |_e, _c| raise boom } }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
      result : FSM::State = service.send("north")

      # The entry callback raised, so the commit is never reached and the pointer stays
      # at "cave"; the snapshot records the unchanged id, Failed, and the exception.
      # current_state reflects that last committed step, which is the failed one, so its
      # status is Failed.
      result.status.should eq FSM::Status::Failed
      result.error.should eq boom
      result.id.should eq "cave"
      service.current_state.should eq result
    end
  end

  describe "the snapshot reflects the last committed step across a sequence" do
    it "returns Success again after a successful step follows a failed one" do
      ctx : TurnContext = TurnContext.new
      boom : Exception = Exception.new("entry raised")

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("cave") do |s|
          s.on_event("north", "clearing")
          s.on_event("east", "tunnel")
        end
        # Entering "clearing" raises, so "north" is a failed step that leaves the pointer
        # at "cave".
        m.state("clearing") { |s| s.on_entry { |_e, _c| raise boom } }
        m.state("tunnel") { |s| }
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)

      service.send("north")
      # The failed step is now the last committed step: Failed, unchanged id.
      service.current_state.status.should eq FSM::Status::Failed
      service.current_state.id.should eq "cave"

      service.send("east")
      # A later successful step replaces the cache entirely, so the Failed status and its
      # exception do not linger.
      after : FSM::State = service.current_state
      after.id.should eq "tunnel"
      after.status.should eq FSM::Status::Success
      after.error.should be_nil
    end
  end

  describe "matches? still compares the id" do
    it "answers against current_state.id, unchanged by the snapshot return" do
      machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("world") do |m|
        m.state("state1") { |s| s.on_event("event1", "state2") }
        m.state("state2") { |s| }
      end

      service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "state1", FSM::Context.new)

      service.matches?("state1").should be_true
      service.matches?("state2").should be_false
      # matches? is sugar for current_state.id == state_id.
      service.matches?(service.current_state.id).should be_true

      service.send("event1")

      service.matches?("state2").should be_true
      service.current_state.id.should eq "state2"
    end
  end

  describe "reentrant mid-step current_state returns the pre-commit snapshot as a State (owner-fiber fast path)" do
    # A callback of the same service calls current_state on the owner fiber, which already
    # holds @transition_mutex. The owner-fiber fast path returns the cached @state without
    # locking. A callback reading mid-step sees the OLD,
    # pre-commit snapshot: the commit runs after the callbacks. Returning the cached State
    # rather than a String id keeps the same id semantics.
    it "returns the old committed snapshot from an entry callback, id unchanged, Success" do
      ctx : TurnContext = TurnContext.new
      svc : FSM::Service(TurnContext)? = nil
      captured : FSM::State? = nil

      machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
        m.state("a") { |s| s.on_event("go", "b") }
        m.state("b") do |s|
          s.on_entry do |_e, _c|
            inner : FSM::Service(TurnContext)? = svc
            captured = inner.current_state if inner
          end
        end
      end

      service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "a", ctx)
      svc = service

      result : FSM::State = service.send("go")

      # The outer step committed rather than deadlocking on the checked mutex.
      result.id.should eq "b"
      result.status.should eq FSM::Status::Success
      service.current_state.id.should eq "b"

      # The mid-step read saw the pre-commit snapshot: the interpreter is still committed
      # to "a" during "b".on_entry, and that snapshot is Success from
      # the initial interpret. current_state returns it as a State rather than the bare id.
      snapshot : FSM::State? = captured
      snapshot.should be_a(FSM::State)
      if snapshot
        snapshot.id.should eq "a"
        snapshot.status.should eq FSM::Status::Success
        snapshot.error.should be_nil
      end
    end
  end
end

# The snapshot Service#send returns for each transition outcome (acceptance matrix).
# The status axis: Success means the transaction committed, Failed
# means a callback raised part-way. A guard-blocked event and an unknown event are both
# SUCCESSFUL transactions that moved nowhere: they committed, nothing raised, and the
# state simply did not change. The interpreter commits next_state on
# both, which is the unchanged current state. The failed step is covered above.
#
# Each case asserts both the snapshot send returns and that current_state caches the
# same value.
describe "Service#send return-value matrix by transition outcome" do
  it "successful transition to a different state: new id, Success, no error" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("world") do |m|
      m.state("cave") { |s| s.on_event("north", "clearing") }
      m.state("clearing") { |s| }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "cave", FSM::Context.new)
    result : FSM::State = service.send("north")

    # TransitionFound to a different state commits next_state = the target.
    result.id.should eq "clearing"
    result.status.should eq FSM::Status::Success
    result.error.should be_nil
    service.current_state.should eq result
  end

  it "external self-transition: same id, Success, no error" do
    machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("world") do |m|
      # External self-transition is the default; it re-runs exit and entry but commits
      # back to the same state (a self-transition is a
      # Success). next_state is "cave" itself.
      m.state("cave") { |s| s.on_event("look", "cave") }
    end

    service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "cave", FSM::Context.new)
    result : FSM::State = service.send("look")

    result.id.should eq "cave"
    result.status.should eq FSM::Status::Success
    result.error.should be_nil
    service.current_state.should eq result
  end

  it "blocked event: unchanged id, Success, no error" do
    ctx : TurnContext = TurnContext.new(rope_secured: false)

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing") { |t| t.guard { |_e, c| c.rope_secured } }
        s.on_blocked("north") { |_e, c, _blocked| c.say("too steep without a rope") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    result : FSM::State = service.send("north")

    # A guard-blocked event is a successful transaction that moved nowhere: it committed,
    # nothing raised, and the state did not change. next_state is the
    # unchanged current state (on_blocked_spec pins the same
    # "moved nowhere" behavior).
    result.id.should eq "cave"
    result.status.should eq FSM::Status::Success
    result.error.should be_nil
    service.current_state.should eq result
  end

  it "unknown event: unchanged id, Success, no error" do
    ctx : TurnContext = TurnContext.new

    machine : FSM::Machine(TurnContext) = FSM::Machine(TurnContext).build("world") do |m|
      m.state("cave") do |s|
        s.on_event("north", "clearing")
        s.on_unknown_event { |_e, c| c.say("you can't go that way") }
      end
      m.state("clearing") { |s| }
    end

    service : FSM::Service(TurnContext) = FSM::Service(TurnContext).interpret(machine, "cave", ctx)
    result : FSM::State = service.send("xyzzy")

    # EventNotRecognized also commits next_state = the unchanged current state: nothing
    # raised, so the
    # transaction is a Success that moved nowhere. on_unknown_event
    # running does not change that outcome (on_unknown_event_spec pins the "moved
    # nowhere" behavior).
    result.id.should eq "cave"
    result.status.should eq FSM::Status::Success
    result.error.should be_nil
    service.current_state.should eq result
  end
end

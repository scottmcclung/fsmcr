# fsmcr

fsmcr is a finite state machine library for Crystal. You define a machine once, seal
it, and then interpret it. The definition is immutable and safe to share across any
number of interpreters and fibers.

The library separates **deciding** from **doing**. A pure core evaluates guards and
computes what should happen but runs nothing. An interpreter sits over that core and
carries it out. Two interpreters ship: `Service`, which is synchronous, and
`AsyncService`, which owns a fiber and a mailbox. Both call the same core.

## Features

- **Immutable, sealed definitions.** A machine is built once and validated at build
  time. After sealing it cannot be mutated, so one definition is safe to share across
  interpreters and fibers.
- **Typed context.** Every machine is generic over a context type `T`. Guards and
  callbacks receive your real domain object, not values unwrapped from a hash.
- **Guards and multiple transitions per event.** One event can have several candidate
  transitions on a state, resolved in registration order by the first passing guard.
- **State and transition callbacks.** `on_entry`, `on_exit`, a per-transition callback,
  and the per-transition guard.
- **Blocked and unknown-event handlers.** `on_blocked` fires when every guard for an
  event rejects; `on_unknown_event` fires when the state has no transition for the
  event at all.
- **Interpreter observers.** `on_transition` fires only on a real change;
  `on_event_processed` fires after every step.
- **Snapshot return values.** `send` returns a `State` snapshot with an id, a status,
  and any error. A failing callback or guard surfaces as a `Failed` snapshot rather than
  a raise. One narrow exception exists: an observer's own exception. See the observers
  section.
- **Two interpreters.** A synchronous `Service` that serializes by lock and an
  `AsyncService` that serializes by fiber ownership.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  fsm:
    github: scottmcclung/fsmcr
```

Then require it:

```crystal
require "fsm"
```

This requires Crystal >= 1.21.0, the first release with `Fiber::ExecutionContext` on by
default, which `AsyncService` depends on. `shard.yml` enforces it.

## Quick start

```crystal
require "fsm"

machine = FSM::Machine(FSM::Context).build("worker") do |m|
  m.state("idle")    { |s| s.on_event("start", "running") }
  m.state("running") { |s| s.on_event("stop", "idle") }
end

service = FSM::Service(FSM::Context).interpret(machine, "idle", FSM::Context.new)

state = service.send("start")

puts state.id                    # => running
puts state.status                # => Success
puts service.current_state.id    # => running
puts service.matches?("running") # => true
```

`build` defines and seals the machine. `interpret` produces a running interpreter from
an initial state. `send` applies an event and returns the resulting `State` snapshot.
`current_state` returns the last snapshot the interpreter produced, and `matches?` is
sugar for comparing its id.

## The context type `T`

A machine is `FSM::Machine(T)`, generic over a context type you choose. `T` is passed
to every guard and callback directly, so a guard reads `ctx.rope_secured` on a real
typed object rather than pulling a primitive out of a hash.

```crystal
require "fsm"

class Player
  property has_key : Bool
  getter log : Array(String)

  def initialize(@has_key : Bool)
    @log = [] of String
  end

  def say(message : String) : Nil
    @log << message
  end
end

machine = FSM::Machine(Player).build("door") do |m|
  m.state("locked") do |s|
    s.on_event("open", "opened") { |t| t.guard { |_event, ctx| ctx.has_key } }
    s.on_blocked("open") { |_event, ctx, _blocked| ctx.say("It's locked.") }
  end
  m.state("opened") { |s| }
end

player = Player.new(has_key: true)
service = FSM::Service(Player).interpret(machine, "locked", player)
service.send("open") # => opened, because the guard passed
```

### `FSM::Context`, the bucket the library ships

If you have no domain object of your own, use `FSM::Context` as `T`. It is a
hash-behind-a-mutex with `get`, `set`, and `modify`.

```crystal
require "fsm"

ctx = FSM::Context.new
ctx.set("count", 0)
ctx.get("count") # => 0

# modify reads, transforms, and writes back under one lock, so a read-modify-write
# does not race the way set(get + 1) would.
ctx.modify("count") do |value|
  current = value.is_a?(Int32) ? value : 0
  current + 1
end

ctx.get("count") # => 1
```

Values come back as `FSM::Any`, a union that includes `Nil` and `Bool`, so narrow with
`is_a?` before doing arithmetic. `get` on a missing key raises `KeyError`.

### `T = Nil` is unsupported

There is no contextless machine. `FSM::Machine(Nil).build` is rejected at compile time
with a message pointing you at `FSM::Context`. A caller with no context of its own uses
`FSM::Context` as `T`, as in the quick start.

## States, transitions, and callbacks

Inside the build block, `m.state` registers a state and yields its definition. On the
definition you register transitions and callbacks.

```crystal
require "fsm"

class Room
  getter log : Array(String)

  def initialize
    @log = [] of String
  end

  def say(message : String) : Nil
    @log << message
  end
end

machine = FSM::Machine(Room).build("world") do |m|
  m.state("cave") do |s|
    s.on_entry { |_event, ctx| ctx.say("You enter the cave.") }
    s.on_exit  { |_event, ctx| ctx.say("You leave the cave.") }

    s.on_event("north", "clearing") do |t|
      t.on    { |_event, ctx| ctx.say("You walk north.") }
      t.guard { |_event, _ctx| true }
    end
  end

  m.state("clearing") { |s| }
end
```

- `on_entry` runs when the state is entered.
- `on_exit` runs when the state is exited.
- `t.on` registers the transition callback.
- `t.guard` registers the predicate that must return true for the transition to be
  selected.

A callback receives `(event, context)`. A guard receives the same and returns `Bool`.

### Callback order

For a transition from one state to another, the interpreter runs the source state's
`on_exit`, then the transition callback, then the target state's `on_entry`. Only after
all of them succeed does the interpreter commit the new state.

## Guards and multiple transitions per event

A single event can have several transitions on one state, distinguished by guards.

```crystal
require "fsm"

class Hero
  property has_key : Bool
  property strength : Int32

  def initialize(@has_key : Bool, @strength : Int32)
  end
end

machine = FSM::Machine(Hero).build("door") do |m|
  m.state("locked") do |s|
    s.on_event("open", "opened") { |t| t.guard { |_event, ctx| ctx.has_key } }
    s.on_event("open", "forced") { |t| t.guard { |_event, ctx| ctx.strength > 15 } }
  end
  m.state("opened") { |s| }
  m.state("forced") { |s| }
end

hero = Hero.new(has_key: false, strength: 20)
service = FSM::Service(Hero).interpret(machine, "locked", hero)
service.send("open") # => forced, because the first guard rejected and the second passed
```

Resolution rules:

- Candidates are evaluated in **registration order**.
- The **first transition whose guard passes wins**, and evaluation stops there.
- A transition **without a guard always passes**.

The last rule is a sharp edge. A guardless transition registered before others for the
same event makes them unreachable, and it can never be blocked. A guardless fallback
and an `on_blocked` handler for the same event are therefore mutually exclusive.

## Self-transitions

A self-transition is **external** by default: it re-runs `on_exit`, the transition
callback, and `on_entry`, exactly like a move to any other state. Mark a transition
`internal` to suppress exit and entry and run only the transition callback.

```crystal
require "fsm"

class Room
  getter log : Array(String)

  def initialize
    @log = [] of String
  end

  def say(message : String) : Nil
    @log << message
  end
end

machine = FSM::Machine(Room).build("world") do |m|
  m.state("cave") do |s|
    s.on_entry { |_event, ctx| ctx.say("You are in a cave.") }

    # External (default): re-runs on_exit and on_entry.
    s.on_event("wait", "cave")

    # Internal (opt-in): only the transition callback runs.
    s.on_event("look", "cave") do |t|
      t.internal.on { |_event, ctx| ctx.say("Dark. Damp. Something drips.") }
    end
  end
end
```

## The `State` snapshot

`send` returns a `State`, an immutable value describing the outcome of the step. It
carries three read-only fields:

- `id : String` — the state the interpreter is in.
- `status : FSM::Status` — `Success` or `Failed`.
- `error : Exception?` — the exception on a failed step, otherwise `nil`.

`Status` has two values. `Success` means the transaction committed. That includes a
guard-blocked event, which committed and simply moved nowhere. `Failed` means a
callback or guard raised part-way through, so the transaction did not commit.

The interpreter caches the last snapshot. `current_state` returns it rather than
recomputing, and every `send` replaces it.

Comparing `id` before and after a `send` cannot distinguish an internal self-transition
from a guard-blocked event: both leave the id unchanged. Callbacks and observers are
where that distinction is visible.

### A failing callback or guard returns a value

If a callback or guard raises during `send`, the interpreter catches it. The machine
stays in the state it was already in, and `send` returns a `Failed` snapshot carrying
the unchanged id and the exception. A callback or guard failure surfaces this way rather
than as a raise. An observer's own exception is the one path where `send` still raises;
see the observers section.

```crystal
require "fsm"

class Ctx
end

machine = FSM::Machine(Ctx).build("m") do |m|
  m.state("a") do |s|
    s.on_event("go", "b") { |t| t.on { |_event, _ctx| raise "boom" } }
  end
  m.state("b") { |s| }
end

service = FSM::Service(Ctx).interpret(machine, "a", Ctx.new)
state = service.send("go")

state.status.failed? # => true
state.id             # => "a", unchanged
state.error          # => the raised exception
```

Because a callback or guard bug becomes a value rather than a raise, a caller that
ignores a returned `Failed` snapshot swallows the failure. Check `status` when it matters.

## `on_blocked` and `on_unknown_event`

Two state-level handlers cover the events that do not transition:

- `on_blocked(event)` fires when the event has at least one registered transition and
  every candidate guard rejected. It is keyed per event. The handler receives the event,
  the context, and an `Array(String)` of the blocked target ids, so it can give a
  specific reason without re-running any guard.
- `on_unknown_event` fires when the state has no transition registered for the event at
  all. It is state-wide: one handler catches every unregistered event.

```crystal
require "fsm"

machine = FSM::Machine(FSM::Context).build("cave") do |m|
  m.state("cave") do |s|
    s.on_event("north", "clearing") { |t| t.guard { |_event, ctx| ctx.get("rope") == true } }

    s.on_blocked("north") do |_event, ctx, blocked|
      ctx.set("message", blocked.includes?("clearing") ? "Too steep without a rope." : "You can't.")
    end

    s.on_unknown_event { |event, ctx| ctx.set("message", "You can't #{event} here.") }
  end
  m.state("clearing") { |s| }
end

ctx = FSM::Context.new
ctx.set("rope", false)
service = FSM::Service(FSM::Context).interpret(machine, "cave", ctx)

service.send("north") # guard rejects -> on_blocked fires
service.send("fly")   # no such transition -> on_unknown_event fires
```

A step produces one of three outcomes: the transition happened, the event was blocked by
a guard, or the event means nothing in this state.

## Observers: `on_transition` and `on_event_processed`

Observers are registered on the interpreter, not on a state, through an optional block
that `interpret` yields. The block receives a registrar; register handlers on it. The
handlers are copied into the interpreter and the registrar is sealed before `interpret`
returns, so a live interpreter has no observer setter.

```crystal
require "fsm"

machine = FSM::Machine(FSM::Context).build("m") do |m|
  m.state("idle")    { |s| s.on_event("start", "running") }
  m.state("running") { |s| s.on_event("stop", "idle") }
end

service = FSM::Service(FSM::Context).interpret(machine, "idle", FSM::Context.new) do |observers|
  observers.on_transition      { |snapshot| puts "moved to #{snapshot.id}" }
  observers.on_event_processed { |snapshot| puts "processed, now #{snapshot.id}" }
end

service.send("start")
```

The pairing is "on change" versus "after every step":

- `on_transition` fires only when a transition actually occurred.
- `on_event_processed` fires after every step, including blocked, unknown, and failed
  steps, and receives the snapshot the step produced.

On a failed step `on_transition` does not fire, because nothing changed, while
`on_event_processed` fires and receives the `Failed` snapshot.

An observer's own exception is the one path where `Service#send` raises. When an observer
raises, the step has already committed, and `send` re-raises the first observer exception
to the caller rather than converting it to a `Failed` snapshot. This is the exception to
"a callback or guard failure surfaces as a value." An observer raising under `AsyncService`
behaves differently: the async service records the exception and moves to `errored?`
without raising, because a `post` has no reply channel to raise across, and a `send`
already received the committed snapshot before the poisoning is recorded.

## Reentrant `send` from a callback

A callback may call `send` on its own service. It does not recurse. The event is queued
and applied after the current step commits, and the queue drains before the outer `send`
returns. This makes cascading events an ordinary property of the interpreter rather than
a concurrency hazard. The inner `send` returns the interpreter's current committed
snapshot, since the queued event has not been applied yet.

## `AsyncService`: the fiber-and-mailbox interpreter

`AsyncService` owns a fiber and a mailbox. Exactly one fiber ever runs the machine's
code; other fibers reach it by putting a message in the mailbox. It exposes `post`,
`send`, and `stop`.

```crystal
require "fsm"

class Ctx
end

machine = FSM::Machine(Ctx).build("m") do |m|
  m.state("idle")    { |s| s.on_event("start", "running") }
  m.state("running") { |s| s.on_event("stop", "idle") }
end

service = FSM::AsyncService(Ctx).start(machine, initial: "idle", context: Ctx.new)

service.post("start")        # fire and forget; returns immediately
state = service.send("stop") # blocks THIS fiber, not a thread; awaits the reply
state.id                     # => "idle"

service.stop
```

`post` is fire-and-forget and returns immediately. `send` blocks the calling fiber and
reads the reply snapshot off a channel, so it reads as synchronous while other fibers
keep running. `stop` drains what is already queued and then stops.

Once the async service has stopped or errored, the two entry points diverge. A `send`
returns immediately with a `Failed` snapshot carrying `FSM::StoppedError`, or the recorded
poisoning exception if it errored, rather than enqueuing and waiting on a fiber that is no
longer draining. A `post` in the same situation is dropped silently, because it has no
return value to carry a refusal.

### The rule: `post` from inside, `send` from outside

A `send` from inside a callback of the same instance **deadlocks**, because it would be
waiting on itself. From inside a callback, use `post` instead: it queues onto the same
mailbox and drains after the current step commits.

```crystal
require "fsm"

class TrapCtx
  property service : FSM::AsyncService(TrapCtx)? = nil
end

machine = FSM::Machine(TrapCtx).build("m") do |m|
  m.state("armed") do |s|
    s.on_entry do |_event, ctx|
      svc = ctx.service
      svc.post("trigger") if svc # queues; drains after this step commits
      # svc.send("trigger")      # DEADLOCK: it would wait on itself
    end
    s.on_event("trigger", "sprung")
  end
  m.state("sprung") { |s| }
end
```

`AsyncService` does not expose its context. Reads go through `send`, which runs on the
owning fiber. It does expose its own lifecycle through `running?`, `stopped?`, and
`errored?`. That lifecycle is separate from `State#status`: one describes the health of
the interpreter, the other describes the outcome of a single transaction.

## Sealing and errors

At the end of the build block the builder validates the machine and seals it. After
sealing, every state and transition is read-only; a builder method called through a
retained reference raises `FSM::SealedStateError`.

Build and interpret raise for the following:

- `FSM::DuplicateStateError` — two states registered with the same id.
- `FSM::MissingTargetStateError` — a transition names a target state that does not exist.
- `FSM::InvalidInitialStateError` — `interpret` is given an initial id that is not a
  state in the machine.

```crystal
require "fsm"

# MissingTargetStateError: a transition names a state that does not exist.
begin
  FSM::Machine(FSM::Context).build("m") do |m|
    m.state("idle") { |s| s.on_event("start", "running") } # no "running" state
  end
rescue ex : FSM::MissingTargetStateError
  puts ex.message
end

# DuplicateStateError: two states share an id.
begin
  FSM::Machine(FSM::Context).build("m") do |m|
    m.state("idle") { |s| }
    m.state("idle") { |s| }
  end
rescue ex : FSM::DuplicateStateError
  puts ex.message
end

# InvalidInitialStateError: the initial id is not a state in the machine.
machine = FSM::Machine(FSM::Context).build("m") do |m|
  m.state("idle") { |s| }
end

begin
  FSM::Service(FSM::Context).interpret(machine, "missing", FSM::Context.new)
rescue ex : FSM::InvalidInitialStateError
  puts ex.message
end
```

Because targets are validated at build time and sealing prevents later mutation, a
missing target can never surface at runtime.

## Contributing

Contributions are welcome. Open an issue or submit a pull request.

1. Fork it (<https://github.com/scottmcclung/fsmcr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Scott McClung](https://github.com/scottmcclung) - creator and maintainer

## License

This project is licensed under the [MIT License](LICENSE).

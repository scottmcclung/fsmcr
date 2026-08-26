require "spec"
require "../src/fsmcr"

# Enable real parallelism for the whole spec suite. Crystal's default execution
# context is Fiber::ExecutionContext::Parallel
# but ships capped at one worker, so without this resize no two fibers ever run
# simultaneously, the scheduler only switches at explicit suspend points, and
# Service#@transition_mutex is never actually contended. The concurrency
# contract covers interpreter state with the mutex and the shared machine with sealing.
# That contract is only exercised when more than one worker runs fibers at the same
# time, which is what the resize provides.
#
# Resizing the DEFAULT context, rather than spawning the concurrency specs into a
# separate explicit Fiber::ExecutionContext::Parallel, is what the acceptance
# criterion names: the suite must run green with the default context resized to more
# than one worker. It also puts every existing spawn-based spec under genuine
# parallelism rather than only the ones that opt in. `default_workers_count` is the
# CPU-derived worker count; `Math.max(2, ...)` guarantees the "more than one worker"
# criterion even where that count reports 1. CRYSTAL_WORKERS alone does nothing here.
# -Dpreview_mt alone selects the legacy scheduler, under which Fiber::ExecutionContext
# is never required and referencing it fails as an undefined constant. The two flags
# together, -Dpreview_mt -Dexecution_context, remain supported and
# keep execution contexts, but still leave the default context at one worker.
# So none of these substitutes for the resize call below.
Fiber::ExecutionContext.default.resize(Math.max(2, Fiber::ExecutionContext.default_workers_count))

# A spec-defined domain context used as the generic parameter `T`. The core types
# are generic over `T`, and guards and callbacks
# receive this object directly rather than unwrapping values from the FSM::Context
# hash. `rope_secured` is the sort of already-loaded domain state a guard reads;
# `say` records callback effects so a spec can observe that `T` reached a callback.
class TurnContext
  property rope_secured : Bool
  getter log : Array(String)

  def initialize(@rope_secured : Bool = false)
    @log = [] of String
  end

  def say(message : String) : Nil
    @log << message
  end
end

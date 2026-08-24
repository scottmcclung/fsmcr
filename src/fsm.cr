# ObserverFiring is included by both interpreters, so it must be defined before the
# glob reaches them: Crystal resolves `include` in require order (async_service.cr
# sorts ahead of observer_firing.cr). require is idempotent, so the glob re-require
# below is a no-op.
require "./fsm/observer_firing"
require "./fsm/*"

# fsmcr is a general-purpose finite state machine library (design section 1). A
# machine is defined once by a machine-scoped builder, sealed, then interpreted. The
# sealed definition is immutable and safe to share across interpreters and fibers.
# Interpretation separates deciding from doing: a pure core computes an ordered list
# of effects and runs none of them, and an interpreter (Service or AsyncService) runs
# them (design section 1).
module FSM
  alias Any = Nil |
              Bool |
              Int32 |
              Int64 |
              Float32 |
              Float64 |
              String |
              Array(Any) |
              Hash(String, Any)
end

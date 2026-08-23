# ObserverFiring is included by both interpreters, so it must be defined before the
# glob reaches them: Crystal resolves `include` in require order (async_service.cr
# sorts ahead of observer_firing.cr). require is idempotent, so the glob re-require
# below is a no-op.
require "./fsm/observer_firing"
require "./fsm/*"

# The Finite State Machine (FSM) module provides a framework for modeling and implementing finite state machines.
#
# It includes classes for creating and managing state machines, states, transitions, and associated context.
# States define the different conditions or modes that a system can be in, transitions define how the system moves
# from one state to another in response to events, and a context is used to carry information across state transitions.
# See examples directory for an example of how to leverage the FSM in your app
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

require "../spec_helper"

# Test-only bridge to the pure core.
#
# `plan` is protected and Plan, Action, ActionKind, and the three outcome structs
# are not part of the public API. The acceptance criteria still require a spec
# to exercise the pure core WITHOUT constructing an interpreter. A Crystal protected
# method is callable from a type that shares the method's namespace, so this helper
# reopens `module FSM` and calls `Machine#plan` from `FSM::PlanProbe`, whose `self`
# lives in the FSM namespace alongside Machine. This reaches the core without
# weakening any visibility in src; the surface must not be widened for the
# specs' convenience.
module FSM
  module PlanProbe
    # Call the protected pure core. `self` here is FSM::PlanProbe; it shares the FSM
    # namespace with Machine, which is what makes the protected call legal.
    def self.plan(machine : Machine(T), state : StateDefinition(T), event : String, context : T) : Plan(T) forall T
      machine.plan(state, event, context)
    end
  end
end

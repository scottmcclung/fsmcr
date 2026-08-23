require "spec"
require "../src/fsm"

# A spec-defined domain context used as the generic parameter `T`. Per design
# section 3 and D1 the core types are generic over `T`, and guards and callbacks
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

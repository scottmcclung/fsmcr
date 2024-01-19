require "../src/fsm"

enum Stage
  Start
  Middle
  End
end

class StateMachine
  @machine : FSM::Machine(Stage)
  getter current_state : Stage

  def initialize
    # Set the initial state
    @current_state = Stage::Start

    # Create an instance of the FSM::Machine
    @machine = FSM::Machine(Stage).new

    # Register events that each state will respond to and the transitions
    # they will make in response to each event
    @machine.add_transitions(Stage::Start, [
      FSM::Transition.new(event: "Trigger", to: Stage::Middle),
      FSM::Transition.new(event: "Reset", to: Stage::Start),
    ])

    @machine.add_transitions(Stage::Middle, [
      FSM::Transition.new(event: "Complete", to: Stage::End),
      FSM::Transition.new(event: "Reset", to: Stage::Start),
    ])
  end

  def matches?(stage : Stage)
    @current_state === stage
  end

  def send(event : String)
    @current_state = @machine.transition(@current_state, event)
  end
end

# Trigger events
state_machine = StateMachine.new

p! state_machine.current_state           # => Stage::Start
p! state_machine.send("Trigger")         # => Stage::Middle   # Transitions to Middle
p! state_machine.send("InvalidEvent")    # => Stage::Middle   # The "InvalidEvent" message wasn't registered for the Middle state so no transition
p! state_machine.matches?(Stage::Start)  # => false
p! state_machine.matches?(Stage::Middle) # => true
p! state_machine.send("Reset")           # => Stage::Start    # Transitions to Start
p! state_machine.send("InvalidEvent")    # => Stage::Start    # The "InvalidEvent" message wasn't registered for the Start state so no transition

require "../src/fsm"

id = "something from here"
current = "some state"

states = [
  FSM::State.create("red")
    .on_event("change", target: "green") do |transition|
      transition.on { |e, c| p "Transition: Red -> Green" }
      transition.guard { |event, context| true }
    end
    .on_event("error", target: "error")
    .on_entry { |e, c| p "Entry: red" }
    .on_exit { |e, c| p "Exit: red" },

  FSM::State.create("yellow")
    .on_event("change", target: "red") do |transition|
      transition.on { |event, context| p "Transition: Yellow -> Red" }
      transition.guard { |event, context| true }
    end
    .on_event("error", target: "error")
    .on_entry { |e, c| p "Entry: yellow" }
    .on_exit { |e, c| p "Exit: yellow" },

  FSM::State.create("green")
    .on_event("change", target: "yellow") do |transition|
      transition.on { |event, context| p "Transition: Green -> Yellow" }
      transition.guard { |event, context| true }
    end
    .on_event("error", target: "error")
    .on_entry { |e, c| p "Entry: green" }
    .on_exit { |e, c| p "Exit: green" },
]

state = FSM::State.create("error")
  .on_event("reset", target: "red") do |transition|
    transition.on { |event, context| p "Transition: Error -> Red" }
    transition.guard { |event, context| true }
  end
  .on_entry { |e, c| p "Entry: error mode" }
  .on_exit { |e, c| p "Exit: error mode" }

states.push(state)

machine = FSM::Machine.create(id: "stop_light", states: states)

# machine = FSM::Machine.create()
service = FSM::Service.interpret(machine, initial_state: "red") # machine is struct

# Can register new transition callbacks with the service, but the machine and the states are immutable.
service.on_transition { |state| p "State changed to: #{state.id}" }
service.send("event name")
service.matches?("red") # => true
service.current_state   # => "red"

p service.current_state

p service.send("change")
# p! service.send("change")
p service.send("error")
p service.send("change") # invalid
# p! service.send("reset")
# p! service.send("change")
# p! service.send("change")
# p! service.send("error")
# p! service.send("change")
# p! service.send("reset")

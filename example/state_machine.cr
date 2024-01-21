require "../src/fsm"

id = "something from here"
current = "some state"

states = [
  FSM::State.create("red") do |state|
    state.on_event("change", target: "green") { |e, c| p "Transition: Red -> Green" }
    state.on_event("error", target: "error")
    state.on_entry { |e, c| p "Entry: red" }
    state.on_exit { |e, c| p "Exit: red" }
  end,
  FSM::State.create("yellow") do |state|
    state.on_event("change", target: "red") { |event, context| p "Transition: Yellow -> Red" }
    state.on_event("error", target: "error")
    state.on_entry { |e, c| p "Entry: yellow" }
    state.on_exit { |e, c| p "Exit: yellow" }
  end,
  FSM::State.create("green") do |state|
    state.on_event("change", target: "yellow") { |event, context| p "Transition: Green -> Yello" }
    state.on_event("error", target: "error")
    state.on_entry { |e, c| p "Entry: green" }
    state.on_exit { |e, c| p "Exit: green" }
  end,
  FSM::State.create("error") do |state|
    state.on_event("reset", target: "red") { |event, context| p "Transition: Error -> Red" }
    state.on_entry { |e, c| p "Entry: error mode" }
    state.on_exit { |e, c| p "Exit: error mode" }
  end,
]

machine = FSM::Machine.create(id: "stop_light", states: states, initial: "red") do |m|
  m.on_state_change do |state|
    current = state.id
    p "State changed to: #{current}"
  end
end

p! machine.current_state

p! machine.send("change")
# p! machine.send("change")
p! machine.send("error")
p! machine.send("change") # invalid
# p! machine.send("reset")
# p! machine.send("change")
# p! machine.send("change")
# p! machine.send("error")
# p! machine.send("change")
# p! machine.send("reset")

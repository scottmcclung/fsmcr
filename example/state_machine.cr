require "../src/fsm"

# A stop-light machine, built once and then interpreted (design section 4,
# section 8.1). T is FSM::Context, the hash-and-mutex bucket the library ships
# for a caller with no domain object of its own (design section 3.1, D5).
machine : FSM::Machine(FSM::Context) = FSM::Machine(FSM::Context).build("stop_light") do |m|
  m.state("red") do |s|
    s.on_entry { |_event, _ctx| puts "Entry: red" }
    s.on_exit { |_event, _ctx| puts "Exit: red" }
    s.on_event("change", "green") do |t|
      t.on { |_event, _ctx| puts "Transition: red -> green" }
    end
  end

  m.state("green") do |s|
    s.on_entry { |_event, _ctx| puts "Entry: green" }
    s.on_exit { |_event, _ctx| puts "Exit: green" }
    s.on_event("change", "yellow") do |t|
      t.on { |_event, _ctx| puts "Transition: green -> yellow" }
    end
  end

  m.state("yellow") do |s|
    s.on_entry { |_event, _ctx| puts "Entry: yellow" }
    s.on_exit { |_event, _ctx| puts "Exit: yellow" }
    s.on_event("change", "red") do |t|
      t.on { |_event, _ctx| puts "Transition: yellow -> red" }
    end
  end
end

# Interpret the sealed machine from an initial state (design section 8.1,
# section 10.2). The machine is immutable and shareable; the service holds this
# run's current state and context.
context : FSM::Context = FSM::Context.new
service : FSM::Service(FSM::Context) = FSM::Service(FSM::Context).interpret(machine, "red", context)

# An observer fired only when a transition actually occurred (design section 9).
service.on_transition { |state| puts "State changed to: #{state.id}" }

puts "matches?(\"red\"): #{service.matches?("red")}"
puts "current_state: #{service.current_state}"

# Each send blocks, applies the actions, and returns the resulting snapshot
# (design section 10.3).
puts "send(\"change\").id => #{service.send("change").id}" # red -> green
puts "send(\"change\").id => #{service.send("change").id}" # green -> yellow
puts "send(\"change\").id => #{service.send("change").id}" # yellow -> red

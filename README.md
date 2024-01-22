# Finite State Machine

This repository contains a Crystal module for creating and managing Finite State Machines (FSMs). It is designed to model complex stateful systems, allowing for easy definition and management of states, transitions, and context data.

## Features

- **State Management**: Define and manage various states in your system.
- **Transitions**: Easily configure transitions between states triggered by events.
- **Contextual Data**: Carry and manage contextual data across state transitions.
- **Callback Support**: Utilize entry and exit actions for states and custom actions for transitions.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     fsm:
       github: scottmcclung/fsmcr
   ```

2. Include the module in your project:

   ```crystal
   require "fsm"
   ```

## Usage

### Defining States and Transitions

Create states and define transitions between them. Each state can have entry and exit actions, and each transition can have associated actions.

```crystal
state1 = FSM::State.new("state1")
state2 = FSM::State.new("state2")
state3 = FSM::State.new("state3")

state1.on_event("event_to_state2", "state2") # Registers standard transition that responds to "event_to_state2" and transitions to state2

state2.on_event("event_to_state3", "state3") do |transition|
  transition.on {|event, context| # Transition callback. } # Registers a callback to be executed when the transition happens
  transition.guard {|event, context| # Condition to determine if the transition should be allowed. } 
end

state3.on_entry do |event, context|
  # Code here is executed when entering state3
end

state3.on_exit do |event, context|
  # Code here is executed when exiting state3
end
```

### Creating a State Machine

Instantiate the Machine with the defined states and transitions.

```crystal
states = [state1, state2, state3]
initial_state = "state1"
context_data = {"key1" => "value1", "key2" => "value2"}

machine = FSM::Machine.create("machine_id", states)
```

The interpreter is responsible for interpreting the machine and parsing and executing it.  Instatiate the Interpreter to interact with the Machine.

```crystal
service = FSM::Service.interpret(machine, initial_state, context_data)
```


### Triggering Transitions

Send events to the interpreter to trigger state transitions.

```crystal
new_state = service.send("event_to_state2")
```

### Callback Operations During State Transitions

In the FSM, callbacks during a state transition occur in the following order:

1. **Exit Callback**: Executed for the current state before the transition.
2. **Transition Callback**: Performed during the transition, after exiting the current state.
3. **Entry Callback**: Executed for the new state after the transition.

```crystal
# Define states with entry and exit actions
state1 = FSM::State.new("state1")
  .on_exit do |event, context|
    puts "Exiting state1"
  end

state2 = FSM::State.new("state2")
  .on_entry do |event, context|
    puts "Entering state2"
  end

# Define transition with an action
state1.on_event("event_to_state2", "state2") do |transition|
  transition.on { |event, context| puts "Transitioning from state1 to state2" }
end

# Create and use the state machine
machine = FSM::Machine.create("machine_id", [state1, state2])
service = FSM::Service.interpret(machine, "state1")
service.send("event_to_state2")
# Output:
# Exiting state1
# Transitioning from state1 to state2
# Entering state2
```


## Contributing

Contributions are welcome! If you find any issues or have suggestions for improvements, please open an issue or submit a pull request.

1. Fork it (<https://github.com/scottmcclung/fsmcr/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Scott McClung](https://github.com/scottmcclung) - creator and maintainer

## License

This project is licensed under the [MIT License](LICENSE).
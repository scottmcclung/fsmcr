# Finite State Machine

The FSM (Finite State Machine) module provides a super simple implementation of a state machine in Crystal.  Define the possible states using an enum to ensure only valid states are used.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     fsm:
       github: scottmcclung/fsmcr
   ```

2. Navigate to the project directory:

   ```bash
   cd fsmcr
   ```

## Usage

1. Include the `FSM` module and create an instance of the `Machine` class:

   ```crystal
   require "fsm"

   enum Stage
      Start
      Middle
      End
   end

   machine = FSM::Machine(Stage).new
   ```

2. Configure possible states and transitions using the `add_transitions` method:

   ```crystal
   machine.add_transitions(Stage::Start, [
     FSM::Transition.new(event: "Trigger", to: Stage::Middle),
     FSM::Transition.new(event: "Reset", to: Stage::Start)
   ])

   machine.add_transitions(Stage::Middle, [
     FSM::Transition.new(event: "Complete", to: Stage::End),
     FSM::Transition.new(event: "Reset", to: Stage::Start)
   ])
   ```

3. Perform state transitions based on events using the `transition` method:

   ```crystal
   current_state = Stage::Start

   current_state = machine.transition(current_state, "Trigger")  # => Stage::Middle
   current_state = machine.transition(current_state, "Other")    # => Stage::Middle  # Event not recognized by the "Middle" state so current_state stays "Middle"
   current_state = machine.transition(current_state, "Complete") # => Stage::End
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
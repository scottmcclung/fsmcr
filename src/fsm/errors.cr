module FSM
  class StateMachineError < Exception; end

  class InvalidInitialStateError < StateMachineError; end

  class MissingTargetStateError < StateMachineError; end
end

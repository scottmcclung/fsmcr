module FSM
  class StateMachineError < Exception; end

  class InvalidInitialStateError < StateMachineError; end

  class MissingTargetStateError < StateMachineError; end

  class SealedStateError < StateMachineError; end

  # The error an AsyncService#send carries in its Failed snapshot when the async
  # service is no longer running (design section 8.2, section 11, section 15). A send
  # on a stopped async service returns Failed rather than blocking on a fiber that has
  # stopped draining; since a clean stop records no exception of its own, the snapshot
  # needs a concrete error to satisfy the invariant that Failed carries one (design
  # section 3.3). A send on an errored async service carries the recorded poisoning
  # exception instead, so this error stands only for the stopped case.
  class StoppedError < StateMachineError; end
end

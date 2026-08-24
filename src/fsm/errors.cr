module FSM
  class StateMachineError < Exception; end

  class InvalidInitialStateError < StateMachineError; end

  class MissingTargetStateError < StateMachineError; end

  # Raised when a build registers two states sharing an id. No two states share an
  # id, so the second registration raises rather than silently overwriting the first
  # definition, which would discard its transitions and surface much later as an event
  # with no transition. The message names the duplicated id.
  class DuplicateStateError < StateMachineError; end

  class SealedStateError < StateMachineError; end

  # The error an AsyncService#send carries in its Failed snapshot when the async
  # service is no longer running. A send
  # on a stopped async service returns Failed rather than blocking on a fiber that has
  # stopped draining; since a clean stop records no exception of its own, the snapshot
  # needs a concrete error to satisfy the invariant that Failed carries one. A send on
  # an errored async service carries the recorded poisoning exception instead, so this
  # error stands only for the stopped case.
  class StoppedError < StateMachineError; end
end

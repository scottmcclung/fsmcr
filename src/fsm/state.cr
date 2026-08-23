module FSM
  # The runtime snapshot an interpreter returns (design section 3.3, D13, D17).
  #
  # State reports the outcome of one transaction, not the condition of an
  # interpreter. By the time a snapshot exists the step is over, so there is no
  # "running": `id` is the state the machine is in, `status` says whether the
  # transaction committed, and `error` holds the exception on a failed step.
  #
  # Construction must maintain the invariant that Failed carries an exception and
  # Success does not (design section 3.3). The types do not enforce it.
  #
  # State is the immutable value read constantly in consumer code, so it holds the
  # short name; the definition carries the longer StateDefinition (design section
  # 3.3). Nothing in a snapshot points back into the machine definition, so it is
  # safe to return, compare, and cache.
  struct State
    getter id : String
    getter status : Status
    getter error : Exception?

    def initialize(@id : String, @status : Status, @error : Exception? = nil)
    end
  end
end

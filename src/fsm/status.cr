module FSM
  # The outcome axis of a runtime snapshot.
  #
  # Status describes what happened to the transaction the caller initiated, not
  # the condition of an interpreter:
  # - Success: the transaction committed, or a guard blocked it and it moved
  #   nowhere. Either way nothing raised.
  # - Failed: a callback raised part-way through, so the transaction did not
  #   commit and the snapshot carries the exception.
  enum Status
    Success
    Failed
  end
end

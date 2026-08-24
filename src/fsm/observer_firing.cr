module FSM
  # The shared observer-firing step for both interpreters. Service(T) and
  # AsyncService(T) include this so the firing
  # order and the failed-step asymmetry live in one place; what each interpreter DOES
  # with the returned exception (Service re-raises it to the calling fiber, AsyncService
  # records it into its lifecycle) stays in the respective interpreter.
  #
  # State is not generic, so this module carries no type parameter and includes cleanly
  # into both generic classes.
  module ObserverFiring
    # Fire the step's observers and return the first exception one of them raised, or
    # nil. Each observer fires in its own
    # begin/rescue so an on_transition that raises never skips on_event_processed,
    # which fires after every step. The FIRST
    # exception is captured and returned so the interpreter can act on it; a later
    # observer's exception is discarded.
    #
    # The two branches are asymmetric on what happens when on_event_processed raises. On
    # a failed step the snapshot already carries the first exception,
    # so on_transition does not fire and on_event_processed's own exception is discarded
    # with a bare rescue and the method returns nil: the snapshot's recorded exception
    # stays authoritative and the returning path stays a value, not a raise. That
    # silence is deliberate. On a non-failed step
    # (status Success, covering a successful transition, a blocked event, and an unknown
    # event) there is no recorded exception, so an observer exception is captured and
    # returned for the interpreter to act on.
    private def fire_observers(snapshot : State, transitioned : Bool) : Exception?
      if snapshot.status.failed?
        handler : (State ->)? = @on_event_processed
        if handler
          begin
            handler.call(snapshot)
          rescue
            # The observer's own exception is discarded, not logged.
          end
        end
        nil
      else
        first_error : Exception? = nil

        # on_transition fires first, only when a transition actually completed.
        if transitioned
          transition_handler : (State ->)? = @on_transition
          if transition_handler
            begin
              transition_handler.call(snapshot)
            rescue ex
              first_error = ex
            end
          end
        end

        processed_handler : (State ->)? = @on_event_processed
        if processed_handler
          begin
            processed_handler.call(snapshot)
          rescue ex
            first_error = ex if first_error.nil?
          end
        end

        first_error
      end
    end
  end
end

module FSM
  # The hash-and-mutex bucket the library ships as one selectable T (design
  # section 3.2, D1). It is not the context mechanism; it is one context a caller
  # can choose when they have no typed domain object of their own, or when they
  # share one context across fibers and want per-operation atomicity without
  # writing their own locking (design section 3.2, section 12.5).
  #
  # Every method holds @mutex for the whole operation, which is what gives a
  # caller per-operation atomicity on a shared context (design section 12.5). A
  # compound read-modify-write is not two locked operations with an unlocked gap;
  # modify does the read, the block, and the write under one lock hold, so
  # `modify("n") { |v| v + 1 }` does not race the way `set("n", get("n") + 1)`
  # would (design section 12.5).
  class Context
    @mutex : Mutex = Mutex.new

    @data : Hash(String, Any) = {} of String => Any

    # Create a context, optionally seeded with initial data merged into the
    # empty store.
    def initialize(initial_data : Hash(String, Any) = {} of String => Any)
      @data.merge!(initial_data)
    end

    # Return the value stored for a key, raising KeyError when the key is absent
    # (design section 3.2). This forwards Hash#[] and keeps its raising contract on
    # purpose; get? is the non-raising accessor for a possibly-absent key. Holds
    # the mutex for the read (design section 12.5).
    def get(key : String) : Any
      @mutex.synchronize { @data[key] }
    end

    # Return the value stored for a key, or nil when the key is absent, forwarding
    # Hash#[]? rather than raising the way get does (design section 3.2). Holds the
    # mutex for the read (design section 12.5).
    #
    # FSM::Any includes Nil, so a key whose stored value is nil and a key that was
    # never set both come back nil. get? alone cannot tell the two apart; has_key?
    # is the disambiguator. The get?/has_key? pair is two separate lock
    # acquisitions: safe when no other fiber can touch the key between them, but on
    # a shared context another fiber can mutate the key in the gap, since there is
    # no atomic compound read and modify is the only atomic compound operation
    # (design section 12.5).
    def get?(key : String) : Any?
      @mutex.synchronize { @data[key]? }
    end

    # Store a value under a key and return the value stored, mirroring Hash#[]=
    # which evaluates to its right-hand side (design section 3.2). Holds the mutex
    # for the write (design section 12.5).
    def set(key : String, value : Any) : Any
      @mutex.synchronize { @data[key] = value }
    end

    # Return the stored value when the key is present and the supplied default
    # when it is absent (design section 3.2). It does not store the default: a
    # defaulted lookup leaves the key absent, so a later get still raises and
    # has_key? stays false. Holds the mutex for the read (design section 12.5).
    def fetch(key : String, default : Any) : Any
      @mutex.synchronize { @data.fetch(key, default) }
    end

    # Report whether a key is present, regardless of the stored value (design
    # section 3.2). Presence is about the key, not the value, so a key whose value
    # is nil is present. This is what lets get? and a stored nil be told apart.
    # Holds the mutex for the read (design section 12.5).
    def has_key?(key : String) : Bool
      @mutex.synchronize { @data.has_key?(key) }
    end

    # Remove a key and return the value that was removed, or nil when the key was
    # absent, following Crystal's Hash#delete convention (design section 3.2). The
    # nil return for an absent key makes delete safe to call unconditionally. Holds
    # the mutex for the removal (design section 12.5).
    #
    # As with get?, the nil return is ambiguous: a removed value of nil and an
    # absent key both come back nil. has_key? before the delete is the
    # disambiguator when a caller must tell them apart. That pair is two separate
    # lock acquisitions: safe when no other fiber can touch the key between them,
    # but on a shared context another fiber can mutate the key in the gap, since
    # there is no atomic compound read and modify is the only atomic compound
    # operation (design section 12.5).
    def delete(key : String) : Any?
      @mutex.synchronize { @data.delete(key) }
    end

    # Read the current value, apply the block, and store the result, returning the
    # value stored (design section 3.2). The read, the block, and the write all run
    # under one lock hold, which is what makes a compound read-modify-write atomic
    # against a shared context (design section 12.5). Reads @data[key] before
    # calling the block, so a missing key raises KeyError and the block never runs.
    #
    # The block runs while @mutex is held. Calling back into an interpreter's send
    # from inside it holds the context lock across the transition and inverts the
    # transition-mutex-before-context-mutex order the interpreters keep, which can
    # deadlock against a concurrent step whose callback wants this same lock (design
    # section 12.7).
    def modify(key : String, &block : (Any) -> Any) : Any
      @mutex.synchronize do
        current_value : Any = @data[key]
        modified_value : Any = block.call(current_value)
        @data[key] = modified_value
        modified_value
      end
    end
  end
end

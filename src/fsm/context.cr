module FSM
  # Represents the "extended" context associated with the finite state machine.
  class Context
    # Mutex for thread safety
    @mutex : Mutex = Mutex.new

    # Internal data storage
    @data : Hash(String, Any) = {} of String => Any

    # Create a new context with optional initial data.
    #
    # @param initial_data [Hash(String, Any)] Optional initial data to be registered in the context.
    def initialize(initial_data = {} of String => Any)
      @data.merge!(initial_data) if initial_data
    end

    # Get the value associated with a key from the context.
    #
    # @param key [String] The key to retrieve.
    # @return [Any] The value associated with the key.
    def get(key : String) : Any
      @mutex.synchronize { @data[key] }
    end

    # Set the value associated with a key in the context.
    #
    # @param key [String] The key to set.
    # @param value [Any] The value to associate with the key.
    def set(key : String, value : Any)
      @mutex.synchronize { @data[key] = value }
    end

    # Modify the value associated with a key in the context using a block.
    #
    # @param key [String] The key to modify.
    # @yieldparam current_value [Any] The current value associated with the key.
    # @return [Any] The modified value.
    def modify(key : String, &block : (Any) -> Any)
      @mutex.synchronize do
        current_value = @data[key]
        modified_value = block.call(current_value)
        @data[key] = modified_value
        modified_value
      end
    end
  end
end

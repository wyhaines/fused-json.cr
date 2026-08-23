module FusedJSON
  # Immutable resource controls shared by every parser entry point.
  struct Limits
    DEFAULT_MAX_NESTING = 512

    getter max_nesting : Int32
    getter max_token_bytes : Int32?
    getter max_document_bytes : Int64?
    getter max_typed_value_bytes : Int64?
    getter max_total_values : Int64?
    getter max_container_entries : Int64?
    getter max_cached_keys : Int64?
    # ameba:disable Naming/QueryBoolMethods
    getter reject_duplicate_keys : Bool

    # ameba:enable Naming/QueryBoolMethods

    def initialize(*, max_nesting : Int = DEFAULT_MAX_NESTING,
                   max_token_bytes : Int? = nil,
                   max_document_bytes : Int? = nil,
                   max_typed_value_bytes : Int? = nil,
                   max_total_values : Int? = nil,
                   max_container_entries : Int? = nil,
                   max_cached_keys : Int? = nil,
                   @reject_duplicate_keys : Bool = false)
      @max_nesting = checked_i32(
        max_nesting,
        "max_nesting",
        1,
        DEFAULT_MAX_NESTING
      )
      @max_token_bytes = max_token_bytes.try do |value|
        checked_i32(value, "max_token_bytes", 1, Int32::MAX)
      end
      @max_document_bytes = checked_nonnegative_i64(max_document_bytes, "max_document_bytes")
      @max_typed_value_bytes = checked_nonnegative_i64(max_typed_value_bytes, "max_typed_value_bytes")
      @max_total_values = checked_nonnegative_i64(max_total_values, "max_total_values")
      @max_container_entries = checked_nonnegative_i64(max_container_entries, "max_container_entries")
      @max_cached_keys = checked_nonnegative_i64(max_cached_keys, "max_cached_keys")
    end

    private def checked_i32(value : Int, name : String, minimum : Int32, maximum : Int32) : Int32
      unless value >= minimum && value <= maximum
        raise ArgumentError.new("#{name} must be between #{minimum} and #{maximum}")
      end
      value.to_i32
    end

    private def checked_nonnegative_i64(value : Int?, name : String) : Int64?
      return unless value
      unless value >= 0 && value <= Int64::MAX
        raise ArgumentError.new("#{name} must be between 0 and #{Int64::MAX}")
      end
      value.to_i64
    end

    DEFAULT = new
  end

  # Optional scanner state exists only when a token or extended resource limit
  # is enabled. Keeping those controls behind one reference minimizes their
  # effect on the default parser layout.
  private class ResourceLimitState
    enum ByteKind
      Document
      TypedValue
    end

    private struct ContainerState
      property entries : Int64
      getter seen_keys : Hash(String, Nil)?

      def initialize(track_keys : Bool)
        @entries = 0_i64
        @seen_keys = {} of String => Nil if track_keys
      end
    end

    getter max_token_bytes : Int32?
    getter max_document_bytes : Int64?
    getter max_typed_value_bytes : Int64?
    getter max_total_values : Int64?
    getter max_container_entries : Int64?
    getter max_cached_keys : Int64?
    getter byte_limit : Int64?
    getter byte_kind : ByteKind
    property selected_value_frame_id : Int64

    @total_values : Int64
    @containers : Array(ContainerState)?

    def self.required?(limits : Limits, max_token_bytes : Int32?) : Bool
      !!(
        max_token_bytes ||
          limits.max_document_bytes ||
          limits.max_typed_value_bytes ||
          limits.max_total_values ||
          limits.max_container_entries ||
          limits.max_cached_keys ||
          limits.reject_duplicate_keys
      )
    end

    def initialize(limits : Limits, *, @max_token_bytes : Int32?)
      @max_document_bytes = limits.max_document_bytes
      @max_typed_value_bytes = limits.max_typed_value_bytes
      @max_total_values = limits.max_total_values
      @max_container_entries = limits.max_container_entries
      @max_cached_keys = limits.max_cached_keys
      @reject_duplicate_keys = limits.reject_duplicate_keys
      @byte_limit = @max_document_bytes
      @byte_kind = ByteKind::Document
      @total_values = 0_i64
      @selected_value_frame_id = 0_i64
      @containers = [] of ContainerState if @max_container_entries || @reject_duplicate_keys
    end

    def limits_active? : Bool
      !!(
        @max_token_bytes ||
          @max_document_bytes ||
          @max_typed_value_bytes ||
          @max_total_values ||
          @max_container_entries ||
          @max_cached_keys ||
          @reject_duplicate_keys
      )
    end

    def record_value? : Bool
      return true unless limit = @max_total_values
      return false if @total_values >= limit
      @total_values += 1
      true
    end

    def enter_container(object : Bool) : Nil
      @containers.try &.<< ContainerState.new(object && @reject_duplicate_keys)
    end

    def leave_container : Nil
      @containers.try &.pop
    end

    def record_entry? : Bool
      containers = @containers
      return true unless containers

      index = containers.size - 1
      container = containers[index]
      if (limit = @max_container_entries) && container.entries >= limit
        return false
      end
      container.entries += 1
      containers[index] = container
      true
    end

    def duplicate_key?(key : String) : Bool
      containers = @containers || return false
      seen = containers.last.seen_keys || return false
      return true if seen.has_key?(key)
      seen[key] = nil
      false
    end

    def duplicate_keys? : Bool
      @reject_duplicate_keys
    end

    def begin_typed_value(start : Int64) : Nil
      limit = @max_typed_value_bytes || return
      typed_limit = if limit > Int64::MAX - start
                      Int64::MAX
                    else
                      start + limit
                    end

      if (document_limit = @max_document_bytes) && document_limit <= typed_limit
        @byte_limit = document_limit
        @byte_kind = ByteKind::Document
      else
        @byte_limit = typed_limit
        @byte_kind = ByteKind::TypedValue
      end
    end

    def end_typed_value : Nil
      @byte_limit = @max_document_bytes
      @byte_kind = ByteKind::Document
    end
  end
end

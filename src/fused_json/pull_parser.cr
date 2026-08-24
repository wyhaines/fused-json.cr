module FusedJSON
  # A forward-only reader for consuming one strict JSON document value by
  # value. The reader is primed on the first value when it is constructed.
  class PullParser < ByteScanner
    # The semantic event currently under the reader's cursor. JSON punctuation
    # other than container boundaries is intentionally not exposed.
    enum Kind
      Null
      Bool
      Int
      Float
      String
      BeginArray
      EndArray
      BeginObject
      EndObject
      EOF
    end

    private enum FrameState
      ArrayFirstOrEnd
      ArrayCommaOrEnd
      ObjectFirstKeyOrEnd
      ObjectValue
      ObjectCommaOrEnd
    end

    private struct Frame
      property state : FrameState
      getter id : Int64

      def initialize(@state : FrameState, @id : Int64)
      end
    end

    getter kind : Kind
    getter bool_value : Bool
    getter byte_offset : Int64

    @frames : Array(Frame)
    @object_key : Bool
    @string_start : Int32
    @string_finish : Int32
    @string_escaped : Bool
    @string_materialized : Bool
    @next_frame_id : Int64
    @event_context_id : Int64
    @location_position : Int32
    @location_line : Int64
    @location_column : Int64
    @number_token : NumberToken
    @int_materialized : Bool
    @float_materialized : Bool
    @enforce_dynamic_numbers : Bool

    def initialize(source : String, *, max_nesting : Int = MAX_NESTING,
                   cache_keys : Bool = false, limits : Limits = Limits::DEFAULT)
      initialize(
        source,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        limits: limits,
        enforce_dynamic_numbers: false
      )
    end

    private def initialize(source : String, *, max_nesting : Int, cache_keys : Bool,
                           limits : Limits, enforce_dynamic_numbers : Bool)
      initialize(
        source,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        limits: limits,
        enforce_dynamic_numbers: enforce_dynamic_numbers,
        prime: true
      )
    end

    protected def initialize(source : String, *, max_nesting : Int, cache_keys : Bool,
                             limits : Limits, enforce_dynamic_numbers : Bool, prime : Bool,
                             max_token_bytes : Int? = nil)
      super(
        source,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        limits: limits,
        max_token_bytes: max_token_bytes
      )
      @frames = [] of Frame
      @kind = Kind::EOF
      @bool_value = false
      @int_value = 0_i64
      @float_value = 0.0
      @string_value = ""
      @byte_offset = 0_i64
      @object_key = false
      @string_start = 0
      @string_finish = 0
      @string_escaped = false
      @string_materialized = false
      @next_frame_id = 0_i64
      @event_context_id = 0_i64
      @location_position = 0
      @location_line = 1_i64
      @location_column = 1_i64
      @number_token = NumberToken.new(0, 0, false, false)
      @int_materialized = false
      @float_materialized = false
      @enforce_dynamic_numbers = enforce_dynamic_numbers
      prime_reader if prime
    end

    protected def prime_reader : Nil
      unless @limits_active
        skip_whitespace_unlimited
        raise_error("expected a JSON value") if eof?
        emit_value_unlimited
        return
      end

      skip_whitespace
      enforce_available_byte
      raise_error("expected a JSON value") if eof?
      emit_value
    end

    def int_value : Int64
      if @kind.int? && !@int_materialized
        @int_value = number_to_int64(@number_token)
        @int_materialized = true
      end
      @int_value
    end

    def float_value : Float64
      if @kind.float? && !@float_materialized
        @float_value = number_to_float64(@number_token)
        @float_materialized = true
      end
      @float_value
    end

    # Returns the current decoded string. Materialization is lazy so skipping a
    # string does not allocate its contents.
    @[AlwaysInline]
    def string_value : String
      if @kind.string? && !@string_materialized
        @string_value = if @string_escaped
                          materialize_string(
                            @string_start,
                            @string_finish,
                            true,
                            key: @object_key
                          )
                        else
                          content_start = @string_start + 1
                          content_size = @string_finish - content_start - 1
                          if @object_key && @key_pool
                            materialize_cached_unescaped_string(
                              @string_start,
                              content_start,
                              content_size
                            )
                          else
                            String.new(@bytes.to_unsafe + content_start, content_size)
                          end
                        end
        @string_materialized = true
      end
      @string_value
    end

    # Returns an owned copy of the exact source token for the current integer
    # or float without consuming it. Raises `ParseError` at any other event.
    def raw_number_value : String
      unless @kind.int? || @kind.float?
        raise_error("expected a number, found #{@kind}", @byte_offset)
      end
      materialize_number(@number_token)
    end

    # Returns an owned copy of the exact source token for the current integer
    # or float and advances to the next event. Raises `ParseError` at any other
    # event.
    def read_raw_number : String
      value = raw_number_value
      read_next
      value
    end

    # Consumes the current event and returns the kind of the next event.
    # Calling this at EOF is idempotent.
    def read_next : Kind
      advance unless @kind.eof?
      @kind
    end

    def read_begin_array : Kind
      expect_kind(Kind::BeginArray)
      read_next
    end

    def read_end_array : Kind
      expect_kind(Kind::EndArray)
      read_next
    end

    def read_begin_object : Kind
      expect_kind(Kind::BeginObject)
      read_next
    end

    def read_end_object : Kind
      expect_kind(Kind::EndObject)
      read_next
    end

    def read_null : Nil
      expect_kind(Kind::Null)
      read_next
      nil
    end

    def read_bool : Bool
      expect_kind(Kind::Bool)
      value = @bool_value
      read_next
      value
    end

    def read_int : Int64
      expect_kind(Kind::Int)
      value = int_value
      read_next
      value
    end

    # Reads a float, converting an integer event when necessary.
    def read_float : Float64
      value = case @kind
              when .int?
                int_value.to_f64
              when .float?
                float_value
              else
                raise_error("expected Float, found #{@kind}", @byte_offset)
              end
      read_next
      value
    end

    def read_string : String
      expect_kind(Kind::String)
      value = string_value
      read_next
      value
    end

    # Object keys are exposed as string events, matching Crystal's pull API.
    def read_object_key : String
      raise_error("expected an object key", @byte_offset) unless @object_key
      read_string
    end

    # Reads an array boundary and yields once for each element. The block must
    # consume at least one complete value per invocation and leave the reader
    # within this array.
    def read_array(&) : Nil
      expect_kind(Kind::BeginArray)
      container_id = @frames.last.id
      read_next
      until @kind.end_array?
        event = {@kind, @byte_offset}
        yield
        ensure_block_consumed_value(event, container_id, "array")
      end
      read_end_array
    end

    # Reads an object and yields each owned key. The block must consume the
    # associated value.
    def read_object(& : String ->) : Nil
      expect_kind(Kind::BeginObject)
      container_id = @frames.last.id
      read_next
      until @kind.end_object?
        key = read_object_key
        event = {@kind, @byte_offset}
        yield key
        ensure_block_consumed_value(event, container_id, "object")
      end
      read_end_object
    end

    # Reads an object and yields each owned key and its one-based source
    # location. The block must consume the associated value.
    def read_object(& : String, Tuple(Int32, Int32) ->) : Nil
      expect_kind(Kind::BeginObject)
      container_id = @frames.last.id
      read_next
      until @kind.end_object?
        key_location = location
        key = read_object_key
        event = {@kind, @byte_offset}
        yield key, key_location
        ensure_block_consumed_value(event, container_id, "object")
      end
      read_end_object
    end

    # Validates and consumes the complete current value. Skipped strings are
    # scanned without being decoded or allocated.
    def skip_value : Nil
      raise_error("cannot skip an object key", @byte_offset) if @object_key

      if @limits_active
        skip_value_limited
        return
      end

      case @kind
      when .null?, .bool?, .int?, .float?, .string?
        advance_unlimited
      when .begin_array?, .begin_object?
        target_depth = @frames.size
        while @frames.size >= target_depth
          advance_unlimited
        end
        advance_unlimited
      else
        raise_error("expected a JSON value", @byte_offset)
      end
    end

    @[NoInline]
    private def skip_value_limited : Nil
      case @kind
      when .null?, .bool?, .int?, .float?, .string?
        advance
      when .begin_array?, .begin_object?
        target_depth = @frames.size
        while @frames.size >= target_depth
          advance
        end
        advance
      else
        raise_error("expected a JSON value", @byte_offset)
      end
    end

    # Alias matching Crystal's pull parser.
    def skip : Nil
      skip_value
    end

    # Ensures the document value has been completely consumed.
    def finish : Nil
      raise_error("expected end of document", @byte_offset) unless @kind.eof?
    end

    def location_i64 : Tuple(Int64, Int64)
      update_location(@byte_offset)
      {@location_line, @location_column}
    end

    def location : Tuple(Int32, Int32)
      line, column = location_i64
      {line.to_i32, column.to_i32}
    end

    def line_number : Int32
      location[0]
    end

    def column_number : Int32
      location[1]
    end

    private def advance : Nil
      release_token

      if @limits_active
        advance_limited
        return
      end

      if @frames.empty?
        finish_document_unlimited
        return
      end

      case @frames.last.state
      when .array_first_or_end?
        next_array_value_unlimited(first: true)
      when .array_comma_or_end?
        next_array_value_unlimited(first: false)
      when .object_first_key_or_end?
        next_object_key_unlimited(first: true)
      when .object_value?
        next_object_value_unlimited
      when .object_comma_or_end?
        next_object_key_unlimited(first: false)
      end
    end

    private def advance_unlimited : Nil
      release_token

      if @frames.empty?
        finish_document_unlimited
        return
      end

      case @frames.last.state
      when .array_first_or_end?
        next_array_value_unlimited(first: true)
      when .array_comma_or_end?
        next_array_value_unlimited(first: false)
      when .object_first_key_or_end?
        next_object_key_unlimited(first: true)
      when .object_value?
        next_object_value_unlimited
      when .object_comma_or_end?
        next_object_key_unlimited(first: false)
      end
    end

    @[NoInline]
    private def advance_limited : Nil
      if @frames.empty?
        finish_document
        return
      end

      case @frames.last.state
      when .array_first_or_end?
        next_array_value(first: true)
      when .array_comma_or_end?
        next_array_value(first: false)
      when .object_first_key_or_end?
        next_object_key(first: true)
      when .object_value?
        next_object_value
      when .object_comma_or_end?
        next_object_key(first: false)
      end
    end

    private def finish_document_unlimited : Nil
      skip_whitespace_unlimited
      raise_error("unexpected trailing content") unless eof?
      set_event_position
      @event_context_id = 0_i64
      @kind = Kind::EOF
      @object_key = false
      reset_string
    end

    private def next_array_value_unlimited(*, first : Bool) : Nil
      skip_whitespace_unlimited

      if first
        if current_byte? == 0x5d_u8 # ]
          emit_container_end_unlimited(Kind::EndArray)
          return
        end
      else
        case current_byte?
        when 0x5d_u8 # ]
          emit_container_end_unlimited(Kind::EndArray)
          return
        when 0x2c_u8 # ,
          advance_byte_unlimited
          skip_whitespace_unlimited
          raise_error("trailing comma in array") if current_byte? == 0x5d_u8
        else
          raise_error("expected ',' or ']' in array")
        end
      end

      set_top_state(FrameState::ArrayCommaOrEnd)
      emit_value_unlimited
    end

    private def next_object_key_unlimited(*, first : Bool) : Nil
      skip_whitespace_unlimited

      if first
        if current_byte? == 0x7d_u8 # }
          emit_container_end_unlimited(Kind::EndObject)
          return
        end
      else
        case current_byte?
        when 0x7d_u8 # }
          emit_container_end_unlimited(Kind::EndObject)
          return
        when 0x2c_u8 # ,
          advance_byte_unlimited
          skip_whitespace_unlimited
          raise_error("trailing comma in object") if current_byte? == 0x7d_u8
        else
          raise_error("expected ',' or '}' in object")
        end
      end

      raise_error("expected a string object key") unless current_byte? == 0x22_u8
      set_event_position
      @event_context_id = @frames.last.id
      start_string
      @string_escaped = scan_string_unlimited
      @string_finish = token_position
      @kind = Kind::String
      @object_key = true
      set_top_state(FrameState::ObjectValue)
    end

    @[AlwaysInline]
    private def next_object_value_unlimited : Nil
      skip_whitespace_unlimited
      raise_error("expected ':' after object key") unless consume_if_unlimited(0x3a_u8)
      skip_whitespace_unlimited
      set_top_state(FrameState::ObjectCommaOrEnd)
      emit_value_unlimited
    end

    private def emit_value_unlimited : Nil
      raise_error("expected a JSON value") if eof?

      set_event_position
      @event_context_id = @frames.last?.try(&.id) || 0_i64
      @object_key = false
      reset_string

      case byte = current_byte
      when 0x22_u8 # "
        start_string
        @string_escaped = scan_string_unlimited
        @string_finish = token_position
        @kind = Kind::String
      when 0x5b_u8 # [
        enter_container_unlimited(FrameState::ArrayFirstOrEnd, Kind::BeginArray)
      when 0x7b_u8 # {
        enter_container_unlimited(FrameState::ObjectFirstKeyOrEnd, Kind::BeginObject)
      when 0x6e_u8 # n
        consume_literal_unlimited("null")
        @kind = Kind::Null
      when 0x74_u8 # t
        consume_literal_unlimited("true")
        @bool_value = true
        @kind = Kind::Bool
      when 0x66_u8 # f
        consume_literal_unlimited("false")
        @bool_value = false
        @kind = Kind::Bool
      else
        if byte == 0x2d_u8 || digit?(byte)
          @number_token = scan_number_unlimited
          if @number_token.floating?
            @float_materialized = false
            if @enforce_dynamic_numbers
              @float_value = number_to_float64(@number_token)
              @float_materialized = true
            end
            @kind = Kind::Float
          else
            @int_materialized = false
            if @enforce_dynamic_numbers
              @int_value = number_to_int64(@number_token)
              @int_materialized = true
            end
            @kind = Kind::Int
          end
        else
          raise_error("unexpected byte 0x#{byte.to_s(16)}")
        end
      end
    end

    private def enter_container_unlimited(state : FrameState, kind : Kind) : Nil
      raise_error("nesting exceeds #{@max_nesting}") if @frames.size >= @max_nesting
      advance_byte_unlimited
      @next_frame_id += 1
      @frames << Frame.new(state, @next_frame_id)
      @kind = kind
    end

    private def emit_container_end_unlimited(kind : Kind) : Nil
      set_event_position
      @event_context_id = @frames.last.id
      advance_byte_unlimited
      @frames.pop
      @kind = kind
      @object_key = false
      reset_string
    end

    private def finish_document : Nil
      skip_whitespace
      enforce_available_byte
      raise_error("unexpected trailing content") unless eof?
      set_event_position
      @event_context_id = 0_i64
      @kind = Kind::EOF
      @object_key = false
      reset_string
    end

    private def next_array_value(*, first : Bool) : Nil
      skip_whitespace
      enforce_available_byte

      if first
        if current_byte? == 0x5d_u8 # ]
          emit_container_end(Kind::EndArray)
          return
        end
      else
        case current_byte?
        when 0x5d_u8 # ]
          emit_container_end(Kind::EndArray)
          return
        when 0x2c_u8 # ,
          advance_byte
          skip_whitespace
          enforce_available_byte
          raise_error("trailing comma in array") if current_byte? == 0x5d_u8
        else
          raise_error("expected ',' or ']' in array")
        end
      end

      set_top_state(FrameState::ArrayCommaOrEnd)
      record_container_entry
      emit_value
    end

    private def next_object_key(*, first : Bool) : Nil
      skip_whitespace
      enforce_available_byte

      if first
        if current_byte? == 0x7d_u8 # }
          emit_container_end(Kind::EndObject)
          return
        end
      else
        case current_byte?
        when 0x7d_u8 # }
          emit_container_end(Kind::EndObject)
          return
        when 0x2c_u8 # ,
          advance_byte
          skip_whitespace
          enforce_available_byte
          raise_error("trailing comma in object") if current_byte? == 0x7d_u8
        else
          raise_error("expected ',' or '}' in object")
        end
      end

      raise_error("expected a string object key") unless current_byte? == 0x22_u8
      record_container_entry
      set_event_position
      @event_context_id = @frames.last.id
      start_string
      @string_escaped = scan_string
      @string_finish = token_position
      @kind = Kind::String
      @object_key = true
      enforce_duplicate_key(string_value, @byte_offset) if duplicate_keys?
      set_top_state(FrameState::ObjectValue)
    end

    private def next_object_value : Nil
      skip_whitespace
      enforce_available_byte
      raise_error("expected ':' after object key") unless consume_if(0x3a_u8)
      skip_whitespace
      enforce_available_byte
      set_top_state(FrameState::ObjectCommaOrEnd)
      emit_value
    end

    private def emit_value : Nil
      enforce_available_byte
      raise_error("expected a JSON value") if eof?
      record_value

      set_event_position
      @event_context_id = @frames.last?.try(&.id) || 0_i64
      @object_key = false
      reset_string

      case byte = current_byte
      when 0x22_u8 # "
        start_string
        @string_escaped = scan_string
        @string_finish = token_position
        @kind = Kind::String
      when 0x5b_u8 # [
        enter_container(FrameState::ArrayFirstOrEnd, Kind::BeginArray)
      when 0x7b_u8 # {
        enter_container(FrameState::ObjectFirstKeyOrEnd, Kind::BeginObject)
      when 0x6e_u8 # n
        consume_literal("null")
        @kind = Kind::Null
      when 0x74_u8 # t
        consume_literal("true")
        @bool_value = true
        @kind = Kind::Bool
      when 0x66_u8 # f
        consume_literal("false")
        @bool_value = false
        @kind = Kind::Bool
      else
        if byte == 0x2d_u8 || digit?(byte)
          @number_token = scan_number
          if @number_token.floating?
            @float_materialized = false
            if @enforce_dynamic_numbers
              @float_value = number_to_float64(@number_token)
              @float_materialized = true
            end
            @kind = Kind::Float
          else
            @int_materialized = false
            if @enforce_dynamic_numbers
              @int_value = number_to_int64(@number_token)
              @int_materialized = true
            end
            @kind = Kind::Int
          end
        else
          raise_error("unexpected byte 0x#{byte.to_s(16)}")
        end
      end
    end

    private def enter_container(state : FrameState, kind : Kind) : Nil
      raise_error("nesting exceeds #{@max_nesting}") if @frames.size >= @max_nesting
      advance_byte
      enter_limit_container(object: kind.begin_object?)
      @next_frame_id += 1
      @frames << Frame.new(state, @next_frame_id)
      @kind = kind
    end

    private def emit_container_end(kind : Kind) : Nil
      set_event_position
      frame_id = @frames.last.id
      @event_context_id = frame_id
      advance_byte
      leave_limit_container
      if (state = resource_limits) && state.selected_value_frame_id == frame_id
        end_typed_value_limit
        state.selected_value_frame_id = 0_i64
      end
      @frames.pop
      @kind = kind
      @object_key = false
      reset_string
    end

    private def set_top_state(state : FrameState) : Nil
      index = @frames.size - 1
      frame = @frames[index]
      frame.state = state
      @frames[index] = frame
    end

    private def start_string : Nil
      @string_value = ""
      prepare_string_token
      @string_start = token_position
      @string_finish = token_position
      @string_escaped = false
      @string_materialized = false
    end

    private def reset_string : Nil
      @string_value = ""
      @string_materialized = false
    end

    private def ensure_block_consumed_value(event : Tuple(Kind, Int64), container_id : Int64, container : String) : Nil
      if event == {@kind, @byte_offset} || @event_context_id != container_id
        raise_error("#{container} block must consume one complete value", @byte_offset)
      end
    end

    private def set_event_position : Nil
      @byte_offset = current_offset
      record_event_position
    end

    protected def begin_current_typed_value_limit : Nil
      return unless begin_typed_value_limit(@byte_offset)

      if @kind.begin_array? || @kind.begin_object?
        state = resource_limits || raise "missing resource-limit state"
        state.selected_value_frame_id = @frames.last.id
      else
        end_typed_value_limit
      end
    end

    private def update_location(position : Int64) : Nil
      target = position.to_i32
      index = @location_position
      while index < target
        byte = @bytes[index]
        if byte == 0x0a_u8
          @location_line += 1
          @location_column = 1_i64
          index += 1
        else
          @location_column += 1
          width = if byte < 0x80_u8
                    1
                  elsif byte < 0xe0_u8
                    2
                  elsif byte < 0xf0_u8
                    3
                  elsif byte < 0xf5_u8
                    4
                  else
                    1
                  end
          index += Math.min(width, target - index)
        end
      end

      @location_position = target
    end

    private def expect_kind(expected : Kind) : Nil
      return if @kind == expected
      raise_error("expected #{expected}, found #{@kind}", @byte_offset)
    end

    private def digit?(byte : UInt8) : Bool
      0x30_u8 <= byte <= 0x39_u8
    end
  end
end

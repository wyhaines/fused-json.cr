module FusedJSON
  # :nodoc:
  # A pull parser that reads strict JSON incrementally from caller-owned IO.
  # Input buffering is bounded by `buffer_size`; the reusable token buffer can
  # grow to the size of the current string or number.
  class StreamingPullParser < PullParser
    DEFAULT_BUFFER_SIZE   = 32 * 1024
    MAX_BUFFER_SIZE       = 16 * 1024 * 1024
    private MIN_SCRATCH_RETENTION = 64 * 1024

    @input : IO
    @input_buffer : Bytes
    @input_position : Int32
    @input_size : Int32
    @input_eof : Bool
    @stream_offset : Int64
    @stream_line : Int64
    @stream_column : Int64
    @event_line : Int64
    @event_column : Int64
    @token_offset : Int64
    @token_line : Int64
    @token_column : Int64
    @token_active : Bool
    @token_buffer_start : Int32
    @token_length : Int32
    @token_uses_scratch : Bool
    @token : IO::Memory
    @scratch_retention_limit : Int32

    # `max_token_bytes` limits each raw string or number in the decoded stream.
    def initialize(input : IO, *, buffer_size : Int = DEFAULT_BUFFER_SIZE,
                   max_nesting : Int = MAX_NESTING, cache_keys : Bool = false,
                   max_token_bytes : Int? = nil,
                   limits : Limits = Limits::DEFAULT)
      initialize(
        input,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        max_token_bytes: max_token_bytes,
        limits: limits,
        enforce_dynamic_numbers: false
      )
    end

    protected def initialize(@input : IO, *, buffer_size : Int,
                             max_nesting : Int, cache_keys : Bool,
                             enforce_dynamic_numbers : Bool,
                             max_token_bytes : Int? = nil,
                             limits : Limits = Limits::DEFAULT)
      unless buffer_size > 0 && buffer_size <= MAX_BUFFER_SIZE
        raise ArgumentError.new("buffer_size must be between 1 and #{MAX_BUFFER_SIZE}")
      end
      @input_buffer = Bytes.new(buffer_size.to_i32)
      @input_position = 0
      @input_size = 0
      @input_eof = false
      @stream_offset = 0_i64
      @stream_line = 1_i64
      @stream_column = 1_i64
      @event_line = 1_i64
      @event_column = 1_i64
      @token_offset = 0_i64
      @token_line = 1_i64
      @token_column = 1_i64
      @token_active = false
      @token_buffer_start = 0
      @token_length = 0
      @token_uses_scratch = false
      @token = IO::Memory.new(Math.min(buffer_size.to_i32, 256))
      @scratch_retention_limit = Math.max(@input_buffer.size * 2, MIN_SCRATCH_RETENTION)
      super(
        "",
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        limits: limits,
        max_token_bytes: max_token_bytes,
        enforce_dynamic_numbers: enforce_dynamic_numbers,
        prime: false
      )
      prime_reader
    end

    def location_i64 : Tuple(Int64, Int64)
      {@event_line, @event_column}
    end

    protected def current_offset : Int64
      @stream_offset
    end

    protected def advance_byte : Nil
      byte = current_byte
      consume_ascii(byte)
    end

    protected def advance_byte_unlimited : Nil
      byte = current_byte
      consume_ascii_unlimited(byte)
    end

    @[AlwaysInline]
    protected def enforce_available_byte : Nil
      state = @resource_limits || return
      limit = state.byte_limit || return
      return if @stream_offset < limit

      if @stream_offset > limit
        raise_stream_byte_limit(state, limit, @stream_line, @stream_column)
      end
      if @input_position >= @input_size
        return unless refill
      end
      raise_stream_byte_limit(state, limit, @stream_line, @stream_column)
    end

    protected def prepare_string_token : Nil
      begin_token
    end

    protected def token_position : Int32
      @token_length
    end

    protected def record_event_position : Nil
      @event_line = @stream_line
      @event_column = @stream_column
      @token_active = false
    end

    protected def release_token : Nil
      @token_active = false
      @token_length = 0
      return unless @token_uses_scratch

      @token_uses_scratch = false
      if @token.bytesize > @scratch_retention_limit
        @token = IO::Memory.new(Math.min(@input_buffer.size, 256))
      else
        @token.clear
      end
    end

    protected def current_byte : UInt8
      current_byte? || raise_error("unexpected end of input")
    end

    protected def current_byte? : UInt8?
      if @input_position >= @input_size
        return nil unless refill
      end
      @input_buffer[@input_position]
    end

    protected def eof? : Bool
      current_byte?.nil?
    end

    protected def consume_if(byte : UInt8) : Bool
      return false unless current_byte? == byte
      consume_ascii(byte)
      true
    end

    @[AlwaysInline]
    protected def consume_if_unlimited(byte : UInt8) : Bool
      return false unless current_byte? == byte
      consume_ascii_unlimited(byte)
      true
    end

    protected def skip_whitespace : Nil
      if @resource_limits.try(&.byte_limit)
        skip_whitespace_with_byte_limit
        return
      end

      loop do
        if @input_position >= @input_size
          return unless refill
        end

        while @input_position < @input_size
          byte = @input_buffer[@input_position]
          case byte
          when 0x20_u8, 0x09_u8, 0x0d_u8
            @input_position += 1
            @stream_offset += 1
            @stream_column += 1
          when 0x0a_u8
            @input_position += 1
            @stream_offset += 1
            @stream_line += 1
            @stream_column = 1_i64
          else
            return
          end
        end
      end
    end

    protected def skip_whitespace_unlimited : Nil
      loop do
        if @input_position >= @input_size
          return unless refill
        end

        while @input_position < @input_size
          byte = @input_buffer[@input_position]
          case byte
          when 0x20_u8, 0x09_u8, 0x0d_u8
            @input_position += 1
            @stream_offset += 1
            @stream_column += 1
          when 0x0a_u8
            @input_position += 1
            @stream_offset += 1
            @stream_line += 1
            @stream_column = 1_i64
          else
            return
          end
        end
      end
    end

    protected def consume_literal(literal : String) : Nil
      literal.each_byte do |expected|
        enforce_available_byte
        raise_error("invalid literal") unless current_byte? == expected
        consume_ascii(expected)
      end
    end

    protected def consume_literal_unlimited(literal : String) : Nil
      literal.each_byte do |expected|
        raise_error("invalid literal") unless current_byte? == expected
        consume_ascii_unlimited(expected)
      end
    end

    protected def scan_string : Bool
      consume_token_ascii(0x22_u8) # opening quote
      escaped = false

      loop do
        enforce_available_byte
        if @input_position >= @input_size
          raise_error("unterminated string") unless refill
        end
        enforce_stream_token_byte

        byte = @input_buffer[@input_position]
        case byte
        when 0x22_u8 # "
          consume_token_ascii(byte)
          finish_token
          return escaped
        when 0x5c_u8 # \
          escaped = true
          scan_escape
        else
          raise_error("unescaped control byte in string") if byte < 0x20_u8
          if byte < 0x80_u8
            start = @input_position
            @input_position = ASCIIStringScanner.find_special(@input_buffer, @input_position, @input_size)
            advance_ascii_span(@input_position - start)
          else
            scan_utf8_sequence
          end
        end
      end
    end

    protected def scan_string_unlimited : Bool
      consume_token_ascii_unlimited(0x22_u8) # opening quote
      escaped = false

      loop do
        if @input_position >= @input_size
          raise_error("unterminated string") unless refill
        end

        byte = @input_buffer[@input_position]
        case byte
        when 0x22_u8 # "
          consume_token_ascii_unlimited(byte)
          finish_token
          return escaped
        when 0x5c_u8 # \
          escaped = true
          scan_escape_unlimited
        else
          raise_error("unescaped control byte in string") if byte < 0x20_u8
          if byte < 0x80_u8
            start = @input_position
            @input_position = ASCIIStringScanner.find_special(@input_buffer, @input_position, @input_size)
            advance_ascii_span_unlimited(@input_position - start)
          else
            scan_utf8_sequence_unlimited
          end
        end
      end
    end

    protected def materialize_string(start : Int32, finish : Int32, escaped : Bool, *, key : Bool) : String
      bytes = token_bytes
      if !escaped && key && @key_pool
        return cache_key(bytes.to_unsafe + 1, bytes.size - 2, @token_offset)
      end

      value = if escaped
                decode_escaped_string(bytes)
              else
                String.new(bytes.to_unsafe + 1, bytes.size - 2)
              end

      key && @key_pool ? cache_key(value, @token_offset) : value
    end

    protected def scan_number : NumberToken
      begin_token
      negative = consume_token_if(0x2d_u8)
      enforce_available_byte
      raise_error("expected digit after '-'") if eof?

      if current_byte == 0x30_u8
        consume_token_ascii(0x30_u8)
        enforce_available_byte
        raise_error("leading zero in number") if (byte = current_byte?) && digit?(byte)
      elsif nonzero_digit?(current_byte)
        consume_token_digits
      else
        raise_error("invalid number")
      end

      floating = false
      if consume_token_if(0x2e_u8) # .
        floating = true
        raise_error("expected digit after decimal point") unless consume_token_digits
      end

      enforce_available_byte
      if (byte = current_byte?) && (byte == 0x65_u8 || byte == 0x45_u8) # e/E
        floating = true
        consume_token_ascii(byte)
        enforce_available_byte
        if (sign = current_byte?) && (sign == 0x2b_u8 || sign == 0x2d_u8)
          consume_token_ascii(sign)
        end
        raise_error("expected digit in exponent") unless consume_token_digits
      end

      finish_token
      NumberToken.new(0, @token_length, negative, floating)
    end

    protected def scan_number_unlimited : NumberToken
      begin_token
      negative = consume_token_if_unlimited(0x2d_u8)
      raise_error("expected digit after '-'") if eof?

      if current_byte == 0x30_u8
        consume_token_ascii_unlimited(0x30_u8)
        raise_error("leading zero in number") if (byte = current_byte?) && digit?(byte)
      elsif nonzero_digit?(current_byte)
        consume_token_digits_unlimited
      else
        raise_error("invalid number")
      end

      floating = false
      if consume_token_if_unlimited(0x2e_u8) # .
        floating = true
        raise_error("expected digit after decimal point") unless consume_token_digits_unlimited
      end

      if (byte = current_byte?) && (byte == 0x65_u8 || byte == 0x45_u8) # e/E
        floating = true
        consume_token_ascii_unlimited(byte)
        if (sign = current_byte?) && (sign == 0x2b_u8 || sign == 0x2d_u8)
          consume_token_ascii_unlimited(sign)
        end
        raise_error("expected digit in exponent") unless consume_token_digits_unlimited
      end

      finish_token
      NumberToken.new(0, @token_length, negative, floating)
    end

    protected def number_to_float64(token : NumberToken) : Float64
      Float64Decoder.parse?(token_bytes, token.start, token.finish) ||
        raise_error("number is outside Float64 range", @token_offset)
    end

    protected def number_to_int64(token : NumberToken) : Int64
      bytes = token_bytes
      limit = token.negative ? 9_223_372_036_854_775_808_u64 : 9_223_372_036_854_775_807_u64
      value = 0_u64
      index = token.negative ? token.start + 1 : token.start

      while index < token.finish
        digit = (bytes[index] - 0x30_u8).to_u64
        raise_error("integer is outside Int64 range", @token_offset) if value > (limit - digit) // 10_u64
        value = value * 10_u64 + digit
        index += 1
      end

      if token.negative
        value == 9_223_372_036_854_775_808_u64 ? Int64::MIN : -value.to_i64
      else
        value.to_i64
      end
    end

    protected def materialize_number(token : NumberToken) : String
      String.new(token_bytes.to_unsafe + token.start, token.finish - token.start)
    end

    protected def raise_error(message : String, position : Int64) : NoReturn
      line, column = stream_location_at(position)
      raise ParseError.new(message, position, line, column)
    end

    private def refill : Bool
      return false if @input_eof

      flush_token_span if @token_active
      count = @input.read_utf8(@input_buffer)
      unless 0 <= count <= @input_buffer.size
        raise IO::Error.new("IO#read returned invalid byte count #{count}")
      end

      @input_position = 0
      @input_size = count
      @token_buffer_start = 0 if @token_active
      if count == 0
        @input_eof = true
        false
      else
        true
      end
    end

    private def begin_token : Nil
      release_token
      @token_offset = @stream_offset
      @token_line = @stream_line
      @token_column = @stream_column
      @token_active = true
      @token_buffer_start = @input_position
      @token_length = 0
      @token_uses_scratch = false
    end

    @[AlwaysInline]
    private def consume_ascii(byte : UInt8) : Nil
      enforce_stream_byte
      @input_position += 1
      @stream_offset += 1
      if byte == 0x0a_u8
        @stream_line += 1
        @stream_column = 1_i64
      else
        @stream_column += 1
      end
    end

    @[AlwaysInline]
    private def consume_ascii_unlimited(byte : UInt8) : Nil
      @input_position += 1
      @stream_offset += 1
      if byte == 0x0a_u8
        @stream_line += 1
        @stream_column = 1_i64
      else
        @stream_column += 1
      end
    end

    private def consume_token_ascii(byte : UInt8) : Nil
      enforce_stream_byte
      enforce_stream_token_byte
      @input_position += 1
      @stream_offset += 1
      if byte == 0x0a_u8
        @stream_line += 1
        @stream_column = 1_i64
      else
        @stream_column += 1
      end
    end

    @[AlwaysInline]
    private def consume_token_raw(byte : UInt8) : Nil
      enforce_stream_byte
      enforce_stream_token_byte
      @input_position += 1
      @stream_offset += 1
    end

    private def consume_token_ascii_unlimited(byte : UInt8) : Nil
      consume_ascii_unlimited(byte)
    end

    @[AlwaysInline]
    private def consume_token_raw_unlimited(byte : UInt8) : Nil
      @input_position += 1
      @stream_offset += 1
    end

    private def consume_token_if(byte : UInt8) : Bool
      enforce_available_byte
      return false unless current_byte? == byte
      consume_token_ascii(byte)
      true
    end

    private def consume_token_if_unlimited(byte : UInt8) : Bool
      return false unless current_byte? == byte
      consume_token_ascii_unlimited(byte)
      true
    end

    private def consume_token_digits : Bool
      consumed = false
      loop do
        enforce_available_byte
        if @input_position >= @input_size
          return consumed unless refill
        end

        start = @input_position
        while @input_position < @input_size && digit?(@input_buffer[@input_position])
          @input_position += 1
        end
        count = @input_position - start
        advance_ascii_span(count)
        consumed = true if count > 0
        return consumed if @input_position < @input_size
      end
    end

    private def consume_token_digits_unlimited : Bool
      consumed = false
      loop do
        if @input_position >= @input_size
          return consumed unless refill
        end

        start = @input_position
        while @input_position < @input_size && digit?(@input_buffer[@input_position])
          @input_position += 1
        end
        count = @input_position - start
        advance_ascii_span_unlimited(count)
        consumed = true if count > 0
        return consumed if @input_position < @input_size
      end
    end

    @[AlwaysInline]
    private def advance_ascii_span(count : Int32) : Nil
      state = @resource_limits
      byte_limit = state.try(&.byte_limit)
      byte_distance = byte_limit.try { |limit| limit - @stream_offset }
      token_limit = max_token_bytes
      token_distance = token_limit.try do |limit|
        limit.to_i64 - (@stream_offset - @token_offset)
      end

      if state && byte_limit && byte_distance && byte_distance < count &&
         (!token_distance || byte_distance <= token_distance)
        column = @stream_column + Math.max(byte_distance, 0_i64)
        raise_stream_byte_limit(state, byte_limit, @stream_line, column)
      end
      if token_limit && token_distance && token_distance < count
        raise_error("token exceeds max_token_bytes of #{token_limit}", @token_offset)
      end
      @stream_offset += count
      @stream_column += count
    end

    @[AlwaysInline]
    private def advance_ascii_span_unlimited(count : Int32) : Nil
      @stream_offset += count
      @stream_column += count
    end

    private def scan_escape : Nil
      slash_offset = @stream_offset
      consume_token_ascii(0x5c_u8)
      enforce_available_byte
      byte = current_byte? || raise_error("unterminated string escape", slash_offset)
      enforce_stream_token_byte

      case byte
      when 0x22_u8, 0x5c_u8, 0x2f_u8, 0x62_u8, 0x66_u8, 0x6e_u8, 0x72_u8, 0x74_u8
        consume_token_ascii(byte)
      when 0x75_u8 # u
        consume_token_ascii(byte)
        codepoint = scan_hex4
        if 0xd800 <= codepoint <= 0xdbff
          low = scan_low_surrogate
          raise_error("invalid low surrogate") unless 0xdc00 <= low <= 0xdfff
        elsif 0xdc00 <= codepoint <= 0xdfff
          raise_error("unexpected low surrogate")
        end
      else
        raise_error("invalid string escape", slash_offset)
      end
    end

    private def scan_escape_unlimited : Nil
      slash_offset = @stream_offset
      consume_token_ascii_unlimited(0x5c_u8)
      byte = current_byte? || raise_error("unterminated string escape", slash_offset)

      case byte
      when 0x22_u8, 0x5c_u8, 0x2f_u8, 0x62_u8, 0x66_u8, 0x6e_u8, 0x72_u8, 0x74_u8
        consume_token_ascii_unlimited(byte)
      when 0x75_u8 # u
        consume_token_ascii_unlimited(byte)
        codepoint = scan_hex4_unlimited
        if 0xd800 <= codepoint <= 0xdbff
          low = scan_low_surrogate_unlimited
          raise_error("invalid low surrogate") unless 0xdc00 <= low <= 0xdfff
        elsif 0xdc00 <= codepoint <= 0xdfff
          raise_error("unexpected low surrogate")
        end
      else
        raise_error("invalid string escape", slash_offset)
      end
    end

    private def scan_hex4 : Int32
      start_offset = @stream_offset
      bytes = uninitialized UInt8[4]
      4.times do |offset|
        enforce_available_byte
        byte = current_byte? || raise_error("incomplete unicode escape", start_offset)
        enforce_stream_token_byte
        bytes[offset] = byte
        consume_token_ascii(byte)
      end

      value = 0
      4.times do |offset|
        byte = bytes[offset]
        digit = hex_value(byte)
        raise_error("invalid hex digit in unicode escape", start_offset + offset) if digit < 0
        value = (value << 4) | digit
      end
      value
    end

    private def scan_hex4_unlimited : Int32
      start_offset = @stream_offset
      bytes = uninitialized UInt8[4]
      4.times do |offset|
        byte = current_byte? || raise_error("incomplete unicode escape", start_offset)
        bytes[offset] = byte
        consume_token_ascii_unlimited(byte)
      end

      value = 0
      4.times do |offset|
        byte = bytes[offset]
        digit = hex_value(byte)
        raise_error("invalid hex digit in unicode escape", start_offset + offset) if digit < 0
        value = (value << 4) | digit
      end
      value
    end

    private def scan_low_surrogate : Int32
      start_offset = @stream_offset
      bytes = uninitialized UInt8[6]
      6.times do |offset|
        enforce_available_byte
        byte = current_byte? || raise_error("high surrogate must be followed by a low surrogate", start_offset)
        enforce_stream_token_byte
        bytes[offset] = byte
        consume_token_ascii(byte)
      end

      unless bytes[0] == 0x5c_u8 && bytes[1] == 0x75_u8
        raise_error("high surrogate must be followed by a low surrogate", start_offset)
      end

      value = 0
      4.times do |offset|
        byte = bytes[2 + offset]
        digit = hex_value(byte)
        raise_error("invalid hex digit in unicode escape", start_offset + 2 + offset) if digit < 0
        value = (value << 4) | digit
      end
      value
    end

    private def scan_low_surrogate_unlimited : Int32
      start_offset = @stream_offset
      bytes = uninitialized UInt8[6]
      6.times do |offset|
        byte = current_byte? || raise_error("high surrogate must be followed by a low surrogate", start_offset)
        bytes[offset] = byte
        consume_token_ascii_unlimited(byte)
      end

      unless bytes[0] == 0x5c_u8 && bytes[1] == 0x75_u8
        raise_error("high surrogate must be followed by a low surrogate", start_offset)
      end

      value = 0
      4.times do |offset|
        byte = bytes[2 + offset]
        digit = hex_value(byte)
        raise_error("invalid hex digit in unicode escape", start_offset + 2 + offset) if digit < 0
        value = (value << 4) | digit
      end
      value
    end

    private def scan_utf8_sequence : Nil
      first = current_byte
      case first
      when 0xc2_u8..0xdf_u8
        consume_utf8_lead(first)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
      when 0xe0_u8
        consume_utf8_lead(first)
        consume_utf8_continuation(0xa0_u8, 0xbf_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
      when 0xe1_u8..0xec_u8, 0xee_u8..0xef_u8
        consume_utf8_lead(first)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
      when 0xed_u8
        consume_utf8_lead(first)
        consume_utf8_continuation(0x80_u8, 0x9f_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
      when 0xf0_u8
        consume_utf8_lead(first)
        consume_utf8_continuation(0x90_u8, 0xbf_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
      when 0xf1_u8..0xf3_u8
        consume_utf8_lead(first)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
      when 0xf4_u8
        consume_utf8_lead(first)
        consume_utf8_continuation(0x80_u8, 0x8f_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
        consume_utf8_continuation(0x80_u8, 0xbf_u8)
      else
        raise_error("invalid UTF-8 in string")
      end
    end

    private def scan_utf8_sequence_unlimited : Nil
      first = current_byte
      case first
      when 0xc2_u8..0xdf_u8
        consume_utf8_lead_unlimited(first)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
      when 0xe0_u8
        consume_utf8_lead_unlimited(first)
        consume_utf8_continuation_unlimited(0xa0_u8, 0xbf_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
      when 0xe1_u8..0xec_u8, 0xee_u8..0xef_u8
        consume_utf8_lead_unlimited(first)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
      when 0xed_u8
        consume_utf8_lead_unlimited(first)
        consume_utf8_continuation_unlimited(0x80_u8, 0x9f_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
      when 0xf0_u8
        consume_utf8_lead_unlimited(first)
        consume_utf8_continuation_unlimited(0x90_u8, 0xbf_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
      when 0xf1_u8..0xf3_u8
        consume_utf8_lead_unlimited(first)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
      when 0xf4_u8
        consume_utf8_lead_unlimited(first)
        consume_utf8_continuation_unlimited(0x80_u8, 0x8f_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
        consume_utf8_continuation_unlimited(0x80_u8, 0xbf_u8)
      else
        raise_error("invalid UTF-8 in string")
      end
    end

    private def consume_utf8_lead(byte : UInt8) : Nil
      consume_token_raw(byte)
      @stream_column += 1
    end

    private def consume_utf8_lead_unlimited(byte : UInt8) : Nil
      consume_token_raw_unlimited(byte)
      @stream_column += 1
    end

    private def consume_utf8_continuation(minimum : UInt8, maximum : UInt8) : Nil
      enforce_available_byte
      byte = current_byte? || raise_error("incomplete UTF-8 sequence")
      enforce_stream_token_byte
      raise_error("invalid UTF-8 in string") unless minimum <= byte <= maximum
      consume_token_raw(byte)
    end

    private def consume_utf8_continuation_unlimited(minimum : UInt8, maximum : UInt8) : Nil
      byte = current_byte? || raise_error("incomplete UTF-8 sequence")
      raise_error("invalid UTF-8 in string") unless minimum <= byte <= maximum
      consume_token_raw_unlimited(byte)
    end

    private def decode_escaped_string(bytes : Bytes) : String
      builder = String::Builder.new(bytes.size)
      index = 1
      segment_start = index
      limit = bytes.size - 1

      while index < limit
        unless bytes[index] == 0x5c_u8
          index += 1
          next
        end

        builder.write(bytes[segment_start, index - segment_start])
        index += 1
        case byte = bytes[index]
        when 0x22_u8, 0x5c_u8, 0x2f_u8
          builder.write_byte(byte)
          index += 1
        when 0x62_u8
          builder.write_byte(0x08_u8)
          index += 1
        when 0x66_u8
          builder.write_byte(0x0c_u8)
          index += 1
        when 0x6e_u8
          builder.write_byte(0x0a_u8)
          index += 1
        when 0x72_u8
          builder.write_byte(0x0d_u8)
          index += 1
        when 0x74_u8
          builder.write_byte(0x09_u8)
          index += 1
        when 0x75_u8
          codepoint = decode_hex4(bytes, index + 1)
          index += 5
          if 0xd800 <= codepoint <= 0xdbff
            low = decode_hex4(bytes, index + 2)
            index += 6
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00)
          end
          if codepoint <= 0x7f
            builder.write_byte(codepoint.to_u8)
          else
            builder << codepoint.unsafe_chr
          end
        end
        segment_start = index
      end

      builder.write(bytes[segment_start, limit - segment_start])
      builder.to_s
    end

    private def decode_hex4(bytes : Bytes, start : Int32) : Int32
      value = 0
      4.times do |offset|
        value = (value << 4) | hex_value(bytes[start + offset])
      end
      value
    end

    private def stream_location_at(position : Int64) : Tuple(Int64, Int64)
      return {@stream_line, @stream_column} if position == @stream_offset
      return {@event_line, @event_column} if position == @byte_offset

      if (@kind.null? || @kind.bool?) && @byte_offset < position < @stream_offset
        return {@event_line, @event_column + position - @byte_offset}
      end

      if @token_active && @token_offset <= position <= @stream_offset
        line = @token_line
        column = @token_column
        index = 0
        bytes = token_bytes_for_error
        limit = Math.min(position - @token_offset, bytes.size.to_i64).to_i32
        while index < limit
          byte = bytes[index]
          if byte == 0x0a_u8
            line += 1
            column = 1_i64
            index += 1
          else
            column += 1
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
            index += Math.min(width, limit - index)
          end
        end
        return {line, column}
      end

      {@stream_line, @stream_column}
    end

    private def finish_token : Nil
      if @token_uses_scratch
        flush_token_span
        @token_length = @token.bytesize
      else
        @token_length = @input_position - @token_buffer_start
      end
      enforce_token_size(@token_length)
    end

    private def flush_token_span : Nil
      count = @input_position - @token_buffer_start
      if count > 0
        if count > Int32::MAX - @token.bytesize
          raise_error("token exceeds maximum supported size", @token_offset)
        end
        enforce_token_size(@token.bytesize + count)
        @token.write(@input_buffer[@token_buffer_start, count])
      end
      @token_buffer_start = @input_position
      @token_uses_scratch = true
    end

    private def enforce_token_size(size : Int32) : Nil
      if (limit = max_token_bytes) && size > limit
        raise_error("token exceeds max_token_bytes of #{limit}", @token_offset)
      end
    end

    private def skip_whitespace_with_byte_limit : Nil
      loop do
        byte = current_byte? || return
        case byte
        when 0x20_u8, 0x09_u8, 0x0a_u8, 0x0d_u8
          consume_ascii(byte)
        else
          return
        end
      end
    end

    @[AlwaysInline]
    private def enforce_stream_byte : Nil
      state = @resource_limits || return
      limit = state.byte_limit || return
      if @stream_offset >= limit
        raise_stream_byte_limit(state, limit, @stream_line, @stream_column)
      end
    end

    @[AlwaysInline]
    private def enforce_stream_token_byte : Nil
      limit = max_token_bytes || return
      if @stream_offset - @token_offset >= limit
        raise_error("token exceeds max_token_bytes of #{limit}", @token_offset)
      end
    end

    private def raise_stream_byte_limit(state : ResourceLimitState, position : Int64,
                                        line : Int64, column : Int64) : NoReturn
      message = case state.byte_kind
                when .document?
                  limit = state.max_document_bytes || raise "missing document byte limit"
                  "document exceeds max_document_bytes of #{limit}"
                when .typed_value?
                  limit = state.max_typed_value_bytes || raise "missing typed-value byte limit"
                  "typed value exceeds max_typed_value_bytes of #{limit}"
                else
                  raise "unknown byte limit kind"
                end
      raise ParseError.new(message, position, line, column)
    end

    private def token_bytes : Bytes
      if @token_uses_scratch
        @token.to_slice[0, @token_length]
      else
        @input_buffer[@token_buffer_start, @token_length]
      end
    end

    private def token_bytes_for_error : Bytes
      flush_token_span
      @token_length = @token.bytesize
      @token.to_slice
    end

    private def digit?(byte : UInt8) : Bool
      0x30_u8 <= byte <= 0x39_u8
    end

    private def nonzero_digit?(byte : UInt8) : Bool
      0x31_u8 <= byte <= 0x39_u8
    end

    private def hex_value(byte : UInt8) : Int32
      if 0x30_u8 <= byte <= 0x39_u8
        (byte - 0x30_u8).to_i32
      elsif 0x61_u8 <= byte <= 0x66_u8
        (byte - 0x61_u8 + 10).to_i32
      elsif 0x41_u8 <= byte <= 0x46_u8
        (byte - 0x41_u8 + 10).to_i32
      else
        -1
      end
    end
  end

  class PullParser
    # Creates a streaming pull parser. The input remains owned by the caller and
    # is not closed by the parser. `max_token_bytes` limits each raw string or
    # number in the decoded stream.
    def self.new(source : IO, *, buffer_size : Int = 32 * 1024,
                 max_nesting : Int = MAX_NESTING, cache_keys : Bool = false,
                 max_token_bytes : Int? = nil,
                 limits : Limits = Limits::DEFAULT)
      StreamingPullParser.new(
        source,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        max_token_bytes: max_token_bytes,
        limits: limits
      )
    end
  end
end

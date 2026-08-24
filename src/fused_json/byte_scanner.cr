module FusedJSON
  # Raised when the input is not valid strict JSON.
  class ParseError < JSON::ParseException
    getter byte_offset : Int64

    def initialize(message : String, @byte_offset : Int64, line_number : Int64, column_number : Int64)
      super(message, line_number, column_number)
    end
  end

  # Shared byte cursor and scalar decoder for the tree and pull parsers.
  #
  # Structural traversal intentionally remains in the concrete parsers so the
  # recursive tree builder can keep its specialized fast path.
  private abstract class ByteScanner
    MAX_NESTING = Limits::DEFAULT_MAX_NESTING

    struct NumberToken
      getter start : Int32
      getter finish : Int32
      getter negative : Bool

      def initialize(@start : Int32, @finish : Int32, @negative : Bool, @floating : Bool)
      end

      def floating? : Bool
        @floating
      end
    end

    @bytes : Bytes
    @size : Int32
    @pos : Int32
    @max_nesting : Int32
    @limits_active : Bool
    @key_pool : StringPool?
    # Retains the source directly in default mode. When limits are active, the
    # state occupies the same slot and retains the source through its anchor.
    @source_or_limits : String | ResourceLimitState

    def initialize(source : String, *, max_nesting : Int = MAX_NESTING,
                   cache_keys : Bool = false, limits : Limits = Limits::DEFAULT,
                   max_token_bytes : Int? = nil)
      unless max_nesting > 0 && max_nesting <= MAX_NESTING
        raise ArgumentError.new("max_nesting must be between 1 and #{MAX_NESTING}")
      end
      if (token_limit = max_token_bytes) && !(token_limit > 0 && token_limit <= Int32::MAX)
        raise ArgumentError.new("max_token_bytes must be between 1 and #{Int32::MAX}")
      end

      @bytes = source.to_slice
      @size = @bytes.size
      @pos = 0
      @max_nesting = Math.min(max_nesting.to_i64, limits.max_nesting.to_i64).to_i32
      @key_pool = StringPool.new if cache_keys
      effective_token_limit = if token_limit = max_token_bytes
                                configured = limits.max_token_bytes
                                configured ? Math.min(token_limit.to_i64, configured.to_i64).to_i32 : token_limit.to_i32
                              else
                                limits.max_token_bytes
                              end
      if ResourceLimitState.required?(limits, effective_token_limit)
        @source_or_limits = ResourceLimitState.new(
          source,
          limits,
          max_token_bytes: effective_token_limit
        )
        @limits_active = true
      else
        @source_or_limits = source
        @limits_active = false
      end
    end

    @[AlwaysInline]
    protected def resource_limits : ResourceLimitState?
      @source_or_limits.as?(ResourceLimitState)
    end

    protected def parse_string(*, key : Bool = false) : String
      if max_token_bytes || resource_byte_limit?
        start = @pos
        escaped = scan_string
        return materialize_string(start, @pos, escaped, key: key)
      end

      @pos += 1 # opening quote
      start = @pos

      loop do
        raise_error("unterminated string") if eof?

        byte = @bytes[@pos]
        if byte == 0x22_u8 # "
          value = if key && @key_pool
                    cache_key(@bytes.to_unsafe + start, @pos - start, (start - 1).to_i64)
                  else
                    String.new(@bytes.to_unsafe + start, @pos - start)
                  end
          @pos += 1
          return value
        elsif byte == 0x5c_u8 # \
          return parse_escaped_string(start, key)
        elsif byte < 0x20_u8
          raise_error("unescaped control byte in string")
        elsif byte < 0x80_u8
          @pos = ASCIIStringScanner.find_special(@bytes, @pos, @size)
        else
          @pos += utf8_sequence_length(@pos)
        end
      end
    end

    # Preserves the pre-limits scalar path for callers that decide once, at
    # their entry point, that no token or extended resource limit is active.
    protected def parse_string_unlimited(*, key : Bool = false) : String
      @pos += 1 # opening quote
      start = @pos

      loop do
        raise_error("unterminated string") if eof?

        byte = @bytes[@pos]
        if byte == 0x22_u8 # "
          value = if key && (pool = @key_pool)
                    pool.get(@bytes.to_unsafe + start, @pos - start)
                  else
                    String.new(@bytes.to_unsafe + start, @pos - start)
                  end
          @pos += 1
          return value
        elsif byte == 0x5c_u8 # \
          return parse_escaped_string_unlimited(start, key)
        elsif byte < 0x20_u8
          raise_error("unescaped control byte in string")
        elsif byte < 0x80_u8
          @pos = ASCIIStringScanner.find_special(@bytes, @pos, @size)
        else
          @pos += utf8_sequence_length(@pos)
        end
      end
    end

    # Validates and consumes a string without constructing its decoded value.
    # Returns whether the source token contained an escape.
    protected def scan_string : Bool
      return scan_string_unlimited unless max_token_bytes || resource_byte_limit?

      scan_string_limited
    end

    protected def scan_string_unlimited : Bool
      @pos += 1 # opening quote
      escaped = false

      loop do
        raise_error("unterminated string") if eof?

        byte = @bytes[@pos]
        if byte == 0x22_u8 # "
          @pos += 1
          return escaped
        elsif byte == 0x5c_u8 # \
          escaped = true
          read_escape_codepoint
        elsif byte < 0x20_u8
          raise_error("unescaped control byte in string")
        elsif byte < 0x80_u8
          @pos = ASCIIStringScanner.find_special(@bytes, @pos, @size)
        else
          @pos += utf8_sequence_length(@pos)
        end
      end
    end

    private def scan_string_limited : Bool
      token_start = @pos
      enforce_string_byte_available(token_start)
      @pos += 1 # opening quote
      escaped = false

      loop do
        enforce_string_byte_available(token_start)
        raise_error("unterminated string") if eof?

        byte = @bytes[@pos]
        if byte == 0x22_u8 # "
          @pos += 1
          return escaped
        elsif byte == 0x5c_u8 # \
          escaped = true
          read_escape_codepoint_limited(token_start)
        elsif byte < 0x20_u8
          raise_error("unescaped control byte in string")
        elsif byte < 0x80_u8
          @pos = ASCIIStringScanner.find_special(@bytes, @pos, string_scan_limit(token_start))
        else
          scan_utf8_sequence_limited(token_start)
        end
      end
    end

    # Copies or decodes a previously validated string token.
    protected def materialize_string(start : Int32, finish : Int32, escaped : Bool, *, key : Bool) : String
      unless escaped
        content_start = start + 1
        content_size = finish - content_start - 1
        if key && @key_pool
          return cache_key(@bytes.to_unsafe + content_start, content_size, start.to_i64)
        end
        return String.new(@bytes.to_unsafe + content_start, content_size)
      end

      saved_position = @pos
      begin
        content_start = start + 1
        @pos = content_start
        while @bytes[@pos] != 0x5c_u8 # first validated escape
          @pos += 1
        end
        parse_escaped_string(content_start, key)
      ensure
        @pos = saved_position
      end
    end

    @[NoInline]
    private def materialize_cached_unescaped_string(start : Int32, content_start : Int32,
                                                    content_size : Int32) : String
      cache_key(@bytes.to_unsafe + content_start, content_size, start.to_i64)
    end

    protected def scan_number : NumberToken
      return scan_number_unlimited unless max_token_bytes || resource_byte_limit?

      scan_number_limited
    end

    private def scan_number_limited : NumberToken
      start = @pos
      byte = limited_number_byte? || raise_error("invalid number")
      negative = byte == 0x2d_u8
      if negative
        consume_number_byte(start)
        byte = limited_number_byte? || raise_error("expected digit after '-'")
      end

      if byte == 0x30_u8
        consume_number_byte(start)
        if (following = limited_number_byte?) && digit?(following)
          raise_error("leading zero in number")
        end
      elsif nonzero_digit?(byte)
        while (digit = limited_number_byte?) && digit?(digit)
          consume_number_byte(start)
        end
      else
        raise_error("invalid number")
      end

      floating = false
      if limited_number_byte? == 0x2e_u8 # .
        floating = true
        consume_number_byte(start)
        digit = limited_number_byte?
        raise_error("expected digit after decimal point") unless digit && digit?(digit)
        while (digit = limited_number_byte?) && digit?(digit)
          consume_number_byte(start)
        end
      end

      if (exponent = limited_number_byte?) && (exponent == 0x65_u8 || exponent == 0x45_u8) # e/E
        floating = true
        consume_number_byte(start)
        if (sign = limited_number_byte?) && (sign == 0x2b_u8 || sign == 0x2d_u8)
          consume_number_byte(start)
        end
        digit = limited_number_byte?
        raise_error("expected digit in exponent") unless digit && digit?(digit)
        while (digit = limited_number_byte?) && digit?(digit)
          consume_number_byte(start)
        end
      end

      NumberToken.new(start, @pos, negative, floating)
    end

    protected def read_number : Int64 | Float64
      token = scan_number
      token.floating? ? number_to_float64(token) : number_to_int64(token)
    end

    # The recursive tree builder is the only caller. Keep its number scan
    # inline without forcing the same large body into pull-parser event code.
    @[AlwaysInline]
    protected def read_number_unlimited : Int64 | Float64
      start = @pos
      negative = consume_if_unlimited(0x2d_u8)
      raise_error("expected digit after '-'") if eof?

      if current_byte == 0x30_u8
        @pos += 1
        raise_error("leading zero in number") if !eof? && digit?(current_byte)
      elsif nonzero_digit?(current_byte)
        @pos += 1
        while !eof? && digit?(current_byte)
          @pos += 1
        end
      else
        raise_error("invalid number")
      end

      floating = false
      if consume_if_unlimited(0x2e_u8) # .
        floating = true
        raise_error("expected digit after decimal point") if eof? || !digit?(current_byte)
        while !eof? && digit?(current_byte)
          @pos += 1
        end
      end

      if !eof? && (current_byte == 0x65_u8 || current_byte == 0x45_u8) # e/E
        floating = true
        @pos += 1
        @pos += 1 if !eof? && (current_byte == 0x2b_u8 || current_byte == 0x2d_u8)
        raise_error("expected digit in exponent") if eof? || !digit?(current_byte)
        while !eof? && digit?(current_byte)
          @pos += 1
        end
      end

      token = NumberToken.new(start, @pos, negative, floating)
      token.floating? ? number_to_float64(token) : number_to_int64(token)
    end

    protected def number_to_float64(token : NumberToken) : Float64
      Float64Decoder.parse?(@bytes, token.start, token.finish) ||
        raise_error("number is outside Float64 range", token.start)
    end

    protected def number_to_int64(token : NumberToken) : Int64
      limit = token.negative ? 9_223_372_036_854_775_808_u64 : 9_223_372_036_854_775_807_u64
      value = 0_u64
      index = token.negative ? token.start + 1 : token.start

      while index < token.finish
        digit = (@bytes[index] - 0x30_u8).to_u64
        raise_error("integer is outside Int64 range", token.start) if value > (limit - digit) // 10_u64
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
      String.new(@bytes.to_unsafe + token.start, token.finish - token.start)
    end

    protected def consume_literal(literal : String) : Nil
      literal.each_byte do |expected|
        enforce_available_byte
        raise_error("invalid literal") if eof? || current_byte != expected
        advance_byte
      end
    end

    protected def consume_literal_unlimited(literal : String) : Nil
      literal.each_byte do |expected|
        raise_error("invalid literal") if eof? || current_byte != expected
        @pos += 1
      end
    end

    protected def skip_whitespace : Nil
      while @pos < @size
        case @bytes[@pos]
        when 0x20_u8, 0x09_u8, 0x0a_u8, 0x0d_u8
          @pos += 1
        else
          break
        end
      end
      enforce_consumed_bytes
    end

    @[AlwaysInline]
    protected def skip_whitespace_unlimited : Nil
      while @pos < @size
        case @bytes[@pos]
        when 0x20_u8, 0x09_u8, 0x0a_u8, 0x0d_u8
          @pos += 1
        else
          break
        end
      end
    end

    protected def consume_if(byte : UInt8) : Bool
      if @pos < @size && @bytes[@pos] == byte
        @pos += 1
        enforce_consumed_bytes
        true
      else
        false
      end
    end

    @[AlwaysInline]
    protected def consume_if_unlimited(byte : UInt8) : Bool
      if @pos < @size && @bytes[@pos] == byte
        @pos += 1
        true
      else
        false
      end
    end

    @[AlwaysInline]
    protected def current_byte : UInt8
      @bytes[@pos]
    end

    protected def current_byte? : UInt8?
      @bytes[@pos]? if @pos < @size
    end

    protected def current_offset : Int64
      @pos.to_i64
    end

    protected def advance_byte : Nil
      @pos += 1
      enforce_consumed_bytes
    end

    protected def advance_byte_unlimited : Nil
      @pos += 1
    end

    protected def prepare_string_token : Nil
    end

    protected def token_position : Int32
      @pos
    end

    protected def record_event_position : Nil
    end

    protected def release_token : Nil
    end

    protected def eof? : Bool
      @pos >= @size
    end

    protected def raise_error(message : String) : NoReturn
      raise_error(message, current_offset)
    end

    protected def raise_error(message : String, position : Int32) : NoReturn
      raise_error(message, position.to_i64)
    end

    protected def raise_error(message : String, position : Int64) : NoReturn
      line, column = location_at(position)
      raise ParseError.new(message, position, line, column)
    end

    @[AlwaysInline]
    protected def enforce_available_byte : Nil
      state = resource_limits || return
      limit = state.byte_limit || return
      if current_offset >= limit && @pos < @size
        raise_byte_limit(state, limit)
      end
    end

    @[AlwaysInline]
    protected def enforce_consumed_bytes : Nil
      state = resource_limits || return
      limit = state.byte_limit || return
      raise_byte_limit(state, limit) if current_offset > limit
    end

    @[AlwaysInline]
    protected def record_value : Nil
      state = resource_limits || return
      unless state.record_value?
        raise_error("document exceeds max_total_values of #{state.max_total_values}", current_offset)
      end
    end

    @[AlwaysInline]
    protected def enter_limit_container(*, object : Bool) : Nil
      resource_limits.try &.enter_container(object)
    end

    @[AlwaysInline]
    protected def leave_limit_container : Nil
      resource_limits.try &.leave_container
    end

    @[AlwaysInline]
    protected def record_container_entry : Nil
      state = resource_limits || return
      unless state.record_entry?
        raise_error("container exceeds max_container_entries of #{state.max_container_entries}", current_offset)
      end
    end

    protected def enforce_duplicate_key(key : String, position : Int64) : Nil
      state = resource_limits || return
      raise_error("duplicate object key", position) if state.duplicate_key?(key)
    end

    @[AlwaysInline]
    protected def duplicate_keys? : Bool
      resource_limits.try(&.duplicate_keys?) || false
    end

    protected def begin_typed_value_limit(start : Int64) : Bool
      state = resource_limits || return false
      return false unless state.max_typed_value_bytes
      state.begin_typed_value(start)
      enforce_consumed_bytes
      true
    end

    protected def end_typed_value_limit : Nil
      resource_limits.try &.end_typed_value
    end

    @[AlwaysInline]
    protected def max_token_bytes : Int32?
      resource_limits.try &.max_token_bytes
    end

    protected def location_at(position : Int64) : Tuple(Int64, Int64)
      line = 1_i64
      column = 1_i64
      index = 0
      limit = Math.min(position, @size.to_i64).to_i32
      while index < limit
        byte = @bytes[index]
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

      {line, column}
    end

    private def parse_escaped_string(start : Int32, key : Bool) : String
      prefix_size = @pos - start
      initial_capacity = prefix_size <= Int32::MAX - 16 ? prefix_size + 16 : prefix_size
      builder = String::Builder.new(initial_capacity)
      builder.write(@bytes[start, prefix_size])

      loop do
        raise_error("unterminated string") if eof?

        case @bytes[@pos]
        when 0x22_u8 # "
          @pos += 1
          value = builder.to_s
          return key && @key_pool ? cache_key(value, (start - 1).to_i64) : value
        when 0x5c_u8 # \
          append_escape(builder)
        else
          segment_start = @pos
          while @pos < @size
            byte = @bytes[@pos]
            break if byte == 0x22_u8 || byte == 0x5c_u8
            raise_error("unescaped control byte in string") if byte < 0x20_u8

            if byte < 0x80_u8
              @pos += 1
            else
              @pos += utf8_sequence_length(@pos)
            end
          end
          builder.write(@bytes[segment_start, @pos - segment_start])
        end
      end
    end

    private def parse_escaped_string_unlimited(start : Int32, key : Bool) : String
      prefix_size = @pos - start
      initial_capacity = prefix_size <= Int32::MAX - 16 ? prefix_size + 16 : prefix_size
      builder = String::Builder.new(initial_capacity)
      builder.write(@bytes[start, prefix_size])

      loop do
        raise_error("unterminated string") if eof?

        case @bytes[@pos]
        when 0x22_u8 # "
          @pos += 1
          value = builder.to_s
          return key && (pool = @key_pool) ? pool.get(value) : value
        when 0x5c_u8 # \
          append_escape(builder)
        else
          segment_start = @pos
          while @pos < @size
            byte = @bytes[@pos]
            break if byte == 0x22_u8 || byte == 0x5c_u8
            raise_error("unescaped control byte in string") if byte < 0x20_u8

            if byte < 0x80_u8
              @pos += 1
            else
              @pos += utf8_sequence_length(@pos)
            end
          end
          builder.write(@bytes[segment_start, @pos - segment_start])
        end
      end
    end

    protected def scan_number_unlimited : NumberToken
      start = @pos
      negative = consume_if_unlimited(0x2d_u8)
      raise_error("expected digit after '-'") if eof?

      if current_byte == 0x30_u8
        @pos += 1
        raise_error("leading zero in number") if !eof? && digit?(current_byte)
      elsif nonzero_digit?(current_byte)
        @pos += 1
        while !eof? && digit?(current_byte)
          @pos += 1
        end
      else
        raise_error("invalid number")
      end

      floating = false
      if consume_if_unlimited(0x2e_u8) # .
        floating = true
        raise_error("expected digit after decimal point") if eof? || !digit?(current_byte)
        while !eof? && digit?(current_byte)
          @pos += 1
        end
      end

      if !eof? && (current_byte == 0x65_u8 || current_byte == 0x45_u8) # e/E
        floating = true
        @pos += 1
        @pos += 1 if !eof? && (current_byte == 0x2b_u8 || current_byte == 0x2d_u8)
        raise_error("expected digit in exponent") if eof? || !digit?(current_byte)
        while !eof? && digit?(current_byte)
          @pos += 1
        end
      end

      NumberToken.new(start, @pos, negative, floating)
    end

    private def append_escape(builder : String::Builder) : Nil
      codepoint = read_escape_codepoint
      if codepoint <= 0x7f
        builder.write_byte(codepoint.to_u8)
      else
        builder << codepoint.unsafe_chr
      end
    end

    private def read_escape_codepoint : Int32
      slash_pos = @pos
      @pos += 1
      raise_error("unterminated string escape", slash_pos) if eof?

      case byte = @bytes[@pos]
      when 0x22_u8, 0x5c_u8, 0x2f_u8 # ", \, /
        @pos += 1
        byte.to_i32
      when 0x62_u8 # b
        @pos += 1
        0x08
      when 0x66_u8 # f
        @pos += 1
        0x0c
      when 0x6e_u8 # n
        @pos += 1
        0x0a
      when 0x72_u8 # r
        @pos += 1
        0x0d
      when 0x74_u8 # t
        @pos += 1
        0x09
      when 0x75_u8 # u
        @pos += 1
        codepoint = read_hex4

        if 0xd800 <= codepoint <= 0xdbff
          unless remaining_at_least?(6) && @bytes[@pos] == 0x5c_u8 && @bytes[@pos + 1] == 0x75_u8
            raise_error("high surrogate must be followed by a low surrogate")
          end
          @pos += 2
          low = read_hex4
          raise_error("invalid low surrogate") unless 0xdc00 <= low <= 0xdfff
          codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00)
        elsif 0xdc00 <= codepoint <= 0xdfff
          raise_error("unexpected low surrogate")
        end

        codepoint
      else
        raise_error("invalid string escape", slash_pos)
      end
    end

    private def read_escape_codepoint_limited(token_start : Int32) : Int32
      slash_pos = @pos
      enforce_string_byte_available(token_start)
      @pos += 1
      enforce_string_byte_available(token_start)
      raise_error("unterminated string escape", slash_pos) if eof?

      byte = @bytes[@pos]
      @pos += 1
      case byte
      when 0x22_u8, 0x5c_u8, 0x2f_u8 # ", \, /
        byte.to_i32
      when 0x62_u8 # b
        0x08
      when 0x66_u8 # f
        0x0c
      when 0x6e_u8 # n
        0x0a
      when 0x72_u8 # r
        0x0d
      when 0x74_u8 # t
        0x09
      when 0x75_u8 # u
        codepoint = read_hex4_limited(token_start)

        if 0xd800 <= codepoint <= 0xdbff
          pair_position = @pos
          slash = next_string_token_byte(token_start)
          u = next_string_token_byte(token_start)
          unless slash == 0x5c_u8 && u == 0x75_u8
            raise_error("high surrogate must be followed by a low surrogate", pair_position)
          end
          low = read_hex4_limited(token_start)
          raise_error("invalid low surrogate") unless 0xdc00 <= low <= 0xdfff
          codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00)
        elsif 0xdc00 <= codepoint <= 0xdfff
          raise_error("unexpected low surrogate")
        end

        codepoint
      else
        raise_error("invalid string escape", slash_pos)
      end
    end

    private def read_hex4_limited(token_start : Int32) : Int32
      start = @pos
      value = 0
      4.times do
        byte = next_string_token_byte(token_start) || raise_error("incomplete unicode escape", start)
        digit = hex_value(byte)
        raise_error("invalid hex digit in unicode escape", @pos - 1) if digit < 0
        value = (value << 4) | digit
      end
      value
    end

    private def read_hex4 : Int32
      raise_error("incomplete unicode escape") unless remaining_at_least?(4)

      value = 0
      4.times do
        byte = @bytes[@pos]
        digit = hex_value(byte)
        raise_error("invalid hex digit in unicode escape") if digit < 0
        value = (value << 4) | digit
        @pos += 1
      end
      value
    end

    private def utf8_sequence_length(position : Int32) : Int32
      first = @bytes[position]

      if 0xc2_u8 <= first <= 0xdf_u8
        require_continuation(position + 1)
        2
      elsif first == 0xe0_u8
        require_byte_range(position + 1, 0xa0_u8, 0xbf_u8)
        require_continuation(position + 2)
        3
      elsif (0xe1_u8 <= first <= 0xec_u8) || (0xee_u8 <= first <= 0xef_u8)
        require_continuation(position + 1)
        require_continuation(position + 2)
        3
      elsif first == 0xed_u8
        require_byte_range(position + 1, 0x80_u8, 0x9f_u8)
        require_continuation(position + 2)
        3
      elsif first == 0xf0_u8
        require_byte_range(position + 1, 0x90_u8, 0xbf_u8)
        require_continuation(position + 2)
        require_continuation(position + 3)
        4
      elsif 0xf1_u8 <= first <= 0xf3_u8
        require_continuation(position + 1)
        require_continuation(position + 2)
        require_continuation(position + 3)
        4
      elsif first == 0xf4_u8
        require_byte_range(position + 1, 0x80_u8, 0x8f_u8)
        require_continuation(position + 2)
        require_continuation(position + 3)
        4
      else
        raise_error("invalid UTF-8 in string", position)
      end
    end

    private def scan_utf8_sequence_limited(token_start : Int32) : Nil
      first = @bytes[@pos]
      case first
      when 0xc2_u8..0xdf_u8
        @pos += 1
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
      when 0xe0_u8
        @pos += 1
        consume_utf8_continuation_limited(token_start, 0xa0_u8, 0xbf_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
      when 0xe1_u8..0xec_u8, 0xee_u8..0xef_u8
        @pos += 1
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
      when 0xed_u8
        @pos += 1
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0x9f_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
      when 0xf0_u8
        @pos += 1
        consume_utf8_continuation_limited(token_start, 0x90_u8, 0xbf_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
      when 0xf1_u8..0xf3_u8
        @pos += 1
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
      when 0xf4_u8
        @pos += 1
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0x8f_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
        consume_utf8_continuation_limited(token_start, 0x80_u8, 0xbf_u8)
      else
        raise_error("invalid UTF-8 in string", @pos)
      end
    end

    private def consume_utf8_continuation_limited(token_start : Int32,
                                                  minimum : UInt8, maximum : UInt8) : Nil
      position = @pos
      byte = next_string_token_byte(token_start) || raise_error("incomplete UTF-8 sequence", position)
      raise_error("invalid UTF-8 in string", position) unless minimum <= byte <= maximum
    end

    private def require_continuation(position : Int32) : Nil
      require_byte_range(position, 0x80_u8, 0xbf_u8)
    end

    private def require_byte_range(position : Int32, minimum : UInt8, maximum : UInt8) : Nil
      raise_error("incomplete UTF-8 sequence", position) if position >= @size
      byte = @bytes[position]
      raise_error("invalid UTF-8 in string", position) unless minimum <= byte <= maximum
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

    private def digit?(byte : UInt8) : Bool
      0x30_u8 <= byte <= 0x39_u8
    end

    private def nonzero_digit?(byte : UInt8) : Bool
      0x31_u8 <= byte <= 0x39_u8
    end

    private def remaining_at_least?(count : Int32) : Bool
      @size - @pos >= count
    end

    private def next_string_token_byte(token_start : Int32) : UInt8?
      enforce_string_byte_available(token_start)
      return if eof?
      byte = @bytes[@pos]
      @pos += 1
      byte
    end

    private def string_scan_limit(token_start : Int32) : Int32
      limit = @size.to_i64
      if token_limit = max_token_bytes
        limit = Math.min(limit, token_start.to_i64 + token_limit)
      end
      if byte_limit = resource_limits.try(&.byte_limit)
        limit = Math.min(limit, byte_limit)
      end
      limit.to_i32
    end

    private def enforce_string_byte_available(token_start : Int32) : Nil
      return if eof?

      position = @pos.to_i64
      token_limit = max_token_bytes
      token_boundary = token_limit.try { |limit| token_start.to_i64 + limit }
      state = resource_limits
      byte_boundary = state.try(&.byte_limit)

      if state && byte_boundary && position >= byte_boundary &&
         (!token_boundary || byte_boundary <= token_boundary)
        raise_byte_limit(state, byte_boundary)
      end
      if token_limit && token_boundary && position >= token_boundary
        raise_error("token exceeds max_token_bytes of #{token_limit}", token_start)
      end
    end

    private def limited_number_byte? : UInt8?
      enforce_available_byte
      current_byte? unless eof?
    end

    private def consume_number_byte(token_start : Int32) : Nil
      if (limit = max_token_bytes) && @pos.to_i64 - token_start >= limit
        raise_error("token exceeds max_token_bytes of #{limit}", token_start)
      end
      @pos += 1
    end

    @[AlwaysInline]
    private def resource_byte_limit? : Bool
      !!resource_limits.try(&.byte_limit)
    end

    private def enforce_token_size(size : Int32, position : Int64) : Nil
      if (limit = max_token_bytes) && size > limit
        raise_error("token exceeds max_token_bytes of #{limit}", position)
      end
    end

    protected def cache_key(pointer : UInt8*, size : Int32, position : Int64) : String
      pool = @key_pool || raise "key cache is not enabled"
      if limit = resource_limits.try(&.max_cached_keys)
        if existing = pool.get?(pointer, size)
          return existing
        end
        if pool.size.to_i64 >= limit
          raise_error("key cache exceeds max_cached_keys of #{limit}", position)
        end
      end
      pool.get(pointer, size)
    end

    protected def cache_key(value : String, position : Int64) : String
      pool = @key_pool || raise "key cache is not enabled"
      if limit = resource_limits.try(&.max_cached_keys)
        if existing = pool.get?(value)
          return existing
        end
        if pool.size.to_i64 >= limit
          raise_error("key cache exceeds max_cached_keys of #{limit}", position)
        end
      end
      pool.get(value)
    end

    private def raise_byte_limit(state : ResourceLimitState, position : Int64) : NoReturn
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
      raise_error(message, position)
    end
  end
end

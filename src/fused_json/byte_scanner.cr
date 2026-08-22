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
    MAX_NESTING = 512

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
    @key_pool : StringPool?

    def initialize(@source : String, *, max_nesting : Int = MAX_NESTING, cache_keys : Bool = false)
      unless max_nesting > 0 && max_nesting <= MAX_NESTING
        raise ArgumentError.new("max_nesting must be between 1 and #{MAX_NESTING}")
      end

      @bytes = @source.to_slice
      @size = @bytes.size
      @pos = 0
      @max_nesting = max_nesting.to_i32
      @key_pool = StringPool.new if cache_keys
    end

    protected def parse_string(*, key : Bool = false) : String
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

    # Validates and consumes a string without constructing its decoded value.
    # Returns whether the source token contained an escape.
    protected def scan_string : Bool
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

    # Copies or decodes a previously validated string token.
    protected def materialize_string(start : Int32, finish : Int32, escaped : Bool, *, key : Bool) : String
      unless escaped
        content_start = start + 1
        content_size = finish - content_start - 1
        if key && (pool = @key_pool)
          return pool.get(@bytes.to_unsafe + content_start, content_size)
        end
        return String.new(@bytes.to_unsafe + content_start, content_size)
      end

      saved_position = @pos
      begin
        @pos = start
        parse_string(key: key)
      ensure
        @pos = saved_position
      end
    end

    protected def scan_number : NumberToken
      start = @pos
      negative = consume_if(0x2d_u8)
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
      if consume_if(0x2e_u8) # .
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

    protected def read_number : Int64 | Float64
      token = scan_number
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
    end

    protected def consume_if(byte : UInt8) : Bool
      if @pos < @size && @bytes[@pos] == byte
        @pos += 1
        true
      else
        false
      end
    end

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
  end
end

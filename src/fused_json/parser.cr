module FusedJSON
  # :nodoc:
  # A byte-oriented parser that builds `JSON::Any` values directly, without an
  # intermediate lexer token stream.
  class Parser < ByteScanner
    MAX_NESTING = ByteScanner::MAX_NESTING

    @depth : Int32

    def initialize(source : String, *, max_nesting : Int = MAX_NESTING,
                   cache_keys : Bool = false, limits : Limits = Limits::DEFAULT)
      super(source, max_nesting: max_nesting, cache_keys: cache_keys, limits: limits)
      @depth = 0
    end

    def parse : JSON::Any
      return parse_unlimited unless @limits_active

      skip_whitespace
      enforce_available_byte
      value = parse_value
      skip_whitespace
      enforce_available_byte
      raise_error("unexpected trailing content") unless eof?
      value
    end

    private def parse_unlimited : JSON::Any
      skip_whitespace_unlimited
      value = parse_value_unlimited
      skip_whitespace_unlimited
      raise_error("unexpected trailing content") unless eof?
      value
    end

    private def parse_value_unlimited : JSON::Any
      raise_error("expected a JSON value") if eof?

      case byte = current_byte
      when 0x22_u8 # "
        JSON::Any.new(parse_string_unlimited)
      when 0x5b_u8 # [
        parse_array_unlimited
      when 0x7b_u8 # {
        parse_object_unlimited
      when 0x6e_u8 # n
        consume_literal_unlimited("null")
        JSON::Any.new(nil)
      when 0x74_u8 # t
        consume_literal_unlimited("true")
        JSON::Any.new(true)
      when 0x66_u8 # f
        consume_literal_unlimited("false")
        JSON::Any.new(false)
      else
        if byte == 0x2d_u8 || digit?(byte)
          JSON::Any.new(read_number_unlimited)
        else
          raise_error("unexpected byte 0x#{byte.to_s(16)}")
        end
      end
    end

    private def parse_array_unlimited : JSON::Any
      enter_container
      @pos += 1
      skip_whitespace_unlimited

      values = Array(JSON::Any).new
      if consume_if_unlimited(0x5d_u8) # ]
        leave_container
        return JSON::Any.new(values)
      end

      loop do
        values << parse_value_unlimited
        skip_whitespace_unlimited

        case current_byte?
        when 0x2c_u8 # ,
          @pos += 1
          skip_whitespace_unlimited
          raise_error("trailing comma in array") if current_byte? == 0x5d_u8
        when 0x5d_u8 # ]
          @pos += 1
          leave_container
          return JSON::Any.new(values)
        else
          raise_error("expected ',' or ']' in array")
        end
      end
    end

    private def parse_object_unlimited : JSON::Any
      enter_container
      @pos += 1
      skip_whitespace_unlimited

      object = Hash(String, JSON::Any).new
      if consume_if_unlimited(0x7d_u8) # }
        leave_container
        return JSON::Any.new(object)
      end

      loop do
        raise_error("expected a string object key") unless current_byte? == 0x22_u8
        key = parse_string_unlimited(key: true)
        skip_whitespace_unlimited
        raise_error("expected ':' after object key") unless consume_if_unlimited(0x3a_u8)
        skip_whitespace_unlimited

        object[key] = parse_value_unlimited
        skip_whitespace_unlimited

        case current_byte?
        when 0x2c_u8 # ,
          @pos += 1
          skip_whitespace_unlimited
          raise_error("trailing comma in object") if current_byte? == 0x7d_u8
        when 0x7d_u8 # }
          @pos += 1
          leave_container
          return JSON::Any.new(object)
        else
          raise_error("expected ',' or '}' in object")
        end
      end
    end

    private def parse_value : JSON::Any
      raise_error("expected a JSON value") if eof?
      record_value

      case byte = current_byte
      when 0x22_u8 # "
        JSON::Any.new(parse_string)
      when 0x5b_u8 # [
        parse_array
      when 0x7b_u8 # {
        parse_object
      when 0x6e_u8 # n
        consume_literal("null")
        JSON::Any.new(nil)
      when 0x74_u8 # t
        consume_literal("true")
        JSON::Any.new(true)
      when 0x66_u8 # f
        consume_literal("false")
        JSON::Any.new(false)
      else
        if byte == 0x2d_u8 || digit?(byte)
          parse_number
        else
          raise_error("unexpected byte 0x#{byte.to_s(16)}")
        end
      end
    end

    private def parse_array : JSON::Any
      enter_container
      enter_limit_container(object: false)
      advance_byte
      skip_whitespace
      enforce_available_byte

      values = Array(JSON::Any).new
      if consume_if(0x5d_u8) # ]
        leave_container
        leave_limit_container
        return JSON::Any.new(values)
      end

      loop do
        record_container_entry
        values << parse_value
        skip_whitespace
        enforce_available_byte

        case current_byte?
        when 0x2c_u8 # ,
          advance_byte
          skip_whitespace
          enforce_available_byte
          raise_error("trailing comma in array") if current_byte? == 0x5d_u8
        when 0x5d_u8 # ]
          advance_byte
          leave_container
          leave_limit_container
          return JSON::Any.new(values)
        else
          raise_error("expected ',' or ']' in array")
        end
      end
    end

    private def parse_object : JSON::Any
      enter_container
      enter_limit_container(object: true)
      advance_byte
      skip_whitespace
      enforce_available_byte

      object = Hash(String, JSON::Any).new
      if consume_if(0x7d_u8) # }
        leave_container
        leave_limit_container
        return JSON::Any.new(object)
      end

      loop do
        record_container_entry
        raise_error("expected a string object key") unless current_byte? == 0x22_u8
        key_position = current_offset
        key = parse_string(key: true)
        enforce_duplicate_key(key, key_position)
        skip_whitespace
        enforce_available_byte
        raise_error("expected ':' after object key") unless consume_if(0x3a_u8)
        skip_whitespace
        enforce_available_byte

        object[key] = parse_value
        skip_whitespace
        enforce_available_byte

        case current_byte?
        when 0x2c_u8 # ,
          advance_byte
          skip_whitespace
          enforce_available_byte
          raise_error("trailing comma in object") if current_byte? == 0x7d_u8
        when 0x7d_u8 # }
          advance_byte
          leave_container
          leave_limit_container
          return JSON::Any.new(object)
        else
          raise_error("expected ',' or '}' in object")
        end
      end
    end

    private def parse_number : JSON::Any
      JSON::Any.new(read_number)
    end

    private def digit?(byte : UInt8) : Bool
      0x30_u8 <= byte <= 0x39_u8
    end

    private def enter_container : Nil
      @depth += 1
      raise_error("nesting exceeds #{@max_nesting}") if @depth > @max_nesting
    end

    private def leave_container : Nil
      @depth -= 1
    end
  end
end

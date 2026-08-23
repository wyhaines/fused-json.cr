module FusedJSON
  # Keeps streaming JSON::Any construction in its checked numeric domain while
  # public pull traversal remains range neutral until a numeric getter is used.
  private class DynamicStreamingPullParser < StreamingPullParser
    def initialize(input : IO, *, buffer_size : Int, max_nesting : Int,
                   cache_keys : Bool, max_token_bytes : Int?, limits : Limits)
      super(
        input,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        max_token_bytes: max_token_bytes,
        limits: limits,
        enforce_dynamic_numbers: true
      )
    end
  end

  # :nodoc:
  # Builds a standard `JSON::Any` tree from a caller-owned IO without first
  # loading the complete JSON document into a String. `max_token_bytes`
  # optionally limits each raw string or number in the decoded stream.
  class StreamingParser
    @pull : StreamingPullParser

    def initialize(input : IO, *, buffer_size : Int = StreamingPullParser::DEFAULT_BUFFER_SIZE,
                   max_nesting : Int = PullParser::MAX_NESTING, cache_keys : Bool = false,
                   max_token_bytes : Int? = nil,
                   limits : Limits = Limits::DEFAULT)
      @pull = DynamicStreamingPullParser.new(
        input,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        max_token_bytes: max_token_bytes,
        limits: limits
      )
    end

    def parse : JSON::Any
      value = read_value
      @pull.finish
      value
    end

    private def read_value : JSON::Any
      case @pull.kind
      when .null?
        JSON::Any.new(@pull.read_null)
      when .bool?
        JSON::Any.new(@pull.read_bool)
      when .int?
        JSON::Any.new(@pull.read_int)
      when .float?
        JSON::Any.new(@pull.read_float)
      when .string?
        JSON::Any.new(@pull.read_string)
      when .begin_array?
        read_array
      when .begin_object?
        read_object
      else
        line, column = @pull.location_i64
        raise ParseError.new(
          "expected a JSON value, found #{@pull.kind}",
          @pull.byte_offset,
          line,
          column
        )
      end
    end

    private def read_array : JSON::Any
      values = [] of JSON::Any
      @pull.read_begin_array
      until @pull.kind.end_array?
        values << read_value
      end
      @pull.read_end_array
      JSON::Any.new(values)
    end

    private def read_object : JSON::Any
      values = {} of String => JSON::Any
      @pull.read_begin_object
      until @pull.kind.end_object?
        key = @pull.read_object_key
        values[key] = read_value
      end
      @pull.read_end_object
      JSON::Any.new(values)
    end
  end
end

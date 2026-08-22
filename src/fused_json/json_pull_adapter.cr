# The raw-value replay methods in this file adapt Crystal's JSON::PullParser.
# They were modified to consume FusedJSON's native events and preserve exact
# numeric tokens. See THIRD_PARTY_NOTICES.md and LICENSES/Apache-2.0.txt.
module FusedJSON
  # Numeric tokens used by typed decoding keep their exact source range until
  # Crystal's target-type constructor decides how to interpret them.
  private class TypedPullParser < PullParser
    def initialize(source : String, *, max_nesting : Int, cache_keys : Bool)
      super(source, max_nesting: max_nesting, cache_keys: cache_keys, enforce_dynamic_numbers: false)
    end

    def raw_number_value : String
      super
    end
  end

  # Streaming typed decoding retains exact numeric tokens without forcing them
  # into the dynamic JSON::Any numeric domain.
  private class StreamingTypedPullParser < StreamingPullParser
    def initialize(source : IO, *, buffer_size : Int, max_nesting : Int,
                   cache_keys : Bool, max_token_bytes : Int?)
      super(
        source,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        max_token_bytes: max_token_bytes,
        enforce_dynamic_numbers: false
      )
    end

    def raw_number_value : String
      super
    end
  end

  # Shared nominal stdlib adapter specialized for one concrete native reader.
  private abstract class NativeJSONPullAdapter(N) < JSON::PullParser
    @native : N

    protected def initialize(@native : N, *, max_nesting : Int)
      super("")
      self.max_nesting = max_nesting.to_i32
      sync_kind
    end

    def int_value : Int64
      @native.int_value
    end

    def float_value : Float64
      @native.float_value
    end

    def string_value : String
      @native.string_value
    end

    def raw_value : String
      @native.raw_number_value
    end

    def read_next : JSON::PullParser::Kind
      @native.read_next
      sync_kind
      @kind
    end

    def read_object_key : String
      @native.read_object_key.tap { sync_kind }
    end

    def read_string : String
      @native.read_string.tap { sync_kind }
    end

    def read_raw : String
      case @kind
      when .null?
        read_next
        "null"
      when .bool?
        @bool_value.to_s.tap { read_next }
      when .int?, .float?
        raw_value.tap { read_next }
      when .string?
        string_value.to_json.tap { read_next }
      when .begin_array?, .begin_object?
        JSON.build { |json| read_raw(json) }
      else
        raise("expected a JSON value, found #{@kind}")
      end
    end

    def read_raw(json : JSON::Builder) : Nil
      case @kind
      when .null?
        json.null
        read_next
      when .bool?
        json.bool(@bool_value)
        read_next
      when .int?, .float?
        json.raw(raw_value)
        read_next
      when .string?
        json.string(read_string)
      when .begin_array?
        json.array do
          read_begin_array
          until kind.end_array?
            read_raw(json)
          end
          read_end_array
        end
      when .begin_object?
        json.object do
          read_begin_object
          until kind.end_object?
            key = read_object_key
            json.field(key) { read_raw(json) }
          end
          read_end_object
        end
      else
        raise("expected a JSON value, found #{@kind}")
      end
    end

    def skip : Nil
      @native.skip
      sync_kind
    end

    def location_i64 : Tuple(Int64, Int64)
      @native.location_i64
    end

    def location : Tuple(Int32, Int32)
      @native.location
    end

    def line_number_i64 : Int64
      location_i64[0]
    end

    def line_number : Int32
      location[0]
    end

    def column_number_i64 : Int64
      location_i64[1]
    end

    def column_number : Int32
      location[1]
    end

    def raise(message : String) : NoReturn
      line, column = @native.location_i64
      ::raise ParseError.new(message, @native.byte_offset, line, column)
    end

    def finish : Nil
      @native.finish
    end

    private def sync_kind : Nil
      @kind = case @native.kind
              when .null?         then JSON::PullParser::Kind::Null
              when .bool?         then JSON::PullParser::Kind::Bool
              when .int?          then JSON::PullParser::Kind::Int
              when .float?        then JSON::PullParser::Kind::Float
              when .string?       then JSON::PullParser::Kind::String
              when .begin_array?  then JSON::PullParser::Kind::BeginArray
              when .end_array?    then JSON::PullParser::Kind::EndArray
              when .begin_object? then JSON::PullParser::Kind::BeginObject
              when .end_object?   then JSON::PullParser::Kind::EndObject
              when .eof?          then JSON::PullParser::Kind::EOF
              else                     raise("unknown native pull-parser kind")
              end
      @bool_value = @native.bool_value if @kind.bool?
    end
  end

  # Adapts in-memory typed events to Crystal's nominal pull-parser type.
  private class JSONPullAdapter < NativeJSONPullAdapter(TypedPullParser)
    def initialize(source : String, *, max_nesting : Int, cache_keys : Bool)
      super(
        TypedPullParser.new(source, max_nesting: max_nesting, cache_keys: cache_keys),
        max_nesting: max_nesting
      )
    end
  end

  # Adapts streaming typed events without adding a union dispatch to the
  # existing in-memory path.
  private class StreamingJSONPullAdapter < NativeJSONPullAdapter(StreamingTypedPullParser)
    def initialize(source : IO, *, buffer_size : Int = StreamingPullParser::DEFAULT_BUFFER_SIZE,
                   max_nesting : Int, cache_keys : Bool, max_token_bytes : Int?)
      super(
        StreamingTypedPullParser.new(
          source,
          buffer_size: buffer_size,
          max_nesting: max_nesting,
          cache_keys: cache_keys,
          max_token_bytes: max_token_bytes
        ),
        max_nesting: max_nesting
      )
    end
  end
end

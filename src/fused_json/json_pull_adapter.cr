# The raw-value replay methods in this file adapt Crystal's JSON::PullParser.
# They were modified to consume FusedJSON's native events and preserve exact
# numeric tokens. See THIRD_PARTY_NOTICES.md and LICENSES/Apache-2.0.txt.
module FusedJSON
  # Numeric tokens used by typed decoding keep their exact source range until
  # Crystal's target-type constructor decides how to interpret them.
  private class TypedPullParser < PullParser
    def initialize(source : String, *, max_nesting : Int, cache_keys : Bool, limits : Limits)
      super(
        source,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        limits: limits,
        enforce_dynamic_numbers: false
      )
      begin_current_typed_value_limit
    end

    def raw_number_value : String
      super
    end
  end

  # Streaming typed decoding retains exact numeric tokens without forcing them
  # into the dynamic JSON::Any numeric domain.
  private class StreamingTypedPullParser < StreamingPullParser
    def initialize(source : IO, *, buffer_size : Int, max_nesting : Int,
                   cache_keys : Bool, max_token_bytes : Int?, limits : Limits)
      super(
        source,
        buffer_size: buffer_size,
        max_nesting: max_nesting,
        cache_keys: cache_keys,
        max_token_bytes: max_token_bytes,
        limits: limits,
        enforce_dynamic_numbers: false
      )
      begin_current_typed_value_limit
    end

    def raw_number_value : String
      super
    end
  end

  # Shared nominal stdlib adapter specialized for one concrete native reader.
  # This unbounded form serves whole-document `from_json` without cursor-boundary
  # bookkeeping on its hot path. Concrete factories duplicate a valid
  # initialized prototype so `super("")` runs only once per adapter class.
  private abstract class NativeJSONPullAdapter(N) < JSON::PullParser
    {% unless FusedJSON::PullParser::Kind::Null == JSON::PullParser::Kind::Null &&
                FusedJSON::PullParser::Kind::Bool == JSON::PullParser::Kind::Bool &&
                FusedJSON::PullParser::Kind::Int == JSON::PullParser::Kind::Int &&
                FusedJSON::PullParser::Kind::Float == JSON::PullParser::Kind::Float &&
                FusedJSON::PullParser::Kind::String == JSON::PullParser::Kind::String &&
                FusedJSON::PullParser::Kind::BeginArray == JSON::PullParser::Kind::BeginArray &&
                FusedJSON::PullParser::Kind::EndArray == JSON::PullParser::Kind::EndArray &&
                FusedJSON::PullParser::Kind::BeginObject == JSON::PullParser::Kind::BeginObject &&
                FusedJSON::PullParser::Kind::EndObject == JSON::PullParser::Kind::EndObject &&
                FusedJSON::PullParser::Kind::EOF == JSON::PullParser::Kind::EOF %}
      {% raise "native and standard JSON pull kinds must have matching values" %}
    {% end %}

    @native : N

    protected def initialize(@native : N, *, max_nesting : Int)
      super("")
      self.max_nesting = max_nesting.to_i32
      sync_kind
    end

    protected def reset_native(@native : N, *, max_nesting : Int) : self
      self.max_nesting = max_nesting.to_i32
      sync_kind
      self
    end

    def int_value : Int64
      @native.int_value
    end

    def bool_value : Bool
      @native.bool_value
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

    def read_bool : Bool
      expect_kind(JSON::PullParser::Kind::Bool)
      bool_value.tap { read_next }
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
        bool_value.to_s.tap { read_next }
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
        json.bool(bool_value)
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
      # Both enums are kept value-compatible by the compile-time check above.
      @kind = @native.kind.unsafe_as(JSON::PullParser::Kind)
    end
  end

  # Adapts an owned in-memory reader for whole-document typed decoding.
  private class JSONPullAdapter < NativeJSONPullAdapter(TypedPullParser)
    private PROTOTYPE_SOURCE = "null"

    def initialize(source : String, *, max_nesting : Int, cache_keys : Bool, limits : Limits)
      super(
        TypedPullParser.new(
          source,
          max_nesting: max_nesting,
          cache_keys: cache_keys,
          limits: limits
        ),
        max_nesting: max_nesting
      )
    end

    def self.build(source : String, *, max_nesting : Int,
                   cache_keys : Bool, limits : Limits) : self
      adapter = PROTOTYPE.dup
      adapter.reset_native(
        TypedPullParser.new(
          source,
          max_nesting: max_nesting,
          cache_keys: cache_keys,
          limits: limits
        ),
        max_nesting: max_nesting
      )
      adapter
    end

    private PROTOTYPE = new(
      PROTOTYPE_SOURCE,
      max_nesting: PullParser::MAX_NESTING,
      cache_keys: false,
      limits: Limits::DEFAULT
    )
  end

  # Adapts an owned streaming reader for whole-document typed decoding.
  private class StreamingJSONPullAdapter < NativeJSONPullAdapter(StreamingTypedPullParser)
    private PROTOTYPE_SOURCE = "null"

    def initialize(source : IO, *, buffer_size : Int = StreamingPullParser::DEFAULT_BUFFER_SIZE,
                   max_nesting : Int, cache_keys : Bool, max_token_bytes : Int?,
                   limits : Limits)
      super(
        StreamingTypedPullParser.new(
          source,
          buffer_size: buffer_size,
          max_nesting: max_nesting,
          cache_keys: cache_keys,
          max_token_bytes: max_token_bytes,
          limits: limits
        ),
        max_nesting: max_nesting
      )
    end

    def self.build(source : IO, *, buffer_size : Int = StreamingPullParser::DEFAULT_BUFFER_SIZE,
                   max_nesting : Int, cache_keys : Bool, max_token_bytes : Int?,
                   limits : Limits) : self
      adapter = PROTOTYPE.dup
      adapter.reset_native(
        StreamingTypedPullParser.new(
          source,
          buffer_size: buffer_size,
          max_nesting: max_nesting,
          cache_keys: cache_keys,
          max_token_bytes: max_token_bytes,
          limits: limits
        ),
        max_nesting: max_nesting
      )
      adapter
    end

    private PROTOTYPE = new(
      IO::Memory.new(PROTOTYPE_SOURCE),
      buffer_size: 1,
      max_nesting: PullParser::MAX_NESTING,
      cache_keys: false,
      max_token_bytes: nil,
      limits: Limits::DEFAULT
    )
  end

  # Adds a permanent one-value boundary only to adapters that borrow a public
  # native cursor. The existing whole-document adapters remain branch-free.
  private abstract class BoundedNativeJSONPullAdapter(N) < NativeJSONPullAdapter(N)
    @value_depth : Int32
    @value_complete : Bool
    @boundary_byte_offset : Int64
    @boundary_location : Tuple(Int64, Int64)?

    protected def initialize(native : N, *, max_nesting : Int)
      @value_depth = 0
      @value_complete = false
      @boundary_byte_offset = 0_i64
      @boundary_location = nil
      super(native, max_nesting: max_nesting)
      @bool_value = @native.bool_value if @kind.bool?
    end

    protected def reset_bounded(native : N, *, max_nesting : Int) : self
      @value_depth = 0
      @value_complete = false
      @boundary_byte_offset = 0_i64
      @boundary_location = nil
      reset_native(native, max_nesting: max_nesting)
      @bool_value = @native.bool_value if @kind.bool?
      self
    end

    def int_value : Int64
      ensure_value_open
      @native.int_value
    end

    def bool_value : Bool
      ensure_value_open
      @bool_value
    end

    def float_value : Float64
      ensure_value_open
      @native.float_value
    end

    def string_value : String
      ensure_value_open
      @native.string_value
    end

    def raw_value : String
      ensure_value_open
      @native.raw_number_value
    end

    def read_next : JSON::PullParser::Kind
      return @kind if @value_complete

      completes_value = case @kind
                        when .begin_array?, .begin_object?
                          @value_depth += 1
                          false
                        when .end_array?, .end_object?
                          @value_depth -= 1
                          @value_depth == 0
                        when .null?, .bool?, .int?, .float?, .string?
                          @value_depth == 0
                        when .eof?
                          false
                        end

      @native.read_next
      completes_value ? complete_value : sync_bounded_kind
      @kind
    end

    def read_object_key : String
      ensure_value_open
      @native.read_object_key.tap { sync_bounded_kind }
    end

    def read_string : String
      ensure_value_open
      expect_kind(JSON::PullParser::Kind::String)
      string_value.tap { read_next }
    end

    def read_raw : String
      ensure_value_open
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
      ensure_value_open
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
      ensure_value_open
      completes_value = @value_depth == 0
      @native.skip
      completes_value ? complete_value : sync_bounded_kind
    end

    def location_i64 : Tuple(Int64, Int64)
      return @native.location_i64 unless @value_complete
      if boundary = @boundary_location
        return boundary
      end

      @boundary_location = locate_boundary(@boundary_byte_offset)
    end

    def location : Tuple(Int32, Int32)
      line, column = location_i64
      {line.to_i32, column.to_i32}
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
      line, column = location_i64
      byte_offset = @value_complete ? @boundary_byte_offset : @native.byte_offset
      ::raise ParseError.new(message, byte_offset, line, column)
    end

    def finish_value : Nil
      return if @value_complete
      raise("typed constructor must consume exactly one value")
    end

    private def sync_bounded_kind : Nil
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

    private def complete_value : Nil
      @boundary_byte_offset = @native.byte_offset
      @boundary_location = capture_boundary_location
      @value_complete = true
      @kind = JSON::PullParser::Kind::EOF
    end

    private def ensure_value_open : Nil
      raise("typed constructor cannot consume more than one value") if @value_complete
    end

    protected abstract def capture_boundary_location : Tuple(Int64, Int64)?

    protected abstract def locate_boundary(byte_offset : Int64) : Tuple(Int64, Int64)
  end

  # Borrows an in-memory reader and exposes only its current value.
  private class BoundedJSONPullAdapter < BoundedNativeJSONPullAdapter(PullParser)
    @source_bytes : Bytes

    private PROTOTYPE_SOURCE = "null"
    private PROTOTYPE        = new(
      PullParser.new(PROTOTYPE_SOURCE),
      PROTOTYPE_SOURCE.to_slice,
      max_nesting: PullParser::MAX_NESTING
    )

    def initialize(native : PullParser, @source_bytes : Bytes, *, max_nesting : Int)
      super(native, max_nesting: max_nesting)
    end

    def self.borrow(native : PullParser, source_bytes : Bytes, *, max_nesting : Int) : self
      adapter = PROTOTYPE.dup
      adapter.reset(native, source_bytes, max_nesting: max_nesting)
      adapter
    end

    protected def reset(native : PullParser, @source_bytes : Bytes, *, max_nesting : Int) : self
      reset_bounded(native, max_nesting: max_nesting)
      self
    end

    protected def capture_boundary_location : Tuple(Int64, Int64)?
      nil
    end

    protected def locate_boundary(byte_offset : Int64) : Tuple(Int64, Int64)
      target = byte_offset.to_i32
      index = 0
      line = 1_i64
      column = 1_i64

      while index < target
        byte = @source_bytes[index]
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
          index += Math.min(width, target - index)
        end
      end

      {line, column}
    end
  end

  # Borrows a streaming reader and exposes only its current value.
  private class BoundedStreamingJSONPullAdapter < BoundedNativeJSONPullAdapter(StreamingPullParser)
    private PROTOTYPE = new(
      StreamingPullParser.new(IO::Memory.new("null"), buffer_size: 1),
      max_nesting: PullParser::MAX_NESTING
    )

    def initialize(native : StreamingPullParser, *, max_nesting : Int)
      super(native, max_nesting: max_nesting)
    end

    def self.borrow(native : StreamingPullParser, *, max_nesting : Int) : self
      adapter = PROTOTYPE.dup
      adapter.reset_bounded(native, max_nesting: max_nesting)
      adapter
    end

    protected def capture_boundary_location : Tuple(Int64, Int64)?
      @native.location_i64
    end

    protected def locate_boundary(byte_offset : Int64) : Tuple(Int64, Int64)
      @native.location_i64
    end
  end

  class PullParser
    # Decodes the complete value under the cursor and advances to its sibling.
    # Built-in scalar types use equivalent native reads; other types use
    # Crystal's standard `new(pull : JSON::PullParser)` constructor.
    def read(type : T.class) : T forall T
      ensure_typed_value
      begin_current_typed_value_limit
      {% if T == Nil || T == Bool || T == String || Number::Primitive.union_types.includes?(T) %}
        return read_typed_scalar(type) if typed_scalar_kind?(type)
      {% end %}
      adapter = BoundedJSONPullAdapter.borrow(self, @bytes, max_nesting: @max_nesting)
      value = T.new(adapter)
      adapter.finish_value
      value
    end

    # Consumes the current array and yields each element after decoding it
    # through `read(T)`. Values are not retained by the parser. The callback
    # must not advance this reader. A callback exception or early block exit
    # leaves the remainder unconsumed, after which the reader must be discarded.
    def read_array(type : T.class, & : T ->) : Nil forall T
      read_array do
        value = read(type)
        callback_cursor = {@kind, @byte_offset, @event_context_id}
        yield value
        unless callback_cursor == {@kind, @byte_offset, @event_context_id}
          raise_error("typed array callback must not advance the reader", @byte_offset)
        end
      end
    end

    private def ensure_typed_value : Nil
      if @object_key
        raise_error("cannot decode an object key as a typed value", @byte_offset)
      end

      case @kind
      when .null?, .bool?, .int?, .float?, .string?, .begin_array?, .begin_object?
      else
        raise_error("expected a JSON value, found #{@kind}", @byte_offset)
      end
    end

    @[AlwaysInline]
    private def typed_scalar_kind?(_type : Nil.class) : Bool
      @kind.null?
    end

    @[AlwaysInline]
    private def typed_scalar_kind?(_type : Bool.class) : Bool
      @kind.bool?
    end

    @[AlwaysInline]
    private def typed_scalar_kind?(_type : String.class) : Bool
      @kind.string?
    end

    {% for type in [Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32] %}
      @[AlwaysInline]
      private def typed_scalar_kind?(_type : {{ type }}.class) : Bool
        @kind.int?
      end
    {% end %}

    {% for type in [Int128, UInt64, UInt128, Float32, Float64] %}
      @[AlwaysInline]
      private def typed_scalar_kind?(_type : {{ type }}.class) : Bool
        @kind.int? || @kind.float?
      end
    {% end %}

    @[AlwaysInline]
    private def read_typed_scalar(_type : Nil.class) : Nil
      read_null
    end

    @[AlwaysInline]
    private def read_typed_scalar(_type : Bool.class) : Bool
      read_bool
    end

    @[AlwaysInline]
    private def read_typed_scalar(_type : String.class) : String
      read_string
    end

    {% for type, method in {
                             "Int8"    => "i8",
                             "Int16"   => "i16",
                             "Int32"   => "i32",
                             "Int64"   => "i64",
                             "Int128"  => "i128",
                             "UInt8"   => "u8",
                             "UInt16"  => "u16",
                             "UInt32"  => "u32",
                             "UInt64"  => "u64",
                             "UInt128" => "u128",
                           } %}
      private def read_typed_scalar(_type : {{ type.id }}.class) : {{ type.id }}
        location = location_i64
        value =
          {% if type == "UInt64" || type == "UInt128" || type == "Int128" %}
            read_raw_number
          {% else %}
            read_int
          {% end %}
        begin
          value.to_{{ method.id }}
        rescue ex : OverflowError | ArgumentError
          raise JSON::ParseException.new("Can't read {{ type.id }}", *location, ex)
        end
      end
    {% end %}

    @[AlwaysInline]
    private def read_typed_scalar(_type : Float32.class) : Float32
      if @kind.int?
        value = int_value.to_f32
        read_next
        value
      else
        read_float.to_f32
      end
    end

    @[AlwaysInline]
    private def read_typed_scalar(_type : Float64.class) : Float64
      if @kind.int?
        value = int_value.to_f64
        read_next
        value
      else
        read_float.to_f64
      end
    end
  end

  class StreamingPullParser
    # Uses native scalar reads or the streaming-specialized stdlib adapter.
    def read(type : T.class) : T forall T
      ensure_typed_value
      begin_current_typed_value_limit
      {% if T == Nil || T == Bool || T == String || Number::Primitive.union_types.includes?(T) %}
        return read_typed_scalar(type) if typed_scalar_kind?(type)
      {% end %}
      adapter = BoundedStreamingJSONPullAdapter.borrow(self, max_nesting: @max_nesting)
      value = T.new(adapter)
      adapter.finish_value
      value
    end
  end
end

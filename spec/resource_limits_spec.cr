require "./spec_helper"
require "./support/chunked_io"

private class ResourceLimitsRecord
  include JSON::Serializable

  getter id : Int32
  getter name : String
end

private class ResourceLimitsIdRecord
  include JSON::Serializable

  getter id : Int32
end

private class ResourceLimitsUnreadableIO < IO
  getter read_calls : Int32

  def initialize
    @read_calls = 0
  end

  def read(slice : Bytes) : Int32
    @read_calls += 1
    raise IO::Error.new("resource-limit validation must not read input")
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("ResourceLimitsUnreadableIO is read-only")
  end
end

private def resource_limit_offset(source : String, needle : String, occurrence = 0) : Int64
  offset = 0
  index = -1
  (occurrence + 1).times do
    index = source.index(needle, offset) || raise "missing #{needle.inspect} in resource-limit fixture"
    offset = index + needle.bytesize
  end
  index.to_i64
end

private def expect_resource_limit_error_at(offset : Int, & : -> T) : FusedJSON::ParseError forall T
  error = expect_raises(FusedJSON::ParseError) { yield }
  error.byte_offset.should eq(offset.to_i64)
  error
end

private def expect_serializable_limit_error_at(offset : Int, & : -> T) : JSON::SerializableError forall T
  error = expect_raises(JSON::SerializableError) { yield }
  cause = error.cause
  cause.should be_a(FusedJSON::ParseError)
  cause.as(FusedJSON::ParseError).byte_offset.should eq(offset.to_i64)
  error
end

private def resource_limit_stream(source : String) : StreamSpecSupport::ChunkedIO
  StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
end

private def expect_resource_limit_on_string_and_io(source : String, limits : FusedJSON::Limits,
                                                   offset : Int, message : String) : Nil
  error = expect_resource_limit_error_at(offset) do
    FusedJSON.load(source, limits: limits)
  end
  error.message.to_s.should contain(message)

  io = resource_limit_stream(source)
  error = expect_resource_limit_error_at(offset) do
    FusedJSON.load(io, buffer_size: 1, limits: limits)
  end
  error.message.to_s.should contain(message)
  io.closed_called.should be_false
end

describe FusedJSON::Limits do
  it "validates every limit at construction" do
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_nesting: 0) }
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_nesting: 513) }
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_token_bytes: 0) }
    expect_raises(ArgumentError) do
      FusedJSON::Limits.new(max_token_bytes: Int32::MAX.to_i64 + 1)
    end

    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_document_bytes: -1) }
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_typed_value_bytes: -1) }
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_total_values: -1) }
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_container_entries: -1) }
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_cached_keys: -1) }
    expect_raises(ArgumentError) { FusedJSON::Limits.new(max_document_bytes: UInt64::MAX) }

    FusedJSON::Limits.new(
      max_document_bytes: 0,
      max_typed_value_bytes: 0,
      max_total_values: 0,
      max_container_entries: 0,
      max_cached_keys: 0
    )
    FusedJSON::Limits.new(
      max_token_bytes: Int32::MAX,
      max_document_bytes: Int64::MAX,
      max_typed_value_bytes: Int64::MAX,
      max_total_values: Int64::MAX,
      max_container_entries: Int64::MAX,
      max_cached_keys: Int64::MAX
    )
  end

  it "validates legacy options before reading IO even when limits are present" do
    limits = FusedJSON::Limits.new(max_nesting: 2, max_token_bytes: 8)

    io = ResourceLimitsUnreadableIO.new
    expect_raises(ArgumentError) { FusedJSON.load(io, limits: limits, max_nesting: 0) }
    io.read_calls.should eq(0)

    io = ResourceLimitsUnreadableIO.new
    expect_raises(ArgumentError) { FusedJSON.parse(io, limits: limits, max_token_bytes: 0) }
    io.read_calls.should eq(0)

    io = ResourceLimitsUnreadableIO.new
    expect_raises(ArgumentError) do
      FusedJSON.from_json(io, Int32, limits: limits, max_nesting: 513)
    end
    io.read_calls.should eq(0)

    io = ResourceLimitsUnreadableIO.new
    expect_raises(ArgumentError) do
      FusedJSON::PullParser.new(io, limits: limits, max_token_bytes: Int64::MAX)
    end
    io.read_calls.should eq(0)
  end

  it "uses the smaller legacy and limits nesting constraint" do
    source = "[[0]]"
    exact = FusedJSON::Limits.new(max_nesting: 2)
    restrictive = FusedJSON::Limits.new(max_nesting: 1)

    FusedJSON.load(source, limits: exact, max_nesting: 2).should eq(JSON.parse(source))
    expect_resource_limit_error_at(1) do
      FusedJSON.load(source, limits: exact, max_nesting: 1)
    end
    expect_resource_limit_error_at(1) do
      FusedJSON.load(source, limits: restrictive, max_nesting: 2)
    end

    io = resource_limit_stream(source)
    pull = FusedJSON::PullParser.new(
      io,
      buffer_size: 1,
      limits: exact,
      max_nesting: 1
    )
    expect_resource_limit_error_at(1) do
      pull.skip
    end
    io.closed_called.should be_false
  end

  it "uses the smaller legacy and limits token constraint" do
    source = %q("abcd")
    exact = FusedJSON::Limits.new(max_token_bytes: source.bytesize)
    restrictive = FusedJSON::Limits.new(max_token_bytes: source.bytesize - 1)

    FusedJSON.load(source, limits: exact).as_s.should eq("abcd")
    expect_resource_limit_error_at(0) { FusedJSON.load(source, limits: restrictive) }

    io = resource_limit_stream(source)
    FusedJSON.load(
      io,
      buffer_size: 2,
      limits: exact,
      max_token_bytes: source.bytesize
    ).as_s.should eq("abcd")

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(0) do
      FusedJSON.load(
        io,
        buffer_size: 2,
        limits: exact,
        max_token_bytes: source.bytesize - 1
      )
    end

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(0) do
      FusedJSON.load(
        io,
        buffer_size: 2,
        limits: restrictive,
        max_token_bytes: source.bytesize
      )
    end
  end
end

describe "FusedJSON resource byte limits" do
  it "enforces the zero document boundary at the first byte" do
    limits = FusedJSON::Limits.new(max_document_bytes: 0)

    expect_resource_limit_error_at(0) { FusedJSON.load("null", limits: limits) }

    io = resource_limit_stream("null")
    expect_resource_limit_error_at(0) do
      FusedJSON.load(io, buffer_size: 1, limits: limits)
    end
    io.closed_called.should be_false
  end

  it "counts the complete decoded document for dynamic String and IO parsing" do
    source = " \n{\"x\":\"λ\"}\t"
    exact = FusedJSON::Limits.new(max_document_bytes: source.bytesize)
    short = FusedJSON::Limits.new(max_document_bytes: source.bytesize - 1)

    FusedJSON.load(source, limits: exact).should eq(JSON.parse(source))
    expect_resource_limit_error_at(source.bytesize - 1) do
      FusedJSON.load(source, limits: short)
    end

    io = resource_limit_stream(source)
    FusedJSON.parse(io, buffer_size: 2, limits: exact).should eq(JSON.parse(source))
    io.closed_called.should be_false

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(source.bytesize - 1) do
      FusedJSON.parse(io, buffer_size: 2, limits: short)
    end
    io.closed_called.should be_false
  end

  it "enforces document bytes while skipping nested values" do
    source = %q( [0,{"ignored":[1,2]}] )
    exact = FusedJSON::Limits.new(max_document_bytes: source.bytesize)

    pull = FusedJSON::PullParser.new(source, limits: exact)
    pull.skip
    pull.finish

    forbidden = resource_limit_offset(source, "2")
    pull = FusedJSON::PullParser.new(
      source,
      limits: FusedJSON::Limits.new(max_document_bytes: forbidden)
    )
    expect_resource_limit_error_at(forbidden) { pull.skip }

    io = resource_limit_stream(source)
    pull = FusedJSON::PullParser.new(
      io,
      buffer_size: 1,
      limits: FusedJSON::Limits.new(max_document_bytes: forbidden)
    )
    expect_resource_limit_error_at(forbidden) { pull.skip }
    io.closed_called.should be_false
  end

  it "applies document bytes to typed String and IO documents" do
    source = %q( {"id":7,"name":"Ada","ignored":[1,2]} )
    exact = FusedJSON::Limits.new(max_document_bytes: source.bytesize)
    short = FusedJSON::Limits.new(max_document_bytes: source.bytesize - 1)

    record = FusedJSON.from_json(source, ResourceLimitsRecord, limits: exact)
    {record.id, record.name}.should eq({7, "Ada"})

    returned = nil
    expect_resource_limit_error_at(source.bytesize - 1) do
      returned = FusedJSON.from_json(source, ResourceLimitsRecord, limits: short)
    end
    returned.should be_nil

    io = resource_limit_stream(source)
    record = FusedJSON.from_json(
      io,
      ResourceLimitsRecord,
      buffer_size: 1,
      limits: exact
    )
    {record.id, record.name}.should eq({7, "Ada"})

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(source.bytesize - 1) do
      FusedJSON.from_json(
        io,
        ResourceLimitsRecord,
        buffer_size: 1,
        limits: short
      )
    end
    io.closed_called.should be_false
  end

  it "counts transcoded UTF-8 output rather than source encoding bytes" do
    encoded = Bytes[0x22_u8, 0x63_u8, 0x61_u8, 0x66_u8, 0xe9_u8, 0x22_u8]

    accepted_io = IO::Memory.new(encoded)
    accepted_io.set_encoding("ISO-8859-1")
    pull = FusedJSON::PullParser.new(
      accepted_io,
      buffer_size: 1,
      limits: FusedJSON::Limits.new(max_document_bytes: 7)
    )
    pull.read_string.should eq("café")
    pull.finish

    rejected_io = IO::Memory.new(encoded)
    rejected_io.set_encoding("ISO-8859-1")
    expect_resource_limit_error_at(6) do
      FusedJSON::PullParser.new(
        rejected_io,
        buffer_size: 1,
        limits: FusedJSON::Limits.new(max_document_bytes: 6)
      )
    end
  end

  it "counts invalid trailing data before reporting its syntax" do
    error = expect_resource_limit_error_at(4) do
      FusedJSON.load(
        "null?",
        limits: FusedJSON::Limits.new(max_document_bytes: 4)
      )
    end
    error.message.to_s.should contain("max_document_bytes")
  end

  it "gives the first forbidden document byte precedence over later token or syntax errors" do
    token_at_document_boundary = FusedJSON::Limits.new(
      max_document_bytes: 5,
      max_token_bytes: 5
    )
    expect_resource_limit_on_string_and_io(
      %q("abcd"),
      token_at_document_boundary,
      5,
      "max_document_bytes"
    )

    expect_resource_limit_on_string_and_io(
      "1e",
      FusedJSON::Limits.new(max_document_bytes: 1),
      1,
      "max_document_bytes"
    )

    invalid_escape = %q("\x")
    {1, 2}.each do |limit|
      expect_resource_limit_on_string_and_io(
        invalid_escape,
        FusedJSON::Limits.new(max_document_bytes: limit),
        limit,
        "max_document_bytes"
      )
    end

    {
      "nuxx" => 2,
      "01"   => 1,
      "-x"   => 1,
      "1.x"  => 2,
    }.each do |source, limit|
      expect_resource_limit_on_string_and_io(
        source,
        FusedJSON::Limits.new(max_document_bytes: limit),
        limit,
        "max_document_bytes"
      )
    end

    invalid_utf8 = String.new(Bytes[0x22_u8, 0xc2_u8, 0x41_u8, 0x22_u8])
    expect_resource_limit_on_string_and_io(
      invalid_utf8,
      FusedJSON::Limits.new(max_document_bytes: 2),
      2,
      "max_document_bytes"
    )
  end

  it "reports a token limit reached before the document boundary" do
    limits = FusedJSON::Limits.new(max_document_bytes: 5, max_token_bytes: 4)
    expect_resource_limit_on_string_and_io(%q("abcd"), limits, 0, "max_token_bytes")
  end

  it "keeps token and document precedence independent of the IO buffer size" do
    sources = {"\"" + ("a" * 100) + "\"", "1" * 100}
    limits = FusedJSON::Limits.new(max_document_bytes: 50)

    sources.each do |source|
      {1, 8, 16, 32, 64, 128}.each do |buffer_size|
        io = IO::Memory.new(source)
        error = expect_resource_limit_error_at(0) do
          FusedJSON.load(
            io,
            buffer_size: buffer_size,
            max_token_bytes: 10,
            limits: limits
          )
        end
        error.message.to_s.should contain("max_token_bytes")
      end
    end
  end

  it "materializes escaped String values and keys under token and document limits" do
    source = %q({"id":7,"\u006eame":"line\n\u03bb"})
    expected_name = "line\nλ"
    escaped_value_token = %q("line\n\u03bb")
    token_limits = FusedJSON::Limits.new(max_token_bytes: escaped_value_token.bytesize)
    document_limits = FusedJSON::Limits.new(max_document_bytes: source.bytesize)

    FusedJSON.load(source, limits: token_limits).as_h["name"].as_s.should eq(expected_name)
    FusedJSON.from_json(source, ResourceLimitsRecord, limits: token_limits).name.should eq(expected_name)
    FusedJSON.load(source, limits: document_limits).as_h["name"].as_s.should eq(expected_name)
    FusedJSON.from_json(source, ResourceLimitsRecord, limits: document_limits).name.should eq(expected_name)

    key_source = %q({"\u0061":0})
    escaped_key_token = %q("\u0061")
    expect_resource_limit_error_at(1) do
      FusedJSON.load(
        key_source,
        limits: FusedJSON::Limits.new(max_token_bytes: escaped_key_token.bytesize - 1)
      )
    end
    expect_resource_limit_error_at(resource_limit_offset(source, escaped_value_token)) do
      FusedJSON.load(
        source,
        limits: FusedJSON::Limits.new(max_token_bytes: escaped_value_token.bytesize - 1)
      )
    end
  end

  it "materializes escaped keys and values inside a selected typed String span" do
    source = %q({"id":7,"\u006eame":"line\n\u03bb"})
    limits = FusedJSON::Limits.new(max_typed_value_bytes: source.bytesize)

    record = FusedJSON.from_json(source, ResourceLimitsRecord, limits: limits)
    {record.id, record.name}.should eq({7, "line\nλ"})

    pull = FusedJSON::PullParser.new("[#{source}]", limits: limits)
    pull.read_begin_array
    record = pull.read(ResourceLimitsRecord)
    {record.id, record.name}.should eq({7, "line\nλ"})
    pull.read_end_array
    pull.finish
  end

  it "limits each selected typed span without charging surrounding bytes" do
    source = " \n{\"id\":7, \"name\":\"Ada\"}\t\t"
    start = resource_limit_offset(source, "{")
    finish = resource_limit_offset(source, "}")
    span = finish - start + 1

    record = FusedJSON.from_json(
      source,
      ResourceLimitsRecord,
      limits: FusedJSON::Limits.new(max_typed_value_bytes: span)
    )
    {record.id, record.name}.should eq({7, "Ada"})

    returned = nil
    expect_serializable_limit_error_at(start + span - 1) do
      returned = FusedJSON.from_json(
        source,
        ResourceLimitsRecord,
        limits: FusedJSON::Limits.new(max_typed_value_bytes: span - 1)
      )
    end
    returned.should be_nil

    io = resource_limit_stream(source)
    expect_serializable_limit_error_at(start + span - 1) do
      FusedJSON.from_json(
        io,
        ResourceLimitsRecord,
        buffer_size: 1,
        limits: FusedJSON::Limits.new(max_typed_value_bytes: span - 1)
      )
    end
    io.closed_called.should be_false
  end

  it "checks a typed cursor value but excludes sibling lookahead" do
    source = %q([false, {"id":7,"name":"Ada"}, "a much longer sibling"])
    start = resource_limit_offset(source, "{")
    finish = resource_limit_offset(source, "}")
    span = finish - start + 1
    limits = FusedJSON::Limits.new(max_typed_value_bytes: span)

    io = resource_limit_stream(source)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1, limits: limits)
    pull.read_begin_array
    pull.read(Bool).should be_false
    record = pull.read(ResourceLimitsRecord)
    {record.id, record.name}.should eq({7, "Ada"})
    pull.read_string.should eq("a much longer sibling")
    pull.read_end_array
    pull.finish

    returned = nil
    pull = FusedJSON::PullParser.new(
      source,
      limits: FusedJSON::Limits.new(max_typed_value_bytes: span - 1)
    )
    pull.read_begin_array
    pull.read(Bool)
    expect_serializable_limit_error_at(start + span - 1) do
      returned = pull.read(ResourceLimitsRecord)
    end
    returned.should be_nil
  end

  it "starts a fresh typed-value budget for every typed array element" do
    source = %q([{"id":1,"name":"a"},{"id":2,"name":"a longer name"}])
    first_start = resource_limit_offset(source, "{")
    first_finish = resource_limit_offset(source, "}")
    first_span = first_finish - first_start + 1
    second_start = resource_limit_offset(source, "{", 1)
    observed = [] of Int32

    io = resource_limit_stream(source)
    pull = FusedJSON::PullParser.new(
      io,
      buffer_size: 1,
      limits: FusedJSON::Limits.new(max_typed_value_bytes: first_span)
    )
    expect_resource_limit_error_at(second_start + first_span) do
      pull.read_array(ResourceLimitsRecord) { |record| observed << record.id }
    end
    observed.should eq([1])
    io.closed_called.should be_false
  end

  it "does not apply a typed-value budget to structural reads, scalar reads, or skip" do
    limits = FusedJSON::Limits.new(max_typed_value_bytes: 0)

    pull = FusedJSON::PullParser.new(%q({"wide":[1,2,3]}), limits: limits)
    pull.skip
    pull.finish

    pull = FusedJSON::PullParser.new(%q("scalar"), limits: limits)
    pull.read_string.should eq("scalar")
    pull.finish

    expect_resource_limit_error_at(0) do
      FusedJSON::PullParser.new("null", limits: limits).read(Nil)
    end
  end

  it "checks an already-scanned scalar before constructing its typed value" do
    limits = FusedJSON::Limits.new(max_typed_value_bytes: 2)

    FusedJSON::PullParser.new(
      "123",
      limits: FusedJSON::Limits.new(max_typed_value_bytes: 3)
    ).read(Int32).should eq(123)

    expect_resource_limit_error_at(2) do
      FusedJSON::PullParser.new("123", limits: limits).read(Int32)
    end

    io = resource_limit_stream("123")
    pull = FusedJSON::PullParser.new(io, buffer_size: 1, limits: limits, max_token_bytes: 3)
    expect_resource_limit_error_at(2) { pull.read(Int32) }
    io.closed_called.should be_false
  end

  it "locates an already-scanned typed literal at its first forbidden byte" do
    source = "[\n  true]"
    limits = FusedJSON::Limits.new(max_typed_value_bytes: 2)

    pull = FusedJSON::PullParser.new(source, limits: limits)
    pull.read_begin_array
    error = expect_resource_limit_error_at(6) { pull.read(Bool) }
    error.location_i64.should eq({2_i64, 5_i64})

    {1, 64}.each do |buffer_size|
      pull = FusedJSON::PullParser.new(
        IO::Memory.new(source),
        buffer_size: buffer_size,
        limits: limits
      )
      pull.read_begin_array
      error = expect_resource_limit_error_at(6) { pull.read(Bool) }
      error.location_i64.should eq({2_i64, 5_i64})
    end
  end
end

describe "FusedJSON resource count limits" do
  it "enforces zero and exact root-value boundaries" do
    FusedJSON.load(
      "null",
      limits: FusedJSON::Limits.new(max_total_values: 1)
    ).should eq(JSON::Any.new(nil))

    expect_resource_limit_error_at(0) do
      FusedJSON.load(
        "null",
        limits: FusedJSON::Limits.new(max_total_values: 0)
      )
    end

    io = resource_limit_stream("null")
    expect_resource_limit_error_at(0) do
      FusedJSON.load(
        io,
        buffer_size: 1,
        limits: FusedJSON::Limits.new(max_total_values: 0)
      )
    end
  end

  it "counts root, container, and scalar values exactly once" do
    source = %q({"a":[null,{"b":true}],"c":2})
    exact = FusedJSON::Limits.new(max_total_values: 6)
    short = FusedJSON::Limits.new(max_total_values: 5)
    forbidden = resource_limit_offset(source, ":2") + 1

    FusedJSON.load(source, limits: exact).should eq(JSON.parse(source))
    expect_resource_limit_error_at(forbidden) { FusedJSON.load(source, limits: short) }

    io = resource_limit_stream(source)
    FusedJSON.load(io, buffer_size: 1, limits: exact).should eq(JSON.parse(source))

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(forbidden) do
      FusedJSON.load(io, buffer_size: 1, limits: short)
    end
  end

  it "counts values traversed by skip and typed unknown-field handling" do
    source = %q({"unknown":[1,{"x":2}],"id":7,"name":"Ada"})
    # Root object, unknown array, 1, nested object, 2, id, and name.
    exact = FusedJSON::Limits.new(max_total_values: 7)
    short = FusedJSON::Limits.new(max_total_values: 6)
    forbidden = resource_limit_offset(source, %q("Ada"))

    pull = FusedJSON::PullParser.new(source, limits: exact)
    pull.skip
    pull.finish

    pull = FusedJSON::PullParser.new(source, limits: short)
    expect_resource_limit_error_at(forbidden) { pull.skip }

    record = FusedJSON.from_json(source, ResourceLimitsRecord, limits: exact)
    {record.id, record.name}.should eq({7, "Ada"})
    expect_resource_limit_error_at(forbidden) do
      FusedJSON.from_json(source, ResourceLimitsRecord, limits: short)
    end

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(forbidden) do
      FusedJSON.from_json(
        io,
        ResourceLimitsRecord,
        buffer_size: 1,
        limits: short
      )
    end
  end

  it "may encounter a global value limit during typed-array lookahead" do
    source = "[1,2,3]"
    observed = [] of Int32
    pull = FusedJSON::PullParser.new(
      source,
      limits: FusedJSON::Limits.new(max_total_values: 3)
    )

    expect_resource_limit_error_at(5) do
      pull.read_array(Int32) { |value| observed << value }
    end
    observed.should eq([1])
  end

  it "limits array and object entries independently per container" do
    nested = "[[1,2],[3,4]]"
    exact = FusedJSON::Limits.new(max_container_entries: 2)
    FusedJSON.load(nested, limits: exact).should eq(JSON.parse(nested))

    array = "[0,1]"
    expect_resource_limit_error_at(3) do
      FusedJSON.load(
        array,
        limits: FusedJSON::Limits.new(max_container_entries: 1)
      )
    end

    object = %q({"a":0,"b":1})
    second_key = resource_limit_offset(object, %q("b"))
    io = resource_limit_stream(object)
    expect_resource_limit_error_at(second_key) do
      FusedJSON.load(
        io,
        buffer_size: 1,
        limits: FusedJSON::Limits.new(max_container_entries: 1)
      )
    end
  end

  it "allows empty containers but rejects the first entry at a zero boundary" do
    limits = FusedJSON::Limits.new(max_container_entries: 0)

    FusedJSON.load("[]", limits: limits).should eq(JSON.parse("[]"))
    FusedJSON.load("{}", limits: limits).should eq(JSON.parse("{}"))
    expect_resource_limit_error_at(1) { FusedJSON.load("[0]", limits: limits) }
    expect_resource_limit_error_at(1) { FusedJSON.load(%q({"a":0}), limits: limits) }
  end

  it "enforces entry limits during skip and unknown typed values" do
    source = %q({"id":7,"ignored":[0,1,2]})
    third = resource_limit_offset(source, "2")
    limits = FusedJSON::Limits.new(max_container_entries: 2)

    pull = FusedJSON::PullParser.new(source, limits: limits)
    expect_resource_limit_error_at(third) { pull.skip }

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(third) do
      FusedJSON.from_json(
        io,
        ResourceLimitsIdRecord,
        buffer_size: 1,
        limits: limits
      )
    end
  end

  it "enforces entry limits before yielding a typed element whose lookahead exceeds them" do
    observed = [] of Int32
    pull = FusedJSON::PullParser.new(
      "[0,1,2]",
      limits: FusedJSON::Limits.new(max_container_entries: 2)
    )

    expect_resource_limit_error_at(5) do
      pull.read_array(Int32) { |value| observed << value }
    end
    observed.should eq([0])
  end
end

describe "FusedJSON duplicate and key-cache limits" do
  it "keeps duplicate-last behavior by default and rejects decoded duplicates on request" do
    source = %q({"a":1,"\u0061":2})
    second_key = resource_limit_offset(source, %q("\u0061"))

    FusedJSON.load(source, limits: FusedJSON::Limits.new).as_h["a"].as_i64.should eq(2_i64)

    rejecting = FusedJSON::Limits.new(reject_duplicate_keys: true)
    expect_resource_limit_error_at(second_key) { FusedJSON.load(source, limits: rejecting) }

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(second_key) do
      FusedJSON.load(io, buffer_size: 1, limits: rejecting)
    end
    io.closed_called.should be_false
  end

  it "scopes duplicate keys per object without Unicode normalization" do
    scoped = %q({"a":1,"nested":{"a":2},"sibling":{"a":3}})
    distinct = %q({"é":1,"e\u0301":2})
    limits = FusedJSON::Limits.new(reject_duplicate_keys: true)

    FusedJSON.load(scoped, limits: limits).should eq(JSON.parse(scoped))
    FusedJSON.load(distinct, limits: limits).should eq(JSON.parse(distinct))
  end

  it "rejects duplicates inside skipped and typed unknown values" do
    skipped = %q([{"x":1,"x":2}])
    duplicate = resource_limit_offset(skipped, %q("x"), 1)
    limits = FusedJSON::Limits.new(reject_duplicate_keys: true)

    pull = FusedJSON::PullParser.new(skipped, limits: limits)
    expect_resource_limit_error_at(duplicate) { pull.skip }

    io = resource_limit_stream(skipped)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1, limits: limits)
    expect_resource_limit_error_at(duplicate) { pull.skip }

    typed = %q({"id":7,"name":"Ada","ignored":{"x":1,"\u0078":2}})
    typed_duplicate = resource_limit_offset(typed, %q("\u0078"))
    expect_resource_limit_error_at(typed_duplicate) do
      FusedJSON.from_json(typed, ResourceLimitsRecord, limits: limits)
    end

    pull = FusedJSON::PullParser.new(typed, limits: limits)
    expect_resource_limit_error_at(typed_duplicate) do
      pull.read(ResourceLimitsRecord)
    end
  end

  it "rejects a duplicate before reading its value" do
    source = %q({"a":1,"\u0061":{"must_not_be_read":true}})
    second_key = resource_limit_offset(source, %q("\u0061"))
    second_colon = resource_limit_offset(source, ":", 1)
    io = resource_limit_stream(source)
    pull = FusedJSON::PullParser.new(
      io,
      buffer_size: 1,
      limits: FusedJSON::Limits.new(reject_duplicate_keys: true)
    )

    expect_resource_limit_error_at(second_key) { pull.skip }
    io.bytes_read.should eq(second_colon)
    io.closed_called.should be_false
  end

  it "counts duplicate object members as container entries" do
    source = %q({"a":1,"a":2})
    second_key = resource_limit_offset(source, %q("a"), 1)

    expect_resource_limit_error_at(second_key) do
      FusedJSON.load(
        source,
        limits: FusedJSON::Limits.new(max_container_entries: 1)
      )
    end
  end

  it "limits distinct decoded strings inserted into the key pool" do
    source = %q({"a":1,"\u0062":2,"a":3,"nested":{"b":4,"c":5}})
    exact = FusedJSON::Limits.new(max_cached_keys: 4)
    short = FusedJSON::Limits.new(max_cached_keys: 3)
    forbidden = resource_limit_offset(source, %q("c"))

    FusedJSON.load(source, cache_keys: true, limits: exact).should eq(JSON.parse(source))
    expect_resource_limit_error_at(forbidden) do
      FusedJSON.load(source, cache_keys: true, limits: short)
    end

    io = resource_limit_stream(source)
    FusedJSON.load(io, buffer_size: 1, cache_keys: true, limits: exact).should eq(JSON.parse(source))

    io = resource_limit_stream(source)
    expect_resource_limit_error_at(forbidden) do
      FusedJSON.load(io, buffer_size: 1, cache_keys: true, limits: short)
    end
  end

  it "does not increment the cache for repeats or escape-equivalent spellings" do
    source = %q({"a":1,"\u0061":2})
    limits = FusedJSON::Limits.new(max_cached_keys: 1)

    FusedJSON.load(source, cache_keys: true, limits: limits).should eq(JSON.parse(source))
  end

  it "allows keyless objects but rejects the first cached key at zero" do
    limits = FusedJSON::Limits.new(max_cached_keys: 0)

    FusedJSON.load("{}", cache_keys: true, limits: limits).should eq(JSON.parse("{}"))
    expect_resource_limit_error_at(1) do
      FusedJSON.load(%q({"a":1}), cache_keys: true, limits: limits)
    end
  end

  it "makes a cache limit inert when caching is disabled" do
    source = %q({"a":1,"b":2,"c":3})
    limits = FusedJSON::Limits.new(max_cached_keys: 0)

    FusedJSON.load(source, cache_keys: false, limits: limits).should eq(JSON.parse(source))

    io = resource_limit_stream(source)
    FusedJSON.load(io, buffer_size: 1, cache_keys: false, limits: limits).should eq(JSON.parse(source))
  end

  it "does not cache keys that an untyped pull skip never materializes" do
    source = %q({"a":1,"b":{"c":2}})
    limits = FusedJSON::Limits.new(max_cached_keys: 0)

    pull = FusedJSON::PullParser.new(source, cache_keys: true, limits: limits)
    pull.skip
    pull.finish

    io = resource_limit_stream(source)
    pull = FusedJSON::PullParser.new(
      io,
      buffer_size: 1,
      cache_keys: true,
      limits: limits
    )
    pull.skip
    pull.finish
  end

  it "enforces a zero cache limit when duplicate checking materializes skipped keys" do
    source = %q({"a":1})
    limits = FusedJSON::Limits.new(
      max_cached_keys: 0,
      reject_duplicate_keys: true
    )

    pull = FusedJSON::PullParser.new(source, cache_keys: true, limits: limits)
    expect_resource_limit_error_at(1) { pull.skip }

    io = resource_limit_stream(source)
    pull = FusedJSON::PullParser.new(
      io,
      buffer_size: 1,
      cache_keys: true,
      limits: limits
    )
    expect_resource_limit_error_at(1) { pull.skip }
    io.closed_called.should be_false
  end

  it "enforces the cache limit when pull traversal materializes keys" do
    source = %q({"a":1,"b":2})
    forbidden = resource_limit_offset(source, %q("b"))
    pull = FusedJSON::PullParser.new(
      source,
      cache_keys: true,
      limits: FusedJSON::Limits.new(max_cached_keys: 1)
    )

    expect_resource_limit_error_at(forbidden) do
      pull.read_object { |_key| pull.skip }
    end
  end

  it "keeps duplicate rejection independent of document-wide caching" do
    source = %q({"a":1,"a":2})
    second_key = resource_limit_offset(source, %q("a"), 1)

    expect_resource_limit_error_at(second_key) do
      FusedJSON.load(
        source,
        cache_keys: false,
        limits: FusedJSON::Limits.new(
          max_cached_keys: 0,
          reject_duplicate_keys: true
        )
      )
    end
  end
end

require "./spec_helper"
require "./support/chunked_io"
require "big/json"

private module StreamTypedConverter
  @@calls = 0
  @@kind = JSON::PullParser::Kind::EOF

  def self.reset : Nil
    @@calls = 0
    @@kind = JSON::PullParser::Kind::EOF
  end

  def self.calls : Int32
    @@calls
  end

  def self.kind : JSON::PullParser::Kind
    @@kind
  end

  def self.from_json(pull : JSON::PullParser) : Int32
    @@calls += 1
    @@kind = pull.kind
    pull.read_string.to_i(16)
  end
end

private class StreamTypedRecord
  include JSON::Serializable

  getter id : UInt128
  getter name : String

  @[JSON::Field(converter: StreamTypedConverter)]
  getter color : Int32
end

private class StreamTypedRawRecord
  include JSON::Serializable

  @[JSON::Field(converter: String::RawConverter)]
  getter raw : String

  getter tail : Int32
end

class StreamTypedAlpha
  include JSON::Serializable

  getter alpha : String
end

class StreamTypedBeta
  include JSON::Serializable

  getter beta : Int32
  getter wide : UInt128
end

private class StreamTypedKnownFields
  include JSON::Serializable

  getter name : String
  getter count : Int32
end

private class StreamTypedLocationRecord
  include JSON::Serializable

  getter name : String
  getter count : Int32
end

private def stream_typed_decode(
  source : String,
  type : T.class,
  *,
  buffer_size : Int = 1,
  max_token_bytes : Int? = nil,
) : Tuple(T, StreamSpecSupport::ChunkedIO) forall T
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    max_chunk: 1,
    read_budget: source.bytesize + 2
  )
  value = FusedJSON.from_json(
    io,
    type,
    buffer_size: buffer_size,
    max_token_bytes: max_token_bytes
  )
  {value, io}
end

describe "streaming typed decoding adapter" do
  it "decodes serializable records and nominal converters through one-byte reads" do
    source = %q({"id":340282366920938463463374607431768211455,"name":"Ada λ","color":"ff"})
    expected = FusedJSON.from_json(source, StreamTypedRecord)
    StreamTypedConverter.reset

    record, io = stream_typed_decode(source, StreamTypedRecord)

    {record.id, record.name, record.color}.should eq({expected.id, expected.name, expected.color})
    record.id.should eq(UInt128::MAX)
    StreamTypedConverter.calls.should eq(1)
    StreamTypedConverter.kind.should eq(JSON::PullParser::Kind::String)
    io.bytes_read.should eq(source.bytesize)
    io.read_calls.should be <= source.bytesize + 2
    io.closed_called.should be_false
  end

  it "preserves wide integers and both raw replay paths with tiny buffers" do
    UInt128::MAX.to_s.tap do |source|
      value, io = stream_typed_decode(source, UInt128)
      value.should eq(UInt128::MAX)
      io.closed_called.should be_false
    end

    raw_source = %q({"raw":{"wide":340282366920938463463374607431768211455,"huge":1e309,"array":[null,true,"line\nλ"]},"tail":7})
    raw, raw_io = stream_typed_decode(raw_source, StreamTypedRawRecord, buffer_size: 2)
    expected_raw = FusedJSON.from_json(raw_source, StreamTypedRawRecord)
    {raw.raw, raw.tail}.should eq({expected_raw.raw, expected_raw.tail})
    raw_io.closed_called.should be_false

    union_source = %q({"beta":9,"wide":340282366920938463463374607431768211455})
    union, union_io = stream_typed_decode(union_source, StreamTypedAlpha | StreamTypedBeta, buffer_size: 3)
    beta = union.as(StreamTypedBeta)
    expected_beta = FusedJSON.from_json(union_source, StreamTypedAlpha | StreamTypedBeta).as(StreamTypedBeta)
    {beta.beta, beta.wide}.should eq({expected_beta.beta, expected_beta.wide})
    beta.beta.should eq(9)
    beta.wide.should eq(UInt128::MAX)
    union_io.closed_called.should be_false
  end

  it "decodes arbitrary-precision integers across one-byte reads" do
    source = "-123456789012345678901234567890123456789012345678901234567890"
    value, io = stream_typed_decode(source, BigInt)

    value.should eq(BigInt.new(source))
    io.bytes_read.should eq(source.bytesize)
    io.closed_called.should be_false
  end

  it "validates but does not materialize unknown fields outside the dynamic numeric domain" do
    source = %q({"ignored":{"huge":1e309,"wide":340282366920938463463374607431768211456,"nested":[-1e400]},"name":"kept","count":3})

    record, io = stream_typed_decode(source, StreamTypedKnownFields)
    expected = FusedJSON.from_json(source, StreamTypedKnownFields)

    {record.name, record.count}.should eq({expected.name, expected.count})
    io.bytes_read.should eq(source.bytesize)
    io.closed_called.should be_false
  end

  it "passes token limits through typed decoding and skipped fields" do
    source = %q({"ignored":"too-long","name":"kept","count":3})
    limit = %q("too-long").bytesize - 1
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)

    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      FusedJSON.from_json(
        io,
        StreamTypedKnownFields,
        buffer_size: 2,
        max_token_bytes: limit
      )
    end
    io.closed_called.should be_false

    accepted, accepted_io = stream_typed_decode(
      source,
      StreamTypedKnownFields,
      max_token_bytes: limit + 1
    )
    {accepted.name, accepted.count}.should eq({"kept", 3})
    accepted_io.closed_called.should be_false
  end

  it "rejects trailing content and leaves caller-owned IO open" do
    ["1 2", %q({"name":"Ada","count":1} [])].each do |source|
      io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)

      expect_raises(FusedJSON::ParseError, "unexpected trailing content") do
        if source.starts_with?('{')
          FusedJSON.from_json(io, StreamTypedKnownFields, buffer_size: 1)
        else
          FusedJSON.from_json(io, Int32, buffer_size: 1)
        end
      end
      io.closed_called.should be_false
    end
  end

  it "matches in-memory typed error locations across short reads" do
    source = "{\n  \"name\": \"λ\",\n  \"count\": \"wrong\"\n}"
    expected = expect_raises(JSON::SerializableError) do
      FusedJSON.from_json(source, StreamTypedLocationRecord)
    end
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)

    actual = expect_raises(JSON::SerializableError) do
      FusedJSON.from_json(io, StreamTypedLocationRecord, buffer_size: 2)
    end

    actual.location_i64.should eq(expected.location_i64)
    io.closed_called.should be_false
  end
end

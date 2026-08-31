require "./spec_helper"
require "./support/chunked_io"
require "./support/pull_helpers"
require "../src/fused_json/streaming_parser"

private def parse_stream(
  source : String,
  *,
  max_chunk : Int32 = 1,
  buffer_size : Int = 3,
  max_nesting : Int = 512,
  cache_keys : Bool = false,
  max_token_bytes : Int? = nil,
)
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    max_chunk: max_chunk,
    read_budget: source.bytesize + 4
  )
  value = FusedJSON::StreamingParser.new(
    io,
    buffer_size: buffer_size,
    max_nesting: max_nesting,
    cache_keys: cache_keys,
    max_token_bytes: max_token_bytes
  ).parse
  {value, io}
end

private def split_stream(source : String, cut : Int32) : StreamSpecSupport::ChunkedIO
  StreamSpecSupport::ChunkedIO.new(
    source,
    chunks: [cut],
    read_budget: source.bytesize + 4
  )
end

private def dynamic_split_value(source : String, cut : Int32, *, cache_keys : Bool) : JSON::Any
  io = split_stream(source, cut)
  value = FusedJSON.load(
    io,
    buffer_size: Math.max(source.bytesize, 1),
    cache_keys: cache_keys
  )
  raise "dynamic parser closed caller-owned IO" if io.closed_called
  value
end

private def pull_split_value(source : String, cut : Int32, *, cache_keys : Bool) : JSON::Any
  io = split_stream(source, cut)
  pull = FusedJSON::PullParser.new(
    io,
    buffer_size: Math.max(source.bytesize, 1),
    cache_keys: cache_keys
  )
  value = PullSpecHelpers.read_any(pull)
  pull.finish
  raise "pull parser closed caller-owned IO" if io.closed_called
  value
end

private def string_error_location(source : String) : Tuple(Int64, Int64, Int64)
  FusedJSON.load(source)
  raise "malformed String input was accepted"
rescue error : FusedJSON::ParseError
  {error.byte_offset, error.line_number.to_i64, error.column_number.to_i64}
end

private def dynamic_error_location(source : String, cut : Int32) : Tuple(Int64, Int64, Int64)
  FusedJSON.load(split_stream(source, cut), buffer_size: Math.max(source.bytesize, 1))
  raise "malformed direct input was accepted"
rescue error : FusedJSON::ParseError
  {error.byte_offset, error.line_number.to_i64, error.column_number.to_i64}
end

private def pull_error_location(source : String, cut : Int32) : Tuple(Int64, Int64, Int64)
  pull = FusedJSON::PullParser.new(
    split_stream(source, cut),
    buffer_size: Math.max(source.bytesize, 1)
  )
  PullSpecHelpers.read_any(pull)
  pull.finish
  raise "malformed pull input was accepted"
rescue error : FusedJSON::ParseError
  {error.byte_offset, error.line_number.to_i64, error.column_number.to_i64}
end

describe FusedJSON::StreamingParser do
  it "exposes strict load and parse IO overloads" do
    source = %q({"name":"Crystal","values":[1,2,3]})
    load_io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    parse_io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 2)

    FusedJSON.load(load_io, buffer_size: 3).should eq(FusedJSON.load(source))
    FusedJSON.parse(parse_io, buffer_size: 4).should eq(FusedJSON.parse(source))
    load_io.closed_called.should be_false
    parse_io.closed_called.should be_false
  end

  it "matches FusedJSON.load through one-byte reads and a tiny buffer" do
    documents = [
      "null",
      "true",
      "-9223372036854775808",
      "-0.0",
      "1.25e+2",
      %q("line\nλ\uD834\uDD1E"),
      %q([null,false,true,0,-0,1.5,"λ",[],{}]),
      %q({"array":[1,{"nested":"value"}],"empty":{},"unicode":"𝄞"}),
      " \r\n{\"a\":1,\"b\":[2,3]}\t",
    ]

    documents.each do |source|
      actual, io = parse_stream(source)
      actual.should eq(FusedJSON.load(source)), source.inspect
      io.bytes_read.should eq(source.bytesize)
      io.closed_called.should be_false
    end
  end

  it "matches String and pull tree construction at every byte split" do
    documents = [
      " -9223372036854775808 ",
      %q("line\nλ\uD834\uDD1E"),
      %q([null,false,true,-0,1.5e+2,"λ",[],{}]),
      %q({"array":[1,{"nested":"value"}],"escaped\u002dkey":"𝄞"}),
      %q([{"cache-key":1},{"cache-key":2},{"\u0063ache-key":3}]),
    ]

    documents.each do |source|
      expected = FusedJSON.load(source)
      [false, true].each do |cache_keys|
        1.upto(source.bytesize - 1) do |cut|
          dynamic_split_value(source, cut, cache_keys: cache_keys).should eq(expected),
            "dynamic split #{cut} for #{source.inspect}"
          pull_split_value(source, cut, cache_keys: cache_keys).should eq(expected),
            "pull split #{cut} for #{source.inspect}"
        end
      end
    end
  end

  it "matches String and pull error locations at every byte split" do
    malformed = [
      "true false",
      "[1,]",
      %q({"a":1 "b":2}),
      %q({"λ":"\uD800"}),
      "[-,0]",
      String.new(Bytes[0x5b_u8, 0x22_u8, 0xe2_u8, 0x82_u8, 0x22_u8, 0x5d_u8]),
    ]

    malformed.each do |source|
      expected = string_error_location(source)
      1.upto(source.bytesize - 1) do |cut|
        dynamic_error_location(source, cut).should eq(expected),
          "dynamic split #{cut} for malformed #{source.inspect}"
        pull_error_location(source, cut).should eq(expected),
          "pull split #{cut} for malformed #{source.inspect}"
      end
    end
  end

  it "builds long keys, plain and escaped strings, and numbers across refills" do
    key = "long-key-" + ("k" * 300)
    plain = ("plainλ𝄞" * 100) + "end"
    escaped = ("line\n\t\"\\" * 64) + "λ𝄞"
    number = "0." + ("0" * 180) + "1"
    source = "{#{key.to_json}:#{plain.to_json},\"escaped\":#{escaped.to_json},\"number\":#{number}}"

    actual, io = parse_stream(source, max_chunk: 2, buffer_size: 3)
    actual.should eq(FusedJSON.load(source))
    actual.as_h[key].as_s.should eq(plain)
    actual.as_h["escaped"].as_s.should eq(escaped)
    io.bytes_read.should eq(source.bytesize)
    io.closed_called.should be_false
  end

  it "keeps the last duplicate value and honors key caching" do
    duplicate = %q({"a":1,"\u0061":2})

    uncached_duplicate, _ = parse_stream(duplicate, cache_keys: false)
    cached_duplicate, _ = parse_stream(duplicate, cache_keys: true)
    uncached_duplicate.as_h.size.should eq(1)
    uncached_duplicate.as_h["a"].as_i64.should eq(2_i64)
    cached_duplicate.should eq(uncached_duplicate)

    repeated = %q([{"cache-key-across-objects":1},{"\u0063ache-key-across-objects":2}])
    uncached, _ = parse_stream(repeated, cache_keys: false)
    cached, _ = parse_stream(repeated, cache_keys: true)
    uncached_keys = uncached.as_a.map { |entry| entry.as_h.keys.first }
    cached_keys = cached.as_a.map { |entry| entry.as_h.keys.first }

    uncached_keys[0].same?(uncached_keys[1]).should be_false
    cached_keys[0].same?(cached_keys[1]).should be_true
  end

  it "rejects trailing content and malformed nested data" do
    invalid = [
      "true false",
      "[1] trailing",
      %q({"value":1} []),
      %q({"kept":1,"ignored":{"bad":"\uD800"}}),
      %q({"kept":1,"ignored":[1,]}),
      %q({"kept":1,"ignored":["unterminated]}),
    ]

    invalid.each do |source|
      io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
      expect_raises(FusedJSON::ParseError) do
        FusedJSON::StreamingParser.new(io, buffer_size: 3).parse
      end
      io.closed_called.should be_false
    end
  end

  it "passes nesting limits through to the pull parser" do
    accepted, accepted_io = parse_stream("[[0]]", max_nesting: 2)
    accepted.should eq(JSON.parse("[[0]]"))
    accepted_io.closed_called.should be_false

    too_deep = StreamSpecSupport::ChunkedIO.new("[[0]]", max_chunk: 1)
    expect_raises(FusedJSON::ParseError) do
      FusedJSON::StreamingParser.new(too_deep, buffer_size: 2, max_nesting: 1).parse
    end
    too_deep.closed_called.should be_false

    [0, -1, 513, Int64::MAX, UInt64::MAX].each do |limit|
      io = StreamSpecSupport::ChunkedIO.new("0")
      expect_raises(ArgumentError, "max_nesting must be between 1 and 512") do
        FusedJSON::StreamingParser.new(io, buffer_size: 2, max_nesting: limit)
      end
      io.read_calls.should eq(0)
      io.closed_called.should be_false
    end
  end

  it "passes token limits through the dynamic IO facades" do
    source = %q({"name":"Crystal","count":12})
    exact_limit = %q("Crystal").bytesize
    accepted, _ = parse_stream(source, max_token_bytes: exact_limit)
    accepted.should eq(FusedJSON.load(source))

    load_io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      FusedJSON.load(load_io, buffer_size: 2, max_token_bytes: exact_limit - 1)
    end

    parse_io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      FusedJSON.parse(parse_io, buffer_size: 2, max_token_bytes: exact_limit - 1)
    end
    load_io.closed_called.should be_false
    parse_io.closed_called.should be_false
  end

  it "handles variable short reads without consuming poisoned tail bytes" do
    source = %q({"alpha":[1,2,3],"omega":"λ𝄞"})
    io = StreamSpecSupport::ChunkedIO.new(
      source,
      chunks: [1, 2, 1, 3, 1, 5],
      max_chunk: 3,
      read_budget: source.bytesize + 4
    )

    actual = FusedJSON::StreamingParser.new(io, buffer_size: 16).parse
    actual.should eq(FusedJSON.load(source))
    io.bytes_read.should eq(source.bytesize)
    io.closed_called.should be_false
  end

  it "treats zero as EOF and propagates later IO failures" do
    zero = StreamSpecSupport::ChunkedIO.new(
      "true",
      zero_on_read: 1,
      read_budget: 2
    )
    expect_raises(FusedJSON::ParseError) do
      FusedJSON::StreamingParser.new(zero, buffer_size: 3)
    end
    zero.read_calls.should eq(1)
    zero.closed_called.should be_false

    failing = StreamSpecSupport::ChunkedIO.new(
      "[1]",
      max_chunk: 1,
      fail_on_read: 2,
      read_budget: 2
    )
    parser = FusedJSON::StreamingParser.new(failing, buffer_size: 3)
    expect_raises(IO::Error, "injected read failure") { parser.parse }
    failing.read_calls.should eq(2)
    failing.bytes_read.should eq(1)
    failing.closed_called.should be_false
  end

  it "leaves caller-owned IO open after success and failure" do
    successful = StreamSpecSupport::ChunkedIO.new(%q({"ok":true}), max_chunk: 1)
    FusedJSON::StreamingParser.new(successful, buffer_size: 2).parse
    successful.closed_called.should be_false

    malformed = StreamSpecSupport::ChunkedIO.new("[1", max_chunk: 1)
    expect_raises(FusedJSON::ParseError) do
      FusedJSON::StreamingParser.new(malformed, buffer_size: 2).parse
    end
    malformed.closed_called.should be_false
  end
end

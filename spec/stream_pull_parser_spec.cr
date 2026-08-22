require "./spec_helper"
require "./support/chunked_io"

module StreamingPullSpec
  extend self

  alias TraceValue = Nil | Bool | Int64 | UInt64 | String

  record Event,
    kind : FusedJSON::PullParser::Kind,
    value : TraceValue,
    byte_offset : Int64,
    line : Int64,
    column : Int64

  COMPREHENSIVE = " \r\n" +
                  %q({"a":[null,false,true,0,-0,-9223372036854775808,9223372036854775807,-0.0,1.25e+2,"plain","line\n\t\"\\\/\b\f\r","λ𝄞\u03bb\uD834\uDD1E"],"\u0061":{"empty":[],"object":{}}}) +
                  "\t"

  SCALARS = [
    "null",
    "false",
    "true",
    "0",
    "-0",
    "-9223372036854775808",
    "9223372036854775807",
    "-0.0",
    "1.25e+2",
    %q("plain"),
    %q("line\nλ\uD834\uDD1E"),
    " \n42\t",
  ]

  def trace(pull : FusedJSON::PullParser) : Array(Event)
    events = [] of Event

    loop do
      kind = pull.kind
      byte_offset = pull.byte_offset
      line, column = pull.location_i64

      value : TraceValue = case kind
      when .null?
        pull.read_null
      when .bool?
        pull.read_bool
      when .int?
        pull.read_int
      when .float?
        pull.read_float.unsafe_as(UInt64)
      when .string?
        pull.read_string
      when .begin_array?, .end_array?, .begin_object?, .end_object?
        pull.read_next
        nil
      when .eof?
        nil
      else
        raise "unhandled pull event #{kind}"
      end

      events << Event.new(kind, value, byte_offset, line, column)
      break if kind.eof?
    end

    pull.finish
    events
  end

  def assert_trace(expected : Array(Event), actual : Array(Event), context : String) : Nil
    actual.should eq(expected), context
  end

  def retained_strings
    first_key = "first-" + ("k" * 96)
    first_value = "plain-" + ("λ𝄞" * 64)
    second_key = "escaped"
    second_value = ("line\n\t\"\\" * 48) + "λ𝄞"
    encoded = "{#{first_key.to_json}:#{first_value.to_json},#{second_key.to_json}:#{second_value.to_json}}"
    source = String.new(encoded.to_slice)
    io = StreamSpecSupport::ChunkedIO.new(
      source,
      max_chunk: 1,
      read_budget: source.bytesize + 4
    )
    pull = FusedJSON::PullParser.new(io, buffer_size: 2)

    pull.read_begin_object
    retained_first_key = pull.read_object_key
    retained_first_value = pull.read_string
    retained_second_key = pull.read_object_key
    retained_second_value = pull.read_string
    pull.read_end_object
    pull.finish

    {
      retained_first_key,
      retained_first_value,
      retained_second_key,
      retained_second_value,
      io.closed_called,
    }
  end
end

# Test-only visibility into scratch identity keeps the reclamation boundary
# deterministic without relying on GC allocation counters.
class FusedJSON::StreamingPullParser
  def __spec_token_scratch : IO::Memory
    @token
  end
end

describe "streaming FusedJSON::PullParser" do
  it "matches every in-memory event, value, and location at every byte split" do
    source = StreamingPullSpec::COMPREHENSIVE
    expected = StreamingPullSpec.trace(FusedJSON::PullParser.new(source))

    (1...source.bytesize).each do |split|
      chunks = [split, source.bytesize - split]
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        chunks: chunks,
        max_chunk: 7,
        read_budget: source.bytesize + 8
      )
      actual = StreamingPullSpec.trace(
        FusedJSON::PullParser.new(io, buffer_size: 11)
      )

      StreamingPullSpec.assert_trace(
        expected,
        actual,
        "event trace diverged at source split #{split}/#{source.bytesize}"
      )
      io.bytes_read.should eq(source.bytesize)
      io.closed_called.should be_false

      skip_io = StreamSpecSupport::ChunkedIO.new(
        source,
        chunks: chunks,
        max_chunk: 7,
        read_budget: source.bytesize + 8
      )
      skip_pull = FusedJSON::PullParser.new(skip_io, buffer_size: 11)
      skip_pull.skip_value
      skip_pull.finish
      skip_pull.kind.should eq(FusedJSON::PullParser::Kind::EOF)
      skip_pull.byte_offset.should eq(source.bytesize.to_i64)
      skip_io.bytes_read.should eq(source.bytesize)
      skip_io.closed_called.should be_false
    end
  end

  it "parses scalar roots through one-byte reads and buffers" do
    StreamingPullSpec::SCALARS.each do |source|
      expected = StreamingPullSpec.trace(FusedJSON::PullParser.new(source))
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        max_chunk: 1,
        read_budget: source.bytesize + 2
      )
      actual = StreamingPullSpec.trace(
        FusedJSON::PullParser.new(io, buffer_size: 1)
      )

      StreamingPullSpec.assert_trace(expected, actual, "scalar root #{source.inspect}")
      io.bytes_read.should eq(source.bytesize)
      io.read_calls.should be <= source.bytesize + 2
      io.closed_called.should be_false
    end
  end

  it "parses and skips long strings, keys, escapes, and numbers with tiny buffers" do
    key = "key-" + ("k" * 257)
    plain = ("plainλ" * 80) + "𝄞"
    escaped = ("line\n\t\"\\/" * 48) + "λ𝄞"
    number = "0." + ("0" * 180) + "1"
    source = "{#{key.to_json}:#{plain.to_json},\"escaped\":#{escaped.to_json},\"number\":#{number}}"
    expected = StreamingPullSpec.trace(FusedJSON::PullParser.new(source))

    io = StreamSpecSupport::ChunkedIO.new(
      source,
      max_chunk: 2,
      read_budget: source.bytesize + 8
    )
    actual = StreamingPullSpec.trace(
      FusedJSON::PullParser.new(io, buffer_size: 3)
    )
    StreamingPullSpec.assert_trace(expected, actual, "long tokens with a three-byte buffer")
    io.bytes_read.should eq(source.bytesize)
    io.closed_called.should be_false

    skip_io = StreamSpecSupport::ChunkedIO.new(
      source,
      max_chunk: 2,
      read_budget: source.bytesize + 8
    )
    skip_pull = FusedJSON::PullParser.new(skip_io, buffer_size: 3)
    skip_pull.skip_value
    skip_pull.finish
    skip_pull.byte_offset.should eq(source.bytesize.to_i64)
    skip_io.closed_called.should be_false
  end

  it "retains ordinary token scratch without pinning oversized tokens" do
    [1, 3, 32 * 1024].each do |buffer_size|
      retention_limit = Math.max(buffer_size * 2, 64 * 1024)

      [retention_limit - 1, retention_limit, retention_limit + 1].each do |token_size|
        value = "x" * (token_size - 2)
        source = [value, value].to_json
        io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: buffer_size)
        pull = FusedJSON::PullParser.new(io, buffer_size: buffer_size)

        pull.read_begin_array
        first_scratch = pull.__spec_token_scratch
        pull.read_string.should eq(value)
        second_scratch = pull.__spec_token_scratch

        second_scratch.same?(first_scratch).should eq(token_size <= retention_limit)
        pull.read_string.should eq(value)
        pull.read_end_array
        pull.finish
      end
    end
  end

  it "enforces an optional raw string and number token limit" do
    string_token = %q("a\u0062λ")
    number_token = "-12.5e+4"

    {string_token => "abλ", number_token => -125_000.0}.each do |token, expected|
      accepted_io = StreamSpecSupport::ChunkedIO.new(token, max_chunk: 1)
      accepted = FusedJSON::PullParser.new(
        accepted_io,
        buffer_size: 3,
        max_token_bytes: token.bytesize
      )
      if expected.is_a?(String)
        accepted.read_string.should eq(expected)
      else
        accepted.read_float.should eq(expected)
      end
      accepted.finish

      rejected_io = StreamSpecSupport::ChunkedIO.new(token, max_chunk: 1)
      error = expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
        FusedJSON::PullParser.new(
          rejected_io,
          buffer_size: 3,
          max_token_bytes: token.bytesize - 1
        )
      end
      error.byte_offset.should eq(0_i64)
      error.line_number.should eq(1_i64)
      error.column_number.should eq(1_i64)
      rejected_io.closed_called.should be_false
    end

    inline = StreamSpecSupport::ChunkedIO.new(%q("abcdef"), max_chunk: 64)
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      FusedJSON::PullParser.new(inline, buffer_size: 64, max_token_bytes: 7)
    end

    key_io = StreamSpecSupport::ChunkedIO.new(%q({"long-key":1}), max_chunk: 1)
    key_pull = FusedJSON::PullParser.new(key_io, buffer_size: 2, max_token_bytes: 9)
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      key_pull.read_begin_object
    end

    skip_io = StreamSpecSupport::ChunkedIO.new(%q(["too-long"]), max_chunk: 1)
    skip_pull = FusedJSON::PullParser.new(skip_io, buffer_size: 2, max_token_bytes: 9)
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      skip_pull.skip_value
    end

    zero_io = StreamSpecSupport::ChunkedIO.new("0", max_chunk: 1)
    zero = FusedJSON::PullParser.new(zero_io, buffer_size: 1, max_token_bytes: 1)
    zero.read_int.should eq(0_i64)
    zero.finish

    empty_string_io = StreamSpecSupport::ChunkedIO.new(%q(""), max_chunk: 1)
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      FusedJSON::PullParser.new(empty_string_io, buffer_size: 1, max_token_bytes: 1)
    end
  end

  it "honors variable short reads and ignores bytes beyond the returned count" do
    source = %q({"alpha":[1,2,3],"omega":"λ𝄞"})
    io = StreamSpecSupport::ChunkedIO.new(
      source,
      chunks: [1, 2, 1, 3, 1, 5],
      max_chunk: 3,
      read_budget: source.bytesize + 8
    )

    actual = StreamingPullSpec.trace(
      FusedJSON::PullParser.new(io, buffer_size: 16)
    )
    expected = StreamingPullSpec.trace(FusedJSON::PullParser.new(source))
    StreamingPullSpec.assert_trace(expected, actual, "variable short reads")
    io.bytes_read.should eq(source.bytesize)
    io.closed_called.should be_false
  end

  it "treats a zero-length read as EOF without retrying" do
    io = StreamSpecSupport::ChunkedIO.new(
      "true",
      zero_on_read: 1,
      read_budget: 2
    )

    expect_raises(FusedJSON::ParseError) do
      FusedJSON::PullParser.new(io, buffer_size: 4)
    end
    io.read_calls.should eq(1)
    io.bytes_read.should eq(0)
    io.closed_called.should be_false
  end

  it "propagates IO errors raised by a later read" do
    io = StreamSpecSupport::ChunkedIO.new(
      "[1]",
      max_chunk: 1,
      fail_on_read: 2,
      read_budget: 2
    )
    pull = FusedJSON::PullParser.new(io, buffer_size: 4)
    pull.kind.should eq(FusedJSON::PullParser::Kind::BeginArray)

    expect_raises(IO::Error, "injected read failure") do
      pull.skip_value
    end
    io.read_calls.should eq(2)
    io.bytes_read.should eq(1)
    io.closed_called.should be_false
  end

  it "rejects invalid byte counts returned by IO#read" do
    {-1, 5}.each do |count|
      io = StreamSpecSupport::InvalidReadCountIO.new(count)
      error = expect_raises(IO::Error) do
        FusedJSON::PullParser.new(io, buffer_size: 4)
      end
      error.message.to_s.should contain("invalid byte count #{count}")
      io.read_calls.should eq(1)
    end
  end

  it "never closes the caller-owned IO on success or parse failure" do
    successful = StreamSpecSupport::ChunkedIO.new("true", max_chunk: 1)
    StreamingPullSpec.trace(FusedJSON::PullParser.new(successful, buffer_size: 2))
    successful.closed_called.should be_false

    malformed = StreamSpecSupport::ChunkedIO.new("[1", max_chunk: 1)
    pull = FusedJSON::PullParser.new(malformed, buffer_size: 2)
    expect_raises(FusedJSON::ParseError) { pull.skip_value }
    malformed.closed_called.should be_false
  end

  it "honors configured IO encodings and reports decoded UTF-8 offsets" do
    io = IO::Memory.new(Bytes[0x22_u8, 0x63_u8, 0x61_u8, 0x66_u8, 0xe9_u8, 0x22_u8])
    io.set_encoding("ISO-8859-1")
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)

    pull.read_string.should eq("café")
    pull.byte_offset.should eq(7_i64)
    pull.location_i64.should eq({1_i64, 7_i64})
    pull.finish
    io.pos.should eq(6)
  end

  it "applies token limits after IO transcoding" do
    encoded = Bytes[0x22_u8, 0x63_u8, 0x61_u8, 0x66_u8, 0xe9_u8, 0x22_u8]

    accepted_io = IO::Memory.new(encoded)
    accepted_io.set_encoding("ISO-8859-1")
    accepted = FusedJSON::PullParser.new(accepted_io, buffer_size: 1, max_token_bytes: 7)
    accepted.read_string.should eq("café")
    accepted.finish

    rejected_io = IO::Memory.new(encoded)
    rejected_io.set_encoding("ISO-8859-1")
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      FusedJSON::PullParser.new(rejected_io, buffer_size: 1, max_token_bytes: 6)
    end
  end

  it "keeps returned strings alive after refills and parser collection" do
    expected_first_key = "first-" + ("k" * 96)
    expected_first_value = "plain-" + ("λ𝄞" * 64)
    expected_second_value = ("line\n\t\"\\" * 48) + "λ𝄞"
    retained = StreamingPullSpec.retained_strings

    GC.collect
    churn = Array.new(2_000) { |index| "stream-lifetime-churn-#{index}" }
    churn.size.should eq(2_000)
    retained.should eq({
      expected_first_key,
      expected_first_value,
      "escaped",
      expected_second_value,
      false,
    })
  end

  it "reports exact offsets and Unicode-aware locations across refills" do
    source = " \n[\"λ\", {\"𝄞\": true}]\n"
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 2)

    {pull.byte_offset, pull.location_i64}.should eq({2_i64, {2_i64, 1_i64}})
    pull.read_begin_array
    {pull.byte_offset, pull.location_i64}.should eq({3_i64, {2_i64, 2_i64}})
    pull.read_string
    {pull.byte_offset, pull.location_i64}.should eq({9_i64, {2_i64, 7_i64}})
    pull.read_begin_object
    {pull.byte_offset, pull.location_i64}.should eq({10_i64, {2_i64, 8_i64}})
    pull.read_object_key
    {pull.byte_offset, pull.location_i64}.should eq({18_i64, {2_i64, 13_i64}})
    pull.read_bool
    {pull.byte_offset, pull.location_i64}.should eq({22_i64, {2_i64, 17_i64}})
    pull.read_end_object
    {pull.byte_offset, pull.location_i64}.should eq({23_i64, {2_i64, 18_i64}})
    pull.read_end_array
    {pull.byte_offset, pull.location_i64}.should eq({25_i64, {3_i64, 1_i64}})
    io.closed_called.should be_false

    malformed_source = "{\n  \"λ\": true,\n  \"𝄞\": ]\n}"
    expected_error = expect_raises(FusedJSON::ParseError) do
      in_memory = FusedJSON::PullParser.new(malformed_source)
      in_memory.skip_value
    end
    malformed_io = StreamSpecSupport::ChunkedIO.new(malformed_source, max_chunk: 1)
    actual_error = expect_raises(FusedJSON::ParseError) do
      streaming = FusedJSON::PullParser.new(malformed_io, buffer_size: 3)
      streaming.skip_value
    end

    actual_error.byte_offset.should eq(expected_error.byte_offset)
    actual_error.line_number.should eq(expected_error.line_number)
    actual_error.column_number.should eq(expected_error.column_number)
    malformed_io.closed_called.should be_false
  end

  it "matches in-memory error locations for truncated tokens and invalid bytes" do
    failures = [] of String
    malformed_fragments = [
      {"null prefix n", "n"},
      {"null prefix nu", "nu"},
      {"null prefix nul", "nul"},
      {"true prefix t", "t"},
      {"true prefix tr", "tr"},
      {"true prefix tru", "tru"},
      {"false prefix f", "f"},
      {"false prefix fa", "fa"},
      {"false prefix fal", "fal"},
      {"false prefix fals", "fals"},
      {"minus without digits", "-"},
      {"fraction without digits", "0."},
      {"negative fraction without digits", "-1."},
      {"exponent without digits", "1e"},
      {"positive exponent without digits", "1e+"},
      {"negative exponent without digits", "1e-"},
      {"opening quote", "\""},
      {"trailing string escape", "\"abc\\"},
      {"unicode escape without hex", "\"\\u"},
      {"unicode escape with one hex digit", "\"\\u0"},
      {"unicode escape with two hex digits", "\"\\u00"},
      {"unicode escape with three hex digits", "\"\\u000"},
      {"unicode escape with invalid hex", "\"\\u00x0"},
      {"high surrogate without low surrogate", "\"\\uD800"},
      {"high surrogate with trailing escape", "\"\\uD800\\"},
      {"high surrogate with low escape prefix", "\"\\uD800\\u"},
      {"high surrogate with partial low surrogate", "\"\\uD800\\uDC0"},
      {"lone low surrogate", "\"\\uDC00"},
      {"embedded NUL in a string", String.new(Bytes[0x22_u8, 0x61_u8, 0x00_u8, 0x62_u8, 0x22_u8])},
      {"embedded NUL after a value", String.new(Bytes[0x74_u8, 0x72_u8, 0x75_u8, 0x65_u8, 0x00_u8])},
      {"lone UTF-8 continuation", String.new(Bytes[0x22_u8, 0x80_u8])},
      {"invalid UTF-8 leading byte", String.new(Bytes[0x22_u8, 0xff_u8])},
      {"incomplete two-byte UTF-8", String.new(Bytes[0x22_u8, 0xc2_u8])},
      {"incomplete three-byte UTF-8", String.new(Bytes[0x22_u8, 0xe2_u8, 0x82_u8])},
      {"incomplete four-byte UTF-8", String.new(Bytes[0x22_u8, 0xf0_u8, 0x9d_u8, 0x84_u8])},
      {"invalid two-byte continuation", String.new(Bytes[0x22_u8, 0xc2_u8, 0x20_u8])},
      {"overlong three-byte UTF-8", String.new(Bytes[0x22_u8, 0xe0_u8, 0x80_u8, 0x80_u8])},
      {"UTF-8 encoded surrogate", String.new(Bytes[0x22_u8, 0xed_u8, 0xa0_u8, 0x80_u8])},
      {"UTF-8 above Unicode range", String.new(Bytes[0x22_u8, 0xf4_u8, 0x90_u8, 0x80_u8, 0x80_u8])},
    ]

    malformed_fragments.each do |name, fragment|
      source = " \n" + fragment
      expected_error = expect_raises(FusedJSON::ParseError) do
        in_memory = FusedJSON::PullParser.new(source)
        in_memory.skip_value
      end
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        max_chunk: 1,
        read_budget: source.bytesize + 2
      )
      actual_error = expect_raises(FusedJSON::ParseError) do
        streaming = FusedJSON::PullParser.new(io, buffer_size: 3)
        streaming.skip_value
      end

      actual_location = {
        actual_error.byte_offset,
        actual_error.line_number,
        actual_error.column_number,
      }
      expected_location = {
        expected_error.byte_offset,
        expected_error.line_number,
        expected_error.column_number,
      }
      unless actual_location == expected_location
        failures << "#{name}: got #{actual_location}, expected #{expected_location}"
      end
      failures << "#{name}: parser closed caller-owned IO" if io.closed_called
    end

    failures.should be_empty
  end

  it "rejects invalid streaming buffer sizes before reading the IO" do
    [0, -1, 16_777_217, Int64::MAX, UInt64::MAX].each do |buffer_size|
      io = StreamSpecSupport::ChunkedIO.new("null")
      expect_raises(ArgumentError) do
        FusedJSON::PullParser.new(io, buffer_size: buffer_size)
      end
      io.read_calls.should eq(0)
      io.closed_called.should be_false
    end
  end

  it "rejects invalid token limits before reading the IO" do
    [0, -1, Int64::MAX, UInt64::MAX].each do |max_token_bytes|
      io = StreamSpecSupport::ChunkedIO.new("null")
      expect_raises(ArgumentError, "max_token_bytes must be between 1 and #{Int32::MAX}") do
        FusedJSON::PullParser.new(io, max_token_bytes: max_token_bytes)
      end
      io.read_calls.should eq(0)
      io.closed_called.should be_false
    end
  end
end

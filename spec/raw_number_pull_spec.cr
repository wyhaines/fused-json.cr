require "./spec_helper"
require "./support/chunked_io"

module RawNumberPullSpec
  extend self

  UINT128_MAX_PLUS_ONE = "340282366920938463463374607431768211456"
  INT128_MIN_MINUS_ONE = "-170141183460469231731687303715884105729"
  VERY_WIDE_INTEGER    = "9" * 257
  OVERFLOWING_FLOAT    = "-7.5000000000000000000000000000000000000000000000000001E+9999"

  NUMBER_CASES = [
    {"0", FusedJSON::PullParser::Kind::Int},
    {"-0", FusedJSON::PullParser::Kind::Int},
    {"42", FusedJSON::PullParser::Kind::Int},
    {"-42", FusedJSON::PullParser::Kind::Int},
    {Int64::MIN.to_s, FusedJSON::PullParser::Kind::Int},
    {Int64::MAX.to_s, FusedJSON::PullParser::Kind::Int},
    {UINT128_MAX_PLUS_ONE, FusedJSON::PullParser::Kind::Int},
    {INT128_MIN_MINUS_ONE, FusedJSON::PullParser::Kind::Int},
    {VERY_WIDE_INTEGER, FusedJSON::PullParser::Kind::Int},
    {"0.0", FusedJSON::PullParser::Kind::Float},
    {"-0.0", FusedJSON::PullParser::Kind::Float},
    {"1e0", FusedJSON::PullParser::Kind::Float},
    {"1E+09", FusedJSON::PullParser::Kind::Float},
    {"-12.500e-004", FusedJSON::PullParser::Kind::Float},
    {"6.02214076E23", FusedJSON::PullParser::Kind::Float},
    {OVERFLOWING_FLOAT, FusedJSON::PullParser::Kind::Float},
  ]

  def each_parser(source : String, &)
    yield FusedJSON::PullParser.new(source), "in-memory"

    io = StreamSpecSupport::ChunkedIO.new(
      source,
      max_chunk: 1,
      read_budget: source.bytesize + 8
    )
    yield FusedJSON::PullParser.new(io, buffer_size: 1), "one-byte streaming"
    io.closed_called.should be_false
  end

  def cursor(pull : FusedJSON::PullParser)
    {pull.kind, pull.byte_offset, pull.location_i64}
  end

  def consume_for_malformed_number_check(pull : FusedJSON::PullParser) : Nil
    if pull.kind.int? || pull.kind.float?
      pull.read_raw_number
    else
      pull.skip
    end
    pull.finish
  end
end

describe "raw-number pull parsing" do
  it "preserves every root number lexeme without observing or consuming it early" do
    RawNumberPullSpec::NUMBER_CASES.each do |lexeme, expected_kind|
      source = " \n#{lexeme}\t "

      RawNumberPullSpec.each_parser(source) do |pull, mode|
        pull.kind.should eq(expected_kind), "#{mode}: #{lexeme}"
        pull.byte_offset.should eq(2_i64), "#{mode}: #{lexeme}"
        before = RawNumberPullSpec.cursor(pull)

        first = pull.raw_number_value
        second = pull.raw_number_value
        first.should eq(lexeme), "#{mode}: #{lexeme}"
        second.should eq(lexeme), "#{mode}: #{lexeme}"
        RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: #{lexeme}"

        pull.read_raw_number.should eq(lexeme), "#{mode}: #{lexeme}"
        pull.kind.should eq(FusedJSON::PullParser::Kind::EOF), "#{mode}: #{lexeme}"
        pull.byte_offset.should eq(source.bytesize.to_i64), "#{mode}: #{lexeme}"
        pull.finish

        # Returned lexemes must not alias reusable streaming scratch storage.
        first.should eq(lexeme), "#{mode}: retained #{lexeme}"
        second.should eq(lexeme), "#{mode}: retained #{lexeme}"
      end
    end
  end

  it "consumes exactly one numeric event in arrays" do
    source = "[#{RawNumberPullSpec::UINT128_MAX_PLUS_ONE},-0.0,1E+09,7]"

    RawNumberPullSpec.each_parser(source) do |pull, mode|
      pull.read_begin_array.should eq(FusedJSON::PullParser::Kind::Int)

      first = pull.read_raw_number
      first.should eq(RawNumberPullSpec::UINT128_MAX_PLUS_ONE), mode
      pull.kind.should eq(FusedJSON::PullParser::Kind::Float), mode
      pull.raw_number_value.should eq("-0.0"), mode

      second = pull.read_raw_number
      second.should eq("-0.0"), mode
      pull.kind.should eq(FusedJSON::PullParser::Kind::Float), mode
      pull.raw_number_value.should eq("1E+09"), mode

      pull.skip
      pull.kind.should eq(FusedJSON::PullParser::Kind::Int), mode
      pull.read_raw_number.should eq("7"), mode
      pull.kind.should eq(FusedJSON::PullParser::Kind::EndArray), mode
      pull.read_end_array.should eq(FusedJSON::PullParser::Kind::EOF)
      pull.finish

      first.should eq(RawNumberPullSpec::UINT128_MAX_PLUS_ONE), mode
      second.should eq("-0.0"), mode
    end
  end

  it "preserves numeric values and following keys in objects" do
    source = %({"integer":#{RawNumberPullSpec::INT128_MIN_MINUS_ONE},"float":#{RawNumberPullSpec::OVERFLOWING_FLOAT},"tail":true})

    RawNumberPullSpec.each_parser(source) do |pull, mode|
      pull.read_begin_object
      pull.read_object_key.should eq("integer"), mode
      pull.raw_number_value.should eq(RawNumberPullSpec::INT128_MIN_MINUS_ONE), mode
      pull.read_raw_number.should eq(RawNumberPullSpec::INT128_MIN_MINUS_ONE), mode

      pull.read_object_key.should eq("float"), mode
      pull.raw_number_value.should eq(RawNumberPullSpec::OVERFLOWING_FLOAT), mode
      pull.read_raw_number.should eq(RawNumberPullSpec::OVERFLOWING_FLOAT), mode

      pull.read_object_key.should eq("tail"), mode
      pull.read_bool.should be_true
      pull.read_end_object
      pull.finish
    end
  end

  it "skips arbitrarily wide numbers without materializing a machine number" do
    [
      RawNumberPullSpec::UINT128_MAX_PLUS_ONE,
      RawNumberPullSpec::INT128_MIN_MINUS_ONE,
      RawNumberPullSpec::VERY_WIDE_INTEGER,
      RawNumberPullSpec::OVERFLOWING_FLOAT,
    ].each do |lexeme|
      RawNumberPullSpec.each_parser(lexeme) do |pull, mode|
        pull.skip
        pull.kind.should eq(FusedJSON::PullParser::Kind::EOF), "#{mode}: #{lexeme}"
        pull.finish
      end
    end

    source = "[#{RawNumberPullSpec::VERY_WIDE_INTEGER},#{RawNumberPullSpec::OVERFLOWING_FLOAT},11]"
    RawNumberPullSpec.each_parser(source) do |pull, mode|
      pull.read_begin_array
      pull.skip_value
      pull.raw_number_value.should eq(RawNumberPullSpec::OVERFLOWING_FLOAT), mode
      pull.skip_value
      pull.read_int.should eq(11_i64), mode
      pull.read_end_array
      pull.finish
    end
  end

  it "rejects raw-number access for every non-number event without advancing" do
    ["null", "true", %q("text"), "[]", "{}"].each do |source|
      RawNumberPullSpec.each_parser(source) do |pull, mode|
        before = RawNumberPullSpec.cursor(pull)
        expect_raises(FusedJSON::ParseError) { pull.raw_number_value }
        RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: #{source}"
        expect_raises(FusedJSON::ParseError) { pull.read_raw_number }
        RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: #{source}"
      end
    end
  end

  it "rejects raw-number access at object keys, container ends, and EOF" do
    RawNumberPullSpec.each_parser(%({"key":1})) do |pull, mode|
      pull.read_begin_object
      key_cursor = RawNumberPullSpec.cursor(pull)
      expect_raises(FusedJSON::ParseError) { pull.raw_number_value }
      expect_raises(FusedJSON::ParseError) { pull.read_raw_number }
      RawNumberPullSpec.cursor(pull).should eq(key_cursor), mode
      pull.read_object_key.should eq("key")
      pull.read_raw_number.should eq("1")
      pull.read_end_object

      eof_cursor = RawNumberPullSpec.cursor(pull)
      expect_raises(FusedJSON::ParseError) { pull.raw_number_value }
      expect_raises(FusedJSON::ParseError) { pull.read_raw_number }
      RawNumberPullSpec.cursor(pull).should eq(eof_cursor), mode
    end

    RawNumberPullSpec.each_parser("[]") do |pull, mode|
      pull.read_begin_array
      end_cursor = RawNumberPullSpec.cursor(pull)
      expect_raises(FusedJSON::ParseError) { pull.raw_number_value }
      expect_raises(FusedJSON::ParseError) { pull.read_raw_number }
      RawNumberPullSpec.cursor(pull).should eq(end_cursor), mode
      pull.read_end_array
      pull.finish
    end
  end

  it "keeps checked integer conversions range-bound and non-consuming on failure" do
    [
      RawNumberPullSpec::UINT128_MAX_PLUS_ONE,
      RawNumberPullSpec::INT128_MIN_MINUS_ONE,
      RawNumberPullSpec::VERY_WIDE_INTEGER,
    ].each do |lexeme|
      RawNumberPullSpec.each_parser(lexeme) do |pull, mode|
        before = RawNumberPullSpec.cursor(pull)

        expect_raises(FusedJSON::ParseError, "integer is outside Int64 range") { pull.int_value }
        RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: int_value #{lexeme}"
        pull.raw_number_value.should eq(lexeme)

        expect_raises(FusedJSON::ParseError, "integer is outside Int64 range") { pull.read_int }
        RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: read_int #{lexeme}"
        pull.raw_number_value.should eq(lexeme)

        expect_raises(FusedJSON::ParseError, "integer is outside Int64 range") { pull.read_float }
        RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: read_float #{lexeme}"
        pull.read_raw_number.should eq(lexeme)
        pull.finish
      end
    end
  end

  it "keeps checked float conversions finite and non-consuming on failure" do
    RawNumberPullSpec.each_parser(RawNumberPullSpec::OVERFLOWING_FLOAT) do |pull, mode|
      before = RawNumberPullSpec.cursor(pull)

      expect_raises(FusedJSON::ParseError, "number is outside Float64 range") { pull.float_value }
      RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: float_value"
      pull.raw_number_value.should eq(RawNumberPullSpec::OVERFLOWING_FLOAT)

      expect_raises(FusedJSON::ParseError, "number is outside Float64 range") { pull.read_float }
      RawNumberPullSpec.cursor(pull).should eq(before), "#{mode}: read_float"
      pull.read_raw_number.should eq(RawNumberPullSpec::OVERFLOWING_FLOAT)
      pull.finish
    end
  end

  it "retains checked conversion behavior for representable values" do
    RawNumberPullSpec.each_parser("[#{Int64::MIN},#{Int64::MAX},-0,-0.0,1.25e2]") do |pull, mode|
      pull.read_begin_array

      pull.int_value.should eq(Int64::MIN), mode
      pull.int_value.should eq(Int64::MIN), mode
      pull.raw_number_value.should eq(Int64::MIN.to_s), mode
      pull.read_int.should eq(Int64::MIN), mode

      pull.raw_number_value.should eq(Int64::MAX.to_s), mode
      pull.read_float.should eq(Int64::MAX.to_f64), mode
      pull.read_int.should eq(0_i64), mode

      negative_zero = pull.read_float
      negative_zero.unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64), mode
      pull.float_value.should eq(125.0), mode
      pull.float_value.should eq(125.0), mode
      pull.read_float.should eq(125.0), mode

      pull.read_end_array
      pull.finish
    end
  end

  it "preserves raw numbers at every source split with tiny streaming buffers" do
    lexemes = [
      RawNumberPullSpec::UINT128_MAX_PLUS_ONE,
      "-0.000e+10",
      RawNumberPullSpec::OVERFLOWING_FLOAT,
    ]
    source = "[#{lexemes.join(',')}]"

    (1...source.bytesize).each do |split|
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        chunks: [split, source.bytesize - split],
        max_chunk: 2,
        read_budget: source.bytesize + 8
      )
      pull = FusedJSON::PullParser.new(io, buffer_size: 3)
      actual = [] of String
      pull.read_array { actual << pull.read_raw_number }
      pull.finish

      actual.should eq(lexemes), "source split #{split}/#{source.bytesize}"
      io.bytes_read.should eq(source.bytesize)
      io.closed_called.should be_false
    end
  end

  it "applies max_token_bytes to raw number scanning" do
    [RawNumberPullSpec::VERY_WIDE_INTEGER, RawNumberPullSpec::OVERFLOWING_FLOAT].each do |lexeme|
      accepted_io = StreamSpecSupport::ChunkedIO.new(lexeme, max_chunk: 1)
      accepted = FusedJSON::PullParser.new(
        accepted_io,
        buffer_size: 1,
        max_token_bytes: lexeme.bytesize
      )
      accepted.raw_number_value.should eq(lexeme)
      accepted.read_raw_number.should eq(lexeme)
      accepted.finish

      rejected_io = StreamSpecSupport::ChunkedIO.new(lexeme, max_chunk: 1)
      error = expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
        FusedJSON::PullParser.new(
          rejected_io,
          buffer_size: 1,
          max_token_bytes: lexeme.bytesize - 1
        )
      end
      error.byte_offset.should eq(0_i64)
      rejected_io.closed_called.should be_false
    end

    container = "[#{RawNumberPullSpec::VERY_WIDE_INTEGER}]"
    io = StreamSpecSupport::ChunkedIO.new(container, max_chunk: 1)
    pull = FusedJSON::PullParser.new(
      io,
      buffer_size: 1,
      max_token_bytes: RawNumberPullSpec::VERY_WIDE_INTEGER.bytesize - 1
    )
    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      pull.read_begin_array
    end
  end

  it "rejects malformed JSON number grammar before raw access can accept it" do
    malformed = [
      "-",
      "01",
      "-01",
      "1.",
      ".1",
      "+1",
      "1e",
      "1e+",
      "1e-",
      "--1",
      "1_0",
      "NaN",
      "Infinity",
    ]

    malformed.each do |source|
      expect_raises(FusedJSON::ParseError) do
        pull = FusedJSON::PullParser.new(source)
        RawNumberPullSpec.consume_for_malformed_number_check(pull)
      end

      io = StreamSpecSupport::ChunkedIO.new(
        source,
        max_chunk: 1,
        read_budget: source.bytesize + 4
      )
      expect_raises(FusedJSON::ParseError) do
        pull = FusedJSON::PullParser.new(io, buffer_size: 1)
        RawNumberPullSpec.consume_for_malformed_number_check(pull)
      end
      io.closed_called.should be_false
    end
  end

  it "keeps dynamic parsing checked while pull traversal remains range-neutral" do
    [
      RawNumberPullSpec::UINT128_MAX_PLUS_ONE,
      RawNumberPullSpec::INT128_MIN_MINUS_ONE,
      RawNumberPullSpec::VERY_WIDE_INTEGER,
      RawNumberPullSpec::OVERFLOWING_FLOAT,
    ].each do |lexeme|
      expect_raises(FusedJSON::ParseError) { FusedJSON.load(lexeme) }

      io = StreamSpecSupport::ChunkedIO.new(lexeme, max_chunk: 1)
      expect_raises(FusedJSON::ParseError) do
        FusedJSON.load(io, buffer_size: 1)
      end
      io.closed_called.should be_false
    end
  end
end

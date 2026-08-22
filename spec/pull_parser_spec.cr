require "./spec_helper"
require "./support/pull_helpers"

private def pull_from_ephemeral_source : FusedJSON::PullParser
  source = String.new(%q(["plain","line\nλ\uD834\uDD1E"]).to_slice)
  pull = FusedJSON::PullParser.new(source)
  pull.read_begin_array
  pull
end

describe FusedJSON::PullParser do
  it "exposes every semantic event and scalar value" do
    source = %q({"values":[null,false,true,-9223372036854775808,9223372036854775807,-0.0,1.25e2,"plain","line\nλ\uD834\uDD1E"],"empty":{}})
    pull = FusedJSON::PullParser.new(source)

    pull.kind.should eq(FusedJSON::PullParser::Kind::BeginObject)
    pull.location.should eq({1, 1})
    pull.read_begin_object
    pull.read_object_key.should eq("values")
    pull.read_begin_array
    pull.read_null.should be_nil
    pull.read_bool.should be_false
    pull.read_bool.should be_true
    pull.read_int.should eq(Int64::MIN)
    pull.read_int.should eq(Int64::MAX)

    negative_zero = pull.read_float
    negative_zero.unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64)
    pull.read_float.should eq(125.0)
    pull.read_string.should eq("plain")
    pull.read_string.should eq("line\nλ𝄞")
    pull.read_end_array
    pull.read_object_key.should eq("empty")
    pull.read_begin_object
    pull.read_end_object
    pull.read_end_object.should eq(FusedJSON::PullParser::Kind::EOF)
    pull.finish
  end

  it "builds the same dynamic values as the specialized parser" do
    documents = [
      "null",
      "true",
      "-12",
      "3.5e2",
      %q("escaped\nλ\uD834\uDD1E"),
      %q([1,true,null,{"nested":["x",2.5]}]),
      %q({"a":1,"b":[],"c":{}}),
    ]

    documents.each do |source|
      PullSpecHelpers.to_any(source).should eq(FusedJSON.load(source))
    end
  end

  it "reads array and object blocks" do
    pull = FusedJSON::PullParser.new(%q({"a":[1,2],"b":3}))
    values = {} of String => Array(Int64)

    pull.read_object do |key, location|
      location[0].should eq(1)
      if key == "a"
        items = [] of Int64
        pull.read_array { items << pull.read_int }
        values[key] = items
      else
        values[key] = [pull.read_int]
      end
    end

    values.should eq({"a" => [1_i64, 2_i64], "b" => [3_i64]})
    pull.finish
  end

  it "keeps returned strings alive independently of parser progress" do
    retained = begin
      source = String.new(%q({"plain":"value","escaped":"line\nλ\uD834\uDD1E"}).to_slice)
      pull = FusedJSON::PullParser.new(source)
      pull.read_begin_object
      first_key = pull.read_object_key
      first_value = pull.read_string
      second_key = pull.read_object_key
      second_value = pull.read_string
      pull.read_end_object
      {first_key, first_value, second_key, second_value}
    end

    GC.collect
    Array.new(1_000) { |index| "allocation-#{index}" }
    retained.should eq({"plain", "value", "escaped", "line\nλ𝄞"})
  end

  it "retains an ephemeral source until lazy strings are consumed" do
    pull = pull_from_ephemeral_source
    GC.collect
    Array.new(1_000) { |index| "source-churn-#{index}" }

    pull.read_string.should eq("plain")
    pull.read_string.should eq("line\nλ𝄞")
    pull.read_end_array
  end

  it "exposes duplicate keys in source order" do
    pull = FusedJSON::PullParser.new(%q({"a":1,"\u0061":2}))
    keys = [] of String
    values = [] of Int64

    pull.read_object do |key, _location|
      keys << key
      values << pull.read_int
    end

    keys.should eq(["a", "a"])
    values.should eq([1_i64, 2_i64])
    PullSpecHelpers.to_any(%q({"a":1,"\u0061":2}))["a"].as_i64.should eq(2_i64)
  end

  it "keeps key pooling local to one reader" do
    source = String.new(%q({"a":1,"\u0061":2}).to_slice)
    cached = FusedJSON::PullParser.new(source, cache_keys: true)
    cached.read_begin_object
    first_key = cached.read_object_key
    cached.read_int
    second_key = cached.read_object_key
    cached.read_int
    cached.read_end_object

    first_key.same?(second_key).should be_true

    other = FusedJSON::PullParser.new(String.new(%q({"a":3}).to_slice), cache_keys: true)
    other.read_begin_object
    other_key = other.read_object_key
    first_key.same?(other_key).should be_false
  end

  it "can consume two readers independently" do
    first = FusedJSON::PullParser.new("[1,2]")
    second = FusedJSON::PullParser.new(%q({"x":true}))

    first.read_begin_array
    second.read_begin_object
    first.read_int.should eq(1_i64)
    second.read_object_key.should eq("x")
    second.read_bool.should be_true
    first.read_int.should eq(2_i64)
    first.read_end_array
    second.read_end_object
  end

  it "does not advance when a read method sees the wrong kind" do
    pull = FusedJSON::PullParser.new("1.5")
    original = {pull.kind, pull.byte_offset, pull.location}

    expect_raises(FusedJSON::ParseError) { pull.read_int }
    {pull.kind, pull.byte_offset, pull.location}.should eq(original)
    pull.read_float.should eq(1.5)
  end

  it "converts integer events when read as floats" do
    pull = FusedJSON::PullParser.new("42")
    pull.read_float.should eq(42.0)
    pull.kind.should eq(FusedJSON::PullParser::Kind::EOF)
    pull.read_next.should eq(FusedJSON::PullParser::Kind::EOF)
    pull.read_next.should eq(FusedJSON::PullParser::Kind::EOF)
  end

  it "requires object-key context" do
    pull = FusedJSON::PullParser.new(%q("value"))
    event = {pull.kind, pull.byte_offset}

    expect_raises(FusedJSON::ParseError) { pull.read_object_key }
    {pull.kind, pull.byte_offset}.should eq(event)
    pull.read_string.should eq("value")
  end

  it "rejects non-consuming and partially consuming helper blocks" do
    array = FusedJSON::PullParser.new("[1]")
    expect_raises(FusedJSON::ParseError) do
      array.read_array { }
    end

    nested = FusedJSON::PullParser.new("[[1]]")
    expect_raises(FusedJSON::ParseError) do
      nested.read_array { nested.read_begin_array }
    end

    migrated = FusedJSON::PullParser.new("[[1],[2]]")
    migrated.read_begin_array
    expect_raises(FusedJSON::ParseError) do
      migrated.read_array do
        migrated.read_int
        migrated.read_end_array
        migrated.read_begin_array
      end
    end

    object = FusedJSON::PullParser.new(%q({"a":"value"}))
    expect_raises(FusedJSON::ParseError) do
      object.read_object { |_key| }
    end
  end

  it "skips scalar and nested values while preserving following events" do
    pull = FusedJSON::PullParser.new(%q({"ignored":{"text":"line\nλ","values":[1,{"x":2}]},"wanted":42}))
    pull.read_begin_object
    pull.read_object_key.should eq("ignored")
    pull.skip_value
    pull.read_object_key.should eq("wanted")
    pull.read_int.should eq(42_i64)
    pull.read_end_object

    ["null", "false", "1", "1.5", %q("text")].each do |source|
      scalar = FusedJSON::PullParser.new(source)
      scalar.skip
      scalar.kind.should eq(FusedJSON::PullParser::Kind::EOF)
    end
  end

  it "selectively skips first, middle, and last array values" do
    pull = FusedJSON::PullParser.new(%q([{"first":1},2,[3],4,{"last":5}]))
    pull.read_begin_array
    pull.skip_value
    pull.read_int.should eq(2_i64)
    pull.skip_value
    pull.read_int.should eq(4_i64)
    pull.skip_value
    pull.kind.should eq(FusedJSON::PullParser::Kind::EndArray)
    pull.read_end_array
  end

  it "reports exact locations for successful Unicode events" do
    pull = FusedJSON::PullParser.new(" \n[\"λ\", {\"𝄞\": true}]\n")

    {pull.byte_offset, pull.location}.should eq({2, {2, 1}})
    pull.location.should eq({2, 1})
    pull.read_begin_array
    {pull.byte_offset, pull.location}.should eq({3, {2, 2}})
    pull.read_string
    {pull.byte_offset, pull.location}.should eq({9, {2, 7}})
    pull.read_begin_object
    {pull.byte_offset, pull.location}.should eq({10, {2, 8}})
    pull.read_object_key
    {pull.byte_offset, pull.location}.should eq({18, {2, 13}})
    pull.read_bool
    {pull.byte_offset, pull.location}.should eq({22, {2, 17}})
    pull.read_end_object
    {pull.byte_offset, pull.location}.should eq({23, {2, 18}})
    pull.read_end_array
    {pull.byte_offset, pull.location}.should eq({25, {3, 1}})
  end

  it "validates malformed content inside skipped containers" do
    invalid = [
      %q([{"x":"\uD800"}]),
      %q([{"x":"\x"}]),
      %q([1,]),
      %q({"x":[1 2]}),
      %q({"x":1} trailing),
    ]

    invalid.each do |source|
      expect_raises(FusedJSON::ParseError) do
        PullSpecHelpers.skip(source)
      end
    end
  end

  it "rejects malformed documents through pull traversal" do
    invalid = [
      "",
      " ",
      "tru",
      "01",
      "-",
      "1.",
      "1e+",
      %q("bad\xescape"),
      %q("\uDC00"),
      %q({"a" 1}),
      %q({"a":}),
      "[1,]",
      "true false",
    ]

    invalid.each do |source|
      expect_raises(FusedJSON::ParseError) do
        PullSpecHelpers.skip(source)
      end
    end
  end

  it "matches dynamic-parser error locations" do
    source = "{\n  \"λ\": true,\n  \"𝄞\": ]\n}"
    dynamic_error = expect_raises(FusedJSON::ParseError) { FusedJSON.load(source) }
    pull_error = expect_raises(FusedJSON::ParseError) { PullSpecHelpers.skip(source) }

    pull_error.byte_offset.should eq(dynamic_error.byte_offset)
    pull_error.line_number.should eq(dynamic_error.line_number)
    pull_error.column_number.should eq(dynamic_error.column_number)
  end

  it "enforces nesting limits while traversing and skipping" do
    source_512 = ("[" * 512) + "0" + ("]" * 512)
    source_513 = ("[" * 513) + "0" + ("]" * 513)

    PullSpecHelpers.skip(source_512)
    PullSpecHelpers.to_any("[[0]]", max_nesting: 2).should eq(JSON.parse("[[0]]"))
    expect_raises(FusedJSON::ParseError) { PullSpecHelpers.skip(source_513) }
    expect_raises(FusedJSON::ParseError) { PullSpecHelpers.skip("[[0]]", max_nesting: 1) }

    [0, -1, 513, Int64::MAX, UInt64::MAX].each do |limit|
      expect_raises(ArgumentError, "max_nesting must be between 1 and 512") do
        FusedJSON::PullParser.new("0", max_nesting: limit)
      end
    end
  end

  it "rejects skipping keys, ends, and EOF" do
    pull = FusedJSON::PullParser.new(%q({"a":1}))
    pull.read_begin_object
    expect_raises(FusedJSON::ParseError) { pull.skip_value }
    pull.read_object_key
    pull.skip_value
    expect_raises(FusedJSON::ParseError) { pull.skip_value }
    pull.read_end_object
    expect_raises(FusedJSON::ParseError) { pull.skip_value }
  end
end

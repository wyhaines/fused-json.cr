require "./spec_helper"

describe FusedJSON do
  describe ".load" do
    it "parses all JSON scalar types" do
      {
        "null"                 => JSON::Any.new(nil),
        "true"                 => JSON::Any.new(true),
        "false"                => JSON::Any.new(false),
        "0"                    => JSON::Any.new(0_i64),
        "-9223372036854775808" => JSON::Any.new(Int64::MIN),
        "9223372036854775807"  => JSON::Any.new(Int64::MAX),
        "-12.5e+2"             => JSON::Any.new(-1250.0),
        %q("plain text")       => JSON::Any.new("plain text"),
      }.each do |source, expected|
        FusedJSON.load(source).should eq(expected)
      end
    end

    it "preserves dynamic integer and float variants" do
      FusedJSON.load("0").raw.should be_a(Int64)
      FusedJSON.load(Int64::MIN.to_s).as_i64.should eq(Int64::MIN)
      FusedJSON.load(Int64::MAX.to_s).as_i64.should eq(Int64::MAX)
      FusedJSON.load("0.0").raw.should be_a(Float64)
      FusedJSON.load("1e0").raw.should be_a(Float64)
    end

    it "builds nested arrays and objects" do
      source = %q({"name":"fused","values":[1,true,null,{"x":2.5}]})

      FusedJSON.load(source).should eq(JSON.parse(source))
    end

    it "decodes escapes, unicode, and surrogate pairs" do
      source = %q({"escaped":"line\nfeed\t\\\"","unicode":"λ","escaped_unicode":"\u03bb","pair":"\uD834\uDD1E"})

      FusedJSON.load(source).should eq(JSON.parse(source))
    end

    it "allows JSON whitespace around and inside a document" do
      source = " \t\r\n { \"a\" : [ 1, 2 ] } \n"

      FusedJSON.load(source).should eq(JSON.parse(source))
    end

    it "uses the last value for duplicate object keys" do
      FusedJSON.load(%q({"a":1,"a":2}))["a"].as_i64.should eq(2_i64)
    end

    it "enforces the configured nesting limit" do
      source = "[[[[0]]]]"

      FusedJSON.load(source, max_nesting: 4).should eq(JSON.parse(source))
      expect_raises(FusedJSON::ParseError) do
        FusedJSON.load(source, max_nesting: 3)
      end
    end

    it "reports the byte offset and location of invalid input" do
      error = expect_raises(FusedJSON::ParseError) do
        FusedJSON.load("{\n  \"a\": 1,\n}")
      end

      error.byte_offset.should be > 0
      error.line_number.should eq(3)
    end

    it "rejects malformed documents" do
      invalid = [
        "",
        " ",
        "[",
        %q({"a":1),
        "[1,]",
        %q({"a":1,}),
        "01",
        "-",
        "1.",
        "1e",
        "1e+",
        "--1",
        "true false",
        %q("bad\xescape"),
        %q("\uD800"),
        %q("\uDC00"),
      ]

      invalid.each do |source|
        expect_raises(FusedJSON::ParseError) do
          FusedJSON.load(source)
        end
      end
    end

    it "rejects integers outside Crystal JSON's Int64 domain" do
      expect_raises(FusedJSON::ParseError) { FusedJSON.load("9223372036854775808") }
      expect_raises(FusedJSON::ParseError) { FusedJSON.load("-9223372036854775809") }
    end
  end
end

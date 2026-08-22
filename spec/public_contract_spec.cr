require "yaml"

require "./spec_helper"

private class PublicContractUnreadableIO < IO
  getter read_count = 0

  def read(slice : Bytes) : Int32
    @read_count += 1
    raise IO::Error.new("input must not be read")
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("test input is read-only")
  end
end

private def expect_option_error_before_read(&block : IO -> T) : Nil forall T
  io = PublicContractUnreadableIO.new
  expect_raises(ArgumentError) { yield io }
  io.read_count.should eq(0)
end

describe "public API contract" do
  it "keeps the source and shard versions synchronized" do
    manifest = YAML.parse(File.read(File.expand_path("../shard.yml", __DIR__)))
    FusedJSON::VERSION.should eq(manifest["version"].as_s)
    FusedJSON::VERSION.should match(/\A\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?\z/)
  end

  it "exposes structured parse locations through JSON::ParseException" do
    error = expect_raises(FusedJSON::ParseError) do
      FusedJSON.load(%({\n"a":x}))
    end

    error.should be_a(JSON::ParseException)
    error.byte_offset.should eq(6)
    error.line_number.should eq(2)
    error.column_number.should eq(5)
  end

  it "rejects invalid String options through every public entry point" do
    expect_raises(ArgumentError) { FusedJSON.load("0", max_nesting: 0) }
    expect_raises(ArgumentError) { FusedJSON.parse("0", max_nesting: 0) }
    expect_raises(ArgumentError) { FusedJSON.from_json("0", Int32, max_nesting: 0) }
    expect_raises(ArgumentError) { FusedJSON::PullParser.new("0", max_nesting: 0) }
  end

  it "rejects invalid IO buffer sizes before reading" do
    expect_option_error_before_read { |io| FusedJSON.load(io, buffer_size: 0) }
    expect_option_error_before_read { |io| FusedJSON.parse(io, buffer_size: 0) }
    expect_option_error_before_read { |io| FusedJSON.from_json(io, Int32, buffer_size: 0) }
    expect_option_error_before_read { |io| FusedJSON::PullParser.new(io, buffer_size: 0) }
  end

  it "rejects invalid IO nesting limits before reading" do
    expect_option_error_before_read { |io| FusedJSON.load(io, max_nesting: 0) }
    expect_option_error_before_read { |io| FusedJSON.parse(io, max_nesting: 0) }
    expect_option_error_before_read { |io| FusedJSON.from_json(io, Int32, max_nesting: 0) }
    expect_option_error_before_read { |io| FusedJSON::PullParser.new(io, max_nesting: 0) }
  end

  it "rejects invalid IO token limits before reading" do
    expect_option_error_before_read { |io| FusedJSON.load(io, max_token_bytes: 0) }
    expect_option_error_before_read { |io| FusedJSON.parse(io, max_token_bytes: 0) }
    expect_option_error_before_read { |io| FusedJSON.from_json(io, Int32, max_token_bytes: 0) }
    expect_option_error_before_read { |io| FusedJSON::PullParser.new(io, max_token_bytes: 0) }
  end
end

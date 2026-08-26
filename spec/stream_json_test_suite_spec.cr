require "./spec_helper"
require "./support/chunked_io"
require "./support/json_test_suite"
require "./support/pull_helpers"

private def stream_fixture_value(source : String) : JSON::Any
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    max_chunk: 1,
    read_budget: source.bytesize + 2
  )
  pull = FusedJSON::PullParser.new(io, buffer_size: 3)
  value = PullSpecHelpers.read_any(pull)
  pull.finish

  raise "parser closed caller-owned IO" if io.closed_called
  raise "parser did not consume the complete fixture" unless io.bytes_read == source.bytesize
  value
end

private def stream_fixture_skip(source : String) : Nil
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    max_chunk: 1,
    read_budget: source.bytesize + 2
  )
  pull = FusedJSON::PullParser.new(io, buffer_size: 3)
  pull.skip_value
  pull.finish

  raise "parser closed caller-owned IO" if io.closed_called
  raise "parser did not consume the complete fixture" unless io.bytes_read == source.bytesize
end

private def dynamic_stream_fixture_value(source : String) : JSON::Any
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    max_chunk: 1,
    read_budget: source.bytesize + 2
  )
  value = FusedJSON.load(io, buffer_size: 3)

  raise "parser closed caller-owned IO" if io.closed_called
  raise "parser did not consume the complete fixture" unless io.bytes_read == source.bytesize
  value
end

private def stream_fixture_rejection(source : String, *, skip : Bool) : String?
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    max_chunk: 1,
    read_budget: source.bytesize + 2
  )

  begin
    pull = FusedJSON::PullParser.new(io, buffer_size: 3)
    skip ? pull.skip_value : PullSpecHelpers.read_any(pull)
    pull.finish
    "accepted"
  rescue FusedJSON::ParseError
    io.closed_called ? "rejected after closing caller-owned IO" : nil
  rescue error
    "#{error.class}: #{error.message}"
  end
end

private def dynamic_stream_fixture_rejection(source : String) : String?
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    max_chunk: 1,
    read_budget: source.bytesize + 2
  )

  begin
    FusedJSON.load(io, buffer_size: 3)
    "accepted"
  rescue FusedJSON::ParseError
    io.closed_called ? "rejected after closing caller-owned IO" : nil
  rescue error
    "#{error.class}: #{error.message}"
  end
end

describe "streaming JSONTestSuite conformance" do
  it "builds and skips every required-valid fixture one byte at a time" do
    failures = [] of String

    JSONTestSuiteSupport.names("y").each do |name|
      source = JSONTestSuiteSupport.source(name)
      begin
        actual = stream_fixture_value(source)
        dynamic = dynamic_stream_fixture_value(source)
        expected = PullSpecHelpers.to_any(source)
        failures << "#{name}: value mismatch" unless actual == expected
        failures << "#{name}: dynamic value mismatch" unless dynamic == expected
        stream_fixture_skip(source)
      rescue error
        failures << "#{name}: #{error.class}: #{error.message}"
      end
    end

    failures.should be_empty
  end

  it "rejects every required-invalid fixture while building and skipping" do
    failures = [] of String

    JSONTestSuiteSupport.names("n").each do |name|
      source = JSONTestSuiteSupport.source(name)
      if error = stream_fixture_rejection(source, skip: false)
        failures << "#{name} build: #{error}"
      end
      if error = dynamic_stream_fixture_rejection(source)
        failures << "#{name} dynamic build: #{error}"
      end
      if error = stream_fixture_rejection(source, skip: true)
        failures << "#{name} skip: #{error}"
      end
    end

    failures.should be_empty
  end

  it "applies the complete implementation-defined fixture policy" do
    failures = [] of String

    JSONTestSuiteSupport::I_ACCEPT.&(JSONTestSuiteSupport::I_REJECT).should be_empty
    (JSONTestSuiteSupport::I_ACCEPT + JSONTestSuiteSupport::I_REJECT).sort.should eq(
      JSONTestSuiteSupport.names("i")
    )

    JSONTestSuiteSupport::I_ACCEPT.each do |name|
      source = JSONTestSuiteSupport.source(name)
      begin
        actual = stream_fixture_value(source)
        dynamic = dynamic_stream_fixture_value(source)
        expected = PullSpecHelpers.to_any(source)
        failures << "#{name}: value mismatch" unless actual == expected
        failures << "#{name}: dynamic value mismatch" unless dynamic == expected
        stream_fixture_skip(source)
      rescue error
        failures << "#{name}: #{error.class}: #{error.message}"
      end
    end

    JSONTestSuiteSupport::I_REJECT.each do |name|
      source = JSONTestSuiteSupport.source(name)
      if error = stream_fixture_rejection(source, skip: false)
        failures << "#{name} build: #{error}"
      end
      if error = dynamic_stream_fixture_rejection(source)
        failures << "#{name} dynamic build: #{error}"
      end
      skip_error = stream_fixture_rejection(source, skip: true)
      if JSONTestSuiteSupport::I_RANGE_NEUTRAL_NUMBERS.includes?(name)
        unless skip_error == "accepted"
          failures << "#{name} skip: #{skip_error || "rejected"}"
        end
      elsif skip_error
        failures << "#{name} skip: #{skip_error}"
      end
    end

    failures.should be_empty
  end
end

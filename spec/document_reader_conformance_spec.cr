require "./spec_helper"
require "./support/chunked_io"
require "./support/json_test_suite"

private def json_whitespace_only?(source : String) : Bool
  source.each_byte.all? do |byte|
    byte == 0x20_u8 || byte == 0x09_u8 || byte == 0x0a_u8 || byte == 0x0d_u8
  end
end

describe "FusedJSON::DocumentReader conformance" do
  it "preserves every accepted JSONTestSuite value in a whitespace sequence" do
    names = JSONTestSuiteSupport.names("y") + JSONTestSuiteSupport::I_ACCEPT
    records = names.map { |name| JSONTestSuiteSupport.source(name) }
    expected = records.map { |record| FusedJSON.load(record) }
    source = records.join('\n')

    reader = FusedJSON.documents(
      StreamSpecSupport::ChunkedIO.new(source, max_chunk: 19),
      framing: FusedJSON::DocumentFraming::WhitespaceSeparated,
      buffer_size: 17
    )

    reader.to_a.should eq(expected)
    reader.documents_read.should eq(records.size)
  end

  it "preserves every single-line accepted JSONTestSuite value in NDJSON" do
    records = (JSONTestSuiteSupport.names("y") + JSONTestSuiteSupport::I_ACCEPT)
      .map { |name| JSONTestSuiteSupport.source(name) }
      .reject { |record| record.includes?('\n') || record.includes?('\r') }
    expected = records.map { |record| FusedJSON.load(record) }
    source = records.join("\r\n") + "\r\n"

    reader = FusedJSON.documents(
      StreamSpecSupport::ChunkedIO.new(source, max_chunk: 23),
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 13
    )

    reader.to_a.should eq(expected)
    reader.documents_read.should eq(records.size)
  end

  it "rejects single-line JSONTestSuite failures after a valid NDJSON record" do
    failures = [] of String

    JSONTestSuiteSupport.names("n").each do |name|
      record = JSONTestSuiteSupport.source(name)
      next if record.includes?('\n') || record.includes?('\r')
      next if json_whitespace_only?(record)

      source = "0\n" + record + "\n"
      reader = FusedJSON.documents(
        StreamSpecSupport::ChunkedIO.new(source, max_chunk: 7),
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: 5
      )

      begin
        reader.next.should eq(JSON::Any.new(0_i64))
        reader.next
        failures << "#{name}: accepted"
      rescue error : FusedJSON::ParseError
        unless error.byte_offset >= 2 && reader.documents_read == 1
          failures << "#{name}: wrong location or document count"
        end
      rescue error
        failures << "#{name}: #{error.class}: #{error.message}"
      end
    end

    failures.should be_empty
  end

  it "matches isolated parsing across deterministic mixed sequences" do
    records = [
      "null",
      "true",
      "-0",
      "6.022e23",
      %q("line\nfeed\r\t\u03bb"),
      %q([0,{"same":1,"escaped":"quote\"slash\\"},[]]),
      %q({"same":2,"\u0073ame":3,"non_ascii":"мир"}),
    ]
    expected = records.map { |record| FusedJSON.load(record) }

    24.times do |rotation|
      ordered = records.rotate(rotation % records.size)
      separator = [" ", "\t", "\n", "\r", " \r\n\t"][rotation % 5]
      source = ordered.join(separator)
      reader = FusedJSON.documents(
        StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1 + rotation % 11),
        framing: FusedJSON::DocumentFraming::WhitespaceSeparated,
        buffer_size: 1 + rotation % 9,
        cache_keys: rotation.even?
      )

      reader.to_a.should eq(expected.rotate(rotation % records.size))
    end
  end
end

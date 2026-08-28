require "./spec_helper"
require "./support/chunked_io"
require "big/json"

private enum DocumentReaderRole
  User
  Admin
end

private module DocumentReaderHexConverter
  def self.from_json(pull : JSON::PullParser) : Int32
    pull.read_string.to_i(16)
  end
end

private class DocumentReaderRecord
  include JSON::Serializable

  getter id : UInt128
  getter name : String
  getter roles : Array(DocumentReaderRole)

  @[JSON::Field(converter: DocumentReaderHexConverter)]
  getter color : Int32
end

private class DocumentReaderRawRecord
  include JSON::Serializable

  @[JSON::Field(converter: String::RawConverter)]
  getter raw : String

  getter tail : Int32
end

class DocumentReaderAlpha
  include JSON::Serializable

  getter alpha : String
end

class DocumentReaderBeta
  include JSON::Serializable

  getter beta : Int32
  getter wide : UInt128
end

private struct DocumentReaderConsumesNothing
  private def initialize(@marker : Bool)
  end

  def self.new(pull : JSON::PullParser) : self
    new(false)
  end
end

private struct DocumentReaderConsumesPartial
  private def initialize(@marker : Bool)
  end

  def self.new(pull : JSON::PullParser) : self
    pull.read_begin_array
    new(false)
  end
end

private struct DocumentReaderConsumesMultiple
  private def initialize(@marker : Bool)
  end

  def self.new(pull : JSON::PullParser) : self
    pull.read_int
    pull.read_int
    new(false)
  end
end

private class DocumentReaderRetainsAdapter
  @@retained : JSON::PullParser?

  getter value : Int32

  private def initialize(@value : Int32)
  end

  def self.new(pull : JSON::PullParser) : self
    value = pull.read_int.to_i32
    @@retained = pull
    new(value)
  end

  def self.retained : JSON::PullParser
    @@retained || raise "adapter was not retained"
  end
end

private class DocumentReaderWrongType
  include JSON::Serializable

  getter id : Int32
end

private def expect_document_reader_constructor_failure(source : String, type : T.class) : Nil forall T
  reader = FusedJSON.documents(
    IO::Memory.new(source),
    type,
    framing: FusedJSON::DocumentFraming::NDJSON,
    buffer_size: 1
  )
  expect_raises(FusedJSON::ParseError) { reader.next }
  reader.documents_read.should eq(0)
  expect_raises(Exception, "cannot be reused after an error") { reader.next }
end

describe "typed FusedJSON::DocumentReader" do
  it "decodes serializable records through one-byte reads" do
    records = [
      %q({"id":1,"name":"Ada λ","roles":["user"],"color":"ff"}),
      %q({"id":340282366920938463463374607431768211455,"name":"Grace","roles":["admin","user"],"color":"10"}),
    ]
    source = records.join('\n') + '\n'
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    reader = FusedJSON.documents(
      io,
      DocumentReaderRecord,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    values = reader.to_a
    expected = records.map { |record| FusedJSON.from_json(record, DocumentReaderRecord) }
    values.map { |value| {value.id, value.name, value.roles, value.color} }.should eq(
      expected.map { |value| {value.id, value.name, value.roles, value.color} }
    )
    reader.documents_read.should eq(2)
    reader.exhausted?.should be_true
    io.closed_called.should be_false
  end

  it "matches isolated typed decoding at every source split" do
    records = [
      %q({"id":7,"name":"split λ","roles":["user"],"color":"2a"}),
      %q({"id":9,"name":"escaped\nvalue","roles":[],"color":"0"}),
    ]
    source = records.join("\r\n") + "\r\n"
    expected = records.map { |record| FusedJSON.from_json(record, DocumentReaderRecord) }

    1.upto(source.bytesize - 1) do |cut|
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        chunks: [cut],
        max_chunk: 5,
        read_budget: source.bytesize + 4
      )
      actual = FusedJSON.documents(
        io,
        DocumentReaderRecord,
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: 5
      ).to_a

      actual.map { |value| {value.id, value.name, value.roles, value.color} }.should eq(
        expected.map { |value| {value.id, value.name, value.roles, value.color} }
      ), "typed NDJSON split #{cut}/#{source.bytesize}"
      io.closed_called.should be_false
    end
  end

  it "bounds typed constructors to multiline whitespace-separated documents" do
    records = [
      "{\n  \"id\": 11,\n  \"name\": \"first\",\n  \"roles\": [\"user\"],\n  \"color\": \"a\"\n}",
      "{\r\n  \"id\": 12,\r\n  \"name\": \"second\",\r\n  \"roles\": [],\r\n  \"color\": \"b\"\r\n}",
    ]
    source = records.join(" \r\n\t")
    expected = records.map { |record| FusedJSON.from_json(record, DocumentReaderRecord) }
    reader = FusedJSON.documents(
      StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1),
      DocumentReaderRecord,
      framing: FusedJSON::DocumentFraming::WhitespaceSeparated,
      buffer_size: 1
    )

    actual = reader.to_a
    actual.map { |value| {value.id, value.name, value.roles, value.color} }.should eq(
      expected.map { |value| {value.id, value.name, value.roles, value.color} }
    )
  end

  it "supports primitive, nil, union, and arbitrary-precision result types" do
    integers = FusedJSON.documents(
      IO::Memory.new("1\n-2\n3\n"),
      Int32,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )
    integers.to_a.should eq([1, -2, 3])

    nils = FusedJSON.documents(
      IO::Memory.new("null\nnull\n"),
      Nil,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )
    nils.next.should be_nil
    nils.next.should be_nil
    nils.next.should be_a(Iterator::Stop)
    nils.documents_read.should eq(2)

    union_source = <<-JSON
      {"alpha":"x"}
      {"beta":9,"wide":340282366920938463463374607431768211455}
      JSON
    union = FusedJSON.documents(
      IO::Memory.new(union_source),
      DocumentReaderAlpha | DocumentReaderBeta,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 2
    ).to_a
    union[0].as(DocumentReaderAlpha).alpha.should eq("x")
    beta = union[1].as(DocumentReaderBeta)
    beta.beta.should eq(9)
    beta.wide.should eq(UInt128::MAX)

    big_integer = "-1234567890123456789012345678901234567890"
    big_float = "1.234567890123456789e400"
    big_decimal = "1234567890.0012300"
    FusedJSON.documents(
      IO::Memory.new("#{big_integer}\n"),
      BigInt,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    ).to_a.should eq([BigInt.new(big_integer)])
    FusedJSON.documents(
      IO::Memory.new("#{big_float}\n"),
      BigFloat,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 2
    ).to_a.should eq([BigFloat.new(big_float)])
    decimal = FusedJSON.documents(
      IO::Memory.new("#{big_decimal}\n"),
      BigDecimal,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 3
    ).to_a.first
    decimal.should eq(BigDecimal.new(big_decimal))
    decimal.scale.should eq(BigDecimal.new(big_decimal).scale)
  end

  it "preserves raw converters without exposing the next document" do
    records = [
      %q({"raw":{"wide":340282366920938463463374607431768211455,"huge":1e309},"tail":7}),
      %q({"raw":[null,true,"line\nλ"],"tail":8}),
    ]
    source = records.join('\n') + '\n'
    values = FusedJSON.documents(
      IO::Memory.new(source),
      DocumentReaderRawRecord,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 2
    ).to_a
    expected = records.map { |record| FusedJSON.from_json(record, DocumentReaderRawRecord) }

    values.map { |value| {value.raw, value.tail} }.should eq(
      expected.map { |value| {value.raw, value.tail} }
    )
  end

  it "keeps retained adapters permanently bounded to their documents" do
    reader = FusedJSON.documents(
      IO::Memory.new("1\n2\n"),
      DocumentReaderRetainsAdapter,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    first = reader.next.as(DocumentReaderRetainsAdapter)
    retained = DocumentReaderRetainsAdapter.retained
    first.value.should eq(1)
    retained.kind.should eq(JSON::PullParser::Kind::EOF)

    second = reader.next.as(DocumentReaderRetainsAdapter)
    second.value.should eq(2)
    retained.kind.should eq(JSON::PullParser::Kind::EOF)
    retained.read_next.should eq(JSON::PullParser::Kind::EOF)
  end

  it "rejects constructors that consume zero, part of one, or multiple values" do
    expect_document_reader_constructor_failure("1\n", DocumentReaderConsumesNothing)
    expect_document_reader_constructor_failure("[1,2]\n", DocumentReaderConsumesPartial)
    expect_document_reader_constructor_failure("1\n2\n", DocumentReaderConsumesMultiple)
  end

  it "preserves typed error wrapping and counts only completed documents" do
    source = "{\"id\":1}\n{\"id\":\"wrong\"}\n"
    reader = FusedJSON.documents(
      StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1),
      DocumentReaderWrongType,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    reader.next.as(DocumentReaderWrongType).id.should eq(1)
    error = expect_raises(JSON::SerializableError) { reader.next }
    error.cause.should be_a(FusedJSON::ParseError)
    error.cause.as(FusedJSON::ParseError).byte_offset.should eq(15_i64)
    reader.documents_read.should eq(1)
  end

  it "can resume after a caller callback raises at a completed boundary" do
    reader = FusedJSON.documents(
      IO::Memory.new("1\n2\n3\n"),
      Int32,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    expect_raises(Exception, "caller failure") do
      reader.each do |value|
        value.should eq(1)
        raise "caller failure"
      end
    end

    reader.documents_read.should eq(1)
    reader.to_a.should eq([2, 3])
    reader.finish
  end
end

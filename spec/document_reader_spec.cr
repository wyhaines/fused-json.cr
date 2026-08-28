require "./spec_helper"
require "./support/chunked_io"

private def dynamic_documents(
  source : String,
  framing : FusedJSON::DocumentFraming,
  *,
  buffer_size : Int = 3,
  max_chunk : Int32 = 1,
  chunks : Array(Int32) = [] of Int32,
)
  io = StreamSpecSupport::ChunkedIO.new(
    source,
    chunks: chunks,
    max_chunk: max_chunk,
    read_budget: source.bytesize + 4
  )
  reader = FusedJSON.documents(io, framing: framing, buffer_size: buffer_size)
  values = reader.to_a
  reader.finish
  {values, reader, io}
end

private class DocumentReaderUnreadableIO < IO
  getter read_calls : Int32

  def initialize
    @read_calls = 0
  end

  def read(slice : Bytes) : Int32
    @read_calls += 1
    raise IO::Error.new("reader options must be validated before input")
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("DocumentReaderUnreadableIO is read-only")
  end
end

private class DocumentReaderBufferTrackingIO < IO
  getter buffer_addresses = [] of UInt64

  @source : Bytes
  @position = 0

  def initialize(source : String)
    @source = source.to_slice
  end

  def read(slice : Bytes) : Int32
    @buffer_addresses << slice.to_unsafe.address
    return 0 if @position == @source.size

    count = Math.min(slice.size, @source.size - @position)
    slice[0, count].copy_from(@source[@position, count])
    @position += count
    count
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("DocumentReaderBufferTrackingIO is read-only")
  end
end

describe FusedJSON::DocumentReader do
  it "reads every JSON root kind from NDJSON" do
    records = [
      "null",
      "true",
      "-12",
      "1.25e2",
      %q("line\nλ"),
      %q([1,2,3]),
      %q({"name":"Ada","nested":{"ok":true}}),
    ]
    source = records.join('\n') + '\n'

    values, reader, io = dynamic_documents(
      source,
      FusedJSON::DocumentFraming::NDJSON
    )

    values.should eq(records.map { |record| FusedJSON.load(record) })
    reader.documents_read.should eq(records.size)
    reader.exhausted?.should be_true
    io.closed_called.should be_false
  end

  it "accepts LF, CRLF, padding, and a final record without a newline" do
    source = " \t{\"id\":1}\t \r\n[2,3]\ntrue"
    expected = [
      FusedJSON.load(%q({"id":1})),
      FusedJSON.load("[2,3]"),
      FusedJSON.load("true"),
    ]

    values, reader, io = dynamic_documents(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    values.should eq(expected)
    reader.documents_read.should eq(3)
    io.bytes_read.should eq(source.bytesize)
    io.closed_called.should be_false
  end

  it "preserves buffered bytes at every NDJSON source split" do
    records = [
      %q({"id":1,"text":"plain"}),
      %q({"id":2,"text":"line\nλ𝄞"}),
      %q([null,false,3.5]),
    ]
    source = records.join("\r\n") + "\r\n"
    expected = records.map { |record| FusedJSON.load(record) }

    1.upto(source.bytesize - 1) do |cut|
      values, reader, io = dynamic_documents(
        source,
        FusedJSON::DocumentFraming::NDJSON,
        buffer_size: 7,
        max_chunk: 7,
        chunks: [cut]
      )
      values.should eq(expected), "NDJSON split #{cut}/#{source.bytesize}"
      reader.documents_read.should eq(3)
      io.closed_called.should be_false
    end
  end

  it "reuses one input buffer throughout the stream" do
    source = (0...100).join('\n') + '\n'
    io = DocumentReaderBufferTrackingIO.new(source)
    reader = FusedJSON.documents(
      io,
      Int32,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 7
    )

    reader.to_a.should eq((0...100).to_a)
    io.buffer_addresses.size.should be > 10
    io.buffer_addresses.uniq.size.should eq(1)
  end

  it "honors IO transcoding across document boundaries" do
    encoded = Bytes[
      0x22_u8, 0x63_u8, 0x61_u8, 0x66_u8, 0xe9_u8, 0x22_u8, 0x0a_u8,
      0x22_u8, 0x64_u8, 0xe9_u8, 0x6a_u8, 0xe0_u8, 0x22_u8, 0x0a_u8,
    ]
    io = IO::Memory.new(encoded)
    io.set_encoding("ISO-8859-1")
    reader = FusedJSON.documents(
      io,
      String,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    reader.to_a.should eq(["café", "déjà"])
    io.pos.should eq(encoded.size)
  end

  it "rejects empty records, line-internal newlines, lone CR, and trailing content" do
    invalid = {
      "\n"             => 0_i64,
      " \t\n"          => 2_i64,
      "{}\n\n"         => 3_i64,
      "[1,\n2]\n"      => 3_i64,
      "{} trailing\n"  => 3_i64,
      "{}\rtrailing\n" => 2_i64,
      "{}\r"           => 2_i64,
    }

    invalid.each do |source, offset|
      io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
      reader = FusedJSON.documents(
        io,
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: 1
      )
      error = expect_raises(FusedJSON::ParseError) { reader.to_a }
      error.byte_offset.should eq(offset), source.inspect
      io.closed_called.should be_false
    end
  end

  it "treats empty input as no NDJSON records but rejects a padded final record" do
    values, reader, _ = dynamic_documents(
      "",
      FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )
    values.should be_empty
    reader.documents_read.should eq(0)

    [" ", "\t", " \t"].each do |source|
      reader = FusedJSON.documents(
        IO::Memory.new(source),
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: 1
      )
      expect_raises(FusedJSON::ParseError, "expected a JSON value") do
        reader.next
      end
    end
  end

  it "reads multiline documents separated by every JSON whitespace byte" do
    records = [
      "{\n  \"id\": 1,\n  \"values\": [1, 2]\n}",
      "[\r\n true,\tfalse\r\n]",
      %q("done"),
    ]
    source = " \t" + records[0] + "\r\n \t" + records[1] + "\n" + records[2] + " \r\n"

    values, reader, io = dynamic_documents(
      source,
      FusedJSON::DocumentFraming::WhitespaceSeparated,
      buffer_size: 2
    )

    values.should eq(records.map { |record| FusedJSON.load(record) })
    reader.documents_read.should eq(3)
    reader.exhausted?.should be_true
    io.closed_called.should be_false
  end

  it "accepts empty and whitespace-only whitespace-separated streams" do
    ["", " ", "\t\r\n  "].each do |source|
      values, reader, io = dynamic_documents(
        source,
        FusedJSON::DocumentFraming::WhitespaceSeparated,
        buffer_size: 1
      )
      values.should be_empty
      reader.documents_read.should eq(0)
      io.closed_called.should be_false
    end
  end

  it "requires whitespace before a following document" do
    {
      %q({}[])    => "{}",
      %q("a""b")  => %q("a"),
      "truefalse" => "true",
      "1-2"       => "1",
    }.each do |source, first_document|
      reader = FusedJSON.documents(
        IO::Memory.new(source),
        framing: FusedJSON::DocumentFraming::WhitespaceSeparated,
        buffer_size: 2
      )

      reader.next.should eq(FusedJSON.load(first_document))
      reader.documents_read.should eq(1)
      expect_raises(FusedJSON::ParseError, "expected JSON whitespace") do
        reader.next
      end
    end
  end

  it "does not probe physical EOF before yielding a self-delimiting document" do
    io = StreamSpecSupport::ChunkedIO.new(
      "{} ",
      chunks: [2],
      fail_on_read: 2,
      read_budget: 2
    )
    reader = FusedJSON.documents(
      io,
      framing: FusedJSON::DocumentFraming::WhitespaceSeparated,
      buffer_size: 2
    )

    reader.next.should eq(FusedJSON.load("{}"))
    io.read_calls.should eq(1)
    reader.exhausted?.should be_false
  end

  it "reports absolute locations in later documents" do
    source = "{}\n{\"a\":]\n"
    reader = FusedJSON.documents(
      StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1),
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    reader.next.should eq(FusedJSON.load("{}"))
    error = expect_raises(FusedJSON::ParseError) { reader.next }
    error.byte_offset.should eq(8_i64)
    error.line_number.should eq(2_i64)
    error.column_number.should eq(6_i64)
    reader.documents_read.should eq(1)
  end

  it "supports stopping and resuming only at completed document boundaries" do
    reader = FusedJSON.documents(
      IO::Memory.new("1\n2\n3\n"),
      Int32,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 2
    )

    reader.each do |value|
      value.should eq(1)
      break
    end
    reader.documents_read.should eq(1)
    reader.next.should eq(2)
    reader.next.should eq(3)
    reader.next.should be_a(Iterator::Stop)
    reader.finish
    reader.exhausted?.should be_true
  end

  it "makes finish idempotent and rejects unread documents without draining them" do
    complete = FusedJSON.documents(
      IO::Memory.new("{} \n\t"),
      framing: FusedJSON::DocumentFraming::WhitespaceSeparated,
      buffer_size: 1
    )
    complete.next.should eq(FusedJSON.load("{}"))
    complete.finish
    complete.finish
    complete.exhausted?.should be_true
    complete.documents_read.should eq(1)

    incomplete = FusedJSON.documents(
      IO::Memory.new("{} []"),
      framing: FusedJSON::DocumentFraming::WhitespaceSeparated,
      buffer_size: 2
    )
    incomplete.next.should eq(FusedJSON.load("{}"))
    expect_raises(FusedJSON::ParseError, "expected end of document stream") do
      incomplete.finish
    end
    incomplete.documents_read.should eq(1)
  end

  it "propagates IO failures, becomes discard-only, and never closes input" do
    io = StreamSpecSupport::ChunkedIO.new(
      "{}\n[]\n",
      max_chunk: 1,
      fail_on_read: 4
    )
    reader = FusedJSON.documents(
      io,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1
    )

    reader.next.should eq(FusedJSON.load("{}"))
    expect_raises(IO::Error, "injected read failure") { reader.next }
    expect_raises(Exception, "cannot be reused after an error") { reader.next }
    io.closed_called.should be_false
  end

  it "validates reader options before reading input" do
    io = DocumentReaderUnreadableIO.new
    expect_raises(ArgumentError, "buffer_size must be between") do
      FusedJSON.documents(
        io,
        framing: FusedJSON::DocumentFraming::NDJSON,
        buffer_size: 0
      )
    end
    io.read_calls.should eq(0)

    io = DocumentReaderUnreadableIO.new
    expect_raises(ArgumentError, "max_nesting must be between") do
      FusedJSON.documents(
        io,
        Int32,
        framing: FusedJSON::DocumentFraming::NDJSON,
        max_nesting: 513
      )
    end
    io.read_calls.should eq(0)

    io = DocumentReaderUnreadableIO.new
    expect_raises(ArgumentError, "max_token_bytes must be between") do
      FusedJSON.documents(
        io,
        framing: FusedJSON::DocumentFraming::NDJSON,
        max_token_bytes: 0
      )
    end
    io.read_calls.should eq(0)
  end
end

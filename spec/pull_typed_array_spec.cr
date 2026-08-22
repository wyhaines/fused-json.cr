require "./spec_helper"
require "./support/chunked_io"

private class PullArrayRecord
  include JSON::Serializable

  getter id : Int32
  getter name : String
  getter groups : Array(Array(UInt64))
end

private class PullArrayRetainsAdapter
  @@retained = [] of JSON::PullParser

  getter value : Int32

  private def initialize(@value : Int32)
  end

  def self.new(pull : JSON::PullParser) : self
    value = Int32.new(pull)
    @@retained << pull
    new(value)
  end

  def self.reset : Nil
    @@retained.clear
  end

  def self.retained : Array(JSON::PullParser)
    @@retained
  end
end

private class PullArrayCallbackError < Exception
end

describe "FusedJSON::PullParser#read_array(T)" do
  it "yields empty, ordered, nested, and duplicate-member values" do
    empty = FusedJSON::PullParser.new("[]")
    empty.read_array(Int32) { fail "empty array yielded" }
    empty.finish

    source = %([{"id":1,"name":"first","groups":[[1,2],[]]},{"id":2,"name":"old","name":"last","groups":[[18446744073709551615]]}])
    pull = FusedJSON::PullParser.new(source)
    observed = [] of PullArrayRecord
    pull.read_array(PullArrayRecord) { |record| observed << record }
    pull.finish

    observed.map(&.id).should eq([1, 2])
    observed.map(&.name).should eq(["first", "last"])
    observed[0].groups.should eq([[1_u64, 2_u64], [] of UInt64])
    observed[1].groups.should eq([[UInt64::MAX]])
  end

  it "preserves the untyped block overload" do
    pull = FusedJSON::PullParser.new(%([1,{"skip":[2,3]},4]))
    values = [] of Int64

    pull.read_array do
      if pull.kind.int?
        values << pull.read_int
      else
        pull.skip
      end
    end
    pull.finish

    values.should eq([1_i64, 4_i64])
  end

  it "uses a fresh permanently bounded adapter for every element" do
    PullArrayRetainsAdapter.reset
    pull = FusedJSON::PullParser.new("[1,2,3]")
    values = [] of Int32
    pull.read_array(PullArrayRetainsAdapter) { |value| values << value.value }
    pull.finish

    values.should eq([1, 2, 3])
    retained = PullArrayRetainsAdapter.retained
    retained.size.should eq(3)
    retained.map(&.object_id).uniq!.size.should eq(3)
    retained.each do |adapter|
      adapter.kind.should eq(JSON::PullParser::Kind::EOF)
      adapter.read_next.should eq(JSON::PullParser::Kind::EOF)
      expect_raises(FusedJSON::ParseError) { adapter.read_int }
    end
  end

  it "keeps fresh streaming adapters isolated across later elements" do
    PullArrayRetainsAdapter.reset
    io = StreamSpecSupport::ChunkedIO.new("[1,2,3]", max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)
    values = [] of Int32
    pull.read_array(PullArrayRetainsAdapter) { |value| values << value.value }
    pull.finish

    values.should eq([1, 2, 3])
    retained = PullArrayRetainsAdapter.retained
    retained.map(&.object_id).uniq!.size.should eq(3)
    retained.each do |adapter|
      adapter.kind.should eq(JSON::PullParser::Kind::EOF)
      expect_raises(FusedJSON::ParseError) { adapter.read_int }
    end
    io.closed_called.should be_false
  end

  it "decodes a typed array at a nested native cursor" do
    pull = FusedJSON::PullParser.new(%({"before":true,"selected":[[1,2],[],[3]],"after":false}))
    observed = [] of Array(Int32)

    pull.read_object do |key|
      case key
      when "selected"
        pull.read_array(Array(Int32)) { |values| observed << values }
      else
        pull.skip
      end
    end
    pull.finish

    observed.should eq([[1, 2], [] of Int32, [3]])
  end

  it "does not drain after an early block exit" do
    pull = FusedJSON::PullParser.new("[1,2,3]")
    values = [] of Int32

    pull.read_array(Int32) do |value|
      values << value
      break
    end

    values.should eq([1])
    pull.kind.should eq(FusedJSON::PullParser::Kind::Int)
    expect_raises(FusedJSON::ParseError, "expected end of document") { pull.finish }
  end

  it "propagates callback exceptions without draining or closing IO" do
    io = StreamSpecSupport::ChunkedIO.new("[1,2,3]", max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)
    values = [] of Int32

    expect_raises(PullArrayCallbackError, "stop") do
      pull.read_array(Int32) do |value|
        values << value
        raise PullArrayCallbackError.new("stop")
      end
    end

    values.should eq([1])
    pull.kind.should eq(FusedJSON::PullParser::Kind::Int)
    pull.byte_offset.should eq(3_i64)
    pull.location_i64.should eq({1_i64, 4_i64})
    io.bytes_read.should eq(5)
    io.closed_called.should be_false
  end

  it "rejects callbacks that advance the shared reader" do
    pull = FusedJSON::PullParser.new("[1,2,3]")
    values = [] of Int32

    expect_raises(FusedJSON::ParseError, "typed array callback must not advance the reader") do
      pull.read_array(Int32) do |value|
        values << value
        pull.read(Int32)
      end
    end

    values.should eq([1])
  end

  it "yields completed objects before a later typed or syntax failure" do
    conversion = FusedJSON::PullParser.new(%([{"id":1,"name":"first","groups":[]},{"id":"bad","name":"second","groups":[]}]))
    converted = [] of Int32
    expect_raises(JSON::SerializableError) do
      conversion.read_array(PullArrayRecord) { |record| converted << record.id }
    end
    converted.should eq([1])

    truncated = FusedJSON::PullParser.new(%([{"id":1,"name":"first","groups":[]},{"id":2))
    traversed = [] of Int32
    expect_raises(JSON::SerializableError) do
      truncated.read_array(PullArrayRecord) { |record| traversed << record.id }
    end
    traversed.should eq([1])
  end

  it "rejects wrong starting positions without advancing" do
    pull = FusedJSON::PullParser.new(%({"items":[]}))
    before = {pull.kind, pull.byte_offset, pull.location_i64}

    expect_raises(FusedJSON::ParseError, "expected BeginArray") do
      pull.read_array(Int32) { |_value| }
    end
    {pull.kind, pull.byte_offset, pull.location_i64}.should eq(before)

    pull.read_begin_object
    before = {pull.kind, pull.byte_offset, pull.location_i64}
    expect_raises(FusedJSON::ParseError, "expected BeginArray") do
      pull.read_array(Int32) { |_value| }
    end
    {pull.kind, pull.byte_offset, pull.location_i64}.should eq(before)

    pull.read_object_key.should eq("items")
    pull.read_begin_array
    before = {pull.kind, pull.byte_offset, pull.location_i64}
    expect_raises(FusedJSON::ParseError, "expected BeginArray") do
      pull.read_array(Int32) { |_value| }
    end
    {pull.kind, pull.byte_offset, pull.location_i64}.should eq(before)

    pull.read_end_array
    pull.read_end_object
    before = {pull.kind, pull.byte_offset, pull.location_i64}
    expect_raises(FusedJSON::ParseError, "expected BeginArray") do
      pull.read_array(Int32) { |_value| }
    end
    {pull.kind, pull.byte_offset, pull.location_i64}.should eq(before)
  end

  it "does not yield a value when its one-token lookahead is malformed" do
    values = [] of Int32
    pull = FusedJSON::PullParser.new("[1,2e]")

    expect_raises(FusedJSON::ParseError) do
      pull.read_array(Int32) { |value| values << value }
    end

    values.should be_empty
  end

  it "applies streaming token limits to lookahead before yielding" do
    source = %([{"id":1,"name":"first","groups":[]},"oversized"])
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 2, max_token_bytes: 8)
    values = [] of Int32

    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      pull.read_array(PullArrayRecord) { |record| values << record.id }
    end

    values.should be_empty
    io.closed_called.should be_false
  end

  it "yields complete elements before rejecting a malformed suffix" do
    pull = FusedJSON::PullParser.new("[1,2] trailing")
    values = [] of Int32

    expect_raises(FusedJSON::ParseError, "unexpected trailing content") do
      pull.read_array(Int32) { |value| values << value }
    end

    values.should eq([1, 2])
  end

  it "yields the first streaming object without traversing the next object" do
    source = %([{"id":1,"name":"first","groups":[]},{"id":2,"name":"second","groups":[[1,2,3]]}])
    sibling_offset = source.index(%({"id":2)) || raise "missing sibling"
    io = StreamSpecSupport::ChunkedIO.new(
      source,
      max_chunk: 1,
      read_budget: sibling_offset + 1
    )
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)
    values = [] of Int32

    pull.read_array(PullArrayRecord) do |record|
      values << record.id
      break
    end

    values.should eq([1])
    pull.kind.should eq(FusedJSON::PullParser::Kind::BeginObject)
    pull.byte_offset.should eq(sibling_offset.to_i64)
    io.bytes_read.should eq(sibling_offset + 1)
    io.closed_called.should be_false
  end

  it "handles every representative IO split and one-byte reads" do
    source = %([{"id":1,"name":"München λ","groups":[[1,2]]},{"id":2,"name":"𝄞","groups":[[18446744073709551615]]}])

    (1...source.bytesize).each do |split|
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        chunks: [split, source.bytesize - split]
      )
      pull = FusedJSON::PullParser.new(io, buffer_size: 7)
      values = [] of PullArrayRecord
      pull.read_array(PullArrayRecord) { |record| values << record }
      pull.finish

      values.map(&.name).should eq(["München λ", "𝄞"]), "source split #{split}/#{source.bytesize}"
      values.last.groups.should eq([[UInt64::MAX]])
      io.closed_called.should be_false
    end

    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)
    ids = [] of Int32
    pull.read_array(PullArrayRecord) { |record| ids << record.id }
    pull.finish
    ids.should eq([1, 2])
    io.closed_called.should be_false
  end

  it "rejects invalid UTF-8 during complete typed traversal" do
    source = String.new(Bytes[0x5b_u8, 0x22_u8, 0xff_u8, 0x22_u8, 0x5d_u8])
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)

    expect_raises(FusedJSON::ParseError, "invalid UTF-8") do
      pull.read_array(String) { |_value| }
    end
    io.closed_called.should be_false
  end
end

require "compress/gzip"

require "./spec_helper"
require "./support/chunked_io"

private struct TICWorkflowProviderReference
  include JSON::Serializable

  getter provider_group_id : UInt64
end

private module TICWorkflowRawNumberConverter
  def self.from_json(pull : JSON::PullParser) : String
    pull.raw_value.tap { pull.read_next }
  end
end

private struct TICWorkflowPrice
  include JSON::Serializable

  getter negotiated_type : String

  @[JSON::Field(converter: TICWorkflowRawNumberConverter)]
  getter negotiated_rate : String

  getter billing_class : String
end

private class TICWorkflowStage
  getter references = [] of UInt64
  getter metadata = [] of Tuple(Int64, String, String)
  getter providers = [] of Tuple(Int64, UInt64)
  getter prices = [] of Tuple(Int64, Int64, TICWorkflowPrice)
  getter reporting_entity : String?
  getter commit_count = 0
  getter? rolled_back = false

  def write(reference : TICWorkflowProviderReference) : Nil
    @references << reference.provider_group_id
  end

  def write_metadata(item_id : Int64, key : String, value : String) : Nil
    @metadata << {item_id, key, value}
  end

  def write_provider(rate_id : Int64, provider_group_id : UInt64) : Nil
    @providers << {rate_id, provider_group_id}
  end

  def write_price(item_id : Int64, rate_id : Int64, price : TICWorkflowPrice) : Nil
    @prices << {item_id, rate_id, price}
  end

  def commit(reporting_entity : String) : Nil
    @reporting_entity = reporting_entity
    @commit_count += 1
  end

  def rollback : Nil
    @rolled_back = true
  end
end

private class TICWorkflowInputFactory
  getter opens = 0
  getter owners = [] of StreamSpecSupport::ChunkedIO
  getter readers = [] of IO
  getter reader_closed_before_scope_exit = [] of Bool

  def initialize(@payloads : Array(String), @gzip : Bool)
  end

  def open(&block : IO -> T) : T forall T
    payload = @payloads[@opens]? || raise "workflow source opened too many times"
    @opens += 1
    owner = StreamSpecSupport::ChunkedIO.new(payload, max_chunk: 1)
    @owners << owner

    if @gzip
      Compress::Gzip::Reader.open(owner) do |reader|
        @readers << reader
        begin
          block.call(reader)
        ensure
          @reader_closed_before_scope_exit << reader.closed?
        end
      end
    else
      @readers << owner
      block.call(owner)
    end
  end
end

private def tic_workflow_document(*, rates_first : Bool) : String
  providers = %q([{"provider_group_id":18446744073709551615,"provider_groups":[{"ignored":true}]},{"provider_group_id":7,"unknown":"skip"}])
  rates = %q([{"billing_code":"A100","negotiated_rates":[{"negotiated_prices":[{"negotiated_type":"negotiated","negotiated_rate":1.2300e+400,"billing_class":"professional","service_code":["01"]}],"provider_references":[18446744073709551615,7],"ignored_rate":{"x":true}}],"description":"after nested","ignored_item":[1,2,3]},{"description":"second before","negotiated_rates":[{"provider_references":[7],"negotiated_prices":[{"billing_class":"institutional","negotiated_rate":56.78,"negotiated_type":"derived"}]}],"billing_code":"B200"}])

  if rates_first
    %({"in_network":#{rates},"ignored_root":{"wide":340282366920938463463374607431768211456},"provider_references":#{providers},"reporting_entity_name":"Example Health"})
  else
    %({"reporting_entity_name":"Example Health","provider_references":#{providers},"out_of_network":[{"skip":true}],"in_network":#{rates}})
  end
end

private def tic_workflow_gzip(source : String) : String
  output = IO::Memory.new
  Compress::Gzip::Writer.open(output, &.write(source.to_slice))
  output.to_s
end

private def tic_workflow_factory(source : String, *, gzip : Bool) : TICWorkflowInputFactory
  payload = gzip ? tic_workflow_gzip(source) : source
  TICWorkflowInputFactory.new([payload, payload], gzip)
end

private def tic_workflow_scan_references(input : IO, stage : TICWorkflowStage,
                                         buffer_size : Int32 = 7) : String
  reporting_entity = nil.as(String?)
  pull = FusedJSON::PullParser.new(input, buffer_size: buffer_size)
  pull.read_object do |key|
    case key
    when "reporting_entity_name"
      reporting_entity = pull.read_string
    when "provider_references"
      pull.read_array(TICWorkflowProviderReference) { |reference| stage.write(reference) }
    else
      pull.skip
    end
  end
  pull.finish
  reporting_entity || raise "missing reporting entity"
end

private def tic_workflow_scan_rates(input : IO, stage : TICWorkflowStage,
                                    buffer_size : Int32 = 7) : Nil
  item_id = 0_i64
  rate_id = 0_i64
  pull = FusedJSON::PullParser.new(input, buffer_size: buffer_size)
  pull.read_object do |root_key|
    if root_key == "in_network"
      pull.read_array do
        item_id += 1
        pull.read_object do |item_key|
          case item_key
          when "billing_code", "description"
            stage.write_metadata(item_id, item_key, pull.read_string)
          when "negotiated_rates"
            pull.read_array do
              rate_id += 1
              current_rate_id = rate_id
              pull.read_object do |rate_key|
                case rate_key
                when "provider_references"
                  pull.read_array(UInt64) do |provider_group_id|
                    stage.write_provider(current_rate_id, provider_group_id)
                  end
                when "negotiated_prices"
                  pull.read_array(TICWorkflowPrice) do |price|
                    stage.write_price(item_id, current_rate_id, price)
                  end
                else
                  pull.skip
                end
              end
            end
          else
            pull.skip
          end
        end
      end
    else
      pull.skip
    end
  end
  pull.finish
end

private def tic_workflow_import(factory : TICWorkflowInputFactory,
                                stage : TICWorkflowStage) : Nil
  reporting_entity = factory.open do |input|
    tic_workflow_scan_references(input, stage)
  end
  factory.open do |input|
    tic_workflow_scan_rates(input, stage)
  end
  stage.commit(reporting_entity)
rescue error
  stage.rollback
  raise error
end

private def tic_workflow_invalid_utf8 : String
  output = IO::Memory.new
  output << %({"reporting_entity_name":"bad)
  output.write_byte(0xff_u8)
  output << %(","provider_references":[],"in_network":[]})
  output.to_s
end

private def tic_workflow_assert_results(stage : TICWorkflowStage) : Nil
  stage.commit_count.should eq(1)
  stage.rolled_back?.should be_false
  stage.reporting_entity.should eq("Example Health")
  stage.references.should eq([UInt64::MAX, 7_u64])
  stage.metadata.should eq([
    {1_i64, "billing_code", "A100"},
    {1_i64, "description", "after nested"},
    {2_i64, "description", "second before"},
    {2_i64, "billing_code", "B200"},
  ])
  stage.providers.should eq([
    {1_i64, UInt64::MAX},
    {1_i64, 7_u64},
    {2_i64, 7_u64},
  ])
  stage.prices.map { |item_id, rate_id, _price| {item_id, rate_id} }.should eq([
    {1_i64, 1_i64},
    {2_i64, 2_i64},
  ])
  stage.prices.map { |_item_id, _rate_id, price| price.negotiated_rate }.should eq(["1.2300e+400", "56.78"])
end

describe "TiC-shaped typed streaming workflows" do
  it "handles both root orders through fresh plain and gzip passes" do
    {false, true}.each do |rates_first|
      {false, true}.each do |gzip|
        source = tic_workflow_document(rates_first: rates_first)
        factory = tic_workflow_factory(source, gzip: gzip)
        stage = TICWorkflowStage.new

        tic_workflow_import(factory, stage)

        tic_workflow_assert_results(stage)
        factory.opens.should eq(2)
        factory.owners.map(&.object_id).uniq!.size.should eq(2)
        factory.readers.map(&.object_id).uniq!.size.should eq(2)
        factory.owners.each(&.closed_called.should(be_false))
        if gzip
          factory.reader_closed_before_scope_exit.should eq([false, false])
          factory.readers.each(&.closed?.should(be_true))
        else
          factory.readers.each(&.closed?.should(be_false))
        end
      end
    end
  end

  it "handles every plain-input split and one-byte reads without taking IO ownership" do
    {false, true}.each do |rates_first|
      source = tic_workflow_document(rates_first: rates_first)
      (1...source.bytesize).each do |split|
        io = StreamSpecSupport::ChunkedIO.new(
          source,
          chunks: [split, source.bytesize - split]
        )
        stage = TICWorkflowStage.new
        entity = tic_workflow_scan_references(io, stage)

        entity.should eq("Example Health"), "source split #{split}/#{source.bytesize}"
        stage.references.should eq([UInt64::MAX, 7_u64]), "source split #{split}/#{source.bytesize}"
        io.closed_called.should be_false
      end
    end

    source = tic_workflow_document(rates_first: true)
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    stage = TICWorkflowStage.new
    tic_workflow_scan_rates(io, stage, buffer_size: 1)
    stage.prices.size.should eq(2)
    io.closed_called.should be_false
  end

  it "does not commit malformed, truncated, or invalid UTF-8 plain documents" do
    source = tic_workflow_document(rates_first: false)

    truncated_factory = TICWorkflowInputFactory.new(
      [source.byte_slice(0, source.bytesize - 1), source],
      false
    )
    truncated_stage = TICWorkflowStage.new
    expect_raises(FusedJSON::ParseError) do
      tic_workflow_import(truncated_factory, truncated_stage)
    end
    truncated_stage.commit_count.should eq(0)
    truncated_stage.rolled_back?.should be_true
    truncated_factory.owners.each(&.closed_called.should(be_false))

    trailing_factory = TICWorkflowInputFactory.new([source + " trailing", source], false)
    trailing_stage = TICWorkflowStage.new
    expect_raises(FusedJSON::ParseError, "unexpected trailing content") do
      tic_workflow_import(trailing_factory, trailing_stage)
    end
    trailing_stage.commit_count.should eq(0)
    trailing_stage.rolled_back?.should be_true
    trailing_factory.owners.each(&.closed_called.should(be_false))

    invalid_factory = TICWorkflowInputFactory.new([tic_workflow_invalid_utf8, source], false)
    invalid_stage = TICWorkflowStage.new
    expect_raises(FusedJSON::ParseError, "invalid UTF-8") do
      tic_workflow_import(invalid_factory, invalid_stage)
    end
    invalid_stage.commit_count.should eq(0)
    invalid_stage.rolled_back?.should be_true
    invalid_factory.owners.each(&.closed_called.should(be_false))
  end

  it "rolls back when a fresh second-pass gzip is truncated or has a bad trailer" do
    source = tic_workflow_document(rates_first: true)
    valid = tic_workflow_gzip(source)

    truncated = String.new(valid.to_slice[0, valid.bytesize - 4])
    truncated_factory = TICWorkflowInputFactory.new([valid, truncated], true)
    truncated_stage = TICWorkflowStage.new
    expect_raises(IO::EOFError) do
      tic_workflow_import(truncated_factory, truncated_stage)
    end
    truncated_factory.opens.should eq(2)
    truncated_stage.commit_count.should eq(0)
    truncated_stage.rolled_back?.should be_true
    truncated_factory.owners.each(&.closed_called.should(be_false))
    truncated_factory.reader_closed_before_scope_exit.should eq([false, false])
    truncated_factory.readers.each(&.closed?.should(be_true))

    corrupt_bytes = valid.to_slice.dup
    corrupt_bytes[corrupt_bytes.size - 8] ^= 0xff_u8
    corrupt = String.new(corrupt_bytes)
    corrupt_factory = TICWorkflowInputFactory.new([valid, corrupt], true)
    corrupt_stage = TICWorkflowStage.new
    expect_raises(Compress::Gzip::Error, "CRC32 checksum mismatch") do
      tic_workflow_import(corrupt_factory, corrupt_stage)
    end
    corrupt_factory.opens.should eq(2)
    corrupt_stage.commit_count.should eq(0)
    corrupt_stage.rolled_back?.should be_true
    corrupt_factory.owners.each(&.closed_called.should(be_false))
    corrupt_factory.reader_closed_before_scope_exit.should eq([false, false])
    corrupt_factory.readers.each(&.closed?.should(be_true))
  end

  it "accounts for scalar lookahead without traversing the following object" do
    source = %([1,2222222222,{"unread":"#{"x" * 256}"}])
    object_offset = source.index('{') || raise "missing lookahead object"
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)
    values = [] of Int64

    pull.read_array(Int64) do |value|
      values << value
      break
    end

    values.should eq([1_i64])
    pull.kind.should eq(FusedJSON::PullParser::Kind::Int)
    io.bytes_read.should eq(object_offset)
    io.bytes_read.should be < source.bytesize
    io.closed_called.should be_false
  end
end

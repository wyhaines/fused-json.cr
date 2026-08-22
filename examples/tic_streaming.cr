require "compress/gzip"
require "option_parser"

require "../src/fused_json"

# A bounded-memory, TiC-shaped two-pass import. The sinks below retain only
# counters for the runnable example; production sinks can stage rows in a
# database or temporary files and expose the same write/commit lifecycle.
module TICStreamingExample
  BUFFER_SIZE = 64 * 1024

  module RawNumberConverter
    def self.from_json(pull : JSON::PullParser) : String
      pull.raw_value.tap { pull.read_next }
    end
  end

  struct ProviderReference
    include JSON::Serializable

    getter provider_group_id : UInt64
  end

  struct NegotiatedPrice
    include JSON::Serializable

    getter negotiated_type : String

    @[JSON::Field(converter: RawNumberConverter)]
    getter negotiated_rate : String

    getter billing_class : String
  end

  class ReferenceSink
    getter rows = 0_i64
    getter last_provider_group_id : UInt64?

    def write(reference : ProviderReference) : Nil
      @rows += 1
      @last_provider_group_id = reference.provider_group_id
    end
  end

  class MetadataSink
    getter rows = 0_i64
    getter last_item_id : Int64?
    getter last_key : String?
    getter last_value : String?

    def write(item_id : Int64, key : String, value : String) : Nil
      @rows += 1
      @last_item_id = item_id
      @last_key = key
      @last_value = value
    end
  end

  class ProviderSink
    getter rows = 0_i64
    getter last_rate_id : Int64?
    getter last_provider_group_id : UInt64?

    def write(rate_id : Int64, provider_group_id : UInt64) : Nil
      @rows += 1
      @last_rate_id = rate_id
      @last_provider_group_id = provider_group_id
    end
  end

  class PriceSink
    getter rows = 0_i64
    getter last_item_id : Int64?
    getter last_rate_id : Int64?
    getter last_price : NegotiatedPrice?

    def write(item_id : Int64, rate_id : Int64, price : NegotiatedPrice) : Nil
      @rows += 1
      @last_item_id = item_id
      @last_rate_id = rate_id
      @last_price = price
    end
  end

  class StagedImport
    getter references = ReferenceSink.new
    getter metadata = MetadataSink.new
    getter providers = ProviderSink.new
    getter prices = PriceSink.new
    getter reporting_entity : String?
    getter? committed = false
    getter? rolled_back = false

    def commit(reporting_entity : String) : Nil
      @reporting_entity = reporting_entity
      @committed = true
    end

    def rollback : Nil
      @rolled_back = true
    end
  end

  extend self

  # Reopens the file, and creates a new gzip reader when requested, every time
  # it is called. These scopes close their resources; FusedJSON itself does not.
  private def with_input(path : String, gzip : Bool, &block : IO -> T) : T forall T
    File.open(path) do |file|
      file.read_buffering = false
      if gzip
        Compress::Gzip::Reader.open(file) { |reader| block.call(reader) }
      else
        block.call(file)
      end
    end
  end

  # The first pass captures a root scalar and streams one selected root array.
  # Root member order is irrelevant; commit remains deferred until both passes
  # reach EOF.
  private def scan_references(input : IO, stage : StagedImport,
                              buffer_size : Int32) : String
    reporting_entity = nil.as(String?)
    pull = FusedJSON::PullParser.new(input, buffer_size: buffer_size)

    pull.read_object do |key|
      case key
      when "reporting_entity_name"
        reporting_entity = pull.read_string
      when "provider_references"
        pull.read_array(ProviderReference) { |reference| stage.references.write(reference) }
      else
        pull.skip
      end
    end
    pull.finish

    reporting_entity || raise "document is missing reporting_entity_name"
  end

  # The second pass never materializes a complete in-network item. Metadata,
  # provider references, and typed prices can arrive in any member order and
  # are joined later through monotonically increasing item and rate IDs.
  private def scan_rates(input : IO, stage : StagedImport,
                         buffer_size : Int32) : Nil
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
              stage.metadata.write(item_id, item_key, pull.read_string)
            when "negotiated_rates"
              pull.read_array do
                rate_id += 1
                current_rate_id = rate_id
                pull.read_object do |rate_key|
                  case rate_key
                  when "provider_references"
                    pull.read_array(UInt64) do |provider_group_id|
                      stage.providers.write(current_rate_id, provider_group_id)
                    end
                  when "negotiated_prices"
                    pull.read_array(NegotiatedPrice) do |price|
                      stage.prices.write(item_id, current_rate_id, price)
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

  # Both passes must finish successfully before the stage is marked committed.
  def run(path : String, gzip : Bool, stage : StagedImport,
          buffer_size : Int32 = BUFFER_SIZE) : StagedImport
    reporting_entity = with_input(path, gzip) do |input|
      scan_references(input, stage, buffer_size)
    end
    with_input(path, gzip) do |input|
      scan_rates(input, stage, buffer_size)
    end
    stage.commit(reporting_entity)
    stage
  rescue error
    stage.rollback
    raise error
  end
end

gzip = false
buffer_size = TICStreamingExample::BUFFER_SIZE
parser = OptionParser.new do |options|
  options.banner = "Usage: #{PROGRAM_NAME} [options] TIC_FILE"
  options.on("--gzip", "Wrap each freshly opened pass in Compress::Gzip::Reader") { gzip = true }
  options.on("--buffer-size=BYTES", "Streaming parser buffer size") { |value| buffer_size = value.to_i }
  options.on("-h", "--help", "Show this help") do
    puts options
    exit
  end
end
parser.parse

path = ARGV.shift? || abort parser.to_s
abort parser.to_s unless ARGV.empty?
gzip = true if path.ends_with?(".gz")

stage = TICStreamingExample::StagedImport.new
TICStreamingExample.run(path, gzip, stage, buffer_size)
raise "import did not commit" unless stage.committed?

puts "reporting entity: #{stage.reporting_entity}"
puts "provider references: #{stage.references.rows}"
puts "metadata rows: #{stage.metadata.rows}"
puts "rate/provider rows: #{stage.providers.rows}"
puts "typed price rows: #{stage.prices.rows}"

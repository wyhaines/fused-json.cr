require "compress/gzip"
require "json"
require "option_parser"

require "../src/fused_json"

module SunlightCompatScan
  ITEM_LIMIT  = 64_i64 * 1024 * 1024
  BUFFER_SIZE = 32 * 1024
  PROTOCOL    = 1

  class ItemTooLarge < Exception; end

  class Budget
    CONTAINER   = 40_i64
    HASH_ENTRY  = 40_i64
    ARRAY_ENTRY =  8_i64
    SCALAR      = 16_i64
    STRING      = 40_i64

    def initialize(@limit : Int64)
      @used = 0_i64
    end

    def charge(n : Int64) : Nil
      @used += n
      raise ItemTooLarge.new("JSON item retained state exceeded #{@limit} bytes") if @used > @limit
    end
  end

  extend self

  private def temp_path(label : String) : String
    File.tempname("fused-json-m6-#{label}", ".jsonl")
  end

  private def with_input(path : String, &block : IO ->) : Nil
    gzip = File.open(path, "rb") do |probe|
      head = Bytes.new(2)
      probe.read_fully?(head)
      head == Bytes[0x1f, 0x8b]
    end
    File.open(path, "rb") do |file|
      file.read_buffering = false
      if gzip
        Compress::Gzip::Reader.open(file) { |reader| block.call(reader) }
      else
        block.call(file)
      end
    end
  end

  private def parser(io : IO) : FusedJSON::PullParser
    FusedJSON::PullParser.new(io, buffer_size: BUFFER_SIZE, cache_keys: false)
  end

  private def raw_value(pull : FusedJSON::PullParser, budget : Budget) : String
    case pull.kind
    when .begin_object?
      budget.charge(Budget::CONTAINER)
      fields = {} of String => String
      pull.read_object do |key|
        budget.charge(Budget::HASH_ENTRY + Budget::STRING + key.bytesize)
        fields[key] = raw_value(pull, budget)
      end
      String.build do |io|
        io << '{'
        fields.each_with_index do |(key, value), index|
          io << ',' unless index.zero?
          key.to_json(io)
          io << ':' << value
        end
        io << '}'
      end
    when .begin_array?
      budget.charge(Budget::CONTAINER)
      values = [] of String
      pull.read_array do
        budget.charge(Budget::ARRAY_ENTRY)
        values << raw_value(pull, budget)
      end
      "[#{values.join(',')}]"
    when .string?
      value = pull.read_string
      budget.charge(Budget::STRING + value.bytesize)
      value.to_json
    when .int?, .float?
      budget.charge(Budget::SCALAR)
      pull.read_raw_number
    when .bool?
      budget.charge(Budget::SCALAR)
      pull.read_bool ? "true" : "false"
    when .null?
      budget.charge(Budget::SCALAR)
      pull.read_null
      "null"
    else
      raise "unexpected #{pull.kind}"
    end
  end

  private def skip_charged(pull : FusedJSON::PullParser, budget : Budget) : Nil
    case pull.kind
    when .begin_object?
      budget.charge(Budget::CONTAINER)
      pull.read_object do |key|
        budget.charge(Budget::HASH_ENTRY + Budget::STRING + key.bytesize)
        skip_charged(pull, budget)
      end
    when .begin_array?
      budget.charge(Budget::CONTAINER)
      pull.read_array do
        budget.charge(Budget::ARRAY_ENTRY)
        skip_charged(pull, budget)
      end
    when .string?
      value = pull.read_string
      budget.charge(Budget::STRING + value.bytesize)
    when .int?, .float?
      budget.charge(Budget::SCALAR)
      pull.read_raw_number
    when .bool?
      budget.charge(Budget::SCALAR)
      pull.read_bool
    when .null?
      budget.charge(Budget::SCALAR)
      pull.read_null
    else
      raise "unexpected #{pull.kind}"
    end
  end

  private def scalar?(kind : FusedJSON::PullParser::Kind) : Bool
    kind.null? || kind.bool? || kind.int? || kind.float? || kind.string?
  end

  private def reset(file : File) : Nil
    file.truncate(0)
    file.rewind
  end

  private def copy(file : File, output : IO) : Nil
    file.flush
    file.rewind
    IO.copy(file, output)
  end

  private def scan_references(path : String, refs : File, limit : Int64) : String
    entity = "null"
    with_input(path) do |io|
      pull = parser(io)
      pull.read_object do |key|
        if key == "reporting_entity_name" && scalar?(pull.kind)
          entity = raw_value(pull, Budget.new(Int64::MAX))
        elsif key == "provider_references" && pull.kind.begin_array?
          pull.read_array do
            if pull.kind.begin_object?
              value = raw_value(pull, Budget.new(limit))
              refs << %({"scan_event":"reference","value":#{value}}) << '\n'
            else
              pull.skip
            end
          end
        else
          pull.skip
        end
      end
      pull.finish
    end
    entity
  end

  private def scan_prices_array(pull : FusedJSON::PullParser, budget : Budget,
                                prices : File) : Nil
    reset(prices)
    unless pull.kind.begin_array?
      skip_charged(pull, budget)
      return
    end
    budget.charge(Budget::CONTAINER)
    pull.read_array do
      budget.charge(Budget::ARRAY_ENTRY)
      if pull.kind.begin_object?
        value = raw_value(pull, budget)
        prices << %({"scan_event":"price","value":#{value}}) << '\n'
      else
        skip_charged(pull, budget)
      end
    end
  end

  private def scan_rate(pull : FusedJSON::PullParser, budget : Budget,
                        item_spool : File, prices : File) : Nil
    refs = "null"
    inline = "null"
    reset(prices)
    pull.read_object do |key|
      budget.charge(Budget::HASH_ENTRY + Budget::STRING + key.bytesize)
      case key
      when "provider_references"
        refs = raw_value(pull, budget)
      when "provider_groups"
        inline = raw_value(pull, budget)
      when "negotiated_prices"
        scan_prices_array(pull, budget, prices)
      else
        skip_charged(pull, budget)
      end
    end
    item_spool << %({"scan_event":"rate","provider_references":#{refs},"provider_groups":#{inline}}) << '\n'
    copy(prices, item_spool)
    item_spool << %({"scan_event":"rate_end"}) << '\n'
  end

  private def scan_rates(pull : FusedJSON::PullParser, budget : Budget,
                         item_spool : File, prices : File) : Nil
    reset(item_spool)
    unless pull.kind.begin_array?
      skip_charged(pull, budget)
      return
    end
    budget.charge(Budget::CONTAINER)
    pull.read_array do
      budget.charge(Budget::ARRAY_ENTRY)
      if pull.kind.begin_object?
        budget.charge(Budget::CONTAINER)
        scan_rate(pull, budget, item_spool, prices)
      else
        skip_charged(pull, budget)
      end
    end
  end

  private def scan_item(pull : FusedJSON::PullParser, limit : Int64,
                        item_spool : File, prices : File, output : IO) : Nil
    budget = Budget.new(limit)
    budget.charge(Budget::CONTAINER)
    code = "null"
    code_type = "null"
    arrangement = "null"
    reset(item_spool)
    pull.read_object do |key|
      budget.charge(Budget::HASH_ENTRY + Budget::STRING + key.bytesize)
      case key
      when "billing_code"
        code = raw_value(pull, budget)
      when "billing_code_type"
        code_type = raw_value(pull, budget)
      when "negotiation_arrangement"
        arrangement = raw_value(pull, budget)
      when "negotiated_rates"
        scan_rates(pull, budget, item_spool, prices)
      else
        skip_charged(pull, budget)
      end
    end
    output << %({"scan_event":"item","billing_code":#{code},"billing_code_type":#{code_type},"negotiation_arrangement":#{arrangement}}) << '\n'
    copy(item_spool, output)
    output << %({"scan_event":"item_end"}) << '\n'
  end

  private def scan_in_network(path : String, limit : Int64, item_spool : File,
                              prices : File, output : IO) : Nil
    with_input(path) do |io|
      pull = parser(io)
      pull.read_object do |key|
        if key == "in_network" && pull.kind.begin_array?
          pull.read_array do
            if pull.kind.begin_object?
              scan_item(pull, limit, item_spool, prices, output)
            else
              pull.skip
            end
          end
        else
          pull.skip
        end
      end
      pull.finish
    end
  end

  def run(path : String, limit : Int64) : Nil
    refs_path = temp_path("refs")
    item_path = temp_path("item")
    price_path = temp_path("prices")
    File.open(refs_path, "w+") do |refs|
      entity = scan_references(path, refs, limit)
      STDOUT << %({"scan_protocol":#{PROTOCOL},"scan_event":"meta","reporting_entity_name":#{entity}}) << '\n'
      copy(refs, STDOUT)
      File.open(item_path, "w+") do |item_spool|
        File.open(price_path, "w+") do |prices|
          scan_in_network(path, limit, item_spool, prices, STDOUT)
        end
      end
    end
    STDOUT.flush
  ensure
    {refs_path, item_path, price_path}.each do |temp|
      File.delete(temp) if temp && File.exists?(temp)
    end
  end
end

limit = SunlightCompatScan::ITEM_LIMIT
parser = OptionParser.new do |opts|
  opts.banner = "usage: #{PROGRAM_NAME} [--item-limit-bytes N] FILE"
  opts.on("--item-limit-bytes N", "Sunlight retained-state item cap") { |v| limit = v.to_i64 }
end
parser.parse
path = ARGV.shift? || abort(parser.to_s)
abort(parser.to_s) unless ARGV.empty?

begin
  SunlightCompatScan.run(path, limit)
rescue SunlightCompatScan::ItemTooLarge
  STDERR.puts "item limit exceeded"
  exit 3
rescue error : FusedJSON::ParseError | Compress::Gzip::Error | IO::EOFError
  STDERR.puts "unparseable: #{error.message}"
  exit 4
end

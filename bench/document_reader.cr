require "benchmark"
require "json"

require "../src/fused_json"

module DocumentReaderBenchmark
  FNV_OFFSET = 14_695_981_039_346_656_037_u64
  FNV_PRIME  =          1_099_511_628_211_u64
  PROFILES   = [
    "repeated-schema",
    "unique-keys",
    "escaped-strings",
    "mixed-scalars",
    "periodic-wide",
  ]

  record Result, count : Int64, checksum : UInt64

  struct Event
    include JSON::Serializable

    getter id : Int64
    getter name : String
    getter? active : Bool
    getter tags : Array(String)
    getter attributes : Hash(String, String)

    def initialize(@id : Int64, @name : String, @active : Bool,
                   @tags : Array(String), @attributes : Hash(String, String))
    end
  end

  class Sink
    @@result = Result.new(0_i64, 0_u64)
    @@dynamic_values = [] of JSON::Any
    @@typed_values = [] of Event

    def self.store(result : Result) : Nil
      @@result = result
    end

    def self.store_dynamic(values : Array(JSON::Any)) : Nil
      @@dynamic_values = values
    end

    def self.store_typed(values : Array(Event)) : Nil
      @@typed_values = values
    end

    def self.result : Result
      @@result
    end
  end

  extend self

  def source(profile : String, count : Int32) : String
    String.build do |io|
      count.times do |index|
        if profile == "mixed-scalars"
          append_scalar(io, index)
        else
          event(profile, index).to_json(io)
        end
        io << '\n'
      end
    end
  end

  def dynamic_reader(source : String, buffer_size : Int32, cache_keys : Bool,
                     retain : Bool) : Result
    reader = FusedJSON.documents(
      IO::Memory.new(source),
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: buffer_size,
      cache_keys: cache_keys
    )
    retained = [] of JSON::Any if retain
    checksum = FNV_OFFSET
    count = 0_i64
    reader.each do |value|
      checksum = mix_any(checksum, value)
      retained.try &.<< value
      count += 1
    end
    reader.finish
    Sink.store_dynamic(retained) if retained
    Result.new(count, checksum)
  end

  def dynamic_fused_lines(source : String, cache_keys : Bool, retain : Bool) : Result
    retained = [] of JSON::Any if retain
    checksum = FNV_OFFSET
    count = 0_i64
    IO::Memory.new(source).each_line do |line|
      value = FusedJSON.load(line, cache_keys: cache_keys)
      checksum = mix_any(checksum, value)
      retained.try &.<< value
      count += 1
    end
    Sink.store_dynamic(retained) if retained
    Result.new(count, checksum)
  end

  def dynamic_crystal_lines(source : String, retain : Bool) : Result
    retained = [] of JSON::Any if retain
    checksum = FNV_OFFSET
    count = 0_i64
    IO::Memory.new(source).each_line do |line|
      value = JSON.parse(line)
      checksum = mix_any(checksum, value)
      retained.try &.<< value
      count += 1
    end
    Sink.store_dynamic(retained) if retained
    Result.new(count, checksum)
  end

  def typed_reader(source : String, buffer_size : Int32, cache_keys : Bool,
                   retain : Bool) : Result
    reader = FusedJSON.documents(
      IO::Memory.new(source),
      Event,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: buffer_size,
      cache_keys: cache_keys
    )
    retained = [] of Event if retain
    checksum = FNV_OFFSET
    count = 0_i64
    reader.each do |value|
      checksum = mix_event(checksum, value)
      retained.try &.<< value
      count += 1
    end
    reader.finish
    Sink.store_typed(retained) if retained
    Result.new(count, checksum)
  end

  def typed_fused_lines(source : String, cache_keys : Bool, retain : Bool) : Result
    retained = [] of Event if retain
    checksum = FNV_OFFSET
    count = 0_i64
    IO::Memory.new(source).each_line do |line|
      value = FusedJSON.from_json(line, Event, cache_keys: cache_keys)
      checksum = mix_event(checksum, value)
      retained.try &.<< value
      count += 1
    end
    Sink.store_typed(retained) if retained
    Result.new(count, checksum)
  end

  def typed_crystal_lines(source : String, retain : Bool) : Result
    retained = [] of Event if retain
    checksum = FNV_OFFSET
    count = 0_i64
    IO::Memory.new(source).each_line do |line|
      value = Event.from_json(line)
      checksum = mix_event(checksum, value)
      retained.try &.<< value
      count += 1
    end
    Sink.store_typed(retained) if retained
    Result.new(count, checksum)
  end

  private def event(profile : String, index : Int32) : Event
    tags = ["json", "event-#{index % 16}"]
    attributes = {
      "region" => "r#{index % 8}",
      "kind"   => "k#{index % 4}",
    }
    name = "event-#{index % 64}"

    case profile
    when "unique-keys"
      attributes = {
        "attribute_#{index}_a" => "value-a",
        "attribute_#{index}_b" => "value-b",
      }
    when "escaped-strings"
      name = "line\nquote\"slash\\tab\tλ𝄞-#{index}"
      tags = ["escaped\n#{index}", "\\\"λ"]
    when "periodic-wide"
      if index % 128 == 0
        tags = Array.new(512) { |tag| "wide-#{tag}-#{index}" }
      end
    when "repeated-schema"
    else
      raise ArgumentError.new("unknown typed profile #{profile.inspect}")
    end

    Event.new(index.to_i64, name, index.even?, tags, attributes)
  end

  private def append_scalar(io : IO, index : Int32) : Nil
    case index % 7
    when 0
      io << "null"
    when 1
      io << (index.even? ? "true" : "false")
    when 2
      io << index - 50_000
    when 3
      io << index << ".125e-2"
    when 4
      "line\nquote\"slash\\λ-#{index}".to_json(io)
    when 5
      io << '[' << index << ",false,"
      "value-#{index % 32}".to_json(io)
      io << ']'
    when 6
      io << %({"id":) << index << %(,"name":)
      "mixed-#{index % 16}".to_json(io)
      io << '}'
    end
  end

  private def mix_any(checksum : UInt64, value : JSON::Any) : UInt64
    case raw = value.raw
    when Nil
      mix_byte(checksum, 0_u8)
    when Bool
      mix_byte(checksum, raw ? 2_u8 : 1_u8)
    when Int64
      mix_u64(mix_byte(checksum, 3_u8), raw.unsafe_as(UInt64))
    when Float64
      mix_u64(mix_byte(checksum, 4_u8), raw.unsafe_as(UInt64))
    when String
      mix_string(mix_byte(checksum, 5_u8), raw)
    when Array(JSON::Any)
      value = mix_u64(mix_byte(checksum, 6_u8), raw.size.to_u64)
      raw.each { |item| value = mix_any(value, item) }
      value
    when Hash(String, JSON::Any)
      value = mix_u64(mix_byte(checksum, 7_u8), raw.size.to_u64)
      raw.each do |key, item|
        value = mix_string(value, key)
        value = mix_any(value, item)
      end
      value
    else
      raise "unknown JSON::Any value #{raw.class}"
    end
  end

  private def mix_event(checksum : UInt64, event : Event) : UInt64
    value = mix_u64(checksum, event.id.unsafe_as(UInt64))
    value = mix_string(value, event.name)
    value = mix_byte(value, event.active? ? 1_u8 : 0_u8)
    value = mix_u64(value, event.tags.size.to_u64)
    event.tags.each { |tag| value = mix_string(value, tag) }
    value = mix_u64(value, event.attributes.size.to_u64)
    event.attributes.each do |key, item|
      value = mix_string(value, key)
      value = mix_string(value, item)
    end
    value
  end

  private def mix_string(checksum : UInt64, string : String) : UInt64
    value = mix_u64(checksum, string.bytesize.to_u64)
    string.each_byte { |byte| value = mix_byte(value, byte) }
    value
  end

  private def mix_u64(checksum : UInt64, integer : UInt64) : UInt64
    value = checksum
    8.times do |index|
      value = mix_byte(value, ((integer >> (index * 8)) & 0xff_u64).to_u8)
    end
    value
  end

  private def mix_byte(checksum : UInt64, byte : UInt8) : UInt64
    (checksum ^ byte.to_u64) &* FNV_PRIME
  end
end

alias DocumentBenchmarkOperation = Tuple(String, Proc(DocumentReaderBenchmark::Result))

private def allocation_per_record(operation : Proc(DocumentReaderBenchmark::Result),
                                  iterations : Int32, records : Int32) : UInt64
  GC.collect
  bytes = Benchmark.memory do
    iterations.times { DocumentReaderBenchmark::Sink.store(operation.call) }
  end
  (bytes.to_f / iterations / records).round.to_u64
end

private def first_record_microseconds(operation : Proc(DocumentReaderBenchmark::Result),
                                      iterations : Int32) : Float64
  GC.collect
  elapsed = Time.measure do
    iterations.times { DocumentReaderBenchmark::Sink.store(operation.call) }
  end
  elapsed.total_seconds * 1_000_000.0 / iterations
end

private def measure_operations(title : String, operations : Array(DocumentBenchmarkOperation),
                               source_bytes : Int32, records : Int32,
                               first_operations : Array(DocumentBenchmarkOperation),
                               warmup : Time::Span, calculation : Time::Span,
                               allocation_iterations : Int32,
                               latency_iterations : Int32, reverse : Bool) : Nil
  expected = operations.first[1].call
  operations.each do |label, operation|
    actual = operation.call
    abort "#{title} semantic mismatch for #{label}" unless actual == expected
  end

  ordered = reverse ? operations.reverse : operations
  job = Benchmark.ips(warmup: warmup, calculation: calculation, interactive: false) do |benchmark|
    ordered.each do |label, operation|
      benchmark.report(label) do
        DocumentReaderBenchmark::Sink.store(operation.call)
      end
    end
  end

  puts title
  job.items.each do |item|
    mib_per_second = item.mean * source_bytes / 1_048_576.0
    records_per_second = item.mean * records
    printf "  %-28s %9.2f MiB/s  %12.0f records/s  (RSD %5.2f%%)\n",
      item.label, mib_per_second, records_per_second, item.relative_stddev
  end

  puts "  Managed allocation"
  operations.each do |label, operation|
    bytes = allocation_per_record(operation, allocation_iterations, records)
    printf "  %-28s %12d B/record\n", label, bytes
  end

  puts "  First-record latency"
  first_operations.each do |label, operation|
    microseconds = first_record_microseconds(operation, latency_iterations)
    printf "  %-28s %12.3f us\n", label, microseconds
  end

  raise "benchmark result was lost" unless DocumentReaderBenchmark::Sink.result.count > 0
end

{% unless flag?(:release) %}
  STDERR.puts "warning: build this benchmark with --release for meaningful results"
{% end %}

record_count = (ENV["FUSED_JSON_DOCUMENT_RECORDS"]? || "10000").to_i
buffer_size = (ENV["FUSED_JSON_DOCUMENT_BUFFER"]? || (32 * 1024).to_s).to_i
profile_setting = ENV["FUSED_JSON_DOCUMENT_PROFILE"]? || "repeated-schema"
profiles = profile_setting == "all" ? DocumentReaderBenchmark::PROFILES : [profile_setting]
retain = ENV["FUSED_JSON_DOCUMENT_RETAIN"]? == "1"
warmup = (ENV["FUSED_JSON_BENCH_WARMUP"]? || "1").to_f.seconds
calculation = (ENV["FUSED_JSON_BENCH_TIME"]? || "3").to_f.seconds
allocation_iterations = (ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "10").to_i
latency_iterations = (ENV["FUSED_JSON_DOCUMENT_LATENCY_ITERATIONS"]? || "100").to_i
reverse = ENV["FUSED_JSON_BENCH_REVERSE"]? == "1"

abort "FUSED_JSON_DOCUMENT_RECORDS must be positive" unless record_count > 0
abort "FUSED_JSON_DOCUMENT_BUFFER must be positive" unless buffer_size > 0
abort "FUSED_JSON_BENCH_ALLOCATIONS must be positive" unless allocation_iterations > 0
abort "FUSED_JSON_DOCUMENT_LATENCY_ITERATIONS must be positive" unless latency_iterations > 0
unknown = profiles - DocumentReaderBenchmark::PROFILES
abort "unknown profile(s): #{unknown.join(", ")}" unless unknown.empty?

profiles.each do |profile|
  source = DocumentReaderBenchmark.source(profile, record_count)
  first_newline = source.to_slice.index(0x0a_u8) || raise "generated profile has no records"
  first_source = source.byte_slice(0, first_newline + 1)
  retention = retain ? "accumulated" : "one at a time"
  puts
  puts "#{profile}: #{record_count} records, #{source.bytesize} bytes, output #{retention}"

  dynamic = [
    {"FusedJSON reader", -> { DocumentReaderBenchmark.dynamic_reader(source, buffer_size, false, retain) }},
    {"FusedJSON reader cached", -> { DocumentReaderBenchmark.dynamic_reader(source, buffer_size, true, retain) }},
    {"FusedJSON each_line", -> { DocumentReaderBenchmark.dynamic_fused_lines(source, false, retain) }},
    {"Crystal JSON each_line", -> { DocumentReaderBenchmark.dynamic_crystal_lines(source, retain) }},
  ] of DocumentBenchmarkOperation
  first_dynamic = [
    {"FusedJSON reader", -> { DocumentReaderBenchmark.dynamic_reader(first_source, buffer_size, false, retain) }},
    {"FusedJSON reader cached", -> { DocumentReaderBenchmark.dynamic_reader(first_source, buffer_size, true, retain) }},
    {"FusedJSON each_line", -> { DocumentReaderBenchmark.dynamic_fused_lines(first_source, false, retain) }},
    {"Crystal JSON each_line", -> { DocumentReaderBenchmark.dynamic_crystal_lines(first_source, retain) }},
  ] of DocumentBenchmarkOperation
  measure_operations(
    "Dynamic JSON::Any",
    dynamic,
    source.bytesize,
    record_count,
    first_dynamic,
    warmup,
    calculation,
    allocation_iterations,
    latency_iterations,
    reverse
  )

  next if profile == "mixed-scalars"

  typed = [
    {"FusedJSON reader", -> { DocumentReaderBenchmark.typed_reader(source, buffer_size, false, retain) }},
    {"FusedJSON reader cached", -> { DocumentReaderBenchmark.typed_reader(source, buffer_size, true, retain) }},
    {"FusedJSON each_line", -> { DocumentReaderBenchmark.typed_fused_lines(source, false, retain) }},
    {"Crystal JSON each_line", -> { DocumentReaderBenchmark.typed_crystal_lines(source, retain) }},
  ] of DocumentBenchmarkOperation
  first_typed = [
    {"FusedJSON reader", -> { DocumentReaderBenchmark.typed_reader(first_source, buffer_size, false, retain) }},
    {"FusedJSON reader cached", -> { DocumentReaderBenchmark.typed_reader(first_source, buffer_size, true, retain) }},
    {"FusedJSON each_line", -> { DocumentReaderBenchmark.typed_fused_lines(first_source, false, retain) }},
    {"Crystal JSON each_line", -> { DocumentReaderBenchmark.typed_crystal_lines(first_source, retain) }},
  ] of DocumentBenchmarkOperation
  measure_operations(
    "Typed Event",
    typed,
    source.bytesize,
    record_count,
    first_typed,
    warmup,
    calculation,
    allocation_iterations,
    latency_iterations,
    reverse
  )
end

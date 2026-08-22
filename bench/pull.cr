require "benchmark"
require "json"

require "../src/fused_json"

class PullBenchmarkSink
  @@load_value = JSON::Any.new(nil)
  @@pull_value = JSON::Any.new(nil)
  @@drain_checksum = 0_u64
  @@skip_checksum = 0_u64

  def self.store_load(value : JSON::Any) : Nil
    @@load_value = value
  end

  def self.store_pull(value : JSON::Any) : Nil
    @@pull_value = value
  end

  def self.store_drain(checksum : UInt64) : Nil
    @@drain_checksum = checksum
  end

  def self.store_skip(checksum : UInt64) : Nil
    @@skip_checksum = checksum
  end

  def self.load_value : JSON::Any
    @@load_value
  end

  def self.pull_value : JSON::Any
    @@pull_value
  end

  def self.drain_checksum : UInt64
    @@drain_checksum
  end

  def self.skip_checksum : UInt64
    @@skip_checksum
  end
end

private def pull_any(pull : FusedJSON::PullParser) : JSON::Any
  case pull.kind
  when .null?
    JSON::Any.new(pull.read_null)
  when .bool?
    JSON::Any.new(pull.read_bool)
  when .int?
    JSON::Any.new(pull.read_int)
  when .float?
    JSON::Any.new(pull.read_float)
  when .string?
    JSON::Any.new(pull.read_string)
  when .begin_array?
    values = [] of JSON::Any
    pull.read_array { values << pull_any(pull) }
    JSON::Any.new(values)
  when .begin_object?
    values = {} of String => JSON::Any
    pull.read_object do |key|
      values[key] = pull_any(pull)
    end
    JSON::Any.new(values)
  else
    raise "expected a value, found #{pull.kind}"
  end
end

private def pull_any(source : String) : JSON::Any
  pull = FusedJSON::PullParser.new(source)
  value = pull_any(pull)
  pull.finish
  value
end

private def drain_pull(source : String) : UInt64
  pull = FusedJSON::PullParser.new(source)
  checksum = 0_u64

  until pull.kind.eof?
    checksum &+= pull.kind.value.to_u64
    checksum &*= 1_099_511_628_211_u64
    case pull.kind
    when .null?, .begin_array?, .end_array?, .begin_object?, .end_object?
      pull.read_next
    when .bool?
      checksum &+= 1_u64 if pull.read_bool
    when .int?
      checksum &+= pull.read_int.unsafe_as(UInt64)
    when .float?
      checksum &+= pull.read_float.unsafe_as(UInt64)
    when .string?
      checksum &+= pull.read_string.bytesize.to_u64
    when .eof?
    end
  end

  checksum
end

private def skip_pull(source : String) : UInt64
  pull = FusedJSON::PullParser.new(source)
  pull.skip_value
  pull.finish
  pull.byte_offset.to_u64
end

private def allocation_per_operation(iterations : Int32, &) : UInt64
  GC.collect
  bytes = Benchmark.memory do
    iterations.times { yield }
  end
  (bytes.to_f / iterations).round.to_u64
end

if ARGV.empty?
  abort "usage: #{PROGRAM_NAME} JSON_FILE [JSON_FILE ...]"
end

warmup = (ENV["FUSED_JSON_BENCH_WARMUP"]? || "1").to_f.seconds
calculation = (ENV["FUSED_JSON_BENCH_TIME"]? || "3").to_f.seconds
allocation_iterations = (ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "20").to_i
reverse_order = ENV["FUSED_JSON_BENCH_REVERSE"]? == "1"
abort "FUSED_JSON_BENCH_ALLOCATIONS must be positive" unless allocation_iterations > 0

{% unless flag?(:release) %}
  STDERR.puts "warning: build this benchmark with --release for meaningful results"
{% end %}

ARGV.each do |path|
  source = File.read(path)
  expected = JSON.parse(source)
  load_value = FusedJSON.load(source)
  pull_value = pull_any(source)
  abort "load semantic mismatch for #{path}" unless load_value == expected
  abort "pull semantic mismatch for #{path}" unless pull_value == expected
  expected_checksum = drain_pull(source)
  abort "skip failed for #{path}" unless skip_pull(source) == source.bytesize.to_u64

  puts
  puts "#{File.basename(path)}: #{source.bytesize} bytes"
  puts "Throughput (#{warmup.total_seconds}s warmup, #{calculation.total_seconds}s calculation)"

  job = Benchmark.ips(warmup: warmup, calculation: calculation, interactive: false) do |x|
    if reverse_order
      x.report("pull skip") { PullBenchmarkSink.store_skip(skip_pull(source)) }
      x.report("pull drain") { PullBenchmarkSink.store_drain(drain_pull(source)) }
      x.report("pull -> JSON::Any") { PullBenchmarkSink.store_pull(pull_any(source)) }
      x.report("FusedJSON.load") { PullBenchmarkSink.store_load(FusedJSON.load(source)) }
    else
      x.report("FusedJSON.load") { PullBenchmarkSink.store_load(FusedJSON.load(source)) }
      x.report("pull -> JSON::Any") { PullBenchmarkSink.store_pull(pull_any(source)) }
      x.report("pull drain") { PullBenchmarkSink.store_drain(drain_pull(source)) }
      x.report("pull skip") { PullBenchmarkSink.store_skip(skip_pull(source)) }
    end
  end

  job.items.each do |item|
    mib_per_second = item.mean * source.bytesize / 1_048_576.0
    printf "  %-18s %9.2f MiB/s  (RSD %5.2f%%)\n",
      item.label, mib_per_second, item.relative_stddev
  end

  load_mean = job.items.find! { |item| item.label == "FusedJSON.load" }.mean
  pull_mean = job.items.find! { |item| item.label == "pull -> JSON::Any" }.mean
  printf "  pull/load ratio    %9.3fx\n", pull_mean / load_mean

  puts "Managed allocations (#{allocation_iterations} operations per implementation)"
  load_bytes = allocation_per_operation(allocation_iterations) do
    PullBenchmarkSink.store_load(FusedJSON.load(source))
  end
  pull_bytes = allocation_per_operation(allocation_iterations) do
    PullBenchmarkSink.store_pull(pull_any(source))
  end
  drain_bytes = allocation_per_operation(allocation_iterations) do
    PullBenchmarkSink.store_drain(drain_pull(source))
  end
  skip_bytes = allocation_per_operation(allocation_iterations) do
    PullBenchmarkSink.store_skip(skip_pull(source))
  end
  printf "  %-18s %12d B/op\n", "FusedJSON.load", load_bytes
  printf "  %-18s %12d B/op\n", "pull -> JSON::Any", pull_bytes
  printf "  %-18s %12d B/op\n", "pull drain", drain_bytes
  printf "  %-18s %12d B/op\n", "pull skip", skip_bytes
  printf "  pull/load ratio    %9.3fx\n", pull_bytes.to_f / load_bytes

  raise "benchmark load result was lost" unless PullBenchmarkSink.load_value == expected
  raise "benchmark pull result was lost" unless PullBenchmarkSink.pull_value == expected
  raise "benchmark drain result was lost" unless PullBenchmarkSink.drain_checksum == expected_checksum
  raise "benchmark skip result was lost" unless PullBenchmarkSink.skip_checksum == source.bytesize.to_u64
end

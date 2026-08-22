require "benchmark"
require "json"

require "../src/fused_json"

class ParseResultSink
  @@value = JSON::Any.new(nil)

  def self.store(value : JSON::Any) : Nil
    @@value = value
  end

  def self.value : JSON::Any
    @@value
  end
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
allocation_iterations = (ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "20").to_i?
reverse_order = ENV["FUSED_JSON_BENCH_REVERSE"]? == "1"
unless allocation_iterations && allocation_iterations > 0
  abort "FUSED_JSON_BENCH_ALLOCATIONS must be a positive integer"
end

ARGV.each do |path|
  source = File.read(path)
  expected = JSON.parse(source)
  actual = FusedJSON.load(source)
  abort "semantic mismatch for #{path}" unless actual == expected

  puts
  puts "#{File.basename(path)}: #{source.bytesize} bytes"

  job = Benchmark.ips(warmup: warmup, calculation: calculation, interactive: false) do |x|
    if reverse_order
      x.report("FusedJSON cached") { ParseResultSink.store(FusedJSON.load(source, cache_keys: true)) }
      x.report("FusedJSON.load") { ParseResultSink.store(FusedJSON.load(source)) }
      x.report("Crystal JSON.parse") { ParseResultSink.store(JSON.parse(source)) }
    else
      x.report("Crystal JSON.parse") { ParseResultSink.store(JSON.parse(source)) }
      x.report("FusedJSON.load") { ParseResultSink.store(FusedJSON.load(source)) }
      x.report("FusedJSON cached") { ParseResultSink.store(FusedJSON.load(source, cache_keys: true)) }
    end
  end

  job.items.each do |item|
    mib_per_second = item.mean * source.bytesize / 1_048_576.0
    printf "  %-18s %9.2f MiB/s  (RSD %5.2f%%)\n",
      item.label, mib_per_second, item.relative_stddev
  end

  stdlib_alloc = allocation_per_operation(allocation_iterations) do
    ParseResultSink.store(JSON.parse(source))
  end
  default_alloc = allocation_per_operation(allocation_iterations) do
    ParseResultSink.store(FusedJSON.load(source))
  end
  cached_alloc = allocation_per_operation(allocation_iterations) do
    ParseResultSink.store(FusedJSON.load(source, cache_keys: true))
  end
  puts "  Managed allocations"
  printf "  %-18s %12d B/op\n", "Crystal JSON.parse", stdlib_alloc
  printf "  %-18s %12d B/op\n", "FusedJSON.load", default_alloc
  printf "  %-18s %12d B/op\n", "FusedJSON cached", cached_alloc

  # Keep the final result observably live after the timed loop.
  raise "benchmark result was lost" unless ParseResultSink.value == expected
end

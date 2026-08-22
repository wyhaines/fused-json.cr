require "benchmark"
require "json"

require "../src/fused_json"

module TypedBenchmark
  alias Indices = Tuple(Int32, Int32)

  struct Hashtag
    include JSON::Serializable

    getter text : String
    getter indices : Indices
  end

  struct Mention
    include JSON::Serializable

    getter id : Int64
    getter name : String
    getter screen_name : String
    getter indices : Indices
  end

  struct Url
    include JSON::Serializable

    getter url : String
    getter expanded_url : String
    getter display_url : String
    getter indices : Indices
  end

  struct Entities
    include JSON::Serializable

    getter hashtags : Array(Hashtag)
    getter urls : Array(Url)
    getter user_mentions : Array(Mention)
  end

  struct User
    include JSON::Serializable

    getter id : Int64
    getter name : String
    getter screen_name : String
    getter followers_count : Int32
    getter verified : Bool
  end

  struct Status
    include JSON::Serializable

    getter id : Int64
    getter text : String
    getter lang : String
    getter retweet_count : Int32
    getter favorited : Bool
    getter in_reply_to_status_id : Int64?
    getter user : User
    getter entities : Entities
  end

  struct SearchMetadata
    include JSON::Serializable

    getter completed_in : Float64
    getter max_id : Int64
    getter count : Int32
    getter query : String
  end

  struct Search
    include JSON::Serializable

    getter statuses : Array(Status)

    @[JSON::Field(key: "search_metadata")]
    getter metadata : SearchMetadata
  end
end

class TypedBenchmarkSink
  @@stdlib : TypedBenchmark::Search? = nil
  @@fused : TypedBenchmark::Search? = nil
  @@fused_cached : TypedBenchmark::Search? = nil
  @@json_tree = JSON::Any.new(nil)
  @@fused_tree = JSON::Any.new(nil)

  def self.store_stdlib(value : TypedBenchmark::Search) : Nil
    @@stdlib = value
  end

  def self.store_fused(value : TypedBenchmark::Search) : Nil
    @@fused = value
  end

  def self.store_fused_cached(value : TypedBenchmark::Search) : Nil
    @@fused_cached = value
  end

  def self.store_json_tree(value : JSON::Any) : Nil
    @@json_tree = value
  end

  def self.store_fused_tree(value : JSON::Any) : Nil
    @@fused_tree = value
  end

  def self.verify(expected : TypedBenchmark::Search) : Nil
    raise "stdlib typed benchmark result was lost" unless @@stdlib == expected
    raise "FusedJSON typed benchmark result was lost" unless @@fused == expected
    raise "cached FusedJSON typed benchmark result was lost" unless @@fused_cached == expected
  end

  def self.verify_trees(expected : JSON::Any) : Nil
    raise "stdlib dynamic benchmark result was lost" unless @@json_tree == expected
    raise "FusedJSON dynamic benchmark result was lost" unless @@fused_tree == expected
  end
end

private def allocation_per_operation(iterations : Int32, &) : UInt64
  GC.collect
  bytes = Benchmark.memory do
    iterations.times { yield }
  end
  (bytes.to_f / iterations).round.to_u64
end

private def typed_values(source : String, path : String) : Tuple(TypedBenchmark::Search, TypedBenchmark::Search, TypedBenchmark::Search)
  begin
    expected = TypedBenchmark::Search.from_json(source)
    raise "statuses must not be empty" if expected.statuses.empty?

    fused = FusedJSON.from_json(source, TypedBenchmark::Search)
    fused_cached = FusedJSON.from_json(source, TypedBenchmark::Search, cache_keys: true)
    raise "FusedJSON result differs from JSON::Serializable" unless fused == expected
    raise "cached FusedJSON result differs from JSON::Serializable" unless fused_cached == expected

    {expected, fused, fused_cached}
  rescue error
    abort "typed benchmark schema mismatch for #{path}: #{error.class}: #{error.message}"
  end
end

if ARGV.empty?
  abort "usage: #{PROGRAM_NAME} TWITTER_JSON [TWITTER_JSON ...]"
end

{% unless flag?(:release) %}
  STDERR.puts "warning: build this benchmark with --release for meaningful results"
{% end %}

warmup = (ENV["FUSED_JSON_BENCH_WARMUP"]? || "1").to_f.seconds
calculation = (ENV["FUSED_JSON_BENCH_TIME"]? || "3").to_f.seconds
allocation_iterations = (ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "20").to_i
reverse_order = ENV["FUSED_JSON_BENCH_REVERSE"]? == "1"
abort "FUSED_JSON_BENCH_ALLOCATIONS must be positive" unless allocation_iterations > 0

ARGV.each do |path|
  source = File.read(path)
  expected, _, _ = typed_values(source, path)
  expected_tree = JSON.parse(source)
  fused_tree = FusedJSON.load(source)
  abort "FusedJSON dynamic result differs from JSON.parse for #{path}" unless fused_tree == expected_tree

  # Seed every independent sink before measuring and verify them again after
  # each pass so all result graphs remain observably live.
  TypedBenchmarkSink.store_stdlib(expected)
  TypedBenchmarkSink.store_fused(FusedJSON.from_json(source, TypedBenchmark::Search))
  TypedBenchmarkSink.store_fused_cached(FusedJSON.from_json(source, TypedBenchmark::Search, cache_keys: true))
  TypedBenchmarkSink.store_json_tree(expected_tree)
  TypedBenchmarkSink.store_fused_tree(fused_tree)
  TypedBenchmarkSink.verify(expected)
  TypedBenchmarkSink.verify_trees(expected_tree)

  puts
  puts "#{File.basename(path)}: #{source.bytesize} bytes, #{expected.statuses.size} statuses"
  puts "Throughput (#{warmup.total_seconds}s warmup, #{calculation.total_seconds}s calculation)"

  job = Benchmark::IPS::Job.new(calculation, warmup, false)
  if reverse_order
    job.report("FusedJSON cached") do
      TypedBenchmarkSink.store_fused_cached(FusedJSON.from_json(source, TypedBenchmark::Search, cache_keys: true))
    end
    job.report("FusedJSON typed") do
      TypedBenchmarkSink.store_fused(FusedJSON.from_json(source, TypedBenchmark::Search))
    end
    job.report("JSON T.from_json") do
      TypedBenchmarkSink.store_stdlib(TypedBenchmark::Search.from_json(source))
    end
  else
    job.report("JSON T.from_json") do
      TypedBenchmarkSink.store_stdlib(TypedBenchmark::Search.from_json(source))
    end
    job.report("FusedJSON typed") do
      TypedBenchmarkSink.store_fused(FusedJSON.from_json(source, TypedBenchmark::Search))
    end
    job.report("FusedJSON cached") do
      TypedBenchmarkSink.store_fused_cached(FusedJSON.from_json(source, TypedBenchmark::Search, cache_keys: true))
    end
  end
  job.execute

  job.items.each do |item|
    mib_per_second = item.mean * source.bytesize / 1_048_576.0
    printf "  %-18s %9.2f MiB/s  (RSD %5.2f%%)\n", item.label, mib_per_second, item.relative_stddev
  end

  stdlib_mean = job.items.find! { |item| item.label == "JSON T.from_json" }.mean
  fused_mean = job.items.find! { |item| item.label == "FusedJSON typed" }.mean
  cached_mean = job.items.find! { |item| item.label == "FusedJSON cached" }.mean
  printf "  %-18s %9.3fx\n", "FusedJSON/stdlib", fused_mean / stdlib_mean
  printf "  %-18s %9.3fx\n", "cached/stdlib", cached_mean / stdlib_mean
  TypedBenchmarkSink.verify(expected)

  puts "Allocations (#{allocation_iterations} operations per implementation)"
  stdlib_bytes = allocation_per_operation(allocation_iterations) do
    TypedBenchmarkSink.store_stdlib(TypedBenchmark::Search.from_json(source))
  end
  fused_bytes = allocation_per_operation(allocation_iterations) do
    TypedBenchmarkSink.store_fused(FusedJSON.from_json(source, TypedBenchmark::Search))
  end
  cached_bytes = allocation_per_operation(allocation_iterations) do
    TypedBenchmarkSink.store_fused_cached(FusedJSON.from_json(source, TypedBenchmark::Search, cache_keys: true))
  end

  printf "  %-18s %12d B/op\n", "JSON T.from_json", stdlib_bytes
  printf "  %-18s %12d B/op\n", "FusedJSON typed", fused_bytes
  printf "  %-18s %12d B/op\n", "FusedJSON cached", cached_bytes
  printf "  %-18s %9.3fx\n", "FusedJSON/stdlib", fused_bytes.to_f / stdlib_bytes
  printf "  %-18s %9.3fx\n", "cached/stdlib", cached_bytes.to_f / stdlib_bytes
  TypedBenchmarkSink.verify(expected)

  puts "Dynamic-tree allocation context (tree construction only)"
  json_tree_bytes = allocation_per_operation(allocation_iterations) do
    TypedBenchmarkSink.store_json_tree(JSON.parse(source))
  end
  fused_tree_bytes = allocation_per_operation(allocation_iterations) do
    TypedBenchmarkSink.store_fused_tree(FusedJSON.load(source))
  end
  printf "  %-18s %12d B/op\n", "JSON.parse", json_tree_bytes
  printf "  %-18s %12d B/op\n", "FusedJSON.load", fused_tree_bytes
  printf "  %-18s %9.3fx JSON.parse\n", "typed/tree ratio", fused_bytes.to_f / json_tree_bytes
  printf "  %-18s %9.3fx JSON.parse\n", "cached/tree ratio", cached_bytes.to_f / json_tree_bytes
  TypedBenchmarkSink.verify_trees(expected_tree)
end

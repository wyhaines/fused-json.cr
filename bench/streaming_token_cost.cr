require "benchmark"
require "digest/sha256"
require "json"

require "./streaming_token_support"

module StreamingTokenBenchmark
  class Sink
    @@result = StreamingTokenCost::RunResult.new(
      StreamingTokenCost::SemanticResult.new(0_i64, 0_u64),
      0_i64,
      0_i64,
      0_i64,
      false
    )

    def self.store(result : StreamingTokenCost::RunResult) : Nil
      @@result = result
    end

    def self.verify(expected : StreamingTokenCost::SemanticResult) : Nil
      unless @@result.semantic == expected
        raise "streaming token benchmark result was lost"
      end
    end
  end

  extend self

  def positive_i32(value : String, name : String, maximum : Int32 = Int32::MAX) : Int32
    parsed = value.to_i64?
    unless parsed && 0 < parsed <= maximum
      raise ArgumentError.new("#{name} must be between 1 and #{maximum}")
    end
    parsed.to_i32
  end

  def nonnegative_i32(value : String, name : String) : Int32
    parsed = value.to_i64?
    unless parsed && 0 <= parsed <= Int32::MAX
      raise ArgumentError.new("#{name} must be between 0 and #{Int32::MAX}")
    end
    parsed.to_i32
  end

  def positive_f64(value : String, name : String) : Float64
    parsed = value.to_f64?
    unless parsed && parsed.finite? && parsed > 0
      raise ArgumentError.new("#{name} must be a positive finite number")
    end
    parsed
  end

  def nonnegative_f64(value : String, name : String) : Float64
    parsed = value.to_f64?
    unless parsed && parsed.finite? && parsed >= 0
      raise ArgumentError.new("#{name} must be a nonnegative finite number")
    end
    parsed
  end

  def allocation_per_operation(iterations : Int32,
                               operation : Proc(StreamingTokenCost::RunResult)) : UInt64
    GC.collect
    bytes = Benchmark.memory do
      iterations.times { Sink.store(operation.call) }
    end
    (bytes.to_f / iterations).round.to_u64
  end

  def one_value_microseconds(iterations : Int32,
                             operation : Proc(StreamingTokenCost::RunResult)) : Float64
    GC.collect
    elapsed = Time.measure do
      iterations.times { Sink.store(operation.call) }
    end
    elapsed.total_seconds * 1_000_000.0 / iterations
  end

  def file_sha256(path : String) : String
    Digest::SHA256.hexdigest(File.read(path))
  end
end

{% unless flag?(:release) %}
  abort "build this benchmark with --release --no-debug"
{% end %}

commit = ENV["FUSED_JSON_BENCH_COMMIT"]? || abort "FUSED_JSON_BENCH_COMMIT is required"
unless commit.matches?(/\A[0-9a-f]{40}\z/)
  abort "FUSED_JSON_BENCH_COMMIT must be a full 40-character SHA"
end

profile = ENV["FUSED_JSON_TOKEN_PROFILE"]? || "escape-sparse"
consumer = ENV["FUSED_JSON_TOKEN_CONSUMER"]? || "pull-materialize"
transport = ENV["FUSED_JSON_TOKEN_TRANSPORT"]? || "io-memory"
limit_policy = ENV["FUSED_JSON_TOKEN_LIMITS"]? || "none"
abort "FUSED_JSON_TOKEN_PROFILE must be one of #{StreamingTokenCost::PROFILES.join(", ")}" unless StreamingTokenCost::PROFILES.includes?(profile)
abort "FUSED_JSON_TOKEN_CONSUMER must be one of #{StreamingTokenCost::CONSUMERS.join(", ")}" unless StreamingTokenCost::CONSUMERS.includes?(consumer)
abort "FUSED_JSON_TOKEN_TRANSPORT must be one of #{StreamingTokenCost::TRANSPORTS.join(", ")}" unless StreamingTokenCost::TRANSPORTS.includes?(transport)
abort "FUSED_JSON_TOKEN_LIMITS must be one of #{StreamingTokenCost::LIMIT_POLICIES.join(", ")}" unless StreamingTokenCost::LIMIT_POLICIES.includes?(limit_policy)

values = StreamingTokenBenchmark.positive_i32(
  ENV["FUSED_JSON_TOKEN_VALUES"]? || "2000",
  "FUSED_JSON_TOKEN_VALUES"
)
token_bytes = StreamingTokenBenchmark.positive_i32(
  ENV["FUSED_JSON_TOKEN_BYTES"]? || "512",
  "FUSED_JSON_TOKEN_BYTES",
  16 * 1024 * 1024
)
leading_padding = StreamingTokenBenchmark.nonnegative_i32(
  ENV["FUSED_JSON_TOKEN_LEADING_PADDING"]? || "0",
  "FUSED_JSON_TOKEN_LEADING_PADDING"
)
buffer_size = StreamingTokenBenchmark.positive_i32(
  ENV["FUSED_JSON_TOKEN_BUFFER"]? || FusedJSON::StreamingPullParser::DEFAULT_BUFFER_SIZE.to_s,
  "FUSED_JSON_TOKEN_BUFFER",
  FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
)
chunk_size = StreamingTokenBenchmark.positive_i32(
  ENV["FUSED_JSON_TOKEN_CHUNK"]? || "4096",
  "FUSED_JSON_TOKEN_CHUNK"
)
warmup = StreamingTokenBenchmark.nonnegative_f64(
  ENV["FUSED_JSON_BENCH_WARMUP"]? || "0.5",
  "FUSED_JSON_BENCH_WARMUP"
).seconds
calculation = StreamingTokenBenchmark.positive_f64(
  ENV["FUSED_JSON_BENCH_TIME"]? || "1",
  "FUSED_JSON_BENCH_TIME"
).seconds
allocation_iterations = StreamingTokenBenchmark.positive_i32(
  ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "5",
  "FUSED_JSON_BENCH_ALLOCATIONS"
)
latency_iterations = StreamingTokenBenchmark.positive_i32(
  ENV["FUSED_JSON_TOKEN_LATENCY_ITERATIONS"]? || "100",
  "FUSED_JSON_TOKEN_LATENCY_ITERATIONS"
)
cache_keys = ENV["FUSED_JSON_TOKEN_CACHE_KEYS"]? == "1"
run_boundary_preflight = ENV["FUSED_JSON_TOKEN_BOUNDARY_PREFLIGHT"]? == "1"
pair_id = ENV["FUSED_JSON_BENCH_PAIR_ID"]?
order_position = ENV["FUSED_JSON_BENCH_ORDER_POSITION"]?

chunks = transport == "chunked-memory" ? [chunk_size] : [] of Int32
config = StreamingTokenCost::RunConfig.new(
  consumer,
  transport,
  buffer_size,
  chunks,
  cache_keys,
  limit_policy
)
fixture = StreamingTokenCost.generate(profile, values, token_bytes, leading_padding)
StreamingTokenCost.validate_config(fixture, config)
expected = StreamingTokenCost.expected_for(fixture, config)
operation = -> { StreamingTokenCost.run(fixture, config) }

preflight = operation.call
abort "semantic mismatch for #{consumer}/#{transport}/#{profile}" unless preflight.semantic == expected
StreamingTokenCost.verify_input(preflight)
StreamingTokenBenchmark::Sink.store(preflight)

if run_boundary_preflight
  StreamingTokenCost.boundary_preflight(
    profile,
    consumer,
    buffer_size,
    token_bytes,
    cache_keys,
    limit_policy
  )
end

job = Benchmark::IPS::Job.new(calculation, warmup, false)
job.report("#{consumer}/#{transport}/#{profile}") do
  StreamingTokenBenchmark::Sink.store(operation.call)
end
job.execute
item = job.items.first

managed_bytes = StreamingTokenBenchmark.allocation_per_operation(
  allocation_iterations,
  operation
)
StreamingTokenBenchmark::Sink.verify(expected)
one_fixture = StreamingTokenCost.generate(profile, 1, token_bytes, leading_padding)
one_config = config
one_expected = StreamingTokenCost.expected_for(one_fixture, one_config)
one_operation = -> { StreamingTokenCost.run(one_fixture, one_config) }
unless one_operation.call.semantic == one_expected
  abort "one-value semantic mismatch for #{consumer}/#{transport}/#{profile}"
end
one_value_microseconds = StreamingTokenBenchmark.one_value_microseconds(
  latency_iterations,
  one_operation
)

source = StreamingTokenCost.source_for(fixture, consumer)
mib_per_second = item.mean * source.bytesize / 1_048_576.0
records_per_second = item.mean * values
puts "  #{mib_per_second.round(3)} MiB/s, #{records_per_second.round(1)} values/s, #{managed_bytes} B/op"

receipt = JSON.build do |json|
  json.object do
    json.field "receipt", "fused-json-streaming-token-cost"
    json.field "version", 1
    json.field "recorded_at", Time.utc.to_rfc3339
    json.field "fused_json_version", FusedJSON::VERSION
    json.field "fused_json_commit", commit
    json.field "crystal_version", Crystal::VERSION
    json.field "crystal_build_commit", Crystal::BUILD_COMMIT
    json.field "llvm_version", Crystal::LLVM_VERSION
    json.field "target", Crystal::TARGET_TRIPLE
    json.field "release_build", true
    json.field "benchmark_source_sha256", StreamingTokenBenchmark.file_sha256(__FILE__)
    json.field "benchmark_support_sha256", StreamingTokenBenchmark.file_sha256(
      File.expand_path("streaming_token_support.cr", __DIR__)
    )
    json.field "profile", profile
    json.field "consumer", consumer
    json.field "transport", transport
    json.field "limit_policy", limit_policy
    json.field "cache_keys", cache_keys
    json.field "values", values
    json.field "requested_token_bytes", token_bytes
    json.field "largest_token_bytes", fixture.largest_token_bytes
    json.field "leading_padding", leading_padding
    json.field "source_bytes", source.bytesize
    json.field "source_sha256", Digest::SHA256.hexdigest(source)
    json.field "expected_values", expected.values
    json.field "expected_checksum", "0x#{expected.checksum.to_s(16).rjust(16, '0')}"
    json.field "buffer_size", buffer_size
    json.field "chunk_pattern", chunks
    json.field "boundary_preflight", run_boundary_preflight
    json.field "warmup_seconds", warmup.total_seconds
    json.field "calculation_seconds", calculation.total_seconds
    json.field "allocation_iterations", allocation_iterations
    json.field "latency_iterations", latency_iterations
    json.field "iterations_per_second", item.mean
    json.field "relative_stddev_percent", item.relative_stddev
    json.field "mib_per_second", mib_per_second
    json.field "values_per_second", records_per_second
    json.field "nanoseconds_per_byte", 1_000_000_000.0 / item.mean / source.bytesize
    json.field "managed_bytes_per_operation", managed_bytes
    json.field "managed_bytes_per_input_byte", managed_bytes.to_f / source.bytesize
    json.field "one_value_microseconds", one_value_microseconds
    json.field "preflight_read_calls", preflight.read_calls
    json.field "preflight_bytes_read", preflight.bytes_read
    json.field "pair_id", pair_id
    json.field "order_position", order_position
    json.field "gc_nprocs", ENV["GC_NPROCS"]?
    json.field "gc_markers", ENV["GC_MARKERS"]?
  end
end
puts receipt

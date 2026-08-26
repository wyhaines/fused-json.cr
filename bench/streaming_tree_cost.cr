require "benchmark"
require "digest/sha256"
require "json"

require "../src/fused_json"

module StreamingTreeCost
  MODES = [
    "string",
    "io-memory",
    "chunked-memory",
    "pull-tree",
    "file",
  ]

  SHAPES = [
    "scalars",
    "small-objects",
    "wide-objects",
    "nested",
    "short-strings",
    "long-strings",
    "escaped-strings",
  ]

  class Sink
    @@value = JSON::Any.new(nil)

    def self.store(value : JSON::Any) : Nil
      @@value = value
    end

    def self.verify(expected : JSON::Any) : Nil
      raise "streaming-tree benchmark result was lost" unless @@value == expected
    end
  end

  class ChunkedMemoryIO < IO
    getter bytes_read : Int64
    getter read_calls : Int64
    getter closed_called : Bool

    @memory : IO::Memory
    @chunk_index : Int32

    def initialize(source : String, @chunks : Array(Int32))
      raise ArgumentError.new("at least one chunk size is required") if @chunks.empty?
      raise ArgumentError.new("chunk sizes must be positive") unless @chunks.all?(&.positive?)

      @memory = IO::Memory.new(source)
      @bytes_read = 0_i64
      @read_calls = 0_i64
      @closed_called = false
      @chunk_index = 0
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("read after close") if @closed_called
      raise IO::Error.new("empty read request") if slice.empty?

      chunk_size = @chunks[@chunk_index]
      @chunk_index = (@chunk_index + 1) % @chunks.size
      count = @memory.read(slice[0, Math.min(slice.size, chunk_size)])
      @bytes_read += count
      @read_calls += 1
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("streaming-tree benchmark input is read-only")
    end

    def close : Nil
      @closed_called = true
    end

    def closed? : Bool
      @closed_called
    end
  end

  extend self

  def generated_source(shape : String, records : Int32) : String
    String.build do |io|
      io << '['
      records.times do |index|
        io << ',' unless index == 0
        append_item(io, shape, index)
      end
      io << ']'
    end
  end

  private def append_item(io : IO, shape : String, index : Int32) : Nil
    case shape
    when "scalars"
      io << 10_000_000 + index
    when "small-objects"
      io << %({"id":) << index
      io << %(,"active":) << (index.even? ? "true" : "false")
      io << %(,"name":"item-) << index % 32 << %("})
    when "wide-objects"
      io << %({"id":) << index
      io << %(,"alpha":) << index + 1
      io << %(,"beta":) << index + 2
      io << %(,"gamma":) << index + 3
      io << %(,"delta":) << index + 4
      io << %(,"epsilon":) << index + 5
      io << %(,"kind":"wide","enabled":) << (index.even? ? "true" : "false")
      io << %(,"tags":["a","b","c"],"tail":null})
    when "nested"
      io << %({"id":) << index
      io << %(,"payload":{"left":[) << index << ',' << index + 1
      io << %(,{"deep":") << index % 64
      io << %("}],"right":{"name":"node-) << index % 16
      io << %(","values":[true,false,null]}}})
    when "short-strings"
      io << %("short-value-) << index % 64 << %(")
    when "long-strings"
      io << '"'
      8.times { io << "plain-λ-0123456789abcdef-" }
      io << index << '"'
    when "escaped-strings"
      value = String.build do |string|
        8.times { string << "line\n\t\"\\λ𝄞/" }
        string << index
      end
      value.to_json(io)
    else
      raise ArgumentError.new("unknown generated shape #{shape.inspect}")
    end
  end

  def read_any(pull : FusedJSON::PullParser) : JSON::Any
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
      pull.read_array { values << read_any(pull) }
      JSON::Any.new(values)
    when .begin_object?
      values = {} of String => JSON::Any
      pull.read_object { |key| values[key] = read_any(pull) }
      JSON::Any.new(values)
    else
      raise "expected a value, found #{pull.kind}"
    end
  end

  def parse_pull_tree(source : String, buffer_size : Int32, cache_keys : Bool) : JSON::Any
    pull = FusedJSON::PullParser.new(
      IO::Memory.new(source),
      buffer_size: buffer_size,
      cache_keys: cache_keys
    )
    value = read_any(pull)
    pull.finish
    value
  end

  def parse_chunked(source : String, buffer_size : Int32, chunk_size : Int32,
                    cache_keys : Bool) : JSON::Any
    io = ChunkedMemoryIO.new(source, [chunk_size])
    value = FusedJSON.load(io, buffer_size: buffer_size, cache_keys: cache_keys)
    verify_complete_io(io, source)
    value
  end

  def parse_file(path : String, buffer_size : Int32, cache_keys : Bool) : JSON::Any
    File.open(path) do |file|
      file.read_buffering = false
      FusedJSON.load(file, buffer_size: buffer_size, cache_keys: cache_keys)
    end
  end

  def operation(mode : String, source : String, path : String?,
                buffer_size : Int32, chunk_size : Int32,
                cache_keys : Bool) : Proc(JSON::Any)
    case mode
    when "string"
      -> { FusedJSON.load(source, cache_keys: cache_keys) }
    when "io-memory"
      -> { FusedJSON.load(
        IO::Memory.new(source),
        buffer_size: buffer_size,
        cache_keys: cache_keys
      ) }
    when "chunked-memory"
      -> { parse_chunked(source, buffer_size, chunk_size, cache_keys) }
    when "pull-tree"
      -> { parse_pull_tree(source, buffer_size, cache_keys) }
    when "file"
      file_path = path || raise ArgumentError.new("file mode requires a path")
      -> { parse_file(file_path, buffer_size, cache_keys) }
    else
      raise ArgumentError.new("unknown mode #{mode.inspect}")
    end
  end

  def boundary_preflight(shape : String, buffer_size : Int32,
                         cache_keys : Bool) : Nil
    source = generated_source(shape, 31)
    expected = FusedJSON.load(source, cache_keys: cache_keys)
    patterns = [
      [1],
      [1, 2, 1, 7, 3, 1, 11],
      [Math.max(1, buffer_size - 1)],
      [buffer_size],
      [buffer_size + 1],
    ].uniq

    patterns.each do |chunks|
      io = ChunkedMemoryIO.new(source, chunks)
      actual = FusedJSON.load(
        io,
        buffer_size: buffer_size,
        cache_keys: cache_keys
      )
      unless actual == expected
        raise "boundary preflight mismatch for chunk pattern #{chunks}"
      end
      verify_complete_io(io, source)
    end
  end

  def verify_complete_io(io : ChunkedMemoryIO, source : String) : Nil
    unless io.bytes_read == source.bytesize
      raise "streaming parser read #{io.bytes_read} of #{source.bytesize} bytes"
    end
    raise "streaming parser closed caller-owned IO" if io.closed_called
  end

  def positive_i32(value : String, name : String, maximum : Int32 = Int32::MAX) : Int32
    parsed = value.to_i64?
    unless parsed && 0 < parsed <= maximum
      raise ArgumentError.new("#{name} must be between 1 and #{maximum}")
    end
    parsed.to_i32
  end

  def nonnegative_f64(value : String, name : String) : Float64
    parsed = value.to_f64?
    unless parsed && parsed.finite? && parsed >= 0
      raise ArgumentError.new("#{name} must be a nonnegative finite number")
    end
    parsed
  end

  def positive_f64(value : String, name : String) : Float64
    parsed = value.to_f64?
    unless parsed && parsed.finite? && parsed > 0
      raise ArgumentError.new("#{name} must be a positive finite number")
    end
    parsed
  end

  def managed_bytes_per_operation(iterations : Int32, operation : Proc(JSON::Any)) : UInt64
    GC.collect
    bytes = Benchmark.memory do
      iterations.times { Sink.store(operation.call) }
    end
    (bytes.to_f / iterations).round.to_u64
  end
end

{% unless flag?(:release) %}
  abort "build this benchmark with --release --no-debug"
{% end %}

commit = ENV["FUSED_JSON_BENCH_COMMIT"]? || abort "FUSED_JSON_BENCH_COMMIT is required"
unless commit.matches?(/\A[0-9a-f]{40}\z/)
  abort "FUSED_JSON_BENCH_COMMIT must be a full 40-character commit SHA"
end

mode = ENV["FUSED_JSON_TREE_MODE"]? || "io-memory"
shape = ENV["FUSED_JSON_TREE_SHAPE"]? || "small-objects"
abort "FUSED_JSON_TREE_MODE must be one of #{StreamingTreeCost::MODES.join(", ")}" unless StreamingTreeCost::MODES.includes?(mode)
abort "FUSED_JSON_TREE_SHAPE must be one of #{StreamingTreeCost::SHAPES.join(", ")}" unless StreamingTreeCost::SHAPES.includes?(shape)

records = StreamingTreeCost.positive_i32(
  ENV["FUSED_JSON_TREE_RECORDS"]? || "20000",
  "FUSED_JSON_TREE_RECORDS"
)
buffer_size = StreamingTreeCost.positive_i32(
  ENV["FUSED_JSON_TREE_BUFFER"]? || FusedJSON::StreamingPullParser::DEFAULT_BUFFER_SIZE.to_s,
  "FUSED_JSON_TREE_BUFFER",
  FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
)
chunk_size = StreamingTreeCost.positive_i32(
  ENV["FUSED_JSON_TREE_CHUNK"]? || "4096",
  "FUSED_JSON_TREE_CHUNK"
)
warmup = StreamingTreeCost.nonnegative_f64(
  ENV["FUSED_JSON_BENCH_WARMUP"]? || "1",
  "FUSED_JSON_BENCH_WARMUP"
).seconds
calculation = StreamingTreeCost.positive_f64(
  ENV["FUSED_JSON_BENCH_TIME"]? || "3",
  "FUSED_JSON_BENCH_TIME"
).seconds
allocation_iterations = StreamingTreeCost.positive_i32(
  ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || "20",
  "FUSED_JSON_BENCH_ALLOCATIONS"
)
cache_keys = ENV["FUSED_JSON_TREE_CACHE_KEYS"]? == "1"
run_boundary_preflight = ENV["FUSED_JSON_TREE_BOUNDARY_PREFLIGHT"]? == "1"
pair_id = ENV["FUSED_JSON_BENCH_PAIR_ID"]?
order_position = ENV["FUSED_JSON_BENCH_ORDER_POSITION"]?

path = ARGV.first?
if mode == "file"
  abort "file mode accepts exactly one JSON path" unless ARGV.size == 1
else
  abort "#{mode} mode does not accept JSON paths" unless ARGV.empty?
end

source = path ? File.read(path) : StreamingTreeCost.generated_source(shape, records)
source_label = path ? File.basename(path) : shape
expected = JSON.parse(source)
operation = StreamingTreeCost.operation(
  mode,
  source,
  path,
  buffer_size,
  chunk_size,
  cache_keys
)
actual = operation.call
abort "semantic mismatch for #{source_label} in #{mode} mode" unless actual == expected
StreamingTreeCost::Sink.store(actual)
StreamingTreeCost.boundary_preflight(shape, buffer_size, cache_keys) if run_boundary_preflight

job = Benchmark::IPS::Job.new(calculation, warmup, false)
job.report(mode) { StreamingTreeCost::Sink.store(operation.call) }
job.execute
item = job.items.first
managed_bytes = StreamingTreeCost.managed_bytes_per_operation(
  allocation_iterations,
  operation
)
StreamingTreeCost::Sink.verify(expected)

mib_per_second = item.mean * source.bytesize / 1_048_576.0
receipt = JSON.build do |json|
  json.object do
    json.field "receipt", "fused-json-streaming-tree-cost"
    json.field "version", 1
    json.field "recorded_at", Time.utc.to_rfc3339
    json.field "fused_json_version", FusedJSON::VERSION
    json.field "fused_json_commit", commit
    json.field "crystal_version", Crystal::VERSION
    json.field "crystal_build_commit", Crystal::BUILD_COMMIT
    json.field "llvm_version", Crystal::LLVM_VERSION
    json.field "target", Crystal::TARGET_TRIPLE
    json.field "release_build", true
    json.field "mode", mode
    json.field "shape", shape
    json.field "source_label", source_label
    json.field "generated_records", path ? nil : records
    json.field "source_bytes", source.bytesize
    json.field "source_sha256", Digest::SHA256.hexdigest(source)
    json.field "result_sha256", Digest::SHA256.hexdigest(expected.to_json)
    json.field "buffer_size", buffer_size
    json.field "chunk_size", mode == "chunked-memory" ? chunk_size : nil
    json.field "cache_keys", cache_keys
    json.field "boundary_preflight", run_boundary_preflight
    json.field "warmup_seconds", warmup.total_seconds
    json.field "calculation_seconds", calculation.total_seconds
    json.field "allocation_iterations", allocation_iterations
    json.field "iterations_per_second", item.mean
    json.field "relative_stddev_percent", item.relative_stddev
    json.field "mib_per_second", mib_per_second
    json.field "nanoseconds_per_byte", 1_000_000_000.0 / item.mean / source.bytesize
    json.field "managed_bytes_per_operation", managed_bytes
    json.field "pair_id", pair_id
    json.field "order_position", order_position
    json.field "gc_nprocs", ENV["GC_NPROCS"]?
    json.field "gc_markers", ENV["GC_MARKERS"]?
  end
end
puts receipt

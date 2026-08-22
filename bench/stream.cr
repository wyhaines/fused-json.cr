require "benchmark"
require "json"
require "option_parser"

require "../src/fused_json"

module StreamBenchmark
  FNV_OFFSET = 14_695_981_039_346_656_037_u64
  FNV_PRIME  =          1_099_511_628_211_u64

  PEAK_MODES = [
    "memory-drain",
    "stream-drain",
    "file-stream-drain",
    "memory-skip",
    "stream-skip",
    "file-stream-skip",
  ]

  record FirstEventSample,
    kind : FusedJSON::PullParser::Kind,
    byte_offset : Int64,
    line : Int64,
    column : Int64,
    bytes_read : Int64 do
    def event_signature
      {kind, byte_offset, line, column}
    end
  end

  record PreflightResult,
    expected : JSON::Any,
    first_memory : FirstEventSample,
    first_stream : FirstEventSample,
    drain_checksum : UInt64,
    skip_checksum : UInt64

  # An IO::Memory input that limits each read so refill behavior remains an
  # explicit benchmark dimension.
  class ChunkedMemoryIO < IO
    getter bytes_read : Int64
    getter read_calls : Int64

    @memory : IO::Memory
    @closed : Bool

    def initialize(@source : String, @chunk_size : Int32)
      @memory = IO::Memory.new(@source)
      @bytes_read = 0_i64
      @read_calls = 0_i64
      @closed = false
    end

    def read(slice : Bytes) : Int32
      raise IO::Error.new("read after close") if @closed

      request_size = Math.min(slice.size, @chunk_size)
      count = @memory.read(slice[0, request_size])
      @bytes_read += count
      @read_calls += 1
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("stream benchmark input is read-only")
    end

    def close : Nil
      @closed = true
    end

    def closed? : Bool
      @closed
    end
  end

  # A file-backed input with the same configurable short-read behavior as the
  # IO::Memory adapter. It never retains a copy of the file contents.
  class ChunkedFileIO < IO
    getter bytes_read : Int64
    getter read_calls : Int64

    @file : File

    def initialize(path : String, @chunk_size : Int32)
      @file = File.open(path)
      @bytes_read = 0_i64
      @read_calls = 0_i64
    end

    def read(slice : Bytes) : Int32
      request_size = Math.min(slice.size, @chunk_size)
      count = @file.read(slice[0, request_size])
      @bytes_read += count
      @read_calls += 1
      count
    end

    def write(slice : Bytes) : Nil
      raise IO::Error.new("stream benchmark input is read-only")
    end

    def close : Nil
      @file.close unless @file.closed?
    end

    def closed? : Bool
      @file.closed?
    end
  end

  # Each measured implementation and operation has a distinct observable sink.
  class Sink
    @@memory_value = JSON::Any.new(nil)
    @@stream_value = JSON::Any.new(nil)
    @@memory_first = FirstEventSample.new(FusedJSON::PullParser::Kind::EOF, 0_i64, 1_i64, 1_i64, 0_i64)
    @@stream_first = FirstEventSample.new(FusedJSON::PullParser::Kind::EOF, 0_i64, 1_i64, 1_i64, 0_i64)
    @@memory_drain = 0_u64
    @@stream_drain = 0_u64
    @@memory_skip = 0_u64
    @@stream_skip = 0_u64
    @@peak = 0_u64

    def self.store_memory_value(value : JSON::Any) : Nil
      @@memory_value = value
    end

    def self.store_stream_value(value : JSON::Any) : Nil
      @@stream_value = value
    end

    def self.store_memory_first(value : FirstEventSample) : Nil
      @@memory_first = value
    end

    def self.store_stream_first(value : FirstEventSample) : Nil
      @@stream_first = value
    end

    def self.store_memory_drain(value : UInt64) : Nil
      @@memory_drain = value
    end

    def self.store_stream_drain(value : UInt64) : Nil
      @@stream_drain = value
    end

    def self.store_memory_skip(value : UInt64) : Nil
      @@memory_skip = value
    end

    def self.store_stream_skip(value : UInt64) : Nil
      @@stream_skip = value
    end

    def self.store_peak(value : UInt64) : Nil
      @@peak = value
    end

    def self.verify_preflight(result : PreflightResult) : Nil
      raise "in-memory semantic result was lost" unless @@memory_value == result.expected
      raise "streaming semantic result was lost" unless @@stream_value == result.expected
      verify_first(result.first_memory, result.first_stream)
      verify_drain(result.drain_checksum)
      verify_skip(result.skip_checksum)
    end

    def self.verify_first(memory : FirstEventSample, stream : FirstEventSample) : Nil
      raise "in-memory first-event result was lost" unless @@memory_first == memory
      raise "streaming first-event result was lost" unless @@stream_first == stream
    end

    def self.verify_drain(expected : UInt64) : Nil
      raise "in-memory drain checksum was lost" unless @@memory_drain == expected
      raise "streaming drain checksum was lost" unless @@stream_drain == expected
    end

    def self.verify_skip(expected : UInt64) : Nil
      raise "in-memory skip checksum was lost" unless @@memory_skip == expected
      raise "streaming skip checksum was lost" unless @@stream_skip == expected
    end

    def self.verify_peak(expected : UInt64) : Nil
      raise "peak-memory checksum was lost" unless @@peak == expected
    end
  end

  extend self

  def stream_parser(source : String, chunk_size : Int32, buffer_size : Int32)
    io = ChunkedMemoryIO.new(source, chunk_size)
    pull = FusedJSON::PullParser.new(io, buffer_size: buffer_size)
    {pull, io}
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
      pull.read_object do |key|
        values[key] = read_any(pull)
      end
      JSON::Any.new(values)
    else
      raise "expected a value, found #{pull.kind}"
    end
  end

  def memory_value(source : String) : JSON::Any
    pull = FusedJSON::PullParser.new(source)
    value = read_any(pull)
    pull.finish
    value
  end

  def stream_value(source : String, chunk_size : Int32, buffer_size : Int32)
    pull, io = stream_parser(source, chunk_size, buffer_size)
    value = read_any(pull)
    pull.finish
    {value, io}
  end

  def memory_first(source : String) : FirstEventSample
    pull = FusedJSON::PullParser.new(source)
    line, column = pull.location_i64
    FirstEventSample.new(pull.kind, pull.byte_offset, line, column, 0_i64)
  end

  def stream_first(source : String, chunk_size : Int32, buffer_size : Int32) : FirstEventSample
    pull, io = stream_parser(source, chunk_size, buffer_size)
    line, column = pull.location_i64
    FirstEventSample.new(pull.kind, pull.byte_offset, line, column, io.bytes_read)
  end

  def mix(checksum : UInt64, value : UInt64) : UInt64
    (checksum ^ value) &* FNV_PRIME
  end

  def drain(pull : FusedJSON::PullParser) : UInt64
    checksum = FNV_OFFSET

    loop do
      kind = pull.kind
      checksum = mix(checksum, kind.value.to_u64)
      checksum = mix(checksum, pull.byte_offset.to_u64)
      break if kind.eof?

      case kind
      when .null?
        pull.read_null
      when .bool?
        checksum = mix(checksum, pull.read_bool ? 1_u64 : 0_u64)
      when .int?
        checksum = mix(checksum, pull.read_int.unsafe_as(UInt64))
      when .float?
        checksum = mix(checksum, pull.read_float.unsafe_as(UInt64))
      when .string?
        value = pull.read_string
        checksum = mix(checksum, value.bytesize.to_u64)
        unless value.empty?
          checksum = mix(checksum, value.to_unsafe[0].to_u64)
          checksum = mix(checksum, value.to_unsafe[value.bytesize - 1].to_u64)
        end
      when .begin_array?, .end_array?, .begin_object?, .end_object?
        pull.read_next
      when .eof?
      end
    end

    pull.finish
    checksum
  end

  def memory_drain(source : String) : UInt64
    drain(FusedJSON::PullParser.new(source))
  end

  def stream_drain(source : String, chunk_size : Int32, buffer_size : Int32)
    pull, io = stream_parser(source, chunk_size, buffer_size)
    {drain(pull), io}
  end

  def skip(pull : FusedJSON::PullParser) : UInt64
    pull.skip_value
    pull.finish
    checksum = mix(FNV_OFFSET, pull.kind.value.to_u64)
    mix(checksum, pull.byte_offset.to_u64)
  end

  def memory_skip(source : String) : UInt64
    skip(FusedJSON::PullParser.new(source))
  end

  def stream_skip(source : String, chunk_size : Int32, buffer_size : Int32)
    pull, io = stream_parser(source, chunk_size, buffer_size)
    {skip(pull), io}
  end

  def file_stream_value(path : String, chunk_size : Int32, buffer_size : Int32)
    io = ChunkedFileIO.new(path, chunk_size)
    begin
      pull = FusedJSON::PullParser.new(io, buffer_size: buffer_size)
      value = read_any(pull)
      pull.finish
      {value, io.bytes_read}
    ensure
      io.close
    end
  end

  def file_stream_drain(path : String, chunk_size : Int32, buffer_size : Int32) : UInt64
    io = ChunkedFileIO.new(path, chunk_size)
    begin
      drain(FusedJSON::PullParser.new(io, buffer_size: buffer_size))
    ensure
      io.close
    end
  end

  def file_stream_skip(path : String, chunk_size : Int32, buffer_size : Int32) : UInt64
    io = ChunkedFileIO.new(path, chunk_size)
    begin
      skip(FusedJSON::PullParser.new(io, buffer_size: buffer_size))
    ensure
      io.close
    end
  end

  def preflight(source : String, path : String, chunk_size : Int32, buffer_size : Int32) : PreflightResult
    expected = JSON.parse(source)
    memory = memory_value(source)
    stream, semantic_io = stream_value(source, chunk_size, buffer_size)
    raise "in-memory Pull differs from JSON.parse" unless memory == expected
    raise "streaming Pull differs from in-memory Pull" unless stream == memory
    verify_complete_io(semantic_io, source)

    file_stream, file_bytes_read = file_stream_value(path, chunk_size, buffer_size)
    raise "file-backed streaming Pull differs from in-memory Pull" unless file_stream == memory
    raise "file-backed streaming Pull did not read the complete input" unless file_bytes_read == source.bytesize

    first_memory = memory_first(source)
    first_stream = stream_first(source, chunk_size, buffer_size)
    unless first_stream.event_signature == first_memory.event_signature
      raise "first streaming event differs from in-memory Pull"
    end

    memory_drain_checksum = memory_drain(source)
    stream_drain_checksum, drain_io = stream_drain(source, chunk_size, buffer_size)
    raise "streaming drain checksum differs from in-memory Pull" unless stream_drain_checksum == memory_drain_checksum
    verify_complete_io(drain_io, source)
    unless file_stream_drain(path, chunk_size, buffer_size) == memory_drain_checksum
      raise "file-backed streaming drain checksum differs from in-memory Pull"
    end

    memory_skip_checksum = memory_skip(source)
    stream_skip_checksum, skip_io = stream_skip(source, chunk_size, buffer_size)
    raise "streaming skip checksum differs from in-memory Pull" unless stream_skip_checksum == memory_skip_checksum
    verify_complete_io(skip_io, source)
    unless file_stream_skip(path, chunk_size, buffer_size) == memory_skip_checksum
      raise "file-backed streaming skip checksum differs from in-memory Pull"
    end

    Sink.store_memory_value(memory)
    Sink.store_stream_value(stream)
    Sink.store_memory_first(first_memory)
    Sink.store_stream_first(first_stream)
    Sink.store_memory_drain(memory_drain_checksum)
    Sink.store_stream_drain(stream_drain_checksum)
    Sink.store_memory_skip(memory_skip_checksum)
    Sink.store_stream_skip(stream_skip_checksum)

    result = PreflightResult.new(
      expected,
      first_memory,
      first_stream,
      memory_drain_checksum,
      memory_skip_checksum
    )
    Sink.verify_preflight(result)
    result
  end

  def verify_complete_io(io : ChunkedMemoryIO, source : String) : Nil
    raise "streaming parser did not read the complete input" unless io.bytes_read == source.bytesize
    raise "streaming parser closed the caller-owned IO" if io.closed?
  end

  def allocation_per_operation(iterations : Int32, &) : UInt64
    GC.collect
    bytes = Benchmark.memory do
      iterations.times { yield }
    end
    (bytes.to_f / iterations).round.to_u64
  end

  def positive_i32(value : String, name : String, maximum : Int32 = Int32::MAX) : Int32
    parsed = value.to_i64?
    unless parsed && 0 < parsed <= maximum
      raise ArgumentError.new("#{name} must be between 1 and #{maximum}")
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

  def report_latency(job : Benchmark::IPS::Job, stream_bytes : Int64) : Nil
    job.items.each do |item|
      microseconds = 1_000_000.0 / item.mean
      bytes = item.label == "IO::Memory" ? stream_bytes.to_s : "n/a"
      printf "  %-18s %10.2f us  %8s bytes read  (RSD %5.2f%%)\n",
        item.label, microseconds, bytes, item.relative_stddev
    end

    memory_mean = job.items.find! { |item| item.label == "in-memory Pull" }.mean
    stream_mean = job.items.find! { |item| item.label == "IO::Memory" }.mean
    printf "  %-18s %10.3fx\n", "stream/memory", memory_mean / stream_mean
  end

  def report_throughput(job : Benchmark::IPS::Job, source_size : Int32) : Nil
    job.items.each do |item|
      mib_per_second = item.mean * source_size / 1_048_576.0
      printf "  %-18s %10.2f MiB/s  (RSD %5.2f%%)\n",
        item.label, mib_per_second, item.relative_stddev
    end

    memory_mean = job.items.find! { |item| item.label == "in-memory Pull" }.mean
    stream_mean = job.items.find! { |item| item.label == "IO::Memory" }.mean
    printf "  %-18s %10.3fx\n", "stream/memory", stream_mean / memory_mean
  end

  def report_allocation(name : String, memory : UInt64, stream : UInt64) : Nil
    ratio = memory == 0 ? "n/a" : sprintf("%.3fx", stream.to_f / memory)
    printf "  %-14s %12d B/op  %12d B/op  %9s\n", name, memory, stream, ratio
  end

  def preloaded_peak_operation(mode : String, source : String, chunk_size : Int32, buffer_size : Int32) : UInt64
    case mode
    when "memory-drain"
      memory_drain(source)
    when "stream-drain"
      stream_drain(source, chunk_size, buffer_size)[0]
    when "memory-skip"
      memory_skip(source)
    when "stream-skip"
      stream_skip(source, chunk_size, buffer_size)[0]
    else
      raise ArgumentError.new("unknown peak-memory mode #{mode.inspect}")
    end
  end

  def file_peak_mode?(mode : String) : Bool
    mode == "file-stream-drain" || mode == "file-stream-skip"
  end

  def file_peak_operation(mode : String, path : String, chunk_size : Int32, buffer_size : Int32) : UInt64
    case mode
    when "file-stream-drain"
      file_stream_drain(path, chunk_size, buffer_size)
    when "file-stream-skip"
      file_stream_skip(path, chunk_size, buffer_size)
    else
      raise ArgumentError.new("unknown file-backed peak-memory mode #{mode.inspect}")
    end
  end
end

chunk_size = 4 * 1024
buffer_size = FusedJSON::StreamingPullParser::DEFAULT_BUFFER_SIZE
warmup_seconds = 0.5
calculation_seconds = 1.0
allocation_iterations = 20
peak_iterations = 25
peak_mode = nil.as(String?)
reverse_order = ENV["FUSED_JSON_BENCH_REVERSE"]? == "1"

begin
  chunk_size = StreamBenchmark.positive_i32(
    ENV["FUSED_JSON_STREAM_CHUNK"]? || chunk_size.to_s,
    "chunk size"
  )
  buffer_size = StreamBenchmark.positive_i32(
    ENV["FUSED_JSON_STREAM_BUFFER"]? || buffer_size.to_s,
    "buffer size",
    FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
  )
  warmup_seconds = StreamBenchmark.nonnegative_f64(
    ENV["FUSED_JSON_BENCH_WARMUP"]? || warmup_seconds.to_s,
    "warmup"
  )
  calculation_seconds = StreamBenchmark.positive_f64(
    ENV["FUSED_JSON_BENCH_TIME"]? || calculation_seconds.to_s,
    "calculation time"
  )
  allocation_iterations = StreamBenchmark.positive_i32(
    ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || allocation_iterations.to_s,
    "allocation iterations"
  )
  peak_iterations = StreamBenchmark.positive_i32(
    ENV["FUSED_JSON_STREAM_PEAK_ITERATIONS"]? || peak_iterations.to_s,
    "peak iterations"
  )
rescue error
  abort error.message || error.class.to_s
end

options = OptionParser.new do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} [options] JSON_FILE [JSON_FILE ...]"
  parser.on("--chunk-size=BYTES", "Maximum bytes returned by each chunked input read") do |value|
    chunk_size = StreamBenchmark.positive_i32(value, "chunk size")
  end
  parser.on("--buffer-size=BYTES", "Streaming parser input-buffer size") do |value|
    buffer_size = StreamBenchmark.positive_i32(
      value,
      "buffer size",
      FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
    )
  end
  parser.on("--warmup=SECONDS", "Warmup per benchmark implementation (default: #{warmup_seconds})") do |value|
    warmup_seconds = StreamBenchmark.nonnegative_f64(value, "warmup")
  end
  parser.on("--time=SECONDS", "Calculation time per implementation (default: #{calculation_seconds})") do |value|
    calculation_seconds = StreamBenchmark.positive_f64(value, "calculation time")
  end
  parser.on("--allocations=COUNT", "Operations used for managed-allocation samples") do |value|
    allocation_iterations = StreamBenchmark.positive_i32(value, "allocation iterations")
  end
  parser.on("--peak-memory=MODE", "Run one peak-RSS workload: #{StreamBenchmark::PEAK_MODES.join(", ")}") do |value|
    peak_mode = value
  end
  parser.on("--peak-iterations=COUNT", "Operations in peak-memory mode (default: #{peak_iterations})") do |value|
    peak_iterations = StreamBenchmark.positive_i32(value, "peak iterations")
  end
  parser.on("-h", "--help", "Show this help") do
    puts parser
    puts
    puts "Peak RSS workflow (run normal mode first to preflight semantics and checksums):"
    puts "  crystal build --release bench/stream.cr -o /tmp/fused-json-stream-bench"
    puts "  /usr/bin/time -v /tmp/fused-json-stream-bench --peak-memory=file-stream-drain LARGE.json"
    puts "  /usr/bin/time -v /tmp/fused-json-stream-bench --peak-memory=stream-drain LARGE.json"
    puts "  /usr/bin/time -v /tmp/fused-json-stream-bench --peak-memory=memory-drain LARGE.json"
    puts
    puts "file-stream-* opens the file for every operation without preloading its contents."
    puts "stream-* uses IO::Memory over one preloaded String for a controlled comparison;"
    puts "memory-* uses the in-memory Pull path over that same String. Peak mode accepts"
    puts "exactly one file and runs only the selected workload. Compare modes in separate"
    puts "processes. Benchmark.memory below reports managed bytes, not peak RSS."
    exit
  end
end

begin
  options.parse
rescue error
  STDERR.puts "error: #{error.message}"
  STDERR.puts options
  exit 1
end

if ARGV.empty?
  STDERR.puts options
  exit 1
end

{% unless flag?(:release) %}
  STDERR.puts "warning: build this benchmark with --release for meaningful results"
{% end %}

if mode = peak_mode
  unless StreamBenchmark::PEAK_MODES.includes?(mode)
    abort "--peak-memory must be one of: #{StreamBenchmark::PEAK_MODES.join(", ")}"
  end
  abort "peak-memory mode accepts exactly one JSON file" unless ARGV.size == 1

  path = ARGV.first
  source_size = File.size(path)
  peak_source = nil.as(String?)
  expected = if StreamBenchmark.file_peak_mode?(mode)
               StreamBenchmark.file_peak_operation(mode, path, chunk_size, buffer_size)
             else
               peak_source = File.read(path)
               StreamBenchmark.preloaded_peak_operation(mode, peak_source.not_nil!, chunk_size, buffer_size)
             end
  StreamBenchmark::Sink.store_peak(expected)
  GC.collect

  started = Time.instant
  peak_iterations.times do
    actual = if loaded_source = peak_source
               StreamBenchmark.preloaded_peak_operation(mode, loaded_source, chunk_size, buffer_size)
             else
               StreamBenchmark.file_peak_operation(mode, path, chunk_size, buffer_size)
             end
    raise "peak workload checksum changed" unless actual == expected
    StreamBenchmark::Sink.store_peak(actual)
  end
  elapsed = Time.instant - started
  StreamBenchmark::Sink.verify_peak(expected)

  processed_bytes = peak_iterations.to_i64 * source_size
  mib_per_second = processed_bytes / elapsed.total_seconds / 1_048_576.0
  input_kind = if StreamBenchmark.file_peak_mode?(mode)
                 "file-backed IO"
               elsif mode.starts_with?("stream-")
                 "preloaded IO::Memory"
               else
                 "preloaded String"
               end
  puts "#{mode}: #{File.basename(path)}, #{source_size} bytes, #{peak_iterations} operations, #{input_kind}"
  printf "elapsed %.3fs, %.2f MiB/s, checksum 0x%016x\n",
    elapsed.total_seconds, mib_per_second, expected
  exit
end

warmup = warmup_seconds.seconds
calculation = calculation_seconds.seconds

ARGV.each do |path|
  source = File.read(path)
  result = begin
    StreamBenchmark.preflight(source, path, chunk_size, buffer_size)
  rescue error
    abort "stream benchmark preflight failed for #{path}: #{error.class}: #{error.message}"
  end

  puts
  puts "#{File.basename(path)}: #{source.bytesize} bytes"
  puts "IO::Memory: chunk #{chunk_size} bytes, parser buffer #{buffer_size} bytes"

  puts "First-event latency"
  first_job = Benchmark::IPS::Job.new(calculation, warmup, false)
  if reverse_order
    first_job.report("IO::Memory") do
      StreamBenchmark::Sink.store_stream_first(
        StreamBenchmark.stream_first(source, chunk_size, buffer_size)
      )
    end
    first_job.report("in-memory Pull") do
      StreamBenchmark::Sink.store_memory_first(StreamBenchmark.memory_first(source))
    end
  else
    first_job.report("in-memory Pull") do
      StreamBenchmark::Sink.store_memory_first(StreamBenchmark.memory_first(source))
    end
    first_job.report("IO::Memory") do
      StreamBenchmark::Sink.store_stream_first(
        StreamBenchmark.stream_first(source, chunk_size, buffer_size)
      )
    end
  end
  first_job.execute
  StreamBenchmark.report_latency(first_job, result.first_stream.bytes_read)
  StreamBenchmark::Sink.verify_first(result.first_memory, result.first_stream)

  puts "Full event drain throughput"
  drain_job = Benchmark::IPS::Job.new(calculation, warmup, false)
  if reverse_order
    drain_job.report("IO::Memory") do
      checksum, _ = StreamBenchmark.stream_drain(source, chunk_size, buffer_size)
      StreamBenchmark::Sink.store_stream_drain(checksum)
    end
    drain_job.report("in-memory Pull") do
      StreamBenchmark::Sink.store_memory_drain(StreamBenchmark.memory_drain(source))
    end
  else
    drain_job.report("in-memory Pull") do
      StreamBenchmark::Sink.store_memory_drain(StreamBenchmark.memory_drain(source))
    end
    drain_job.report("IO::Memory") do
      checksum, _ = StreamBenchmark.stream_drain(source, chunk_size, buffer_size)
      StreamBenchmark::Sink.store_stream_drain(checksum)
    end
  end
  drain_job.execute
  StreamBenchmark.report_throughput(drain_job, source.bytesize)
  StreamBenchmark::Sink.verify_drain(result.drain_checksum)

  puts "Whole-root skip throughput"
  skip_job = Benchmark::IPS::Job.new(calculation, warmup, false)
  if reverse_order
    skip_job.report("IO::Memory") do
      checksum, _ = StreamBenchmark.stream_skip(source, chunk_size, buffer_size)
      StreamBenchmark::Sink.store_stream_skip(checksum)
    end
    skip_job.report("in-memory Pull") do
      StreamBenchmark::Sink.store_memory_skip(StreamBenchmark.memory_skip(source))
    end
  else
    skip_job.report("in-memory Pull") do
      StreamBenchmark::Sink.store_memory_skip(StreamBenchmark.memory_skip(source))
    end
    skip_job.report("IO::Memory") do
      checksum, _ = StreamBenchmark.stream_skip(source, chunk_size, buffer_size)
      StreamBenchmark::Sink.store_stream_skip(checksum)
    end
  end
  skip_job.execute
  StreamBenchmark.report_throughput(skip_job, source.bytesize)
  StreamBenchmark::Sink.verify_skip(result.skip_checksum)

  puts "Managed allocations (Benchmark.memory; not peak RSS)"
  puts "  operation          in-memory Pull      IO::Memory      stream/memory"
  first_memory_alloc = StreamBenchmark.allocation_per_operation(allocation_iterations) do
    StreamBenchmark::Sink.store_memory_first(StreamBenchmark.memory_first(source))
  end
  first_stream_alloc = StreamBenchmark.allocation_per_operation(allocation_iterations) do
    StreamBenchmark::Sink.store_stream_first(
      StreamBenchmark.stream_first(source, chunk_size, buffer_size)
    )
  end
  StreamBenchmark.report_allocation("first event", first_memory_alloc, first_stream_alloc)

  drain_memory_alloc = StreamBenchmark.allocation_per_operation(allocation_iterations) do
    StreamBenchmark::Sink.store_memory_drain(StreamBenchmark.memory_drain(source))
  end
  drain_stream_alloc = StreamBenchmark.allocation_per_operation(allocation_iterations) do
    checksum, _ = StreamBenchmark.stream_drain(source, chunk_size, buffer_size)
    StreamBenchmark::Sink.store_stream_drain(checksum)
  end
  StreamBenchmark.report_allocation("event drain", drain_memory_alloc, drain_stream_alloc)

  skip_memory_alloc = StreamBenchmark.allocation_per_operation(allocation_iterations) do
    StreamBenchmark::Sink.store_memory_skip(StreamBenchmark.memory_skip(source))
  end
  skip_stream_alloc = StreamBenchmark.allocation_per_operation(allocation_iterations) do
    checksum, _ = StreamBenchmark.stream_skip(source, chunk_size, buffer_size)
    StreamBenchmark::Sink.store_stream_skip(checksum)
  end
  StreamBenchmark.report_allocation("root skip", skip_memory_alloc, skip_stream_alloc)

  StreamBenchmark::Sink.verify_preflight(result)
end

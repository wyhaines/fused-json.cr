require "benchmark"
require "digest/sha256"
require "json"
require "option_parser"

require "../src/fused_json"

# Measures the cost of carrying a disabled FusedJSON::Limits value through
# representative parsing paths. Build with -Dfused_json_limits_api to include
# the explicit-empty configuration; an unflagged build remains usable against
# the pre-Limits Milestone 4 source.
module LimitsOverheadBenchmark
  WORKLOADS = [
    "string-dynamic",
    "io-dynamic",
    "string-pull",
    "string-skip",
    "io-pull",
    "io-skip",
    "string-typed",
    "io-typed",
  ]
  {% if flag?(:fused_json_limits_api) %}
    CONFIGURATIONS = ["default", "explicit-empty"]
  {% else %}
    CONFIGURATIONS = ["default"]
  {% end %}
  ENVIRONMENT_KEYS = [
    "CRYSTAL_WORKERS",
    "FUSED_JSON_BENCH_ALLOCATIONS",
    "FUSED_JSON_BENCH_COMMIT",
    "FUSED_JSON_BENCH_CPU",
    "FUSED_JSON_BENCH_TIME",
    "FUSED_JSON_BENCH_WARMUP",
    "FUSED_JSON_LIMITS_BUFFER",
    "FUSED_JSON_LIMITS_RECORDS",
    "GC_FREE_SPACE_DIVISOR",
    "GC_MARKERS",
    "GC_NPROCS",
    "GC_UNMAP_THRESHOLD",
    "MALLOC_CONF",
    "OMP_NUM_THREADS",
  ]

  RELEASE_BUILD        = {{ flag?(:release) }}
  LIMITS_API_BUILD     = {{ flag?(:fused_json_limits_api) }}
  INVOCATION_ARGUMENTS = ARGV.dup
  RECEIPT_VERSION      = 2
  PAIRING_VERSION      = 2
  FIXTURE_FORMAT       = "fused-json-limits-overhead"
  FIXTURE_VERSION      = 1
  TIMING_ESTIMATOR     = "total-iterations-over-total-elapsed-v1"
  BATCH_TARGET         = 100.milliseconds
  FNV_OFFSET           = 14_695_981_039_346_656_037_u64
  FNV_PRIME            =          1_099_511_628_211_u64

  record Observer, count : Int64, checksum : UInt64

  record Expectations,
    dynamic_sha256 : String,
    typed : Observer,
    pull : Observer,
    skip : Observer

  record Measurement,
    iterations_per_second : Float64,
    relative_stddev_percent : Float64,
    iterations : Int64,
    batches : Int32,
    elapsed_seconds : Float64,
    mib_per_second : Float64,
    managed_bytes_per_operation : UInt64,
    managed_bytes_per_input_byte : Float64

  struct FixtureMetadata
    include JSON::Serializable

    getter generator : String
    getter record_count : Int32
  end

  struct FixtureDetail
    include JSON::Serializable

    getter group : Int32
    getter code : String
  end

  struct FixtureRecord
    include JSON::Serializable

    getter id : Int64
    getter? active : Bool
    getter score : Float64
    getter name : String
    getter tags : Array(String)
    getter detail : FixtureDetail
  end

  struct FixtureDocument
    include JSON::Serializable

    getter metadata : FixtureMetadata
    getter records : Array(FixtureRecord)
  end

  class Sink
    @@dynamic = nil.as(JSON::Any?)
    @@typed = nil.as(FixtureDocument?)
    @@observer = Observer.new(0_i64, 0_u64)

    def self.store(value : JSON::Any) : Nil
      @@dynamic = value
    end

    def self.store(value : FixtureDocument) : Nil
      @@typed = value
    end

    def self.store(value : Observer) : Nil
      @@observer = value
    end

    def self.clear_dynamic : Nil
      @@dynamic = nil
    end

    def self.clear_typed : Nil
      @@typed = nil
    end

    def self.clear_retained : Nil
      clear_dynamic
      clear_typed
    end

    def self.verify(workload : String, expected : Expectations) : Nil
      case workload
      when "string-dynamic", "io-dynamic"
        value = @@dynamic || raise "dynamic benchmark result was lost"
        digest = Digest::SHA256.hexdigest(value.to_json)
        raise "dynamic benchmark semantic mismatch" unless digest == expected.dynamic_sha256
      when "string-typed", "io-typed"
        value = @@typed || raise "typed benchmark result was lost"
        raise "typed benchmark semantic mismatch" unless LimitsOverheadBenchmark.observe(value) == expected.typed
      when "string-pull", "io-pull"
        raise "pull benchmark semantic mismatch" unless @@observer == expected.pull
      when "string-skip", "io-skip"
        raise "skip benchmark semantic mismatch" unless @@observer == expected.skip
      else
        raise "unknown workload #{workload.inspect}"
      end
    end
  end

  extend self

  def fixture_source(record_count : Int32) : String
    JSON.build do |json|
      json.object do
        json.field "metadata" do
          json.object do
            json.field "generator", "limits-overhead-v1"
            json.field "record_count", record_count
          end
        end
        json.field "records" do
          json.array do
            record_count.times do |index|
              json.object do
                json.field "id", 10_000_000_i64 + index
                json.field "active", index.even?
                json.field "score", 100.25 + index % 1_000
                json.field "name", "record-#{index}"
                json.field "tags" do
                  json.array do
                    json.string "limits"
                    json.string "group-#{index % 32}"
                  end
                end
                json.field "detail" do
                  json.object do
                    json.field "group", index % 32
                    json.field "code", "C#{index % 10_000}"
                  end
                end
                # Typed decoding must traverse unknown values as well as the
                # fields retained by FixtureRecord.
                json.field "ignored" do
                  json.object do
                    json.field "numbers" do
                      json.array do
                        json.number 1
                        json.number 2
                        json.number 3
                      end
                    end
                    json.field "label", "discard-#{index % 16}"
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def expectations(source : String, buffer_size : Int32) : Expectations
    dynamic_sha256 = Digest::SHA256.hexdigest(JSON.parse(source).to_json)
    typed = observe(FixtureDocument.from_json(source))

    string_pull = drain(FusedJSON::PullParser.new(source))
    io_pull = drain(FusedJSON::PullParser.new(
      IO::Memory.new(source),
      buffer_size: buffer_size,
      cache_keys: false
    ))
    raise "default String and IO pull traversals differ" unless string_pull == io_pull

    string_skip = skip(FusedJSON::PullParser.new(source))
    io_skip = skip(FusedJSON::PullParser.new(
      IO::Memory.new(source),
      buffer_size: buffer_size,
      cache_keys: false
    ))
    raise "default String and IO skip traversals differ" unless string_skip == io_skip
    unless string_skip.checksum == source.bytesize.to_u64
      raise "skip traversal did not consume the complete fixture"
    end

    Expectations.new(dynamic_sha256, typed, string_pull, string_skip)
  end

  def operation(workload : String, configuration : String, source : String,
                buffer_size : Int32) : Proc(Nil)
    case workload
    when "string-dynamic"
      string_dynamic_operation(configuration, source)
    when "io-dynamic"
      io_dynamic_operation(configuration, source, buffer_size)
    when "string-pull"
      string_pull_operation(configuration, source)
    when "string-skip"
      string_skip_operation(configuration, source)
    when "io-pull"
      io_pull_operation(configuration, source, buffer_size)
    when "io-skip"
      io_skip_operation(configuration, source, buffer_size)
    when "string-typed"
      string_typed_operation(configuration, source)
    when "io-typed"
      io_typed_operation(configuration, source, buffer_size)
    else
      raise ArgumentError.new("unknown workload #{workload.inspect}")
    end
  end

  private def string_dynamic_operation(configuration : String,
                                       source : String) : Proc(Nil)
    case configuration
    when "default"
      -> {
        Sink.clear_dynamic
        Sink.store(FusedJSON.load(source))
      }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> {
          Sink.clear_dynamic
          Sink.store(FusedJSON.load(source, limits: FusedJSON::Limits.new))
        }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  private def io_dynamic_operation(configuration : String, source : String,
                                   buffer_size : Int32) : Proc(Nil)
    case configuration
    when "default"
      -> {
        Sink.clear_dynamic
        Sink.store(FusedJSON.load(
          IO::Memory.new(source),
          buffer_size: buffer_size,
          cache_keys: false
        ))
      }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> {
          Sink.clear_dynamic
          Sink.store(FusedJSON.load(
            IO::Memory.new(source),
            buffer_size: buffer_size,
            cache_keys: false,
            limits: FusedJSON::Limits.new
          ))
        }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  private def string_pull_operation(configuration : String,
                                    source : String) : Proc(Nil)
    case configuration
    when "default"
      -> { Sink.store(drain(FusedJSON::PullParser.new(source))) }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> { Sink.store(drain(FusedJSON::PullParser.new(source, limits: FusedJSON::Limits.new))) }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  private def string_skip_operation(configuration : String,
                                    source : String) : Proc(Nil)
    case configuration
    when "default"
      -> { Sink.store(skip(FusedJSON::PullParser.new(source))) }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> { Sink.store(skip(FusedJSON::PullParser.new(source, limits: FusedJSON::Limits.new))) }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  private def io_pull_operation(configuration : String, source : String,
                                buffer_size : Int32) : Proc(Nil)
    case configuration
    when "default"
      -> {
        Sink.store(drain(FusedJSON::PullParser.new(
          IO::Memory.new(source),
          buffer_size: buffer_size,
          cache_keys: false
        )))
      }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> {
          Sink.store(drain(FusedJSON::PullParser.new(
            IO::Memory.new(source),
            buffer_size: buffer_size,
            cache_keys: false,
            limits: FusedJSON::Limits.new
          )))
        }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  private def io_skip_operation(configuration : String, source : String,
                                buffer_size : Int32) : Proc(Nil)
    case configuration
    when "default"
      -> {
        Sink.store(skip(FusedJSON::PullParser.new(
          IO::Memory.new(source),
          buffer_size: buffer_size,
          cache_keys: false
        )))
      }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> {
          Sink.store(skip(FusedJSON::PullParser.new(
            IO::Memory.new(source),
            buffer_size: buffer_size,
            cache_keys: false,
            limits: FusedJSON::Limits.new
          )))
        }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  private def string_typed_operation(configuration : String,
                                     source : String) : Proc(Nil)
    case configuration
    when "default"
      -> {
        Sink.clear_typed
        Sink.store(FusedJSON.from_json(source, FixtureDocument))
      }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> {
          Sink.clear_typed
          Sink.store(FusedJSON.from_json(
            source,
            FixtureDocument,
            limits: FusedJSON::Limits.new
          ))
        }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  private def io_typed_operation(configuration : String, source : String,
                                 buffer_size : Int32) : Proc(Nil)
    case configuration
    when "default"
      -> {
        Sink.clear_typed
        Sink.store(FusedJSON.from_json(
          IO::Memory.new(source),
          FixtureDocument,
          buffer_size: buffer_size,
          cache_keys: false
        ))
      }
    when "explicit-empty"
      {% if flag?(:fused_json_limits_api) %}
        -> {
          Sink.clear_typed
          Sink.store(FusedJSON.from_json(
            IO::Memory.new(source),
            FixtureDocument,
            buffer_size: buffer_size,
            cache_keys: false,
            limits: FusedJSON::Limits.new
          ))
        }
      {% else %}
        limits_api_unavailable
      {% end %}
    else
      unknown_configuration(configuration)
    end
  end

  def measure(source : String, operation : Proc(Nil), warmup : Time::Span,
              calculation : Time::Span,
              allocation_iterations : Int32) : Measurement
    Sink.clear_retained
    GC.collect
    batch_iterations = calibrated_batch_iterations(operation, warmup)

    Sink.clear_retained
    GC.collect
    batch_rates = [] of Float64
    iterations = 0_i64
    elapsed = Time::Span.zero
    target = Time.instant + calculation

    loop do
      batch_elapsed = Time.measure do
        batch_iterations.times { operation.call }
      end
      batch_seconds = batch_elapsed.total_seconds
      batch_rates << batch_iterations.to_f / batch_seconds
      iterations += batch_iterations
      elapsed += batch_elapsed
      break if Time.instant >= target
    end

    iterations_per_second = iterations.to_f / elapsed.total_seconds
    relative_stddev_percent = relative_stddev_percent(batch_rates)

    Sink.clear_retained
    GC.collect
    allocated = Benchmark.memory do
      allocation_iterations.times { operation.call }
    end
    allocated_per_operation = (allocated.to_f / allocation_iterations).round.to_u64

    Measurement.new(
      iterations_per_second,
      relative_stddev_percent,
      iterations,
      batch_rates.size.to_i32,
      elapsed.total_seconds,
      iterations_per_second * source.bytesize / 1_048_576.0,
      allocated_per_operation,
      allocated_per_operation.to_f / source.bytesize
    )
  end

  private def calibrated_batch_iterations(operation : Proc(Nil),
                                          warmup : Time::Span) : Int64
    iterations = 0_i64
    elapsed = Time.measure do
      target = Time.instant + warmup
      while Time.instant < target
        operation.call
        iterations += 1
      end
    end
    return 1_i64 if iterations == 0 || elapsed <= Time::Span.zero

    calibrated = (
      iterations.to_f * BATCH_TARGET.total_seconds / elapsed.total_seconds
    ).to_i64
    calibrated > 0 ? calibrated : 1_i64
  end

  private def relative_stddev_percent(rates : Array(Float64)) : Float64
    mean = rates.sum / rates.size
    variance = rates.sum { |rate| (rate - mean) ** 2 } / rates.size
    100.0 * Math.sqrt(variance) / mean
  end

  def drain(pull : FusedJSON::PullParser) : Observer
    count = 0_i64
    checksum = FNV_OFFSET

    until pull.kind.eof?
      checksum = mix_byte(checksum, pull.kind.value.to_u8)
      count += 1
      case pull.kind
      when .null?, .begin_array?, .end_array?, .begin_object?, .end_object?
        pull.read_next
      when .bool?
        checksum = mix_byte(checksum, pull.read_bool ? 1_u8 : 0_u8)
      when .int?
        checksum = mix_u64(checksum, pull.read_int.unsafe_as(UInt64))
      when .float?
        checksum = mix_u64(checksum, pull.read_float.unsafe_as(UInt64))
      when .string?
        checksum = mix_string_sample(checksum, pull.read_string)
      when .eof?
      end
    end
    pull.finish
    Observer.new(count, checksum)
  end

  def skip(pull : FusedJSON::PullParser) : Observer
    pull.skip_value
    pull.finish
    Observer.new(1_i64, pull.byte_offset.to_u64)
  end

  def observe(document : FixtureDocument) : Observer
    checksum = mix_string(FNV_OFFSET, document.metadata.generator)
    checksum = mix_i64(checksum, document.metadata.record_count)
    document.records.each do |record|
      checksum = mix_i64(checksum, record.id)
      checksum = mix_byte(checksum, record.active? ? 1_u8 : 0_u8)
      checksum = mix_u64(checksum, record.score.unsafe_as(UInt64))
      checksum = mix_string(checksum, record.name)
      checksum = mix_i64(checksum, record.tags.size)
      record.tags.each { |tag| checksum = mix_string(checksum, tag) }
      checksum = mix_i64(checksum, record.detail.group)
      checksum = mix_string(checksum, record.detail.code)
    end
    Observer.new(document.records.size.to_i64, checksum)
  end

  def write_receipt(workload : String, configuration : String,
                    source : String, record_count : Int32,
                    buffer_size : Int32, commit : String,
                    warmup : Time::Span, calculation : Time::Span,
                    allocation_iterations : Int32,
                    expected : Expectations,
                    measurement : Measurement) : Nil
    observer_name, observer = receipt_observer(workload, expected)
    host = host_metadata
    source_sha256 = Digest::SHA256.hexdigest(source)
    semantic_sha256 = expected.dynamic_sha256

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "receipt", "fused-json-limits-overhead"
        json.field "version", RECEIPT_VERSION
        json.field "recorded_at", Time.utc.to_rfc3339
        json.field "workload", workload
        json.field "configuration", configuration
        json.field "call_style", configuration == "default" ? "limits keyword omitted" : "limits: FusedJSON::Limits.new"
        json.field "pairing_key", "v#{PAIRING_VERSION}:#{workload}:#{source_sha256}"
        json.field "fixture" do
          json.object do
            json.field "format", FIXTURE_FORMAT
            json.field "version", FIXTURE_VERSION
            json.field "records", record_count
            json.field "bytes", source.bytesize
            json.field "sha256", source_sha256
            json.field "semantic_sha256", semantic_sha256
          end
        end
        json.field "semantic_verification" do
          json.object do
            json.field "status", "verified"
            json.field "observer", observer_name
            json.field "count", observer.count
            json.field "checksum", hex_checksum(observer.checksum)
            json.field "default_string_io_pull_parity", true
            json.field "default_string_io_skip_parity", true
          end
        end
        json.field "disabled_limits" do
          {% if flag?(:fused_json_limits_api) %}
            json.object do
              json.field "max_nesting", 512
              nullable_field(json, "max_token_bytes")
              nullable_field(json, "max_document_bytes")
              nullable_field(json, "max_typed_value_bytes")
              nullable_field(json, "max_total_values")
              nullable_field(json, "max_container_entries")
              nullable_field(json, "max_cached_keys")
              json.field "reject_duplicate_keys", false
            end
          {% else %}
            json.null
          {% end %}
        end
        json.field "parser_options" do
          json.object do
            json.field "cache_keys", false
            if workload.starts_with?("io-")
              json.field "transport", "IO::Memory"
              json.field "buffer_size", buffer_size
            else
              json.field "transport", "String"
              json.field "buffer_size" { json.null }
            end
          end
        end
        json.field "measurement" do
          json.object do
            json.field "estimator", TIMING_ESTIMATOR
            json.field "iterations_per_second", measurement.iterations_per_second
            json.field "relative_stddev_percent", measurement.relative_stddev_percent
            json.field "iterations", measurement.iterations
            json.field "batches", measurement.batches
            json.field "elapsed_seconds", measurement.elapsed_seconds
            json.field "mib_per_second", measurement.mib_per_second
            json.field "managed_bytes_per_operation", measurement.managed_bytes_per_operation
            json.field "managed_bytes_per_input_byte", measurement.managed_bytes_per_input_byte
            json.field "warmup_seconds", warmup.total_seconds
            json.field "calculation_seconds", calculation.total_seconds
            json.field "allocation_iterations", allocation_iterations
          end
        end
        json.field "build" do
          json.object do
            json.field "fused_json_version", FusedJSON::VERSION
            json.field "fused_json_commit", commit
            json.field "crystal_version", Crystal::VERSION
            json.field "crystal_build_commit", Crystal::BUILD_COMMIT
            json.field "llvm_version", Crystal::LLVM_VERSION
            json.field "target", Crystal::TARGET_TRIPLE
            json.field "release", RELEASE_BUILD
            json.field "limits_api", LIMITS_API_BUILD
          end
        end
        json.field "host" do
          json.object do
            json.field "os", host[:os]
            json.field "cpu_model", host[:cpu_model]
            json.field "cpu_count", host[:cpu_count]
            json.field "cpu_affinity", host[:cpu_affinity]
          end
        end
        json.field "environment" do
          json.object do
            ENVIRONMENT_KEYS.each do |key|
              nullable_field(json, key, ENV[key]?)
            end
          end
        end
        json.field "arguments" do
          json.array do
            INVOCATION_ARGUMENTS.each { |argument| json.string(argument) }
          end
        end
      end
    end
    STDOUT << '\n'
  end

  def receipt_observer(workload : String,
                       expected : Expectations) : Tuple(String, Observer)
    case workload
    when "string-dynamic", "io-dynamic"
      {"sha256-json-any-to-json-v1", Observer.new(1_i64, 0_u64)}
    when "string-typed", "io-typed"
      {"fnv1a64-typed-fields-v1", expected.typed}
    when "string-pull", "io-pull"
      {"fnv1a64-pull-events-v1", expected.pull}
    when "string-skip", "io-skip"
      {"complete-root-byte-offset-v1", expected.skip}
    else
      raise "unknown workload #{workload.inspect}"
    end
  end

  def positive_i32(value : String, name : String,
                   maximum : Int32 = Int32::MAX) : Int32
    parsed = value.to_i64?
    unless parsed && 0 < parsed <= maximum
      raise ArgumentError.new("#{name} must be between 1 and #{maximum}")
    end
    parsed.to_i32
  end

  def nonnegative_f64(value : String, name : String) : Float64
    parsed = value.to_f64?
    unless parsed && parsed.finite? && parsed >= 0
      raise ArgumentError.new("#{name} must be a finite non-negative number")
    end
    parsed
  end

  def positive_f64(value : String, name : String) : Float64
    parsed = value.to_f64?
    unless parsed && parsed.finite? && parsed > 0
      raise ArgumentError.new("#{name} must be a finite positive number")
    end
    parsed
  end

  def required_option(value : String?, name : String) : String
    value || raise ArgumentError.new("--#{name} is required")
  end

  def required_commit(value : String?) : String
    value || raise ArgumentError.new("--commit or FUSED_JSON_BENCH_COMMIT is required")
  end

  def hex_checksum(value : UInt64) : String
    "0x#{value.to_s(16).rjust(16, '0')}"
  end

  private def unknown_configuration(configuration : String) : NoReturn
    raise ArgumentError.new("unknown configuration #{configuration.inspect}")
  end

  private def limits_api_unavailable : NoReturn
    raise ArgumentError.new(
      "explicit-empty requires a build with -Dfused_json_limits_api"
    )
  end

  private def mix_string_sample(value : UInt64, string : String) : UInt64
    checksum = mix_i64(value, string.bytesize)
    unless string.empty?
      bytes = string.to_slice
      checksum = mix_byte(checksum, bytes[0])
      checksum = mix_byte(checksum, bytes[bytes.size - 1])
    end
    checksum
  end

  private def mix_string(value : UInt64, string : String) : UInt64
    checksum = mix_i64(value, string.bytesize)
    string.each_byte { |byte| checksum = mix_byte(checksum, byte) }
    checksum
  end

  private def mix_i64(value : UInt64, integer : Int) : UInt64
    mix_u64(value, integer.to_i64.unsafe_as(UInt64))
  end

  private def mix_u64(value : UInt64, integer : UInt64) : UInt64
    checksum = value
    8.times do |index|
      checksum = mix_byte(checksum, ((integer >> (index * 8)) & 0xff_u64).to_u8)
    end
    checksum
  end

  private def mix_byte(value : UInt64, byte : UInt8) : UInt64
    (value ^ byte) &* FNV_PRIME
  end

  private def nullable_field(json : JSON::Builder, name : String,
                             value : String? = nil) : Nil
    json.field name do
      value ? json.string(value) : json.null
    end
  end

  private def host_metadata
    {
      os:           command_output("uname", ["-srmo"]) || runtime_os,
      cpu_model:    ENV["FUSED_JSON_BENCH_CPU"]? || linux_cpu_model || "unknown",
      cpu_count:    System.cpu_count,
      cpu_affinity: linux_status_value("Cpus_allowed_list") || "unknown",
    }
  end

  private def command_output(command : String, arguments : Array(String)) : String?
    output = IO::Memory.new
    status = Process.run(command, arguments, output: output, error: Process::Redirect::Close)
    status.success? ? output.to_s.strip : nil
  rescue
    nil
  end

  private def linux_cpu_model : String?
    return unless File.file?("/proc/cpuinfo")
    File.each_line("/proc/cpuinfo") do |line|
      if line.starts_with?("model name") || line.starts_with?("Hardware")
        return line.split(':', 2)[1]?.try(&.strip)
      end
    end
    nil
  end

  private def linux_status_value(name : String) : String?
    return unless File.file?("/proc/self/status")
    prefix = "#{name}:"
    File.each_line("/proc/self/status") do |line|
      return line.byte_slice(prefix.bytesize).strip if line.starts_with?(prefix)
    end
    nil
  end

  private def runtime_os : String
    {% if flag?(:linux) %}
      "Linux"
    {% elsif flag?(:darwin) %}
      "macOS"
    {% elsif flag?(:freebsd) %}
      "FreeBSD"
    {% elsif flag?(:windows) %}
      "Windows"
    {% else %}
      "unknown"
    {% end %}
  end
end

unless LimitsOverheadBenchmark::RELEASE_BUILD
  abort "build this benchmark with --release --no-debug"
end

workload = nil.as(String?)
configuration = nil.as(String?)
record_count = 20_000
buffer_size = FusedJSON::StreamingPullParser::DEFAULT_BUFFER_SIZE
warmup_seconds = 1.0
calculation_seconds = 3.0
allocation_iterations = 20
commit = ENV["FUSED_JSON_BENCH_COMMIT"]?

begin
  record_count = LimitsOverheadBenchmark.positive_i32(
    ENV["FUSED_JSON_LIMITS_RECORDS"]? || record_count.to_s,
    "record count"
  )
  buffer_size = LimitsOverheadBenchmark.positive_i32(
    ENV["FUSED_JSON_LIMITS_BUFFER"]? || buffer_size.to_s,
    "buffer size",
    FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
  )
  warmup_seconds = LimitsOverheadBenchmark.nonnegative_f64(
    ENV["FUSED_JSON_BENCH_WARMUP"]? || warmup_seconds.to_s,
    "warmup"
  )
  calculation_seconds = LimitsOverheadBenchmark.positive_f64(
    ENV["FUSED_JSON_BENCH_TIME"]? || calculation_seconds.to_s,
    "calculation time"
  )
  allocation_iterations = LimitsOverheadBenchmark.positive_i32(
    ENV["FUSED_JSON_BENCH_ALLOCATIONS"]? || allocation_iterations.to_s,
    "allocation iterations"
  )
rescue error
  abort error.message || error.class.to_s
end

options = OptionParser.new do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} --workload=NAME --configuration=NAME [options]"
  parser.on("--workload=NAME", LimitsOverheadBenchmark::WORKLOADS.join(", ")) do |value|
    workload = value
  end
  parser.on("--configuration=NAME", LimitsOverheadBenchmark::CONFIGURATIONS.join(", ")) do |value|
    configuration = value
  end
  parser.on("--records=N", "Generated record count (default: #{record_count})") do |value|
    record_count = LimitsOverheadBenchmark.positive_i32(value, "record count")
  end
  parser.on("--buffer-size=N", "IO parser buffer size (default: #{buffer_size})") do |value|
    buffer_size = LimitsOverheadBenchmark.positive_i32(
      value,
      "buffer size",
      FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
    )
  end
  parser.on("--warmup=SECONDS", "Warmup duration (default: #{warmup_seconds})") do |value|
    warmup_seconds = LimitsOverheadBenchmark.nonnegative_f64(value, "warmup")
  end
  parser.on("--time=SECONDS", "Calculation duration (default: #{calculation_seconds})") do |value|
    calculation_seconds = LimitsOverheadBenchmark.positive_f64(value, "calculation time")
  end
  parser.on("--allocations=N", "Operations in the managed-allocation sample") do |value|
    allocation_iterations = LimitsOverheadBenchmark.positive_i32(value, "allocation iterations")
  end
  parser.on("--commit=REV", "Full FusedJSON commit SHA recorded in the receipt") do |value|
    commit = value
  end
  parser.on("-h", "--help", "Show this help") do
    puts parser
    puts
    puts "Run each workload in separate default and explicit-empty processes."
    puts "Alternate process order across samples and compare matching pairing_key values."
    exit
  end
end

begin
  options.parse
  raise ArgumentError.new("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
  selected_workload = LimitsOverheadBenchmark.required_option(workload, "workload")
  unless LimitsOverheadBenchmark::WORKLOADS.includes?(selected_workload)
    raise ArgumentError.new("unknown workload #{selected_workload.inspect}")
  end
  selected_configuration = LimitsOverheadBenchmark.required_option(configuration, "configuration")
  unless LimitsOverheadBenchmark::CONFIGURATIONS.includes?(selected_configuration)
    raise ArgumentError.new("unknown configuration #{selected_configuration.inspect}")
  end
  selected_commit = LimitsOverheadBenchmark.required_commit(commit)
  unless selected_commit.matches?(/\A[0-9a-f]{40}\z/)
    raise ArgumentError.new("commit must be a full lowercase 40-character SHA")
  end

  source = LimitsOverheadBenchmark.fixture_source(record_count)
  expected = LimitsOverheadBenchmark.expectations(source, buffer_size)
  operation = LimitsOverheadBenchmark.operation(
    selected_workload,
    selected_configuration,
    source,
    buffer_size
  )

  operation.call
  LimitsOverheadBenchmark::Sink.verify(selected_workload, expected)
  measurement = LimitsOverheadBenchmark.measure(
    source,
    operation,
    warmup_seconds.seconds,
    calculation_seconds.seconds,
    allocation_iterations
  )
  LimitsOverheadBenchmark::Sink.verify(selected_workload, expected)
  LimitsOverheadBenchmark.write_receipt(
    selected_workload,
    selected_configuration,
    source,
    record_count,
    buffer_size,
    selected_commit,
    warmup_seconds.seconds,
    calculation_seconds.seconds,
    allocation_iterations,
    expected,
    measurement
  )
rescue error
  STDERR.puts "error: #{error.message || error.class.to_s}"
  STDERR.puts options
  exit 1
end

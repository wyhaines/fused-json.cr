require "option_parser"

require "./tic_workload"

module TICBenchmarkCLI
  STRUCTURAL_MODES = ["fused-pull", "crystal-pull"]
  TYPED_MODES      = [
    "fused-typed",
    "crystal-typed",
    "fused-retained-typed",
    "crystal-retained-typed",
    "fused-gzip-typed",
    "crystal-gzip-typed",
    "fused-two-pass-typed",
    "crystal-two-pass-typed",
  ]
  GZIP_MODES       = ["gzip-drain", "fused-gzip-typed", "crystal-gzip-typed"]
  TWO_PASS_MODES   = ["fused-two-pass-typed", "crystal-two-pass-typed"]
  RETAINED_MODES   = ["fused-retained-typed", "crystal-retained-typed"]
  PARSER_MODES     = STRUCTURAL_MODES + TYPED_MODES
  MODES            = ["plain-drain", "gzip-drain"] + PARSER_MODES
  ENVIRONMENT_KEYS = [
    "CRYSTAL_WORKERS",
    "FUSED_JSON_BENCH_COMMIT",
    "GC_FREE_SPACE_DIVISOR",
    "GC_MARKERS",
    "GC_NPROCS",
    "GC_UNMAP_THRESHOLD",
    "MALLOC_CONF",
    "OMP_NUM_THREADS",
  ]

  RELEASE_BUILD        = {{ flag?(:release) }}
  INVOCATION_ARGUMENTS = ARGV.dup
  MAX_NESTING          = 512

  record Measurement,
    wall_seconds : Float64,
    user_cpu_seconds : Float64,
    system_cpu_seconds : Float64,
    allocated_bytes : UInt64,
    heap_before : UInt64,
    heap_after : UInt64,
    free_before : UInt64,
    free_after : UInt64,
    unmapped_before : UInt64,
    unmapped_after : UInt64,
    gc_cycles_before : UInt64,
    gc_cycles_after : UInt64,
    traversal : TICBench::TraversalResult?,
    typed_traversal : TICBench::TypedTraversalResult?,
    drain : TICBench::DrainResult?

  extend self

  def positive_i32(value : String, name : String, maximum : Int32) : Int32
    parsed = value.to_i64?
    unless parsed && 0 < parsed <= maximum
      raise ArgumentError.new("#{name} must be between 1 and #{maximum}")
    end
    parsed.to_i32
  end

  def required_option(value : String?, name : String) : String
    value || raise ArgumentError.new("--#{name} is required")
  end

  def verify_content(content : TICBench::ContentDigest,
                     manifest : TICBench::Manifest, label : String) : Nil
    unless content.bytes == manifest.decompressed_bytes
      raise "#{label} produced #{content.bytes} bytes, expected #{manifest.decompressed_bytes}"
    end
    unless content.sha256 == manifest.document_sha256
      raise "#{label} SHA-256 does not match the fixture manifest"
    end
  end

  def verify(command : String, input : String, manifest_path : String,
             gzip_input : String?, buffer_size : Int32,
             max_nesting : Int32) : Nil
    manifest = TICBench.parse_manifest(manifest_path)
    raise "max nesting is below the fixture requirement" if max_nesting < manifest.maximum_nesting
    validate_boundary_buffer(manifest, buffer_size)

    plain_content = TICBench.plain_content_digest(input, buffer_size)
    verify_content(plain_content, manifest, "plain input")

    fused = TICBench.fused_pull(input, buffer_size, max_nesting)
    TICBench.verify_result(fused, manifest, "FusedJSON")
    crystal = TICBench.crystal_pull(input, buffer_size, max_nesting)
    TICBench.verify_result(crystal, manifest, "Crystal")
    verify_traversal_parity(fused, crystal)

    fused_typed = TICBench.fused_typed_pull(input, buffer_size, max_nesting)
    TICBench.verify_typed_result(fused_typed, manifest, "typed FusedJSON")
    crystal_typed = TICBench.crystal_typed_pull(input, buffer_size, max_nesting)
    TICBench.verify_typed_result(crystal_typed, manifest, "typed Crystal")
    verify_typed_parity(fused_typed, crystal_typed)

    raw_number_verified, raw_number_checksum = verify_raw_numbers(
      input,
      manifest,
      buffer_size,
      max_nesting
    )
    gzip_verified = verify_gzip(gzip_input, manifest, buffer_size)

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "receipt", "fused-json-tic-verification"
        json.field "version", 1
        json.field "command", command
        json.field "status", "verified"
        json.field "profile", manifest.profile
        json.field "seed", manifest.seed
        json.field "root_key_order", manifest.root_key_order
        nullable_field(json, "boundary_bytes", manifest.boundary_bytes)
        json.field "input", File.expand_path(input)
        json.field "manifest", File.expand_path(manifest_path)
        json.field "manifest_sha256", TICBench.file_sha256(manifest_path)
        json.field "document_bytes", plain_content.bytes
        json.field "document_sha256", plain_content.sha256
        json.field "projection_sha256", fused.projection_sha256
        json.field "projection_checksum", fused.projection_checksum
        json.field "typed_verified", true
        json.field "typed_provider_checksum_algorithm", TICBench::PROVIDER_CHECKSUM_ALGORITHM
        json.field "typed_provider_checksum", fused_typed.provider_checksum
        json.field "typed_provider_records", fused_typed.provider_records
        json.field "typed_price_records", fused_typed.price_records
        json.field "typed_scalar_values", fused_typed.scalar_values
        json.field "raw_number_verified", raw_number_verified
        nullable_field(
          json,
          "raw_number_checksum_algorithm",
          manifest.projection.raw_number_checksum_algorithm
        )
        nullable_field(json, "raw_number_checksum", raw_number_checksum)
        json.field "gzip_verified", gzip_verified
        write_counts(json, fused.counts)
        json.field "buffer_size", buffer_size
        json.field "max_nesting", max_nesting
      end
    end
    STDOUT << '\n'
  end

  private def verify_traversal_parity(fused : TICBench::TraversalResult,
                                      crystal : TICBench::TraversalResult) : Nil
    unless fused.counts == crystal.counts &&
           fused.projection_sha256 == crystal.projection_sha256 &&
           fused.projection_checksum == crystal.projection_checksum
      raise "FusedJSON and Crystal traversal results differ"
    end
  end

  private def verify_typed_parity(fused : TICBench::TypedTraversalResult,
                                  crystal : TICBench::TypedTraversalResult) : Nil
    unless fused.traversal.counts == crystal.traversal.counts &&
           fused.traversal.projection_sha256 == crystal.traversal.projection_sha256 &&
           fused.traversal.projection_checksum == crystal.traversal.projection_checksum &&
           fused.provider_records == crystal.provider_records &&
           fused.price_records == crystal.price_records &&
           fused.scalar_values == crystal.scalar_values &&
           fused.provider_checksum == crystal.provider_checksum
      raise "FusedJSON and Crystal typed traversal results differ"
    end
  end

  private def verify_raw_numbers(input : String, manifest : TICBench::Manifest,
                                 buffer_size : Int32,
                                 max_nesting : Int32) : Tuple(Bool, String?)
    return {false, nil} unless manifest.projection.raw_number_checksum

    fused = TICBench.fused_raw_number_pull(input, buffer_size, max_nesting)
    TICBench.verify_raw_number_result(fused, manifest, "FusedJSON")
    crystal = TICBench.crystal_raw_number_pull(input, buffer_size, max_nesting)
    TICBench.verify_raw_number_result(crystal, manifest, "Crystal")
    unless fused.counts == crystal.counts &&
           fused.raw_number_checksum == crystal.raw_number_checksum
      raise "FusedJSON and Crystal raw-number traversal results differ"
    end
    {true, fused.raw_number_checksum}
  end

  private def verify_gzip(path : String?, manifest : TICBench::Manifest,
                          buffer_size : Int32) : Bool
    return false unless compressed_path = path

    compressed = manifest.gzip || raise "manifest does not describe a gzip fixture"
    unless File.size(compressed_path) == compressed.bytes
      raise "gzip input byte size does not match the fixture manifest"
    end
    unless TICBench.file_sha256(compressed_path) == compressed.sha256
      raise "gzip input SHA-256 does not match the fixture manifest"
    end
    verify_content(
      TICBench.gzip_content_digest(compressed_path, buffer_size),
      manifest,
      "gzip input"
    )
    true
  end

  def measure(mode : String, input : String, gzip_input : String?,
              buffer_size : Int32, max_nesting : Int32) : Measurement
    GC.collect
    gc_before = GC.stats
    prof_before = GC.prof_stats
    cpu_before = Process.times
    started = Time.instant

    traversal = nil.as(TICBench::TraversalResult?)
    typed_traversal = nil.as(TICBench::TypedTraversalResult?)
    drain = nil.as(TICBench::DrainResult?)
    case mode
    when "plain-drain", "gzip-drain"
      drain = measure_drain(mode, input, gzip_input, buffer_size)
    when "fused-pull", "crystal-pull"
      traversal = measure_structural(mode, input, buffer_size, max_nesting)
    else
      typed_traversal = measure_typed(mode, input, gzip_input, buffer_size, max_nesting)
    end

    elapsed = (Time.instant - started).total_seconds
    cpu_after = Process.times
    gc_after = GC.stats
    prof_after = GC.prof_stats
    Measurement.new(
      elapsed,
      cpu_after.utime - cpu_before.utime,
      cpu_after.stime - cpu_before.stime,
      gc_after.total_bytes &- gc_before.total_bytes,
      gc_before.heap_size,
      gc_after.heap_size,
      gc_before.free_bytes,
      gc_after.free_bytes,
      gc_before.unmapped_bytes,
      gc_after.unmapped_bytes,
      prof_before.gc_no,
      prof_after.gc_no,
      traversal,
      typed_traversal,
      drain
    )
  end

  private def measure_drain(mode : String, input : String,
                            gzip_input : String?, buffer_size : Int32) : TICBench::DrainResult
    case mode
    when "plain-drain"
      TICBench.plain_drain(input, buffer_size)
    when "gzip-drain"
      TICBench.gzip_drain(required_gzip_input(gzip_input, mode), buffer_size)
    else
      raise "unknown drain mode #{mode.inspect}"
    end
  end

  private def measure_structural(mode : String, input : String,
                                 buffer_size : Int32,
                                 max_nesting : Int32) : TICBench::TraversalResult
    case mode
    when "fused-pull"
      TICBench.fused_pull(input, buffer_size, max_nesting, strong_digest: false)
    when "crystal-pull"
      TICBench.crystal_pull(input, buffer_size, max_nesting, strong_digest: false)
    else
      raise "unknown structural mode #{mode.inspect}"
    end
  end

  private def measure_typed(mode : String, input : String, gzip_input : String?,
                            buffer_size : Int32,
                            max_nesting : Int32) : TICBench::TypedTraversalResult
    case mode
    when "fused-typed"
      TICBench.fused_typed_pull(input, buffer_size, max_nesting, strong_digest: false)
    when "crystal-typed"
      TICBench.crystal_typed_pull(input, buffer_size, max_nesting, strong_digest: false)
    when "fused-retained-typed"
      TICBench.fused_typed_pull(
        input,
        buffer_size,
        max_nesting,
        strong_digest: false,
        retain_output: true
      )
    when "crystal-retained-typed"
      TICBench.crystal_typed_pull(
        input,
        buffer_size,
        max_nesting,
        strong_digest: false,
        retain_output: true
      )
    when "fused-gzip-typed"
      TICBench.fused_gzip_typed_pull(
        required_gzip_input(gzip_input, mode),
        buffer_size,
        max_nesting,
        strong_digest: false
      )
    when "crystal-gzip-typed"
      TICBench.crystal_gzip_typed_pull(
        required_gzip_input(gzip_input, mode),
        buffer_size,
        max_nesting,
        strong_digest: false
      )
    when "fused-two-pass-typed"
      TICBench.fused_two_pass_typed_pull(input, buffer_size, max_nesting, strong_digest: false)
    when "crystal-two-pass-typed"
      TICBench.crystal_two_pass_typed_pull(input, buffer_size, max_nesting, strong_digest: false)
    else
      raise "unknown typed mode #{mode.inspect}"
    end
  end

  private def required_gzip_input(path : String?, mode : String) : String
    path || raise "--gzip-input is required for #{mode}"
  end

  def run(command : String, mode : String, input : String,
          manifest_path : String, gzip_input : String?,
          buffer_size : Int32, max_nesting : Int32,
          fused_commit : String) : Nil
    raise "#{command} requires a --release build" unless RELEASE_BUILD
    raise "--mode must be one of: #{MODES.join(", ")}" unless MODES.includes?(mode)

    manifest = TICBench.parse_manifest(manifest_path)
    validate_run_input(mode, input, manifest, buffer_size, max_nesting)
    compressed_bytes = compressed_input_bytes(mode, gzip_input, manifest)
    validate_commit(fused_commit)
    host = host_metadata
    measurement = measure(mode, input, gzip_input, buffer_size, max_nesting)
    verify_measurement(measurement, manifest, mode)

    write_measurement(
      command,
      mode,
      input,
      gzip_input,
      manifest_path,
      manifest,
      measurement,
      compressed_bytes,
      buffer_size,
      max_nesting,
      fused_commit,
      host
    )
  end

  def validate_run_input(mode : String, input : String,
                         manifest : TICBench::Manifest,
                         buffer_size : Int32, max_nesting : Int32) : Nil
    raise "max nesting is below the fixture requirement" if max_nesting < manifest.maximum_nesting
    validate_boundary_buffer(manifest, buffer_size) if PARSER_MODES.includes?(mode)
    unless File.size(input) == manifest.decompressed_bytes
      raise "plain input byte size does not match the fixture manifest"
    end
  end

  def compressed_input_bytes(mode : String, gzip_input : String?,
                             manifest : TICBench::Manifest) : Int64?
    unless GZIP_MODES.includes?(mode)
      if gzip_input
        raise "--gzip-input is only accepted by gzip benchmark modes"
      end
      return
    end

    compressed_path = gzip_input || raise "--gzip-input is required for #{mode}"
    compressed = manifest.gzip || raise "manifest does not describe a gzip fixture"
    bytes = File.size(compressed_path)
    raise "gzip input byte size does not match the fixture manifest" unless bytes == compressed.bytes
    bytes
  end

  def validate_commit(fused_commit : String) : Nil
    unless fused_commit.matches?(/\A[0-9a-f]{40}\z/)
      raise "--commit must be the full 40-character FusedJSON commit SHA"
    end
  end

  def verify_measurement(measurement : Measurement,
                         manifest : TICBench::Manifest, mode : String) : Nil
    if result = measurement.traversal
      TICBench.verify_result(result, manifest, mode, require_strong: false)
    elsif result = measurement.typed_traversal
      TICBench.verify_typed_result(result, manifest, mode, require_strong: false)
      retained = result.retained_output
      if RETAINED_MODES.includes?(mode)
        unless retained && retained.total_values == result.typed_values
          raise "#{mode} did not retain every selected typed value"
        end
      elsif retained
        raise "#{mode} unexpectedly retained typed values"
      end
    elsif result = measurement.drain
      unless result.bytes == manifest.decompressed_bytes
        raise "#{mode} processed #{result.bytes} bytes, expected #{manifest.decompressed_bytes}"
      end
    end
  end

  def write_measurement(command : String, mode : String, input : String,
                        gzip_input : String?, manifest_path : String,
                        manifest : TICBench::Manifest,
                        measurement : Measurement,
                        compressed_bytes : Int64?,
                        buffer_size : Int32, max_nesting : Int32,
                        fused_commit : String,
                        host : NamedTuple(os: String, cpu_model: String,
                          cpu_count: Int32, cpu_affinity: String)) : Nil
    wall = measurement.wall_seconds
    typed_traversal = measurement.typed_traversal
    traversal = measurement.traversal || typed_traversal.try(&.traversal)
    input_passes = typed_traversal.try(&.input_passes) || 1
    processed_bytes = checked_processed_bytes(manifest.decompressed_bytes, input_passes)
    logical_mib = manifest.decompressed_bytes / 1_048_576.0
    processed_mib = processed_bytes / 1_048_576.0
    drain = measurement.drain
    item_count = traversal.try(&.counts.negotiated_prices)
    typed_values = typed_traversal.try(&.typed_values)

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "receipt", "fused-json-tic-measurement"
        json.field "version", 1
        json.field "command", command
        json.field "mode", mode
        json.field "profile", manifest.profile
        json.field "seed", manifest.seed
        json.field "recorded_at", Time.utc.to_rfc3339
        json.field "arguments", INVOCATION_ARGUMENTS
        json.field "root_key_order", manifest.root_key_order
        nullable_field(json, "boundary_bytes", manifest.boundary_bytes)
        json.field "input", File.expand_path(measured_input(mode, input, gzip_input))
        json.field "manifest", File.expand_path(manifest_path)
        json.field "manifest_sha256", TICBench.file_sha256(manifest_path)
        json.field "expected_document_sha256", manifest.document_sha256
        json.field "expected_projection_sha256", manifest.projection.sha256
        json.field "expected_projection_checksum", manifest.projection.checksum
        json.field "logical_document_bytes", manifest.decompressed_bytes
        json.field "input_passes", input_passes
        json.field "processed_bytes", processed_bytes
        nullable_field(json, "compressed_ingress_bytes", compressed_bytes)
        json.field "decompressed_mib_per_second", processed_mib / wall
        json.field "logical_document_mib_per_second", logical_mib / wall
        nullable_field(
          json,
          "compressed_mib_per_second",
          compressed_bytes.try { |bytes| bytes / 1_048_576.0 / wall }
        )
        nullable_field(
          json,
          "projected_prices_per_second",
          item_count.try { |count| count / wall }
        )
        nullable_field(
          json,
          "typed_values_per_second",
          typed_values.try { |count| count / wall }
        )
        nullable_field(
          json,
          "first_projected_price_seconds",
          traversal.try(&.first_item_seconds)
        )
        nullable_field(json, "projection_sha256", traversal.try(&.projection_sha256))
        nullable_field(
          json,
          "projection_checksum",
          traversal.try(&.projection_checksum)
        )
        nullable_field(
          json,
          "typed_provider_checksum_algorithm",
          typed_traversal.try { TICBench::PROVIDER_CHECKSUM_ALGORITHM }
        )
        nullable_field(
          json,
          "typed_provider_checksum",
          typed_traversal.try(&.provider_checksum)
        )
        nullable_field(
          json,
          "typed_provider_records",
          typed_traversal.try(&.provider_records)
        )
        nullable_field(
          json,
          "typed_price_records",
          typed_traversal.try(&.price_records)
        )
        nullable_field(
          json,
          "typed_scalar_values",
          typed_traversal.try(&.scalar_values)
        )
        nullable_field(
          json,
          "typed_records",
          typed_traversal.try(&.typed_records)
        )
        nullable_field(json, "typed_values", typed_values)
        write_retained_output(json, typed_traversal.try(&.retained_output))
        nullable_field(
          json,
          "typed_pass_wall_seconds",
          typed_traversal.try(&.pass_wall_seconds)
        )
        nullable_field(
          json,
          "drain_observer",
          drain.try { |value| sprintf("0x%016x", value.checksum) }
        )
        if counts = traversal.try(&.counts)
          write_counts(json, counts)
        else
          json.field "counts" { json.null }
        end
        json.field "timing" do
          json.object do
            json.field "wall_seconds", wall
            json.field "user_cpu_seconds", measurement.user_cpu_seconds
            json.field "system_cpu_seconds", measurement.system_cpu_seconds
            json.field "total_cpu_seconds",
              measurement.user_cpu_seconds + measurement.system_cpu_seconds
          end
        end
        json.field "managed_memory" do
          json.object do
            json.field "allocated_bytes", measurement.allocated_bytes
            nullable_field(
              json,
              "bytes_per_projected_price",
              item_count.try { |count| measurement.allocated_bytes.to_f / count }
            )
            nullable_field(
              json,
              "bytes_per_typed_value",
              typed_values.try { |count| measurement.allocated_bytes.to_f / count }
            )
            json.field "bytes_per_decompressed_mib",
              measurement.allocated_bytes.to_f / processed_mib
            json.field "heap_before", measurement.heap_before
            json.field "heap_after", measurement.heap_after
            json.field "free_before", measurement.free_before
            json.field "free_after", measurement.free_after
            json.field "unmapped_before", measurement.unmapped_before
            json.field "unmapped_after", measurement.unmapped_after
            json.field "gc_cycles_before", measurement.gc_cycles_before
            json.field "gc_cycles_after", measurement.gc_cycles_after
            json.field "gc_cycles",
              measurement.gc_cycles_after &- measurement.gc_cycles_before
          end
        end
        json.field "configuration" do
          json.object do
            json.field "buffer_size", buffer_size
            json.field "max_nesting", max_nesting
            nullable_field(json, "parser", parser_name(mode))
            json.field "transport", GZIP_MODES.includes?(mode) ? "gzip" : "plain"
            json.field "workload", workload_name(mode)
            json.field "retained_output_policy",
              RETAINED_MODES.includes?(mode) ? TICBench::RETAINED_OUTPUT_POLICY : "none"
            json.field "fused_cache_keys", false
            json.field "fused_reject_duplicate_keys", false
            json.field "crystal_key_pool", "standard library always enabled"
            json.field "input_buffering", input_buffering(mode)
          end
        end
        json.field "runtime" do
          json.object do
            json.field "fused_json_version", FusedJSON::VERSION
            json.field "fused_json_commit", fused_commit
            json.field "crystal_version", Crystal::VERSION
            nullable_field(json, "crystal_build_commit", Crystal::BUILD_COMMIT)
            json.field "llvm_version", Crystal::LLVM_VERSION
            json.field "target", Crystal::TARGET_TRIPLE
            json.field "release_build", RELEASE_BUILD
            json.field "recommended_build_flags", "--release --no-debug"
            json.field "zlib_version", String.new(LibZ.zlibVersion)
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
              if value = ENV[key]?
                json.field key, value
              end
            end
          end
        end
        if command == "rss"
          json.field "peak_rss", "record separately with GNU /usr/bin/time -v"
        end
      end
    end
    STDOUT << '\n'
  end

  def measured_input(mode : String, input : String, gzip_input : String?) : String
    return input unless GZIP_MODES.includes?(mode)
    gzip_input || raise "gzip measurement is missing its input"
  end

  def checked_processed_bytes(document_bytes : Int64, input_passes : Int32) : Int64
    if document_bytes > Int64::MAX // input_passes
      raise "processed byte count exceeds Int64"
    end
    document_bytes * input_passes
  end

  def parser_name(mode : String) : String?
    return "FusedJSON" if mode.starts_with?("fused-")
    return "Crystal JSON::PullParser" if mode.starts_with?("crystal-")
    nil
  end

  def workload_name(mode : String) : String
    return "drain" if mode.ends_with?("-drain")
    return "typed-retained" if RETAINED_MODES.includes?(mode)
    return "typed-two-pass" if TWO_PASS_MODES.includes?(mode)
    return "typed" if TYPED_MODES.includes?(mode)
    "structural-pull"
  end

  def input_buffering(mode : String) : String
    case mode
    when "plain-drain"
      "unbuffered File plus explicit benchmark drain buffer"
    when "gzip-drain"
      "unbuffered compressed File plus gzip reader and explicit benchmark drain buffer"
    when "fused-gzip-typed"
      "unbuffered compressed File plus gzip reader and FusedJSON parser buffer"
    when "crystal-gzip-typed"
      "unbuffered compressed File plus gzip reader; Crystal lexer buffer is internal"
    when .starts_with?("fused-")
      "unbuffered File plus FusedJSON parser buffer"
    when .starts_with?("crystal-")
      "File buffer set to benchmark buffer size; Crystal lexer buffer is internal"
    else
      raise "unknown benchmark mode #{mode.inspect}"
    end
  end

  def write_retained_output(json : JSON::Builder,
                            retained : TICBench::RetainedTypedOutput?) : Nil
    json.field "retained_output" do
      if retained
        json.object do
          json.field "policy", TICBench::RETAINED_OUTPUT_POLICY
          json.field "provider_records", retained.provider_records.size
          json.field "scalar_values", retained.scalar_values.size
          json.field "price_records", retained.price_records.size
          json.field "total_values", retained.total_values
        end
      else
        json.null
      end
    end
  end

  def write_counts(json : JSON::Builder, counts : TICBench::Counts) : Nil
    json.field "counts" do
      json.object do
        json.field "provider_references", counts.provider_references
        json.field "provider_groups", counts.provider_groups
        json.field "in_network", counts.in_network
        json.field "negotiated_rates", counts.negotiated_rates
        json.field "negotiated_prices", counts.negotiated_prices
      end
    end
  end

  def validate_boundary_buffer(manifest : TICBench::Manifest,
                               buffer_size : Int32) : Nil
    if boundary = manifest.boundary_bytes
      unless buffer_size == boundary
        raise "unicode-boundary fixture requires --buffer-size=#{boundary}"
      end
    end
  end

  def nullable_field(json : JSON::Builder, name : String, value) : Nil
    json.field name do
      value.nil? ? json.null : value.to_json(json)
    end
  end

  def host_metadata
    {
      os:           command_output("uname", ["-srmo"]) || runtime_os,
      cpu_model:    ENV["FUSED_JSON_BENCH_CPU"]? || linux_cpu_model || "unknown",
      cpu_count:    System.cpu_count,
      cpu_affinity: linux_status_value("Cpus_allowed_list") || "unknown",
    }
  end

  def command_output(command : String, arguments : Array(String)) : String?
    output = IO::Memory.new
    status = Process.run(command, arguments, output: output, error: Process::Redirect::Close)
    status.success? ? output.to_s.strip : nil
  rescue
    nil
  end

  def linux_cpu_model : String?
    return unless File.file?("/proc/cpuinfo")
    File.each_line("/proc/cpuinfo") do |line|
      if line.starts_with?("model name") || line.starts_with?("Hardware")
        return line.split(':', 2)[1]?.try(&.strip)
      end
    end
    nil
  end

  def linux_status_value(name : String) : String?
    return unless File.file?("/proc/self/status")
    prefix = "#{name}:"
    File.each_line("/proc/self/status") do |line|
      return line.byte_slice(prefix.bytesize).strip if line.starts_with?(prefix)
    end
    nil
  end

  def runtime_os : String
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

command = ARGV.shift?
unless command && {"verify", "run", "rss"}.includes?(command)
  STDERR.puts "Usage: #{PROGRAM_NAME} verify|run|rss [options]"
  exit 1
end

input = nil.as(String?)
manifest_path = nil.as(String?)
gzip_input = nil.as(String?)
mode = nil.as(String?)
buffer_size = FusedJSON::StreamingPullParser::DEFAULT_BUFFER_SIZE
max_nesting = 512
fused_commit = ENV["FUSED_JSON_BENCH_COMMIT"]? || "unknown"

options = OptionParser.new do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} #{command} --input FILE --manifest FILE [options]"
  parser.on("--input=FILE", "Plain generated JSON input") { |value| input = value }
  parser.on("--manifest=FILE", "Fixture manifest") { |value| manifest_path = value }
  parser.on("--gzip-input=FILE", "Generated gzip input") { |value| gzip_input = value }
  parser.on("--mode=MODE", TICBenchmarkCLI::MODES.join(", ")) { |value| mode = value }
  parser.on("--buffer-size=N", "Input buffer size (default: #{buffer_size})") do |value|
    buffer_size = TICBenchmarkCLI.positive_i32(
      value,
      "buffer size",
      FusedJSON::StreamingPullParser::MAX_BUFFER_SIZE
    )
  end
  parser.on("--max-nesting=N", "Parser nesting limit (default: #{max_nesting})") do |value|
    max_nesting = TICBenchmarkCLI.positive_i32(
      value,
      "max nesting",
      TICBenchmarkCLI::MAX_NESTING
    )
  end
  parser.on("--commit=REV", "FusedJSON revision recorded in receipts") do |value|
    fused_commit = value
  end
  parser.on("-h", "--help", "Show this help") do
    puts parser
    puts
    puts "Run verify before measurements. Each run or rss invocation performs one workload."
    puts "Wrap rss with: /usr/bin/time -v #{PROGRAM_NAME} rss ... >run.json 2>run.time"
    exit
  end
end

begin
  options.parse
  raise ArgumentError.new("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
  selected_input = TICBenchmarkCLI.required_option(input, "input")
  selected_manifest = TICBenchmarkCLI.required_option(manifest_path, "manifest")

  if command == "verify"
    raise ArgumentError.new("--mode is not accepted by verify") if mode
    TICBenchmarkCLI.verify(
      command,
      selected_input,
      selected_manifest,
      gzip_input,
      buffer_size,
      max_nesting
    )
  else
    selected_mode = TICBenchmarkCLI.required_option(mode, "mode")
    TICBenchmarkCLI.run(
      command,
      selected_mode,
      selected_input,
      selected_manifest,
      gzip_input,
      buffer_size,
      max_nesting,
      fused_commit
    )
  end
rescue error
  STDERR.puts "error: #{error.message || error.class.to_s}"
  STDERR.puts options
  exit 1
end

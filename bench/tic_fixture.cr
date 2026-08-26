require "compress/gzip"
require "option_parser"

require "./tic_fixture_generator"

module TICFixtureCLI
  extend self

  def positive_i64(value : String, name : String) : Int64
    parsed = value.to_i64?
    unless parsed && parsed > 0
      raise ArgumentError.new("#{name} must be a positive Int64")
    end
    parsed
  end

  def positive_i32(value : String, name : String) : Int32
    parsed = value.to_i64?
    unless parsed && 0 < parsed <= Int32::MAX
      raise ArgumentError.new("#{name} must be between 1 and #{Int32::MAX}")
    end
    parsed.to_i32
  end

  def uint64(value : String, name : String) : UInt64
    value.to_u64? || raise ArgumentError.new("#{name} must be a UInt64")
  end

  def required(value : T?, name : String) : T forall T
    value || raise ArgumentError.new("#{name} is required")
  end

  def default_order(profile : TICBench::FixtureProfile) : TICBench::FieldOrder
    if profile.wide_item? || profile.unicode_boundary?
      TICBench::FieldOrder::RatesFirst
    else
      TICBench::FieldOrder::ProvidersFirst
    end
  end

  def temporary_path(path : String) : String
    "#{path}.part-#{Process.pid}"
  end

  def backup_path(path : String) : String
    "#{path}.backup-#{Process.pid}"
  end

  def ensure_distinct_paths(paths : Array(String)) : Nil
    expanded = paths.map { |path| File.expand_path(path) }
    unless expanded.uniq.size == expanded.size
      raise ArgumentError.new("output, gzip output, and manifest paths must be distinct")
    end
  end

  def ensure_destinations(paths : Array(String), *, force : Bool) : Nil
    paths.each do |path|
      if info = File.info?(path, follow_symlinks: false)
        unless info.file?
          raise ArgumentError.new("#{path} exists and is not a regular file")
        end
        unless force
          raise ArgumentError.new("#{path} already exists; pass --force to replace it")
        end
      end

      {temporary_path(path), backup_path(path)}.each do |working_path|
        if File.info?(working_path, follow_symlinks: false)
          raise ArgumentError.new("stale transaction file exists: #{working_path}")
        end
      end
    end
  end

  def install_all(files : Array(Tuple(String, String)), *, force : Bool) : Nil
    files.each do |source, _destination|
      info = File.info?(source, follow_symlinks: false)
      unless info.try(&.file?)
        raise ArgumentError.new("staged fixture is not a regular file: #{source}")
      end
    end

    backups = [] of Tuple(String, String)
    installed = [] of String

    begin
      files.each do |_source, destination|
        next unless info = File.info?(destination, follow_symlinks: false)
        unless info.file?
          raise ArgumentError.new("#{destination} exists and is not a regular file")
        end
        unless force
          raise ArgumentError.new("#{destination} already exists; pass --force to replace it")
        end

        backup = backup_path(destination)
        if File.info?(backup, follow_symlinks: false)
          raise ArgumentError.new("stale transaction file exists: #{backup}")
        end
        File.rename(destination, backup)
        backups << {destination, backup}
      end

      files.each do |source, destination|
        File.rename(source, destination)
        installed << destination
      end
    rescue error
      rollback_errors = rollback_install(installed, backups)
      unless rollback_errors.empty?
        detail = rollback_errors.join("; ")
        raise IO::Error.new("#{error.message || error.class}: rollback failed: #{detail}")
      end
      raise error
    end

    backups.each do |_destination, backup|
      File.delete(backup)
    rescue error
      STDERR.puts "warning: could not remove transaction backup #{backup}: #{error.message}"
    end
  end

  private def rollback_install(installed : Array(String),
                               backups : Array(Tuple(String, String))) : Array(String)
    errors = [] of String

    installed.reverse_each do |destination|
      next unless File.info?(destination, follow_symlinks: false)
      begin
        File.delete(destination)
      rescue error
        errors << "could not remove #{destination}: #{error.message}"
      end
    end

    backups.reverse_each do |destination, backup|
      unless File.info?(backup, follow_symlinks: false)
        errors << "missing backup #{backup}"
        next
      end
      if File.info?(destination, follow_symlinks: false)
        errors << "could not restore #{destination}: destination exists"
        next
      end
      File.rename(backup, destination)
    rescue error
      errors << "could not restore #{destination}: #{error.message}"
    end

    errors
  end
end

profile_name = nil.as(String?)
bytes_value = nil.as(Int64?)
output_path = nil.as(String?)
manifest_path = nil.as(String?)
gzip_path = nil.as(String?)
seed = 1_u64
field_order_name = nil.as(String?)
boundary_bytes = 32 * 1024
force = false

options = OptionParser.new do |parser|
  parser.banner = "Usage: #{PROGRAM_NAME} --profile NAME --bytes N --output FILE --manifest FILE [options]"
  parser.on("--profile=NAME", "many-small, wide-item, skip-heavy, or unicode-boundary") do |value|
    profile_name = value
  end
  parser.on("--bytes=N", "Exact decompressed JSON size in bytes") do |value|
    bytes_value = TICFixtureCLI.positive_i64(value, "bytes")
  end
  parser.on("--output=FILE", "Plain JSON destination") { |value| output_path = value }
  parser.on("--manifest=FILE", "Fixture manifest destination") { |value| manifest_path = value }
  parser.on("--gzip-output=FILE", "Optional reproducible gzip destination") { |value| gzip_path = value }
  parser.on("--seed=N", "Deterministic UInt64 seed (default: 1)") do |value|
    seed = TICFixtureCLI.uint64(value, "seed")
  end
  parser.on("--field-order=ORDER", "providers-first or rates-first") do |value|
    field_order_name = value
  end
  parser.on("--boundary-bytes=N", "Unicode split boundary (default: #{boundary_bytes})") do |value|
    boundary_bytes = TICFixtureCLI.positive_i32(value, "boundary bytes")
  end
  parser.on("--force", "Replace existing destinations") { force = true }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

temporary_paths = [] of String
begin
  options.parse
  raise ArgumentError.new("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

  profile_value = TICFixtureCLI.required(profile_name, "--profile")
  bytes = TICFixtureCLI.required(bytes_value, "--bytes")
  output = TICFixtureCLI.required(output_path, "--output")
  manifest_destination = TICFixtureCLI.required(manifest_path, "--manifest")
  profile = TICBench::FixtureProfile.from_cli(profile_value)
  order = if value = field_order_name
            TICBench::FieldOrder.from_cli(value)
          else
            TICFixtureCLI.default_order(profile)
          end

  destinations = [output, manifest_destination]
  if compressed_destination = gzip_path
    destinations << compressed_destination
  end
  TICFixtureCLI.ensure_distinct_paths(destinations)
  TICFixtureCLI.ensure_destinations(destinations, force: force)
  temporary_paths = destinations.map { |path| TICFixtureCLI.temporary_path(path) }

  output_temporary = TICFixtureCLI.temporary_path(output)
  config = TICBench::FixtureConfig.new(profile, bytes, seed, order, boundary_bytes)
  generated = File.open(output_temporary, "w") do |file|
    TICBench::FixtureGenerator.new(config).generate(file)
  end

  gzip_metadata = nil.as(TICBench::GzipMetadata?)
  if compressed_destination = gzip_path
    gzip_temporary = TICFixtureCLI.temporary_path(compressed_destination)
    gzip_metadata = TICBench.gzip_fixture(output_temporary, gzip_temporary)
    TICBench.verify_gzip_fixture(gzip_temporary, bytes, generated.document_sha256)
  end

  manifest = generated.manifest(gzip_metadata)
  manifest.validate!
  manifest_temporary = TICFixtureCLI.temporary_path(manifest_destination)
  File.open(manifest_temporary, "w") do |file|
    manifest.to_pretty_json(file)
    file << '\n'
  end
  TICBench.parse_manifest(manifest_temporary)

  installations = [{output_temporary, output}]
  if compressed_destination = gzip_path
    installations << {
      TICFixtureCLI.temporary_path(compressed_destination),
      compressed_destination,
    }
  end
  installations << {manifest_temporary, manifest_destination}
  TICFixtureCLI.install_all(installations, force: force)
  temporary_paths.clear

  puts "#{profile.cli_name}: #{bytes} bytes, #{manifest.counts.negotiated_prices} projected prices"
  puts "document SHA-256: #{manifest.document_sha256}"
  if compressed = manifest.gzip
    puts "gzip: #{compressed.bytes} bytes, SHA-256 #{compressed.sha256}"
  end
  puts "manifest: #{manifest_destination}"
rescue error
  temporary_paths.each do |path|
    File.delete(path) if File.file?(path)
  rescue exception
    STDERR.puts "warning: could not remove #{path}: #{exception.message}"
  end
  STDERR.puts "error: #{error.message || error.class.to_s}"
  STDERR.puts options
  exit 1
end

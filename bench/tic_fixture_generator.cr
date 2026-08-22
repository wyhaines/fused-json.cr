require "compress/gzip"

require "./tic_support"

module TICBench
  GZIP_LEVEL            = 6
  GZIP_COPY_BUFFER_SIZE = 64 * 1024

  def self.gzip_fixture(source_path : String, destination_path : String,
                        level : Int32 = GZIP_LEVEL) : GzipMetadata
    File.open(source_path) do |source|
      source.read_buffering = false
      File.open(destination_path, "w") do |destination|
        Compress::Gzip::Writer.open(destination, level) do |gzip|
          gzip.header.modification_time = Time.unix(0).to_utc
          gzip.header.os = 255_u8
          gzip.header.extra = Bytes.empty
          gzip.header.name = nil
          gzip.header.comment = nil
          buffer = Bytes.new(GZIP_COPY_BUFFER_SIZE)
          while (count = source.read(buffer)) > 0
            gzip.write(buffer[0, count])
          end
        end
      end
    end

    GzipMetadata.new(
      File.size(destination_path),
      file_sha256(destination_path),
      level,
      String.new(LibZ.zlibVersion)
    )
  end

  def self.verify_gzip_fixture(path : String, expected_bytes : Int64,
                               expected_sha256 : String) : Nil
    digest = Digest::SHA256.new
    bytes = 0_i64
    buffer = Bytes.new(GZIP_COPY_BUFFER_SIZE)
    File.open(path) do |file|
      Compress::Gzip::Reader.open(file) do |gzip|
        while (count = gzip.read(buffer)) > 0
          digest.update(buffer[0, count])
          bytes += count
        end
      end
    end
    raise "gzip decompressed to #{bytes} bytes, expected #{expected_bytes}" unless bytes == expected_bytes
    actual_sha256 = digest.hexfinal
    unless actual_sha256 == expected_sha256
      raise "gzip decompressed SHA-256 #{actual_sha256} does not match #{expected_sha256}"
    end
  end

  enum FixtureProfile
    ManySmall
    WideItem
    SkipHeavy
    UnicodeBoundary

    def self.from_cli(value : String) : self
      case value
      when "many-small"       then ManySmall
      when "wide-item"        then WideItem
      when "skip-heavy"       then SkipHeavy
      when "unicode-boundary" then UnicodeBoundary
      else
        raise ArgumentError.new("unknown profile #{value.inspect}")
      end
    end

    def cli_name : String
      case self
      in .many_small?       then "many-small"
      in .wide_item?        then "wide-item"
      in .skip_heavy?       then "skip-heavy"
      in .unicode_boundary? then "unicode-boundary"
      end
    end
  end

  enum FieldOrder
    ProvidersFirst
    RatesFirst

    def self.from_cli(value : String) : self
      case value
      when "providers-first" then ProvidersFirst
      when "rates-first"     then RatesFirst
      else
        raise ArgumentError.new("field order must be providers-first or rates-first")
      end
    end
  end

  class FixtureConfig
    getter profile : FixtureProfile
    getter bytes : Int64
    getter seed : UInt64
    getter field_order : FieldOrder
    getter boundary_bytes : Int32

    def initialize(@profile, @bytes, @seed, @field_order, @boundary_bytes = 32 * 1024)
      raise ArgumentError.new("bytes must be positive") unless @bytes > 0
      unless 64 <= @boundary_bytes <= 16 * 1024 * 1024
        raise ArgumentError.new("boundary bytes must be between 64 and 16777216")
      end
    end
  end

  class Fragment
    getter source : String
    getter largest_token : SourceMaximum
    getter largest_item : SourceMaximum

    def initialize(@source, @largest_token, @largest_item)
    end
  end

  record GeneratedPrice, fragment : Fragment, row : ProjectionRow
  record GeneratedItem, fragment : Fragment, row : ProjectionRow

  class TrackedOutput
    PADDING_CHUNK = "a" * (16 * 1024)

    getter bytes_written : Int64
    getter largest_token : SourceMaximum
    getter largest_item : SourceMaximum

    def initialize(@io : IO, *, digest = true)
      @digest = digest ? Digest::SHA256.new : nil
      @bytes_written = 0_i64
      @largest_token = SourceMaximum.new(0_i64, "none", "")
      @largest_item = SourceMaximum.new(0_i64, "none", "")
      @finished = false
    end

    def write_raw(value : String) : Nil
      raise "output digest is finalized" if @finished
      @io << value
      @digest.try &.update(value)
      @bytes_written += value.bytesize
    end

    def write_json_string(value : String, path : String, kind = "string") : Nil
      write_token(value.to_json, path, kind)
    end

    def write_number(value : String, path : String) : Nil
      write_token(value, path, "number")
    end

    def write_token(value : String, path : String, kind : String) : Nil
      note_token(value.bytesize.to_i64, path, kind)
      write_raw(value)
    end

    def write_repeated_string(count : Int64, path : String) : Nil
      raise ArgumentError.new("negative repeated string size") if count < 0
      note_token(count + 2, path, "string")
      write_raw("\"")
      remaining = count
      while remaining > 0
        amount = Math.min(remaining, PADDING_CHUNK.bytesize.to_i64).to_i32
        write_raw(PADDING_CHUNK.byte_slice(0, amount))
        remaining -= amount
      end
      write_raw("\"")
    end

    def write_fragment(fragment : Fragment) : Nil
      note_maximum(fragment.largest_token, token: true)
      note_maximum(fragment.largest_item, token: false)
      write_raw(fragment.source)
    end

    def note_token(bytes : Int64, path : String, kind : String) : Nil
      candidate = SourceMaximum.new(bytes, kind, path)
      note_maximum(candidate, token: true)
    end

    def note_item(start_byte : Int64, path : String) : Nil
      candidate = SourceMaximum.new(@bytes_written - start_byte, "array-item", path)
      note_maximum(candidate, token: false)
    end

    def hexfinal : String
      raise "output digest is already finalized" if @finished
      digest = @digest || raise "output digest is disabled"
      @finished = true
      digest.hexfinal
    end

    private def note_maximum(candidate : SourceMaximum, *, token : Bool) : Nil
      current = token ? @largest_token : @largest_item
      return unless candidate.bytes > current.bytes

      if token
        @largest_token = candidate
      else
        @largest_item = candidate
      end
    end
  end

  class GenerationResult
    getter config : FixtureConfig
    getter document_sha256 : String
    getter root_key_order : Array(String)
    getter counts : Counts
    getter maximum_nesting : Int32
    getter largest_token : SourceMaximum
    getter largest_item : SourceMaximum
    getter unicode_splits : Array(UnicodeSplit)
    getter projection_sha256 : String
    getter projection_checksum : String

    def initialize(@config, @document_sha256, @root_key_order, @counts,
                   @maximum_nesting, @largest_token, @largest_item,
                   @unicode_splits, @projection_sha256,
                   @projection_checksum)
    end

    def manifest(gzip : GzipMetadata? = nil) : Manifest
      boundary = config.profile.unicode_boundary? ? config.boundary_bytes : nil
      Manifest.new(
        profile: config.profile.cli_name,
        seed: config.seed.to_s,
        requested_bytes: config.bytes,
        decompressed_bytes: config.bytes,
        document_sha256: document_sha256,
        root_key_order: root_key_order,
        boundary_bytes: boundary,
        counts: counts,
        maximum_nesting: maximum_nesting,
        largest_token: largest_token,
        largest_item: largest_item,
        unicode_splits: unicode_splits,
        projection: ProjectionMetadata.new(
          counts.negotiated_prices,
          projection_sha256,
          projection_checksum
        ),
        gzip: gzip
      )
    end
  end

  class FixtureGenerator
    PROVIDER_COUNT  = 16_i64
    MAXIMUM_NESTING =      8
    PAD_KEY         = "_fixture_padding"

    getter config : FixtureConfig

    def initialize(@config)
      @counts = Counts.new
      @projection = ProjectionDigest.new
      @projection_checksum = ProjectionChecksum.new
      @root_key_order = [] of String
      @unicode_splits = [] of UnicodeSplit
    end

    def generate(io : IO) : GenerationResult
      output = TrackedOutput.new(io)
      providers = provider_array

      output.write_raw("{")
      write_root_string(output, "reporting_entity_name", entity_name, first: true)
      write_root_string(output, "reporting_entity_type", "health insurance issuer")
      write_root_string(output, "last_updated_on", "2026-08-22")
      write_root_string(output, "version", "2.2.1")
      write_boundary_field(output) if config.profile.unicode_boundary?

      if config.field_order.providers_first?
        write_provider_field(output, providers)
        write_in_network_field(output, providers)
      else
        write_in_network_field(output, providers)
        write_provider_field(output, providers)
      end

      write_padding_and_close(output)
      unless output.bytes_written == config.bytes
        raise "generated #{output.bytes_written} bytes, expected #{config.bytes}"
      end

      projection_sha256 = @projection.hexfinal
      document_sha256 = output.hexfinal
      GenerationResult.new(
        config,
        document_sha256,
        @root_key_order,
        @counts,
        MAXIMUM_NESTING,
        output.largest_token,
        output.largest_item,
        @unicode_splits,
        projection_sha256,
        @projection_checksum.hex
      )
    end

    private def write_root_string(output : TrackedOutput, key : String,
                                  value : String, *, first = false) : Nil
      output.write_raw(",") unless first
      output.write_json_string(key, "/#{key}", "key")
      output.write_raw(":")
      output.write_json_string(value, "/#{key}")
      @root_key_order << key
    end

    private def write_provider_field(output : TrackedOutput, providers : Fragment) : Nil
      output.write_raw(",")
      output.write_json_string("provider_references", "/provider_references", "key")
      output.write_raw(":")
      output.write_fragment(providers)
      @root_key_order << "provider_references"
    end

    private def write_in_network_field(output : TrackedOutput, providers : Fragment) : Nil
      output.write_raw(",")
      output.write_json_string("in_network", "/in_network", "key")
      output.write_raw(":[")
      @root_key_order << "in_network"

      if config.profile.wide_item?
        write_wide_item(output, providers)
      else
        write_small_items(output, providers)
      end
      output.write_raw("]")
    end

    private def write_small_items(output : TrackedOutput, providers : Fragment) : Nil
      sample = small_item(0_i64, 0_i64)
      available = config.bytes - output.bytes_written - root_tail_bytes(providers)
      count = repeated_count(available, sample.fragment.source.bytesize.to_i64)
      if count < 1
        raise ArgumentError.new("requested size is too small for #{config.profile.cli_name}; minimum is #{config.bytes - available + sample.fragment.source.bytesize}")
      end

      index = 0_i64
      while index < count
        generated = index == 0 ? sample : small_item(index, index)
        unless generated.fragment.source.bytesize == sample.fragment.source.bytesize
          raise "profile #{config.profile.cli_name} produced a variable-width item"
        end
        output.write_raw(",") unless index == 0
        output.write_fragment(generated.fragment)
        @projection.add(generated.row)
        @projection_checksum.add(generated.row)
        index += 1
      end

      @counts.in_network = count
      @counts.negotiated_rates = count
      @counts.negotiated_prices = count
    end

    private def write_wide_item(output : TrackedOutput, providers : Fragment) : Nil
      item_start = output.bytes_written
      metadata = item_metadata(0_i64)
      output.write_raw("{")
      field_string(output, "negotiation_arrangement", metadata[:arrangement], "/in_network/*", first: true)
      field_string(output, "name", metadata[:name], "/in_network/*")
      field_string(output, "billing_code_type", metadata[:code_type], "/in_network/*")
      field_string(output, "billing_code_type_version", "2026", "/in_network/*")
      field_string(output, "billing_code", metadata[:billing_code], "/in_network/*")
      field_string(output, "description", metadata[:description], "/in_network/*")
      field_prefix(output, "negotiated_rates", "/in_network/*")
      output.write_raw("[{")
      field_prefix(output, "provider_references", "/in_network/*/negotiated_rates/*", first: true)
      output.write_raw("[")
      output.write_number(metadata[:provider_group_id].to_s, "/in_network/*/negotiated_rates/*/provider_references/*")
      output.write_raw("]")
      field_prefix(output, "negotiated_prices", "/in_network/*/negotiated_rates/*")
      output.write_raw("[")

      sample = price(0_i64, 0_i64, metadata)
      outer_suffix = "]}]}"
      available = config.bytes - output.bytes_written -
                  outer_suffix.bytesize - root_tail_bytes(providers)
      price_count = repeated_count(available, sample.fragment.source.bytesize.to_i64)
      if price_count < 1
        raise ArgumentError.new("requested size is too small for wide-item")
      end

      price_index = 0_i64
      while price_index < price_count
        generated = price_index == 0 ? sample : price(price_index, price_index, metadata)
        unless generated.fragment.source.bytesize == sample.fragment.source.bytesize
          raise "wide-item produced a variable-width price"
        end
        output.write_raw(",") unless price_index == 0
        output.write_fragment(generated.fragment)
        @projection.add(generated.row)
        @projection_checksum.add(generated.row)
        price_index += 1
      end

      output.write_raw(outer_suffix)
      output.note_item(item_start, "/in_network/*")
      @counts.in_network = 1_i64
      @counts.negotiated_rates = 1_i64
      @counts.negotiated_prices = price_count
    end

    private def write_padding_and_close(output : TrackedOutput) : Nil
      output.write_raw(",")
      output.write_json_string(PAD_KEY, "/#{PAD_KEY}", "key")
      output.write_raw(":")
      padding_bytes = config.bytes - output.bytes_written - 3
      if padding_bytes < 0
        raise ArgumentError.new("requested size is too small for #{config.profile.cli_name}")
      end
      output.write_repeated_string(padding_bytes, "/#{PAD_KEY}")
      output.write_raw("}")
      @root_key_order << PAD_KEY
    end

    private def root_tail_bytes(providers : Fragment) : Int64
      bytes = 1_i64 # closing in_network array
      if config.field_order.rates_first?
        bytes += 1 + "provider_references".to_json.bytesize + 1 + providers.source.bytesize
      end
      bytes + 1 + PAD_KEY.to_json.bytesize + 1 + 2 + 1
    end

    private def repeated_count(available : Int64, item_bytes : Int64) : Int64
      return 0_i64 if available < item_bytes
      (available + 1) // (item_bytes + 1)
    end

    private def write_boundary_field(output : TrackedOutput) : Nil
      key = "_fixture_unicode_boundary"
      output.write_raw(",")
      output.write_json_string(key, "/#{key}", "key")
      output.write_raw(":")
      token_start = output.bytes_written
      output.write_raw("\"")

      write_split_codepoint(output, "λ", "U+03BB", 1)
      write_split_codepoint(output, "界", "U+754C", 2)
      write_split_codepoint(output, "𝄞", "U+1D11E", 3)

      output.write_raw("\\u03bb\\uD834\\uDD1E")
      output.write_raw("\"")
      output.note_token(output.bytes_written - token_start, "/#{key}", "string")
      @root_key_order << key
    end

    private def write_split_codepoint(output : TrackedOutput, value : String,
                                      codepoint : String, split_after : Int32) : Nil
      boundary_size = config.boundary_bytes.to_i64
      next_boundary = ((output.bytes_written // boundary_size) + 1) * boundary_size
      start_byte = next_boundary - split_after
      output.write_repeated_string_contents(start_byte - output.bytes_written)
      output.write_raw(value)
      @unicode_splits << UnicodeSplit.new(
        "/_fixture_unicode_boundary",
        codepoint,
        start_byte,
        next_boundary
      )
    end

    private def provider_array : Fragment
      result = fragment do |output|
        output.write_raw("[")
        index = 0_i64
        while index < PROVIDER_COUNT
          output.write_raw(",") unless index == 0
          item_start = output.bytes_written
          provider_group_id = 10_000_000_i64 + index
          npi = 1_000_000_000_i64 + (stable_value(0x70_u64, index) % 9_000_000_000_u64).to_i64
          tin = sprintf("%09d", stable_value(0x71_u64, index) % 1_000_000_000_u64)

          output.write_raw("{")
          field_number(output, "provider_group_id", provider_group_id.to_s, "/provider_references/*", first: true)
          field_prefix(output, "provider_groups", "/provider_references/*")
          output.write_raw("[{")
          field_prefix(output, "npi", "/provider_references/*/provider_groups/*", first: true)
          output.write_raw("[")
          output.write_number(npi.to_s, "/provider_references/*/provider_groups/*/npi/*")
          output.write_raw("]")
          field_prefix(output, "tin", "/provider_references/*/provider_groups/*")
          output.write_raw("{")
          field_string(output, "type", "ein", "/provider_references/*/provider_groups/*/tin", first: true)
          field_string(output, "value", tin, "/provider_references/*/provider_groups/*/tin")
          output.write_raw("}}]}")
          output.note_item(item_start, "/provider_references/*")
          index += 1
        end
        output.write_raw("]")
      end
      @counts.provider_references = PROVIDER_COUNT
      @counts.provider_groups = PROVIDER_COUNT
      result
    end

    private def small_item(item_index : Int64, sequence : Int64) : GeneratedItem
      metadata = item_metadata(item_index)
      generated_price = price(sequence, 0_i64, metadata)
      result = fragment do |output|
        item_start = output.bytes_written
        output.write_raw("{")
        field_string(output, "negotiation_arrangement", metadata[:arrangement], "/in_network/*", first: true)
        field_string(output, "name", metadata[:name], "/in_network/*")
        field_string(output, "billing_code_type", metadata[:code_type], "/in_network/*")
        field_string(output, "billing_code_type_version", "2026", "/in_network/*")
        field_string(output, "billing_code", metadata[:billing_code], "/in_network/*")
        field_string(output, "description", metadata[:description], "/in_network/*")
        write_ignored_payload(output, item_index) if config.profile.skip_heavy?
        field_prefix(output, "negotiated_rates", "/in_network/*")
        output.write_raw("[{")
        field_prefix(output, "provider_references", "/in_network/*/negotiated_rates/*", first: true)
        output.write_raw("[")
        output.write_number(metadata[:provider_group_id].to_s, "/in_network/*/negotiated_rates/*/provider_references/*")
        output.write_raw("]")
        field_prefix(output, "negotiated_prices", "/in_network/*/negotiated_rates/*")
        output.write_raw("[")
        output.write_fragment(generated_price.fragment)
        output.write_raw("]}]}")
        output.note_item(item_start, "/in_network/*")
      end
      GeneratedItem.new(result, generated_price.row)
    end

    private def price(sequence : Int64, price_index : Int64, metadata) : GeneratedPrice
      random = stable_value(0x50_u64, sequence)
      whole = 10_000_i64 + (random % 90_000_u64).to_i64
      fraction = {0_i64, 25_i64, 50_i64, 75_i64}[(random >> 17) % 4]
      rate = sprintf("%05d.%02d", whole, fraction)
      cents = whole * 100 + fraction
      service_code = sprintf("%02d", (random >> 23) % 100)
      result = fragment do |output|
        item_start = output.bytes_written
        output.write_raw("{")
        field_string(output, "negotiated_type", "negotiated", "/in_network/*/negotiated_rates/*/negotiated_prices/*", first: true)
        field_number(output, "negotiated_rate", rate, "/in_network/*/negotiated_rates/*/negotiated_prices/*")
        field_string(output, "expiration_date", "2027-12-31", "/in_network/*/negotiated_rates/*/negotiated_prices/*")
        field_string(output, "billing_class", "professional", "/in_network/*/negotiated_rates/*/negotiated_prices/*")
        field_prefix(output, "service_code", "/in_network/*/negotiated_rates/*/negotiated_prices/*")
        output.write_raw("[")
        output.write_json_string(service_code, "/in_network/*/negotiated_rates/*/negotiated_prices/*/service_code/*")
        output.write_raw("]}")
        output.note_item(item_start, "/in_network/*/negotiated_rates/*/negotiated_prices/*")
      end
      row = ProjectionRow.new(
        sequence,
        metadata[:item_index],
        price_index,
        metadata[:billing_code],
        metadata[:name],
        metadata[:code_type],
        metadata[:arrangement],
        metadata[:description],
        metadata[:provider_group_id],
        "negotiated",
        cents,
        "professional",
        service_code
      )
      GeneratedPrice.new(result, row)
    end

    private def item_metadata(item_index : Int64)
      value = stable_value(0x40_u64, item_index)
      description = if config.profile.unicode_boundary?
                      sprintf("München-λ-𝄞-%016x", value)
                    else
                      sprintf("generated-service-%016x", value)
                    end
      {
        item_index:        item_index,
        arrangement:       "ffs",
        name:              sprintf("service-%016x", stable_value(0x41_u64, item_index)),
        code_type:         "CPT",
        billing_code:      sprintf("%05d", stable_value(0x42_u64, item_index) % 100_000_u64),
        description:       description,
        provider_group_id: 10_000_000_i64 + (stable_value(0x43_u64, item_index) % PROVIDER_COUNT.to_u64).to_i64,
      }
    end

    private def write_ignored_payload(output : TrackedOutput, item_index : Int64) : Nil
      field_prefix(output, "_fixture_ignored", "/in_network/*")
      output.write_raw("{")
      field_prefix(output, "claims", "/in_network/*/_fixture_ignored", first: true)
      output.write_raw("[")
      ignored = 0_i32
      while ignored < 48
        output.write_raw(",") unless ignored == 0
        output.write_raw("{")
        value = stable_value(0x60_u64 + ignored.to_u64, item_index)
        field_string(output, "trace", sprintf("%016x", value), "/in_network/*/_fixture_ignored/claims/*", first: true)
        claim_path = "/in_network/*/_fixture_ignored/claims/*"
        field_prefix(output, "codes", claim_path)
        output.write_raw("[")
        {"AA", "BB", "CC"}.each_with_index do |code, code_index|
          output.write_raw(",") unless code_index == 0
          output.write_json_string(code, "#{claim_path}/codes/*")
        end
        output.write_raw("]")
        field_prefix(output, "flags", claim_path)
        output.write_raw("{")
        field_bool(output, "active", true, "#{claim_path}/flags", first: true)
        field_bool(output, "manual", false, "#{claim_path}/flags")
        output.write_raw("}")
        field_number(
          output,
          "amount",
          (10_000_u64 + value % 90_000_u64).to_s,
          "/in_network/*/_fixture_ignored/claims/*"
        )
        output.write_raw("}")
        ignored += 1
      end
      output.write_raw("]}")
    end

    private def field_prefix(output : TrackedOutput, key : String,
                             path : String, *, first = false) : Nil
      output.write_raw(",") unless first
      output.write_json_string(key, "#{path}/#{key}", "key")
      output.write_raw(":")
    end

    private def field_string(output : TrackedOutput, key : String,
                             value : String, path : String, *, first = false) : Nil
      field_prefix(output, key, path, first: first)
      output.write_json_string(value, "#{path}/#{key}")
    end

    private def field_number(output : TrackedOutput, key : String,
                             value : String, path : String, *, first = false) : Nil
      field_prefix(output, key, path, first: first)
      output.write_number(value, "#{path}/#{key}")
    end

    private def field_bool(output : TrackedOutput, key : String,
                           value : Bool, path : String, *, first = false) : Nil
      field_prefix(output, key, path, first: first)
      output.write_raw(value ? "true" : "false")
    end

    private def fragment(& : TrackedOutput ->) : Fragment
      memory = IO::Memory.new
      output = TrackedOutput.new(memory, digest: false)
      yield output
      Fragment.new(memory.to_s, output.largest_token, output.largest_item)
    end

    private def stable_value(section : UInt64, index : Int64) : UInt64
      value = config.seed &+ (section &* 0x9e3779b97f4a7c15_u64) &+
              (index.to_u64 &* 0xbf58476d1ce4e5b9_u64)
      value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9_u64
      value = (value ^ (value >> 27)) &* 0x94d049bb133111eb_u64
      value ^ (value >> 31)
    end

    private def entity_name : String
      sprintf("FusedJSON fixture %016x", stable_value(0x10_u64, 0_i64))
    end
  end

  class TrackedOutput
    # Writes ASCII string contents without opening or closing quotes.
    def write_repeated_string_contents(count : Int64) : Nil
      raise ArgumentError.new("negative repeated string size") if count < 0
      remaining = count
      while remaining > 0
        amount = Math.min(remaining, PADDING_CHUNK.bytesize.to_i64).to_i32
        write_raw(PADDING_CHUNK.byte_slice(0, amount))
        remaining -= amount
      end
    end
  end
end

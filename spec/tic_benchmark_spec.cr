require "./spec_helper"
require "../bench/tic_fixture_generator"
require "../bench/tic_workload"

private class TICCountingDiscardIO < IO
  getter bytes_written : Int64
  getter largest_write : Int32
  getter write_calls : Int64

  def initialize
    @bytes_written = 0_i64
    @largest_write = 0
    @write_calls = 0_i64
  end

  def read(slice : Bytes) : NoReturn
    raise IO::Error.new("counting output is write-only")
  end

  def write(slice : Bytes) : Nil
    @bytes_written += slice.size
    @largest_write = Math.max(@largest_write, slice.size)
    @write_calls += 1
  end
end

private class TICLocationTrapPullParser < JSON::PullParser
  def location : Tuple(Int32, Int32)
    raise "benchmark traversal used the 32-bit location API"
  end
end

module TICBench
  def self.structural_traversal_for_spec(pull : JSON::PullParser) : TraversalResult
    traverse(pull, Time.instant, NormalizedTraversalProjection.new(true))
  end

  def self.typed_traversal_for_spec(pull : JSON::PullParser) : TypedTraversalResult
    started = Time.instant
    projection = NormalizedTraversalProjection.new(true)
    stats = TypedTraversalStats.new
    counts, first_item_seconds = traverse_typed(
      pull,
      started,
      projection,
      stats,
      TypedSelection::Both
    )
    typed_result(projection, counts, first_item_seconds, stats, 1, [0.0])
  end
end

private def generate_tic_memory(profile : TICBench::FixtureProfile,
                                order : TICBench::FieldOrder,
                                bytes = 64 * 1024_i64,
                                seed = 7_u64,
                                boundary = 1024)
  io = IO::Memory.new
  config = TICBench::FixtureConfig.new(profile, bytes, seed, order, boundary)
  result = TICBench::FixtureGenerator.new(config).generate(io)
  {io.to_s, result}
end

private def with_tic_file(profile : TICBench::FixtureProfile,
                          order : TICBench::FieldOrder,
                          bytes = 64 * 1024_i64,
                          seed = 7_u64,
                          boundary = 1024, &)
  file = File.tempfile("fused-json-tic-", ".json")
  begin
    config = TICBench::FixtureConfig.new(profile, bytes, seed, order, boundary)
    result = TICBench::FixtureGenerator.new(config).generate(file)
    file.flush
    file.close
    yield file.path, result
  ensure
    file.delete
  end
end

private def altered_manifest(manifest : TICBench::Manifest, &)
  value = JSON.parse(manifest.to_json)
  yield value.as_h
  TICBench::Manifest.from_json(value.to_json)
end

describe "TiC benchmark fixtures" do
  it "defines the canonical projection as versioned fixed-order JSON Lines" do
    row = TICBench::ProjectionRow.new(
      0_i64,
      2_i64,
      3_i64,
      "01234",
      "quoted \"name\"",
      "CPT",
      "ffs",
      "München λ",
      10_000_001_i64,
      "negotiated",
      12_345_i64,
      "professional",
      "01"
    )
    line = %({"v":1,"sequence":0,"item_index":2,"price_index":3,"billing_code":"01234","name":"quoted \\"name\\"","code_type":"CPT","arrangement":"ffs","description":"München λ","provider_group_id":10000001,"negotiated_type":"negotiated","negotiated_rate_cents":12345,"billing_class":"professional","service_code":"01"}\n)
    projection = TICBench::ProjectionDigest.new
    projection.add(row)
    projection.lines.should eq(1)
    projection.hexfinal.should eq(Digest::SHA256.hexdigest(line))
  end

  it "keeps the normalized v1 checksum stable and versions raw number spelling" do
    row = TICBench::ProjectionRow.new(
      0_i64,
      2_i64,
      3_i64,
      "01234",
      "quoted \"name\"",
      "CPT",
      "ffs",
      "München λ",
      10_000_001_i64,
      "negotiated",
      12_345_i64,
      "professional",
      "01"
    )
    normalized = TICBench::ProjectionChecksum.new
    normalized.add(row)
    normalized.hex.should eq("0xfd57530e2d877c80")
    TICBench::PROJECTION_CHECKSUM_ALGORITHM.should eq("fnv1a64-fields-v1")

    raw = TICBench::RawNumberProjectionRow.new(
      0_i64,
      2_i64,
      3_i64,
      "01234",
      "quoted \"name\"",
      "CPT",
      "ffs",
      "München λ",
      10_000_001_i64,
      "negotiated",
      "123.4500",
      "professional",
      "01"
    )
    raw_checksum = TICBench::RawNumberProjectionChecksum.new
    raw_checksum.add(raw)
    raw_checksum.hex.should eq("0x5a98b99012bf63a1")
    TICBench::RAW_NUMBER_CHECKSUM_ALGORITHM.should eq("fnv1a64-fields-raw-number-v2")

    alternate_spelling = raw.copy_with(negotiated_rate: "1.234500e2")
    alternate_checksum = TICBench::RawNumberProjectionChecksum.new
    alternate_checksum.add(alternate_spelling)
    alternate_checksum.hex.should_not eq(raw_checksum.hex)
  end

  it "is deterministic and keeps the semantic digest independent of root order" do
    first_source, first = generate_tic_memory(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    )
    repeated_source, repeated = generate_tic_memory(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    )
    reordered_source, reordered = generate_tic_memory(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::RatesFirst
    )
    changed_source, changed = generate_tic_memory(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst,
      seed: 8_u64
    )

    first_source.should eq(repeated_source)
    first.document_sha256.should eq(repeated.document_sha256)
    first.projection_sha256.should eq(repeated.projection_sha256)
    reordered_source.should_not eq(first_source)
    reordered.document_sha256.should_not eq(first.document_sha256)
    reordered.projection_sha256.should eq(first.projection_sha256)
    reordered.counts.should eq(first.counts)
    changed_source.should_not eq(first_source)
    changed.document_sha256.should_not eq(first.document_sha256)
    changed.projection_sha256.should_not eq(first.projection_sha256)
  end

  it "parses both root-field orders through both pull baselines" do
    results = {} of TICBench::FieldOrder => Tuple(TICBench::TraversalResult, TICBench::TraversalResult)
    raw_results = {} of TICBench::FieldOrder => Tuple(TICBench::RawNumberTraversalResult, TICBench::RawNumberTraversalResult)

    {TICBench::FieldOrder::ProvidersFirst, TICBench::FieldOrder::RatesFirst}.each do |order|
      with_tic_file(TICBench::FixtureProfile::ManySmall, order) do |path, generated|
        manifest = generated.manifest
        provider_position = manifest.root_key_order.index!("provider_references")
        rates_position = manifest.root_key_order.index!("in_network")
        if order.providers_first?
          provider_position.should be < rates_position
        else
          rates_position.should be < provider_position
        end

        fused = TICBench.fused_pull(path, 1024)
        crystal = TICBench.crystal_pull(path, 1024)
        TICBench.verify_result(fused, manifest, "FusedJSON")
        TICBench.verify_result(crystal, manifest, "Crystal")
        fused.counts.should eq(crystal.counts)
        fused.projection_sha256.should eq(crystal.projection_sha256)
        fused.projection_checksum.should eq(crystal.projection_checksum)
        results[order] = {fused, crystal}

        fused_raw = TICBench.fused_raw_number_pull(path, 1024)
        crystal_raw = TICBench.crystal_raw_number_pull(path, 1024)
        TICBench.verify_raw_number_result(fused_raw, manifest, "FusedJSON")
        TICBench.verify_raw_number_result(crystal_raw, manifest, "Crystal")
        fused_raw.counts.should eq(crystal_raw.counts)
        fused_raw.raw_number_checksum.should eq(crystal_raw.raw_number_checksum)
        raw_results[order] = {fused_raw, crystal_raw}
      end
    end

    providers_first = results[TICBench::FieldOrder::ProvidersFirst]
    rates_first = results[TICBench::FieldOrder::RatesFirst]
    providers_first[0].counts.should eq(rates_first[0].counts)
    providers_first[0].projection_sha256.should eq(rates_first[0].projection_sha256)
    providers_first[0].projection_checksum.should eq(rates_first[0].projection_checksum)

    providers_first_raw = raw_results[TICBench::FieldOrder::ProvidersFirst]
    rates_first_raw = raw_results[TICBench::FieldOrder::RatesFirst]
    providers_first_raw[0].counts.should eq(rates_first_raw[0].counts)
    providers_first_raw[0].raw_number_checksum.should eq(rates_first_raw[0].raw_number_checksum)
  end

  it "decodes typed values in one and two passes for both root-field orders" do
    {TICBench::FieldOrder::ProvidersFirst, TICBench::FieldOrder::RatesFirst}.each do |order|
      with_tic_file(TICBench::FixtureProfile::ManySmall, order) do |path, generated|
        manifest = generated.manifest
        fused = TICBench.fused_typed_pull(path, 1024)
        crystal = TICBench.crystal_typed_pull(path, 1024)
        fused_two_pass = TICBench.fused_two_pass_typed_pull(path, 1024)
        crystal_two_pass = TICBench.crystal_two_pass_typed_pull(path, 1024)

        {
          "FusedJSON typed"          => fused,
          "Crystal typed"            => crystal,
          "FusedJSON typed two-pass" => fused_two_pass,
          "Crystal typed two-pass"   => crystal_two_pass,
        }.each do |label, result|
          TICBench.verify_typed_result(result, manifest, label)
          result.provider_records.should eq(manifest.counts.provider_references)
          result.price_records.should eq(manifest.counts.negotiated_prices)
          result.scalar_values.should eq(manifest.counts.negotiated_rates)
          result.typed_records.should eq(result.provider_records + result.price_records)
          result.typed_values.should eq(result.typed_records + result.scalar_values)
        end

        fused.input_passes.should eq(1)
        crystal.input_passes.should eq(1)
        fused_two_pass.input_passes.should eq(2)
        crystal_two_pass.input_passes.should eq(2)
        fused_two_pass.pass_wall_seconds.size.should eq(2)
        crystal_two_pass.pass_wall_seconds.size.should eq(2)

        fused.provider_checksum.should eq(crystal.provider_checksum)
        fused.provider_checksum.should eq(fused_two_pass.provider_checksum)
        fused.provider_checksum.should eq(crystal_two_pass.provider_checksum)
        fused.traversal.projection_sha256.should eq(crystal.traversal.projection_sha256)
        fused.traversal.projection_sha256.should eq(fused_two_pass.traversal.projection_sha256)
        fused.traversal.projection_sha256.should eq(crystal_two_pass.traversal.projection_sha256)
      end
    end
  end

  it "retains every selected typed value only in retained-output mode" do
    with_tic_file(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    ) do |path, generated|
      manifest = generated.manifest
      ordinary = TICBench.fused_typed_pull(path, 1024)
      fused = TICBench.fused_typed_pull(path, 1024, retain_output: true)
      crystal = TICBench.crystal_typed_pull(path, 1024, retain_output: true)

      ordinary.retained_output.should be_nil
      {"retained FusedJSON" => fused, "retained Crystal" => crystal}.each do |label, result|
        TICBench.verify_typed_result(result, manifest, label)
        retained = result.retained_output.should_not be_nil
        retained.provider_records.size.should eq(result.provider_records)
        retained.scalar_values.size.should eq(result.scalar_values)
        retained.price_records.size.should eq(result.price_records)
        retained.total_values.should eq(result.typed_values)
      end
      fused_retained = fused.retained_output.should_not be_nil
      crystal_retained = crystal.retained_output.should_not be_nil
      fused_retained.provider_records.should eq(crystal_retained.provider_records)
      fused_retained.scalar_values.should eq(crystal_retained.scalar_values)
      fused_retained.price_records.should eq(crystal_retained.price_records)
      fused.traversal.projection_sha256.should eq(crystal.traversal.projection_sha256)
      fused.provider_checksum.should eq(crystal.provider_checksum)
    end
  end

  it "does not use Crystal's 32-bit object location convenience path" do
    source, generated = generate_tic_memory(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    )
    manifest = generated.manifest

    structural = TICBench.structural_traversal_for_spec(TICLocationTrapPullParser.new(source))
    typed = TICBench.typed_traversal_for_spec(TICLocationTrapPullParser.new(source))

    TICBench.verify_result(structural, manifest, "location-neutral Crystal")
    TICBench.verify_typed_result(typed, manifest, "location-neutral typed Crystal")
  end

  it "keeps wide outer items structural while decoding nested typed prices" do
    with_tic_file(
      TICBench::FixtureProfile::WideItem,
      TICBench::FieldOrder::RatesFirst,
      128 * 1024_i64
    ) do |path, generated|
      manifest = generated.manifest
      fused = TICBench.fused_typed_pull(path, 1024, strong_digest: false)
      crystal = TICBench.crystal_typed_pull(path, 1024, strong_digest: false)

      TICBench.verify_typed_result(fused, manifest, "FusedJSON typed", require_strong: false)
      TICBench.verify_typed_result(crystal, manifest, "Crystal typed", require_strong: false)
      fused.traversal.projection_sha256.should be_nil
      crystal.traversal.projection_sha256.should be_nil
      fused.traversal.counts.in_network.should eq(1)
      fused.price_records.should be > 100
      fused.provider_checksum.should eq(crystal.provider_checksum)
      fused.traversal.projection_checksum.should eq(crystal.traversal.projection_checksum)
    end
  end

  it "parses gzip typed inputs completely and rejects corrupt trailers" do
    with_tic_file(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    ) do |path, generated|
      gzip = File.tempfile("fused-json-tic-typed-", ".json.gz")
      begin
        gzip.close
        TICBench.gzip_fixture(path, gzip.path)
        manifest = generated.manifest

        fused = TICBench.fused_gzip_typed_pull(gzip.path, 1024)
        crystal = TICBench.crystal_gzip_typed_pull(gzip.path, 1024)
        TICBench.verify_typed_result(fused, manifest, "gzip FusedJSON")
        TICBench.verify_typed_result(crystal, manifest, "gzip Crystal")
        fused.provider_checksum.should eq(crystal.provider_checksum)
        fused.traversal.projection_sha256.should eq(crystal.traversal.projection_sha256)

        File.open(gzip.path, "r+") do |file|
          file.seek(-8, IO::Seek::End)
          byte = file.read_byte || raise "gzip trailer is missing"
          file.seek(-1, IO::Seek::Current)
          file.write_byte(byte ^ 0xff_u8)
        end
        expect_raises(Compress::Gzip::Error) do
          TICBench.fused_gzip_typed_pull(gzip.path, 1024)
        end
        expect_raises(Compress::Gzip::Error) do
          TICBench.crystal_gzip_typed_pull(gzip.path, 1024)
        end
      ensure
        gzip.delete
      end
    end
  end

  it "generates and verifies every bounded-memory profile" do
    cases = [
      {TICBench::FixtureProfile::ManySmall, TICBench::FieldOrder::ProvidersFirst, 64 * 1024_i64},
      {TICBench::FixtureProfile::WideItem, TICBench::FieldOrder::RatesFirst, 64 * 1024_i64},
      {TICBench::FixtureProfile::SkipHeavy, TICBench::FieldOrder::ProvidersFirst, 128 * 1024_i64},
      {TICBench::FixtureProfile::UnicodeBoundary, TICBench::FieldOrder::RatesFirst, 64 * 1024_i64},
    ]

    cases.each do |profile, order, bytes|
      with_tic_file(profile, order, bytes) do |path, result|
        File.size(path).should eq(bytes)
        TICBench.file_sha256(path).should eq(result.document_sha256)
        manifest = result.manifest
        manifest.validate!

        fused = TICBench.fused_pull(path, 1024)
        crystal = TICBench.crystal_pull(path, 1024)
        TICBench.verify_result(fused, manifest, "FusedJSON")
        TICBench.verify_result(crystal, manifest, "Crystal")
        fused.counts.should eq(crystal.counts)
        fused.projection_sha256.should eq(crystal.projection_sha256)

        fused_raw = TICBench.fused_raw_number_pull(path, 1024)
        crystal_raw = TICBench.crystal_raw_number_pull(path, 1024)
        TICBench.verify_raw_number_result(fused_raw, manifest, "FusedJSON")
        TICBench.verify_raw_number_result(crystal_raw, manifest, "Crystal")
        fused_raw.raw_number_checksum.should eq(crystal_raw.raw_number_checksum)

        fused_typed = TICBench.fused_typed_pull(path, 1024)
        crystal_typed = TICBench.crystal_typed_pull(path, 1024)
        TICBench.verify_typed_result(fused_typed, manifest, "typed FusedJSON")
        TICBench.verify_typed_result(crystal_typed, manifest, "typed Crystal")
        fused_typed.traversal.counts.should eq(crystal_typed.traversal.counts)
        fused_typed.traversal.projection_sha256.should eq(crystal_typed.traversal.projection_sha256)
        fused_typed.provider_checksum.should eq(crystal_typed.provider_checksum)

        if profile.wide_item?
          result.counts.in_network.should eq(1)
          result.largest_item.bytes.should be > bytes // 2
        elsif profile.skip_heavy?
          result.largest_item.bytes.should be > 4_000
          result.largest_token.bytes.should be < result.largest_item.bytes
        elsif profile.unicode_boundary?
          result.unicode_splits.size.should eq(3)
          result.unicode_splits.each do |split|
            split.boundary_byte.divisible_by?(1024).should be_true
            split.start_byte.should be < split.boundary_byte
          end
        end
      end
    end
  end

  it "places raw Unicode codepoints across configured input boundaries" do
    source, result = generate_tic_memory(
      TICBench::FixtureProfile::UnicodeBoundary,
      TICBench::FieldOrder::RatesFirst,
      boundary: 1024
    )
    expected = [
      {"U+03BB", "λ".to_slice, 1_i64},
      {"U+754C", "界".to_slice, 2_i64},
      {"U+1D11E", "𝄞".to_slice, 3_i64},
    ]

    result.unicode_splits.zip(expected).each do |split, expected_split|
      codepoint, bytes, distance = expected_split
      split.codepoint.should eq(codepoint)
      split.boundary_byte.divisible_by?(1024).should be_true
      (split.boundary_byte - split.start_byte).should eq(distance)
      source.to_slice[split.start_byte.to_i, bytes.size].should eq(bytes)
      split.start_byte.should be < split.boundary_byte
      (split.start_byte + bytes.size).should be > split.boundary_byte
    end
    source.should contain(%(\\u03bb\\uD834\\uDD1E))
  end

  it "honors odd exact sizes and rejects fixtures below the minimum" do
    odd_size = 65_537_i64
    source, result = generate_tic_memory(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst,
      bytes: odd_size
    )
    source.bytesize.should eq(odd_size)
    result.config.bytes.should eq(odd_size)
    result.manifest.decompressed_bytes.should eq(odd_size)

    expect_raises(ArgumentError) do
      generate_tic_memory(
        TICBench::FixtureProfile::ManySmall,
        TICBench::FieldOrder::ProvidersFirst,
        bytes: 1_i64
      )
    end
  end

  it "round-trips manifests and rejects malformed receipt fields" do
    _, result = generate_tic_memory(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    )
    manifest = result.manifest
    round_trip = TICBench::Manifest.from_json(manifest.to_json)
    round_trip.validate!
    round_trip.to_json.should eq(manifest.to_json)
    round_trip.projection.raw_number_checksum_algorithm.should eq(TICBench::RAW_NUMBER_CHECKSUM_ALGORITHM)
    round_trip.projection.raw_number_checksum.should eq(result.raw_number_checksum)

    bad_digest = altered_manifest(manifest) do |root|
      root["document_sha256"] = JSON::Any.new("g" * 64)
    end
    expect_raises(ArgumentError, "document_sha256 is not a lowercase SHA-256 digest") do
      bad_digest.validate!
    end

    bad_lines = altered_manifest(manifest) do |root|
      root["projection"].as_h["lines"] = JSON::Any.new(0_i64)
    end
    expect_raises(ArgumentError, "projection line count does not match negotiated price count") do
      bad_lines.validate!
    end

    bad_checksum = altered_manifest(manifest) do |root|
      root["projection"].as_h["checksum"] = JSON::Any.new("0xnot-a-checksum")
    end
    expect_raises(ArgumentError, "unsupported fixture projection checksum") do
      bad_checksum.validate!
    end

    bad_raw_checksum = altered_manifest(manifest) do |root|
      root["projection"].as_h["raw_number_checksum"] = JSON::Any.new("0xnot-a-checksum")
    end
    expect_raises(ArgumentError, "unsupported fixture raw-number checksum") do
      bad_raw_checksum.validate!
    end

    bad_raw_algorithm = altered_manifest(manifest) do |root|
      root["projection"].as_h["raw_number_checksum_algorithm"] = JSON::Any.new("fnv1a64-fields-v1")
    end
    expect_raises(ArgumentError, "unsupported fixture raw-number checksum") do
      bad_raw_algorithm.validate!
    end

    milestone_one_manifest = altered_manifest(manifest) do |root|
      projection = root["projection"].as_h
      projection.delete("raw_number_checksum_algorithm")
      projection.delete("raw_number_checksum")
    end
    milestone_one_manifest.validate!
    milestone_one_manifest.projection.raw_number_checksum_algorithm.should be_nil
    milestone_one_manifest.projection.raw_number_checksum.should be_nil

    missing_root_array = altered_manifest(manifest) do |root|
      root["root_key_order"] = JSON::Any.new([JSON::Any.new("in_network")])
    end
    expect_raises(ArgumentError, "root_key_order must include both TiC arrays") do
      missing_root_array.validate!
    end
  end

  it "generates large fixtures without retaining the output document" do
    output = TICCountingDiscardIO.new
    bytes = 8_i64 * 1024 * 1024
    config = TICBench::FixtureConfig.new(
      TICBench::FixtureProfile::ManySmall,
      bytes,
      19_u64,
      TICBench::FieldOrder::ProvidersFirst,
      1024
    )
    result = TICBench::FixtureGenerator.new(config).generate(output)

    output.bytes_written.should eq(bytes)
    output.write_calls.should be > 1
    output.largest_write.should be <= 16 * 1024
    result.config.bytes.should eq(bytes)
    result.document_sha256.bytesize.should eq(64)
    result.counts.negotiated_prices.should be > 1
  end

  it "uses the lightweight projection checksum when strong digests are disabled" do
    with_tic_file(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    ) do |path, result|
      manifest = result.manifest
      fused = TICBench.fused_pull(path, 1024, strong_digest: false)
      crystal = TICBench.crystal_pull(path, 1024, strong_digest: false)

      fused.projection_sha256.should be_nil
      crystal.projection_sha256.should be_nil
      fused.projection_checksum.should eq(manifest.projection.checksum)
      crystal.projection_checksum.should eq(manifest.projection.checksum)
      fused.counts.should eq(crystal.counts)
      TICBench.verify_result(fused, manifest, "FusedJSON", require_strong: false)
      TICBench.verify_result(crystal, manifest, "Crystal", require_strong: false)
      expect_raises(Exception, "FusedJSON projection SHA-256 does not match the fixture manifest") do
        TICBench.verify_result(fused, manifest, "FusedJSON")
      end
    end
  end

  it "writes reproducible gzip output with fixed header metadata" do
    with_tic_file(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    ) do |path, result|
      first = File.tempfile("fused-json-tic-", ".json.gz")
      second = File.tempfile("fused-json-tic-", ".json.gz")
      begin
        first.close
        second.close
        first_metadata = TICBench.gzip_fixture(path, first.path)
        second_metadata = TICBench.gzip_fixture(path, second.path)

        first_metadata.sha256.should eq(second_metadata.sha256)
        first_metadata.bytes.should eq(second_metadata.bytes)
        first_metadata.level.should eq(TICBench::GZIP_LEVEL)
        first_metadata.modification_time.should eq(0)
        first_metadata.os.should eq(255_u8)
        first_metadata.zlib_version.should_not be_empty
        File.read(first.path).should eq(File.read(second.path))
        header = Bytes.new(10)
        File.open(first.path, &.read_fully(header))
        header.should eq(Bytes[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        TICBench.verify_gzip_fixture(
          first.path,
          result.config.bytes,
          result.document_sha256
        )
        result.manifest(first_metadata).validate!
      ensure
        first.delete
        second.delete
      end
    end
  end
  it "drains plain and gzip inputs completely and validates the gzip trailer" do
    with_tic_file(
      TICBench::FixtureProfile::ManySmall,
      TICBench::FieldOrder::ProvidersFirst
    ) do |path, result|
      gzip = File.tempfile("fused-json-tic-", ".json.gz")
      begin
        gzip.close
        TICBench.gzip_fixture(path, gzip.path)
        TICBench.plain_drain(path, 1024).bytes.should eq(result.config.bytes)
        TICBench.gzip_drain(gzip.path, 1024).bytes.should eq(result.config.bytes)

        File.open(gzip.path, "r+") do |file|
          file.seek(-8, IO::Seek::End)
          byte = file.read_byte || raise "gzip trailer is missing"
          file.seek(-1, IO::Seek::Current)
          file.write_byte(byte ^ 0xff_u8)
        end
        expect_raises(Compress::Gzip::Error) do
          TICBench.gzip_drain(gzip.path, 1024)
        end
      ensure
        gzip.delete
      end
    end
  end
end

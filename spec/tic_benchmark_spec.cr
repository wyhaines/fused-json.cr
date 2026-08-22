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
      end
    end

    providers_first = results[TICBench::FieldOrder::ProvidersFirst]
    rates_first = results[TICBench::FieldOrder::RatesFirst]
    providers_first[0].counts.should eq(rates_first[0].counts)
    providers_first[0].projection_sha256.should eq(rates_first[0].projection_sha256)
    providers_first[0].projection_checksum.should eq(rates_first[0].projection_checksum)
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

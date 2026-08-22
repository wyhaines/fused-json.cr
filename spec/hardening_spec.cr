require "./spec_helper"
require "./support/pull_helpers"

module HardeningHelpers
  extend self

  MUTATION_BYTES = [
    0x00_u8,
    0x09_u8,
    0x0a_u8,
    0x1f_u8,
    0x20_u8,
    0x22_u8,
    0x2c_u8,
    0x2d_u8,
    0x2e_u8,
    0x30_u8,
    0x3a_u8,
    0x5b_u8,
    0x5c_u8,
    0x5d_u8,
    0x65_u8,
    0x6e_u8,
    0x74_u8,
    0x7b_u8,
    0x7d_u8,
    0x7f_u8,
    0x80_u8,
    0xc0_u8,
    0xe0_u8,
    0xf0_u8,
    0xff_u8,
  ]

  def mutate(random : Random::PCG32, seed : String) : String
    bytes = seed.bytes
    replacement = MUTATION_BYTES[random.rand(MUTATION_BYTES.size)]

    case random.rand(4)
    when 0
      bytes.insert(random.rand(bytes.size + 1), replacement)
    when 1
      if bytes.empty?
        bytes << replacement
      else
        bytes[random.rand(bytes.size)] = replacement
      end
    when 2
      bytes.delete_at(random.rand(bytes.size)) unless bytes.empty?
    when 3
      bytes = bytes[0, random.rand(bytes.size + 1)]
    end

    String.new(bytes.to_unsafe, bytes.size)
  end
end

describe "FusedJSON parser hardening" do
  it "reports byte offsets and one-based Unicode locations" do
    source = "{\n  \"λ\": true,\n  \"𝄞\": ]\n}"

    error = expect_raises(FusedJSON::ParseError) do
      FusedJSON.load(source)
    end

    error.byte_offset.should eq(26)
    error.line_number.should eq(3)
    error.column_number.should eq(8)
  end

  it "reports an EOF location after multibyte codepoints" do
    source = %q({"λ":"𝄞")

    error = expect_raises(FusedJSON::ParseError) do
      FusedJSON.load(source)
    end

    error.byte_offset.should eq(source.bytesize)
    error.line_number.should eq(1)
    error.column_number.should eq(9)
  end

  it "locates an invalid UTF-8 continuation byte" do
    source = String.new(Bytes[0x22_u8, 0xe2_u8, 0x28_u8, 0xa1_u8, 0x22_u8])

    error = expect_raises(FusedJSON::ParseError) do
      FusedJSON.load(source)
    end

    error.byte_offset.should eq(2)
    error.line_number.should eq(1)
    error.column_number.should eq(3)
  end

  it "handles long numeric tokens without cursor or arithmetic leaks" do
    fraction = "1." + ("0" * 16_384)
    FusedJSON.load(fraction).should eq(JSON::Any.new(1.0))

    ["9" * 16_384, "1e" + ("9" * 16_384)].each do |source|
      expect_raises(FusedJSON::ParseError) do
        FusedJSON.load(source)
      end
    end

    incomplete = fraction + "e+"
    error = expect_raises(FusedJSON::ParseError) do
      FusedJSON.load(incomplete)
    end
    error.byte_offset.should eq(incomplete.bytesize)
  end

  it "rejects unsafe nesting limits before narrowing them to Int32" do
    [0, -1, 513, Int64::MAX, UInt64::MAX].each do |limit|
      expect_raises(ArgumentError, "max_nesting must be between 1 and 512") do
        FusedJSON.load("0", max_nesting: limit)
      end
    end
  end

  it "survives deterministic byte mutations without leaking internal exceptions" do
    random = Random::PCG32.new(0x51a7_e5af_u64)
    seeds = [
      %q({"name":"fused","values":[0,-1.25e+2,true,false,null]}),
      %q({"unicode":"λ𝄞","escaped":"\u03bb\n"}),
      %q([[[{"empty":[],"object":{}}]]]),
    ]

    2_000.times do |iteration|
      source = HardeningHelpers.mutate(random, seeds[random.rand(seeds.size)])

      begin
        FusedJSON.load(source, cache_keys: iteration.odd?)
      rescue _error : FusedJSON::ParseError
        # A mutation may be valid or invalid; only parser-internal exceptions
        # indicate a safety regression.
      rescue error
        raise "mutation #{iteration} leaked #{error.class}: #{error.message}; bytes=#{source.bytes}"
      end
    end
  end

  it "keeps pull building and skipping aligned on deterministic byte mutations" do
    random = Random::PCG32.new(0x51a7_e5af_u64)
    seeds = [
      %q({"name":"fused","values":[0,-1.25e+2,true,false,null]}),
      %q({"unicode":"λ𝄞","escaped":"\u03bb\n"}),
      %q([[[{"empty":[],"object":{}}]]]),
    ]

    2_000.times do |iteration|
      source = HardeningHelpers.mutate(random, seeds[random.rand(seeds.size)])

      dynamic_valid = false
      dynamic_value = JSON::Any.new(nil)
      begin
        dynamic_value = FusedJSON.load(source, cache_keys: iteration.odd?)
        dynamic_valid = true
      rescue _error : FusedJSON::ParseError
      rescue error
        raise "dynamic mutation #{iteration} leaked #{error.class}: #{error.message}; bytes=#{source.bytes}"
      end

      pull_valid = false
      pull_value = JSON::Any.new(nil)
      begin
        pull_value = PullSpecHelpers.to_any(source, cache_keys: iteration.odd?)
        pull_valid = true
      rescue _error : FusedJSON::ParseError
      rescue error
        raise "pull mutation #{iteration} leaked #{error.class}: #{error.message}; bytes=#{source.bytes}"
      end

      unless pull_valid == dynamic_valid && (!pull_valid || pull_value == dynamic_value)
        raise "pull mutation #{iteration} diverged while building; bytes=#{source.bytes}"
      end

      skip_valid = false
      begin
        PullSpecHelpers.skip(source)
        skip_valid = true
      rescue _error : FusedJSON::ParseError
      rescue error
        raise "skip mutation #{iteration} leaked #{error.class}: #{error.message}; bytes=#{source.bytes}"
      end

      unless skip_valid == dynamic_valid
        raise "pull mutation #{iteration} diverged while skipping; bytes=#{source.bytes}"
      end
    end
  end
end

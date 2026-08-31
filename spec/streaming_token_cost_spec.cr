require "./spec_helper"
require "../bench/streaming_token_support"

private def token_cost_config(consumer : String, transport : String, *,
                              chunks = [] of Int32, cache_keys = false,
                              limits = "none", buffer_size = 17) : StreamingTokenCost::RunConfig
  StreamingTokenCost::RunConfig.new(
    consumer,
    transport,
    buffer_size,
    chunks,
    cache_keys,
    limits
  )
end

describe StreamingTokenCost do
  it "generates deterministic valid fixtures for every profile" do
    StreamingTokenCost::PROFILES.each do |profile|
      first = StreamingTokenCost.generate(profile, 5, 73, 9)
      second = StreamingTokenCost.generate(profile, 5, 73, 9)

      first.array_source.should eq(second.array_source), profile
      first.document_source.should eq(second.document_source), profile
      first.expected.should eq(second.expected), profile
      first.expected.values.should eq(5), profile
      first.largest_token_bytes.should be > 0, profile
      first.largest_document_bytes.should be > 0, profile
    end
  end

  it "keeps pull, tree, typed, and document consumers semantically equivalent" do
    StreamingTokenCost::PROFILES.each do |profile|
      fixture = StreamingTokenCost.generate(profile, 5, 73, 3)
      expected = fixture.expected

      {
        token_cost_config("pull-materialize", "string"),
        token_cost_config("pull-materialize", "io-memory"),
        token_cost_config("pull-materialize", "chunked-memory", chunks: [1, 2, 7]),
        token_cost_config("dynamic-tree", "string"),
        token_cost_config("dynamic-tree", "io-memory"),
        token_cost_config("dynamic-tree", "chunked-memory", chunks: [3]),
        token_cost_config("document-dynamic", "io-memory"),
        token_cost_config("document-dynamic", "chunked-memory", chunks: [1, 5, 2]),
      }.each do |config|
        result = StreamingTokenCost.run(fixture, config)
        result.semantic.should eq(expected), "#{profile}/#{config.consumer}/#{config.transport}"
        StreamingTokenCost.verify_input(result)
      end

      next unless StreamingTokenCost.typed_profile?(profile)

      {
        token_cost_config("typed", "string"),
        token_cost_config("typed", "io-memory"),
        token_cost_config("typed", "chunked-memory", chunks: [2, 1, 9]),
        token_cost_config("document-typed", "io-memory"),
        token_cost_config("document-typed", "chunked-memory", chunks: [1, 4]),
      }.each do |config|
        result = StreamingTokenCost.run(fixture, config)
        result.semantic.should eq(expected), "#{profile}/#{config.consumer}/#{config.transport}"
        StreamingTokenCost.verify_input(result)
      end
    end
  end

  it "keeps lazy skip results stable across transports and refill patterns" do
    StreamingTokenCost::PROFILES.each do |profile|
      fixture = StreamingTokenCost.generate(profile, 7, 81, 5)
      reference = token_cost_config("pull-skip", "string")
      expected = StreamingTokenCost.run(fixture, reference).semantic

      {
        token_cost_config("pull-skip", "io-memory"),
        token_cost_config("pull-skip", "chunked-memory", chunks: [1]),
        token_cost_config("pull-skip", "chunked-memory", chunks: [1, 3, 2, 11]),
      }.each do |config|
        result = StreamingTokenCost.run(fixture, config)
        result.semantic.should eq(expected), "#{profile}/#{config.transport}/#{config.chunks}"
        StreamingTokenCost.verify_input(result)
      end
    end
  end

  it "exercises each active limit policy at an accepted boundary" do
    fixtures = [
      StreamingTokenCost.generate("escape-sparse", 5, 97, 2),
      StreamingTokenCost.generate("key-repeated-escaped", 5, 97, 2),
    ]

    fixtures.each do |fixture|
      StreamingTokenCost::LIMIT_POLICIES.each do |limits|
        config = token_cost_config(
          "pull-materialize",
          "chunked-memory",
          chunks: [1, 7, 2],
          cache_keys: true,
          limits: limits
        )
        StreamingTokenCost.run(fixture, config).semantic.should eq(fixture.expected),
          "#{fixture.profile}/#{limits}"
      end
    end
  end

  it "checks one-byte, irregular, and buffer-adjacent boundaries" do
    {
      {"escape-dense", "pull-materialize"},
      {"unicode-escape", "pull-skip"},
      {"surrogate-escape", "typed"},
      {"key-repeated-escaped", "document-typed"},
    }.each do |profile, consumer|
      StreamingTokenCost.boundary_preflight(
        profile,
        consumer,
        17,
        97,
        true,
        "token"
      )
    end
  end

  it "rejects unsupported benchmark configurations before parsing" do
    fixture = StreamingTokenCost.generate("key-unique-plain", 3, 32)

    expect_raises(ArgumentError, "document consumers require an IO transport") do
      StreamingTokenCost.validate_config(
        fixture,
        token_cost_config("document-dynamic", "string")
      )
    end
    expect_raises(ArgumentError, "does not support") do
      StreamingTokenCost.validate_config(
        fixture,
        token_cost_config("typed", "io-memory")
      )
    end
    expect_raises(ArgumentError, "chunked transport requires chunks") do
      StreamingTokenCost.validate_config(
        fixture,
        token_cost_config("pull-materialize", "chunked-memory")
      )
    end
  end
end

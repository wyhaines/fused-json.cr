require "./spec_helper"
require "./support/chunked_io"

private def limited_dynamic_reader(
  source : String,
  framing : FusedJSON::DocumentFraming,
  limits : FusedJSON::Limits,
  *,
  cache_keys : Bool = false,
)
  FusedJSON.documents(
    StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1),
    framing: framing,
    buffer_size: 1,
    cache_keys: cache_keys,
    limits: limits
  )
end

describe "FusedJSON::DocumentReader resource limits" do
  it "resets the NDJSON document-byte budget for every record" do
    source = " 1 \n 2 \n"
    exact = FusedJSON::Limits.new(max_document_bytes: 3)
    reader = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      exact
    )
    reader.to_a.should eq([JSON::Any.new(1_i64), JSON::Any.new(2_i64)])
    reader.documents_read.should eq(2)

    short = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      FusedJSON::Limits.new(max_document_bytes: 2)
    )
    error = expect_raises(FusedJSON::ParseError, "max_document_bytes of 2") do
      short.next
    end
    error.byte_offset.should eq(2_i64)
    short.documents_read.should eq(0)
  end

  it "accepts a numeric root ending exactly at the framing boundary" do
    ["0", "-12", "1.25", "1e2", "1.2e-3"].each do |token|
      expected = FusedJSON.load(token)
      limits = FusedJSON::Limits.new(max_document_bytes: token.bytesize)
      {1, 3, 32}.each do |buffer_size|
        {"\n", "\r\n"}.each do |ending|
          reader = FusedJSON.documents(IO::Memory.new((token + ending) * 2),
            framing: :ndjson, buffer_size: buffer_size, limits: limits)
          reader.to_a.should eq([expected, expected])
        end

        reader = FusedJSON.documents(IO::Memory.new("#{token}\t0"),
          framing: :whitespace_separated, buffer_size: buffer_size, limits: limits)
        reader.next.should eq(expected)
        if token.bytesize == 1
          expect_raises(FusedJSON::ParseError, "max_document_bytes") { reader.next }
        else
          reader.next.should eq(JSON::Any.new(0_i64))
        end
      end
    end
  end

  it "still charges bytes inside a record and gives byte limits precedence over syntax errors" do
    {"1 \n" => 1, "01\n" => 1, "12\n" => 1, "1.x\n" => 2,
     "1e+\n" => 2, "[1\n" => 2}.each do |source, maximum|
      {1, 32}.each do |buffer_size|
        reader = FusedJSON.documents(IO::Memory.new(source), framing: :ndjson, buffer_size: buffer_size,
          limits: FusedJSON::Limits.new(max_document_bytes: maximum))
        error = expect_raises(FusedJSON::ParseError, "max_document_bytes") { reader.next }
        error.byte_offset.should eq(maximum)
      end
    end
  end

  it "applies the selected-value limit only when a type is supplied, including JSON::Any" do
    FusedJSON::DocumentFraming.each do |framing|
      ["12", "[1]"].each do |source|
        limits = FusedJSON::Limits.new(max_typed_value_bytes: source.bytesize - 1)
        dynamic = FusedJSON.documents(IO::Memory.new(source), framing: framing, limits: limits)
        dynamic.next.should eq(FusedJSON.load(source))

        typed = FusedJSON.documents(IO::Memory.new(source), JSON::Any, framing: framing, limits: limits)
        direct = FusedJSON::DocumentReader.new(IO::Memory.new(source), JSON::Any, framing: framing, limits: limits)
        {typed, direct}.each do |reader|
          error = expect_raises(FusedJSON::ParseError, "max_typed_value_bytes") { reader.next }
          error.byte_offset.should eq(source.bytesize - 1)
          reader.documents_read.should eq(0)
        end

        exact = FusedJSON::Limits.new(max_typed_value_bytes: source.bytesize)
        FusedJSON.documents(IO::Memory.new(source), JSON::Any, framing: framing, limits: exact)
          .to_a.should eq([FusedJSON.load(source)])
      end
    end
  end

  it "counts leading separators in the next whitespace-separated budget" do
    source = "1  2"
    exact = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::WhitespaceSeparated,
      FusedJSON::Limits.new(max_document_bytes: 3)
    )
    exact.to_a.should eq([JSON::Any.new(1_i64), JSON::Any.new(2_i64)])

    short = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::WhitespaceSeparated,
      FusedJSON::Limits.new(max_document_bytes: 2)
    )
    short.next.should eq(JSON::Any.new(1_i64))
    error = expect_raises(FusedJSON::ParseError, "max_document_bytes of 2") do
      short.next
    end
    error.byte_offset.should eq(3_i64)
    short.documents_read.should eq(1)
  end

  it "applies the pending document budget to a whitespace-only tail" do
    reader = limited_dynamic_reader(
      "1   ",
      FusedJSON::DocumentFraming::WhitespaceSeparated,
      FusedJSON::Limits.new(max_document_bytes: 2)
    )

    reader.next.should eq(JSON::Any.new(1_i64))
    error = expect_raises(FusedJSON::ParseError, "max_document_bytes of 2") do
      reader.next
    end
    error.byte_offset.should eq(3_i64)
  end

  it "resets value and container-entry counts for every document" do
    source = "[1,2]\n[3,4]\n"
    exact = FusedJSON::Limits.new(
      max_total_values: 3,
      max_container_entries: 2
    )
    reader = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      exact
    )
    reader.to_a.should eq([FusedJSON.load("[1,2]"), FusedJSON.load("[3,4]")])

    value_short = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      FusedJSON::Limits.new(max_total_values: 2)
    )
    expect_raises(FusedJSON::ParseError, "max_total_values of 2") do
      value_short.next
    end

    entry_short = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      FusedJSON::Limits.new(max_container_entries: 1)
    )
    expect_raises(FusedJSON::ParseError, "max_container_entries of 1") do
      entry_short.next
    end
  end

  it "applies token and typed-value limits independently to each record" do
    tokens = FusedJSON.documents(
      IO::Memory.new(<<-JSON),
        "ab"
        "cd"
        JSON
      String,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1,
      max_token_bytes: 4
    )
    tokens.to_a.should eq(["ab", "cd"])

    token_short = FusedJSON.documents(
      IO::Memory.new(<<-JSON),
        "ab"
        "long"
        JSON
      String,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1,
      max_token_bytes: 4
    )
    token_short.next.should eq("ab")
    expect_raises(FusedJSON::ParseError, "max_token_bytes") { token_short.next }

    typed = FusedJSON.documents(
      IO::Memory.new("1\n2\n"),
      Int32,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1,
      limits: FusedJSON::Limits.new(max_typed_value_bytes: 1)
    )
    typed.to_a.should eq([1, 2])

    typed_short = FusedJSON.documents(
      IO::Memory.new("1\n-2\n"),
      Int32,
      framing: FusedJSON::DocumentFraming::NDJSON,
      buffer_size: 1,
      limits: FusedJSON::Limits.new(max_typed_value_bytes: 1)
    )
    typed_short.next.should eq(1)
    expect_raises(FusedJSON::ParseError, "max_typed_value_bytes of 1") do
      typed_short.next
    end
  end

  it "keeps the optional key cache across documents" do
    source = <<-JSON
      {"shared":1}
      {"\u0073hared":2}
      {"shared":3}
      JSON
    reader = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      FusedJSON::Limits::DEFAULT,
      cache_keys: true
    )
    values = reader.to_a
    keys = values.map(&.as_h.keys.first)

    keys[0].should eq("shared")
    keys[1].should eq("shared")
    keys[0].same?(keys[1]).should be_true
    keys[0].same?(keys[2]).should be_true
  end

  it "bounds distinct cached keys over the reader lifetime" do
    source = <<-JSON
      {"shared":1}
      {"\u0073hared":2}
      {"new":3}
      JSON
    reader = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      FusedJSON::Limits.new(max_cached_keys: 1),
      cache_keys: true
    )

    reader.next.as(JSON::Any).as_h["shared"].as_i64.should eq(1_i64)
    reader.next.as(JSON::Any).as_h["shared"].as_i64.should eq(2_i64)
    error = expect_raises(FusedJSON::ParseError, "max_cached_keys of 1") do
      reader.next
    end
    key_offset = source.index(%q("new")) || raise "missing key in fixture"
    error.byte_offset.should eq(key_offset.to_i64)
    reader.documents_read.should eq(2)

    uncached = limited_dynamic_reader(
      source,
      FusedJSON::DocumentFraming::NDJSON,
      FusedJSON::Limits.new(max_cached_keys: 0),
      cache_keys: false
    )
    uncached.to_a.size.should eq(3)
  end

  it "resets duplicate-key state between documents" do
    limits = FusedJSON::Limits.new(reject_duplicate_keys: true)
    accepted_source = <<-JSON
      {"a":1}
      {"a":2}
      JSON
    accepted = limited_dynamic_reader(
      accepted_source,
      FusedJSON::DocumentFraming::NDJSON,
      limits
    )
    accepted.to_a.size.should eq(2)

    rejected_source = <<-JSON
      {"a":1}
      {"a":2,"\u0061":3}
      JSON
    rejected = limited_dynamic_reader(
      rejected_source,
      FusedJSON::DocumentFraming::NDJSON,
      limits
    )
    rejected.next
    expect_raises(FusedJSON::ParseError, "duplicate object key") do
      rejected.next
    end
    rejected.documents_read.should eq(1)
  end
end

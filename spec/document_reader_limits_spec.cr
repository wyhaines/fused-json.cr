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

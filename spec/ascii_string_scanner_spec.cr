require "./spec_helper"
require "./support/chunked_io"

module FusedJSON
  module ASCIIStringScannerSpecProbe
    BACKEND = ASCIIStringScanner::BACKEND

    def self.find_special(bytes : Bytes, start : Int32, finish : Int32) : Int32
      ASCIIStringScanner.find_special(bytes, start, finish)
    end
  end
end

private def scalar_special(bytes : Bytes, start : Int32, finish : Int32) : Int32
  index = start
  while index < finish
    byte = bytes[index]
    return index if byte == 0x22_u8 || byte == 0x5c_u8 || byte < 0x20_u8 || byte >= 0x80_u8
    index += 1
  end
  finish
end

private def assert_string_paths(source : String, expected : String) : Nil
  FusedJSON.load(source).as_s.should eq(expected)

  pull = FusedJSON::PullParser.new(source)
  pull.read_string.should eq(expected)
  pull.finish

  skipped = FusedJSON::PullParser.new(source)
  skipped.skip_value
  skipped.finish

  FusedJSON.from_json(source, String).should eq(expected)
end

private def pull_error(source : String) : FusedJSON::ParseError
  expect_raises(FusedJSON::ParseError) do
    pull = FusedJSON::PullParser.new(source)
    pull.skip_value
  end
end

describe FusedJSON::ASCIIStringScannerSpecProbe do
  it "selects the requested backend" do
    {% if flag?(:fused_json_force_scalar_string_scan) %}
      FusedJSON::ASCIIStringScannerSpecProbe::BACKEND.should eq(:scalar)
    {% else %}
      FusedJSON::ASCIIStringScannerSpecProbe::BACKEND.should eq(:word)
    {% end %}
  end

  it "matches a scalar oracle for every special byte, word lane, and start alignment" do
    specials = (0x00..0x1f).map(&.to_u8) + [0x22_u8, 0x5c_u8] + (0x80..0xff).map(&.to_u8)
    scan_length = 33

    16.times do |alignment|
      bytes = Bytes.new(alignment + scan_length + 1, 0x61_u8)
      start = alignment.to_i32
      finish = (alignment + scan_length).to_i32
      bytes[finish] = 0x00_u8

      specials.each do |special|
        scan_length.times do |position|
          index = alignment + position
          bytes[index] = special
          FusedJSON::ASCIIStringScannerSpecProbe.find_special(bytes, start, finish).should eq(index)
          bytes[index] = 0x61_u8
        end
      end

      FusedJSON::ASCIIStringScannerSpecProbe.find_special(bytes, start, finish).should eq(finish)
    end
  end

  it "accepts ordinary ASCII edge bytes and returns the earliest special" do
    [0x20_u8, 0x21_u8, 0x23_u8, 0x5b_u8, 0x5d_u8, 0x7e_u8, 0x7f_u8].each do |byte|
      bytes = Bytes.new(65, byte)
      FusedJSON::ASCIIStringScannerSpecProbe.find_special(bytes, 0, bytes.size).should eq(bytes.size)
    end

    bytes = Bytes.new(64, 0x61_u8)
    bytes[23] = 0x5c_u8
    bytes[24] = 0x22_u8
    bytes[25] = 0x00_u8
    FusedJSON::ASCIIStringScannerSpecProbe.find_special(bytes, 7, 60).should eq(23)

    bounded = Bytes.new(18, 0x61_u8)
    bounded[17] = 0x00_u8
    FusedJSON::ASCIIStringScannerSpecProbe.find_special(bounded, 1, 16).should eq(16)
  end

  it "matches a scalar oracle for every adjacent byte pair" do
    bytes = Bytes.new(8, 0x61_u8)

    7.times do |position|
      256.times do |first|
        256.times do |second|
          bytes[position] = first.to_u8
          bytes[position + 1] = second.to_u8
          expected = scalar_special(bytes, 0, bytes.size)
          FusedJSON::ASCIIStringScannerSpecProbe.find_special(bytes, 0, bytes.size).should eq(expected)
        end
      end
      bytes[position] = 0x61_u8
      bytes[position + 1] = 0x61_u8
    end
  end

  it "matches a scalar oracle for deterministic bounded slices" do
    random = Random::PCG32.new(0x6173_6369_695f_7275_u64)

    5_000.times do
      bytes = Bytes.new(random.rand(258)) { (random.next_u & 0xff).to_u8 }
      start = random.rand(bytes.size + 1).to_i32
      finish = random.rand(start..bytes.size).to_i32
      expected = scalar_special(bytes, start, finish)
      FusedJSON::ASCIIStringScannerSpecProbe.find_special(bytes, start, finish).should eq(expected)
    end
  end

  it "parses quotes, escapes, Unicode, and long ASCII tails around word boundaries" do
    lengths = (0..17).to_a + [31, 32, 33, 63, 64, 65]
    escaped_values = [
      {"\\\"", "\""},
      {"\\\\", "\\"},
      {"\\/", "/"},
      {"\\b", "\b"},
      {"\\f", "\f"},
      {"\\n", "\n"},
      {"\\r", "\r"},
      {"\\t", "\t"},
      {"\\u03bb", "λ"},
      {"\\uD834\\uDD1E", "𝄞"},
    ]

    lengths.each do |length|
      prefix = "a" * length
      assert_string_paths(%( "#{prefix}" ), prefix)
      assert_string_paths(%( "#{prefix}λtail" ), "#{prefix}λtail")

      escaped_values.each do |token, value|
        assert_string_paths(%( "#{prefix}#{token}#{"z" * 33}" ), "#{prefix}#{value}#{"z" * 33}")
      end
    end
  end

  it "rejects every raw control at exact offsets after bulk ASCII" do
    [0, 7, 8, 9, 15, 16, 17, 31, 32, 33].each do |length|
      (0x00..0x1f).each do |control|
        prefix = " \n[\"" + ("a" * length)
        source = String.new(prefix.to_slice + Bytes[control.to_u8] + %("]).to_slice)
        expected_offset = prefix.bytesize.to_i64

        dynamic = expect_raises(FusedJSON::ParseError) { FusedJSON.load(source) }
        pull = pull_error(source)
        {dynamic.byte_offset, dynamic.line_number_i64, dynamic.column_number_i64}.should eq(
          {expected_offset, 2_i64, (3 + length).to_i64}
        )
        {pull.byte_offset, pull.line_number_i64, pull.column_number_i64}.should eq(
          {dynamic.byte_offset, dynamic.line_number_i64, dynamic.column_number_i64}
        )
      end
    end
  end

  it "preserves exact malformed UTF-8 and escape locations after long ASCII" do
    fragments = [
      Bytes[0x80_u8],
      Bytes[0xc0_u8, 0x80_u8],
      Bytes[0xe0_u8, 0x80_u8, 0x80_u8],
      Bytes[0xed_u8, 0xa0_u8, 0x80_u8],
      Bytes[0xf0_u8, 0x80_u8, 0x80_u8, 0x80_u8],
      Bytes[0xf4_u8, 0x90_u8, 0x80_u8, 0x80_u8],
      Bytes[0xff_u8],
      Bytes[0xe2_u8, 0x28_u8, 0xa1_u8],
    ]

    [7, 8, 9, 15, 16, 17, 31, 32, 33].each do |length|
      prefix = " \n[\"" + ("a" * length)
      suffix = %("]).to_slice
      fragments.each do |fragment|
        source = String.new(prefix.to_slice + fragment + suffix)
        dynamic = expect_raises(FusedJSON::ParseError) { FusedJSON.load(source) }
        pull = pull_error(source)
        {pull.byte_offset, pull.line_number_i64, pull.column_number_i64}.should eq(
          {dynamic.byte_offset, dynamic.line_number_i64, dynamic.column_number_i64}
        )
      end

      ["\\", "\\u", "\\u0", "\\u00", "\\u000", "\\uD800"].each do |fragment|
        source = prefix + fragment
        dynamic = expect_raises(FusedJSON::ParseError) { FusedJSON.load(source) }
        pull = pull_error(source)
        {pull.byte_offset, pull.line_number_i64, pull.column_number_i64}.should eq(
          {dynamic.byte_offset, dynamic.line_number_i64, dynamic.column_number_i64}
        )
      end
    end
  end

  it "preserves values and errors across every streaming split" do
    value = ("a" * 15) + "\n" + ("b" * 16) + "λ" + ("c" * 17) + "𝄞"
    source = value.to_json

    (1...source.bytesize).each do |split|
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        chunks: [split, source.bytesize - split],
        max_chunk: 9,
        read_budget: source.bytesize + 2
      )
      pull = FusedJSON::PullParser.new(io, buffer_size: 17)
      pull.read_string.should eq(value)
      pull.finish
      io.bytes_read.should eq(source.bytesize)
    end

    invalid = String.new(%( "#{"a" * 16}).to_slice + Bytes[0xe2_u8, 0x28_u8, 0xa1_u8, 0x22_u8])
    expected = expect_raises(FusedJSON::ParseError) { FusedJSON.load(invalid) }
    (1...invalid.bytesize).each do |split|
      io = StreamSpecSupport::ChunkedIO.new(
        invalid,
        chunks: [split, invalid.bytesize - split],
        max_chunk: 7
      )
      actual = expect_raises(FusedJSON::ParseError) do
        pull = FusedJSON::PullParser.new(io, buffer_size: 9)
        pull.skip_value
      end
      {actual.byte_offset, actual.line_number_i64, actual.column_number_i64}.should eq(
        {expected.byte_offset, expected.line_number_i64, expected.column_number_i64}
      )
    end
  end

  it "rejects a streaming control byte after complete ASCII words" do
    source = String.new(%("#{"a" * 16}).to_slice + Bytes[0x1f_u8, 0x22_u8])
    expected = expect_raises(FusedJSON::ParseError) { FusedJSON.load(source) }

    [7, 8, 9, 16, 17].each do |buffer_size|
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        max_chunk: buffer_size,
        read_budget: source.bytesize + 2
      )
      actual = expect_raises(FusedJSON::ParseError) do
        FusedJSON::PullParser.new(io, buffer_size: buffer_size)
      end
      {actual.byte_offset, actual.line_number_i64, actual.column_number_i64}.should eq(
        {expected.byte_offset, expected.line_number_i64, expected.column_number_i64}
      )
    end
  end
end

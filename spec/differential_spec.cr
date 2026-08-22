require "./spec_helper"

private def generated_json_value(random : Random::PCG32, depth : Int32 = 0) : JSON::Any
  scalar_count = 5
  choice = random.rand(depth >= 4 ? scalar_count : 7)

  case choice
  when 0
    JSON::Any.new(nil)
  when 1
    JSON::Any.new(random.next_u.even?)
  when 2
    JSON::Any.new((random.rand(2_000_001) - 1_000_000).to_i64)
  when 3
    JSON::Any.new((random.rand * 2_000_000.0) - 1_000_000.0)
  when 4
    strings = ["", "ascii", "line\nfeed", "quote\"slash\\", "λ", "Привет, мир!", "𝄞"]
    JSON::Any.new(strings[random.rand(strings.size)])
  when 5
    values = Array(JSON::Any).new
    random.rand(6).times do
      values << generated_json_value(random, depth + 1)
    end
    JSON::Any.new(values)
  else
    values = Hash(String, JSON::Any).new
    random.rand(6).times do |index|
      values["key_#{index}_#{random.rand(4)}"] = generated_json_value(random, depth + 1)
    end
    JSON::Any.new(values)
  end
end

describe "FusedJSON differential parsing" do
  it "matches Crystal JSON on deterministic generated documents" do
    random = Random::PCG32.new(0x0bad_f00d_u64)

    500.times do
      source = generated_json_value(random).to_json
      FusedJSON.load(source).should eq(JSON.parse(source))
      FusedJSON.load(source, cache_keys: true).should eq(JSON.parse(source))
    end
  end

  it "handles scanner boundaries and UTF-8 after an escape" do
    [0, 1, 15, 16, 17, 63, 64, 65, 255, 256, 257].each do |length|
      value = ("x" * length) + "\nПривет, мир! 𝄞"
      source = {"key" => value}.to_json
      FusedJSON.load(source).should eq(JSON.parse(source))
    end
  end

  it "matches Crystal JSON's supported finite float range" do
    [
      "0.0",
      "-0.0",
      "1e-308",
      "1e308",
      "9.91343313498688",
      "9876543212345678987654321e20",
    ].each do |source|
      FusedJSON.load(source).should eq(JSON.parse(source))
    end

    ["1e309", "-1e309"].each do |source|
      expect_raises(FusedJSON::ParseError) { FusedJSON.load(source) }
    end
  end

  it "rejects invalid UTF-8 and raw control bytes in strings" do
    invalid_documents = [
      Bytes[0x22_u8, 0xc0_u8, 0x80_u8, 0x22_u8],
      Bytes[0x22_u8, 0xe0_u8, 0x80_u8, 0x80_u8, 0x22_u8],
      Bytes[0x22_u8, 0xed_u8, 0xa0_u8, 0x80_u8, 0x22_u8],
      Bytes[0x22_u8, 0xf4_u8, 0x90_u8, 0x80_u8, 0x80_u8, 0x22_u8],
      Bytes[0x22_u8, 0x0a_u8, 0x22_u8],
      Bytes[0x22_u8, 0x00_u8, 0x22_u8],
    ]

    invalid_documents.each do |bytes|
      expect_raises(FusedJSON::ParseError) do
        FusedJSON.load(String.new(bytes))
      end
    end
  end

  it "accepts nesting at 512 and rejects nesting at 513" do
    source_512 = ("[" * 512) + "0" + ("]" * 512)
    source_513 = ("[" * 513) + "0" + ("]" * 513)

    FusedJSON.load(source_512).should eq(JSON.parse(source_512))
    expect_raises(FusedJSON::ParseError) { FusedJSON.load(source_513) }
  end
end

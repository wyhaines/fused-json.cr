require "./spec_helper"

describe FusedJSON::Float64Decoder do
  it "parses only the requested byte range" do
    bytes = "xx-12.5e+2yy".to_slice

    FusedJSON::Float64Decoder.parse?(bytes, 2, 10).should eq(-1250.0)
  end

  it "preserves negative zero" do
    value = FusedJSON::Float64Decoder.parse?("-0.0".to_slice, 0, 4).not_nil!

    value.unsafe_as(UInt64).should eq(0x8000000000000000_u64)
  end

  it "handles Float64 boundaries" do
    {
      "1.7976931348623157e308"  => Float64::MAX,
      "2.2250738585072014e-308" => Float64::MIN_POSITIVE,
      "4.9406564584124654e-324" => 5e-324,
    }.each do |source, expected|
      FusedJSON::Float64Decoder.parse?(source.to_slice, 0, source.bytesize).should eq(expected)
    end
  end

  it "rejects overflow and underflow" do
    ["1.7976931348623159e308", "2e-324"].each do |source|
      FusedJSON::Float64Decoder.parse?(source.to_slice, 0, source.bytesize).should be_nil
      expect_raises(FusedJSON::ParseError) { FusedJSON.load(source) }
    end
  end

  {% if flag?(:fused_json_force_portable_float) %}
    it "can force the public String conversion fallback" do
      FusedJSON::Float64Decoder::BACKEND.should eq(:string)
      FusedJSON::Float64Decoder::ZERO_SUBSTRING.should be_false
    end
  {% end %}
end

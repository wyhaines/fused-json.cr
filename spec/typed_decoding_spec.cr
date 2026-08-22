require "./spec_helper"
require "big/json"

private enum TypedRole
  User
  Admin
end

private module TypedHexConverter
  def self.from_json(pull : JSON::PullParser) : Int32
    pull.read_string.to_i(16)
  end
end

private class TypedProfile
  include JSON::Serializable

  getter id : UInt64

  @[JSON::Field(key: "display_name")]
  getter name : String

  getter roles : Array(TypedRole)
  getter note : String?
  getter enabled : Bool = true

  @[JSON::Field(converter: TypedHexConverter)]
  getter color : Int32
end

private class TypedStrictProfile
  include JSON::Serializable
  include JSON::Serializable::Strict

  getter name : String
end

private class TypedUnmappedProfile
  include JSON::Serializable
  include JSON::Serializable::Unmapped

  getter name : String
end

private def typed_parity(source : String, type : T.class) : T forall T
  expected = T.from_json(source)
  actual = FusedJSON.from_json(source, T)
  actual.should eq(expected)
  actual
end

describe ".from_json" do
  it "matches Crystal's typed decoder across the supported core types" do
    typed_parity("null", Nil)
    typed_parity("false", Bool)
    typed_parity(%q("line\nλ"), String)

    {% for type in [Int8, Int16, Int32, Int64, Int128] %}
      typed_parity({{type}}::MIN.to_s, {{type}})
      typed_parity({{type}}::MAX.to_s, {{type}})
    {% end %}
    {% for type in [UInt8, UInt16, UInt32, UInt64, UInt128] %}
      typed_parity({{type}}::MIN.to_s, {{type}})
      typed_parity({{type}}::MAX.to_s, {{type}})
    {% end %}

    typed_parity("1.25e2", Float32)
    typed_parity("-0.0", Float64).unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64)
    typed_parity("[1,2,3]", Array(Int32))
    typed_parity(%q({"1":true,"2":false}), Hash(Int32, Bool))
    typed_parity(%q([7,"seven"]), Tuple(Int32, String))
    typed_parity(%q({"name":"Ada","age":37}), NamedTuple(name: String, age: Int32))
    typed_parity("null", Int32 | Nil)
    typed_parity("42", Int32 | String)
  end

  it "decodes primitive values with the requested numeric ranges" do
    FusedJSON.from_json("null", Nil).should be_nil
    FusedJSON.from_json("true", Bool).should be_true
    FusedJSON.from_json(%q("hello\nλ"), String).should eq("hello\nλ")
    FusedJSON.from_json("-128", Int8).should eq(Int8::MIN)
    FusedJSON.from_json("65535", UInt16).should eq(UInt16::MAX)
    FusedJSON.from_json("-170141183460469231731687303715884105728", Int128).should eq(Int128::MIN)
    FusedJSON.from_json("340282366920938463463374607431768211455", UInt128).should eq(UInt128::MAX)
    FusedJSON.from_json("1.25e2", Float32).should eq(125_f32)
    FusedJSON.from_json("-0", Float64).unsafe_as(UInt64).should eq(0_u64)
  end

  it "decodes arbitrary-precision integers when big/json is loaded" do
    source = "123456789012345678901234567890123456789012345678901234567890"
    expected = BigInt.new(source)

    FusedJSON.from_json(source, BigInt).should eq(expected)
    FusedJSON.from_json("-#{source}", BigInt).should eq(-expected)
  end

  it "matches Crystal's direct and union Float32 conversion paths" do
    source = "1.0000000596046447753906250000000000000000000000000000000000000001"

    typed_parity(source, Float32).unsafe_as(UInt32).should eq(0x3f80_0000_u32)
    typed_parity(source, Float32 | String).as(Float32).unsafe_as(UInt32).should eq(0x3f80_0001_u32)
  end

  it "keeps the public pull reader's Int64 domain" do
    expect_raises(FusedJSON::ParseError) do
      FusedJSON::PullParser.new("9223372036854775808")
    end
  end

  it "rejects values outside the requested numeric type" do
    expect_raises(JSON::ParseException) do
      FusedJSON.from_json("128", Int8)
    end
    expect_raises(JSON::ParseException) do
      FusedJSON.from_json("340282366920938463463374607431768211456", UInt128)
    end
    expect_raises(JSON::ParseException) do
      FusedJSON.from_json("1e309", Float64)
    end
    expect_raises(JSON::ParseException) do
      FusedJSON.from_json("-0", UInt128)
    end
  end

  it "decodes standard collections, tuples, enums, and unions" do
    FusedJSON.from_json("[1,2,3]", Array(Int32)).should eq([1, 2, 3])
    FusedJSON.from_json(%q({"1":true,"2":false}), Hash(Int32, Bool)).should eq({1 => true, 2 => false})
    FusedJSON.from_json(%q([7,"seven"]), Tuple(Int32, String)).should eq({7, "seven"})
    FusedJSON.from_json(%q({"name":"Ada","age":37}), NamedTuple(name: String, age: Int32)).should eq({name: "Ada", age: 37})
    FusedJSON.from_json(%q("admin"), TypedRole).should eq(TypedRole::Admin)
    FusedJSON.from_json("42", Int32 | String).should eq(42)
    FusedJSON.from_json(%q("forty-two"), Int32 | String).should eq("forty-two")
  end

  it "uses JSON::Serializable field rules and converters" do
    source = %q({"id":18446744073709551615,"display_name":"Ada","roles":["user","admin"],"note":null,"color":"ff","ignored":{"large":340282366920938463463374607431768211456,"float":1e309}})
    profile = FusedJSON.from_json(source, TypedProfile)

    profile.id.should eq(UInt64::MAX)
    profile.name.should eq("Ada")
    profile.roles.should eq([TypedRole::User, TypedRole::Admin])
    profile.note.should be_nil
    profile.enabled.should be_true
    profile.color.should eq(255)

    expected = TypedProfile.from_json(source)
    {profile.id, profile.name, profile.roles, profile.note, profile.enabled, profile.color}.should eq(
      {expected.id, expected.name, expected.roles, expected.note, expected.enabled, expected.color}
    )
  end

  it "supports strict and unmapped serializable policies" do
    expect_raises(JSON::SerializableError, "Unknown JSON attribute") do
      FusedJSON.from_json(%q({"name":"Ada","extra":1}), TypedStrictProfile)
    end

    profile = FusedJSON.from_json(%q({"name":"Ada","extra":{"x":[1,true]}}), TypedUnmappedProfile)
    profile.json_unmapped["extra"]["x"][0].as_i64.should eq(1_i64)
  end

  it "uses the last duplicate field value" do
    profile = FusedJSON.from_json(%q({"id":1,"display_name":"first","roles":[],"note":null,"color":"01","display_name":"last"}), TypedProfile)
    profile.name.should eq("last")
  end

  it "reports typed failures at source locations" do
    error = expect_raises(JSON::SerializableError) do
      FusedJSON.from_json("{\n  \"id\": \"wrong\",\n  \"display_name\": \"Ada\",\n  \"roles\": [],\n  \"note\": null,\n  \"color\": \"ff\"\n}", TypedProfile)
    end

    error.location_i64.should eq({2_i64, 9_i64})
  end

  it "validates skipped fields and applies typed nesting limits" do
    invalid = %q({"id":1,"display_name":"Ada","roles":[],"note":null,"color":"ff","ignored":[1,]})
    expect_raises(FusedJSON::ParseError) do
      FusedJSON.from_json(invalid, TypedProfile)
    end

    FusedJSON.from_json("[[0]]", Array(Array(Int32)), max_nesting: 2).should eq([[0]])
    expect_raises(FusedJSON::ParseError) do
      FusedJSON.from_json("[[0]]", Array(Array(Int32)), max_nesting: 1)
    end
  end

  it "rejects trailing content after typed values" do
    ["1 2", "true false", "[] []", %q({} "extra")].each do |source|
      expect_raises(FusedJSON::ParseError) do
        FusedJSON.from_json(source, JSON::Any)
      end
    end
  end

  it "rejects lazy target constructors that leave the value unfinished" do
    expect_raises(FusedJSON::ParseError, "expected end of document") do
      FusedJSON.from_json("[1,2]", Iterator(Int32))
    end
  end
end

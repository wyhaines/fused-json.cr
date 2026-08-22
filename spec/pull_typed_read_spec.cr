require "./spec_helper"
require "./support/chunked_io"
require "big/json"

private enum PullTypedRole
  User
  Admin
end

private module PullTypedHexConverter
  def self.from_json(pull : JSON::PullParser) : Int32
    pull.read_string.to_i(16)
  end
end

private class PullTypedProfile
  include JSON::Serializable

  getter id : UInt64

  @[JSON::Field(key: "display_name")]
  getter name : String

  getter roles : Array(PullTypedRole)
  getter note : String?
  getter retries : Int32 = 3

  @[JSON::Field(converter: PullTypedHexConverter)]
  getter color : Int32

  @[JSON::Field(root: "payload")]
  getter rooted : String

  @[JSON::Field(presence: true)]
  getter optional : String?

  @[JSON::Field(ignore: true)]
  getter ignored : String = "local"

  @[JSON::Field(ignore: true)]
  getter? optional_present : Bool
end

private class PullTypedStrictProfile
  include JSON::Serializable
  include JSON::Serializable::Strict

  getter name : String
end

private class PullTypedUnmappedProfile
  include JSON::Serializable
  include JSON::Serializable::Unmapped

  getter name : String
end

private class PullTypedRawRecord
  include JSON::Serializable

  @[JSON::Field(converter: String::RawConverter)]
  getter raw : String

  getter tail : Int32
end

class PullTypedAlpha
  include JSON::Serializable

  getter alpha : String
end

class PullTypedBeta
  include JSON::Serializable

  getter beta : Int32
  getter wide : UInt128
end

abstract class PullTypedShape
  include JSON::Serializable

  use_json_discriminator "type", {point: PullTypedPoint, circle: PullTypedCircle}

  getter type : String
end

class PullTypedPoint < PullTypedShape
  getter x : Int32
  getter y : Int32
end

class PullTypedCircle < PullTypedShape
  getter radius : Float64
end

private struct PullTypedConsumesNothing
  private def initialize(@marker : Bool)
  end

  def self.new(pull : JSON::PullParser) : self
    new(false)
  end
end

private struct PullTypedSkipsValue
  private def initialize(@marker : Bool)
  end

  def self.new(pull : JSON::PullParser) : self
    pull.skip
    new(false)
  end
end

private struct PullTypedConsumesPartial
  private def initialize(@marker : Bool)
  end

  def self.new(pull : JSON::PullParser) : self
    pull.read_begin_array
    new(false)
  end
end

private struct PullTypedConsumesMultiple
  private def initialize(@marker : Bool)
  end

  def self.new(pull : JSON::PullParser) : self
    pull.read_int
    pull.read_int
    new(false)
  end
end

private struct PullTypedCatchesValidation
  getter value : Int32

  private def initialize(@value : Int32)
  end

  def self.new(pull : JSON::PullParser) : self
    value = pull.read_int.to_i32
    begin
      pull.raise("custom validation")
    rescue JSON::ParseException
    end
    new(value)
  end
end

private class PullTypedRetainsAdapter
  @@retained : JSON::PullParser?

  getter value : Int32

  private def initialize(@value : Int32)
  end

  def self.new(pull : JSON::PullParser) : self
    value = pull.read_int.to_i32
    @@retained = pull
    new(value)
  end

  def self.retained : JSON::PullParser
    @@retained || raise "adapter was not retained"
  end
end

private class PullTypedSmallRecord
  include JSON::Serializable

  getter id : Int32
  getter name : String
end

private def pull_typed_from_array(source : String, type : T.class) : T forall T
  pull = FusedJSON::PullParser.new("[false,#{source},\"tail\"]")
  pull.read_begin_array
  pull.read(Bool).should be_false
  value = pull.read(T)
  pull.read(String).should eq("tail")
  pull.read_end_array
  pull.finish
  value
end

describe "FusedJSON::PullParser#read" do
  it "decodes every supported scalar and collection family at the cursor" do
    pull_typed_from_array("null", Nil).should be_nil
    pull_typed_from_array("true", Bool).should be_true
    pull_typed_from_array(%q("line\nλ"), String).should eq("line\nλ")

    {% for type in [Int8, Int16, Int32, Int64, Int128] %}
      pull_typed_from_array({{ type }}::MIN.to_s, {{ type }}).should eq({{ type }}::MIN)
      pull_typed_from_array({{ type }}::MAX.to_s, {{ type }}).should eq({{ type }}::MAX)
    {% end %}
    {% for type in [UInt8, UInt16, UInt32, UInt64, UInt128] %}
      pull_typed_from_array({{ type }}::MIN.to_s, {{ type }}).should eq({{ type }}::MIN)
      pull_typed_from_array({{ type }}::MAX.to_s, {{ type }}).should eq({{ type }}::MAX)
    {% end %}

    pull_typed_from_array("1.25e2", Float32).should eq(125_f32)
    pull_typed_from_array("-0.0", Float64).unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64)
    pull_typed_from_array("[1,2,3]", Array(Int32)).should eq([1, 2, 3])
    pull_typed_from_array("[]", Array(Int32)).should be_empty
    pull_typed_from_array(%q({"1":true,"2":false}), Hash(Int32, Bool)).should eq({1 => true, 2 => false})
    pull_typed_from_array(%q([7,"seven"]), Tuple(Int32, String)).should eq({7, "seven"})
    pull_typed_from_array(
      %q({"name":"Ada","age":37}),
      NamedTuple(name: String, age: Int32)
    ).should eq({name: "Ada", age: 37})
    pull_typed_from_array(%q("admin"), PullTypedRole).should eq(PullTypedRole::Admin)
    pull_typed_from_array("null", Int32 | Nil).should be_nil
    pull_typed_from_array("42", Int32 | String).should eq(42)
    pull_typed_from_array(%q("forty-two"), Int32 | String).should eq("forty-two")
    pull_typed_from_array(%q({"nested":[1,true,null]}), JSON::Any)["nested"][1].as_bool.should be_true
  end

  it "preserves arbitrary-precision and exact decimal number paths" do
    integer_source = "123456789012345678901234567890123456789012345678901234567890"
    float_source = "1.234567890123456789012345678901234567890123456789e+120"
    decimal_source = "12345678901234567890.00000000000000000001"

    pull_typed_from_array(integer_source, BigInt).should eq(BigInt.new(integer_source))
    pull_typed_from_array(float_source, BigFloat).should eq(BigFloat.new(float_source))

    decimal = pull_typed_from_array(decimal_source, BigDecimal)
    decimal.should eq(BigDecimal.new(decimal_source))
    decimal.scale.should eq(BigDecimal.new(decimal_source).scale)

    stream_source = "[#{integer_source},#{float_source},#{decimal_source}]"
    io = StreamSpecSupport::ChunkedIO.new(stream_source, max_chunk: 1)
    stream = FusedJSON::PullParser.new(io, buffer_size: 1)
    stream.read_begin_array
    stream.read(BigInt).should eq(BigInt.new(integer_source))
    stream.read(BigFloat).should eq(BigFloat.new(float_source))
    stream.read(BigDecimal).should eq(BigDecimal.new(decimal_source))
    stream.read_end_array
    stream.finish
    io.closed_called.should be_false
  end

  it "applies serializable field rules, converters, unknown skipping, and duplicate-last semantics" do
    source = %q({"ignored":"wire","id":18446744073709551615,"display_name":"first","roles":["user","admin"],"note":null,"color":"ff","rooted":{"before":0,"payload":"inside","after":[false]},"unknown":{"wide":340282366920938463463374607431768211456,"huge":1e309},"optional":null,"display_name":"last"})
    profile = pull_typed_from_array(source, PullTypedProfile)

    profile.id.should eq(UInt64::MAX)
    profile.name.should eq("last")
    profile.roles.should eq([PullTypedRole::User, PullTypedRole::Admin])
    profile.note.should be_nil
    profile.retries.should eq(3)
    profile.color.should eq(255)
    profile.rooted.should eq("inside")
    profile.optional.should be_nil
    profile.optional_present?.should be_true
    profile.ignored.should eq("local")

    absent = pull_typed_from_array(
      %q({"id":1,"display_name":"Ada","roles":[],"note":null,"color":"01","rooted":{"payload":"fallback"}}),
      PullTypedProfile
    )
    absent.optional.should be_nil
    absent.optional_present?.should be_false

    malformed_unknown = %q({"id":1,"display_name":"Ada","roles":[],"note":null,"color":"01","rooted":{"payload":"fallback"},"unknown":[1,]})
    expect_raises(FusedJSON::ParseError) do
      FusedJSON::PullParser.new(malformed_unknown).read(PullTypedProfile)
    end
  end

  it "supports strict, unmapped, raw, structured-union, and discriminator paths" do
    strict = FusedJSON::PullParser.new(%q({"name":"Ada","extra":1}))
    expect_raises(JSON::SerializableError, "Unknown JSON attribute") do
      strict.read(PullTypedStrictProfile)
    end

    unmapped = pull_typed_from_array(
      %q({"name":"Ada","extra":{"x":[1,true]}}),
      PullTypedUnmappedProfile
    )
    unmapped.json_unmapped["extra"]["x"][0].as_i64.should eq(1_i64)
    expect_raises(JSON::ParseException) do
      FusedJSON::PullParser.new(
        %q({"name":"Ada","extra":340282366920938463463374607431768211456})
      ).read(PullTypedUnmappedProfile)
    end

    raw_source = %q({"raw":{"wide":340282366920938463463374607431768211455,"float":1.2300e+04,"huge":1e309,"array":[null,true,"line\n\u03bb",{"x":-0}]},"tail":7})
    raw = pull_typed_from_array(raw_source, PullTypedRawRecord)
    raw.raw.should eq(%q({"wide":340282366920938463463374607431768211455,"float":1.2300e+04,"huge":1e309,"array":[null,true,"line\nλ",{"x":-0}]}))
    raw.tail.should eq(7)

    union = pull_typed_from_array(
      %q({"beta":9,"wide":340282366920938463463374607431768211455}),
      PullTypedAlpha | PullTypedBeta
    ).as(PullTypedBeta)
    {union.beta, union.wide}.should eq({9, UInt128::MAX})

    point = pull_typed_from_array(
      %q({"type":"point","x":3,"y":4,"ignored":{"huge":1e309}}),
      PullTypedShape
    ).as(PullTypedPoint)
    {point.x, point.y}.should eq({3, 4})

    circle = pull_typed_from_array(
      %q({"radius":2.5,"type":"circle"}),
      PullTypedShape
    ).as(PullTypedCircle)
    circle.radius.should eq(2.5)
  end

  it "matches from_json results and errors for isolated values" do
    source = %q({"id":7,"name":"Ada"})
    expected = FusedJSON.from_json(source, PullTypedSmallRecord)
    actual = FusedJSON::PullParser.new(source).read(PullTypedSmallRecord)
    {actual.id, actual.name}.should eq({expected.id, expected.name})

    invalid = "{\n  \"id\": \"wrong\",\n  \"name\": \"Ada\"\n}"
    expected_error = expect_raises(JSON::SerializableError) do
      FusedJSON.from_json(invalid, PullTypedSmallRecord)
    end
    actual_error = expect_raises(JSON::SerializableError) do
      FusedJSON::PullParser.new(invalid).read(PullTypedSmallRecord)
    end
    actual_error.message.should eq(expected_error.message)
    actual_error.location_i64.should eq(expected_error.location_i64)

    expected_overflow = expect_raises(JSON::ParseException) do
      FusedJSON.from_json("128", Int8)
    end
    actual_overflow = expect_raises(JSON::ParseException) do
      FusedJSON::PullParser.new("128").read(Int8)
    end
    actual_overflow.message.should eq(expected_overflow.message)
    actual_overflow.location_i64.should eq(expected_overflow.location_i64)

    missing = %q({"id":7})
    expected_missing = expect_raises(JSON::SerializableError) do
      FusedJSON.from_json(missing, PullTypedSmallRecord)
    end
    actual_missing = expect_raises(JSON::SerializableError) do
      FusedJSON::PullParser.new(missing).read(PullTypedSmallRecord)
    end
    actual_missing.message.should eq(expected_missing.message)
    actual_missing.location_i64.should eq(expected_missing.location_i64)

    expected_validation = FusedJSON.from_json("7", PullTypedCatchesValidation)
    actual_validation = FusedJSON::PullParser.new("7").read(PullTypedCatchesValidation)
    actual_validation.value.should eq(expected_validation.value)
  end

  it "accepts a one-value skip and rejects incomplete or multiple-value constructors" do
    pull_typed_from_array(%q({"ignored":[1,true]}), PullTypedSkipsValue)

    zero = FusedJSON::PullParser.new("[1,2]")
    zero.read_begin_array
    expect_raises(FusedJSON::ParseError, "must consume exactly one value") do
      zero.read(PullTypedConsumesNothing)
    end
    zero.kind.should eq(FusedJSON::PullParser::Kind::Int)

    partial = FusedJSON::PullParser.new("[[1,2],3]")
    partial.read_begin_array
    expect_raises(FusedJSON::ParseError, "must consume exactly one value") do
      partial.read(PullTypedConsumesPartial)
    end

    multiple = FusedJSON::PullParser.new("[1,2]")
    multiple.read_begin_array
    expect_raises(FusedJSON::ParseError) do
      multiple.read(PullTypedConsumesMultiple)
    end
    multiple.kind.should eq(FusedJSON::PullParser::Kind::Int)

    lazy = FusedJSON::PullParser.new("[[1,2],3]")
    lazy.read_begin_array
    expect_raises(FusedJSON::ParseError, "must consume exactly one value") do
      lazy.read(Iterator(Int32))
    end
  end

  it "keeps a retained adapter permanently isolated from the sibling" do
    pull = FusedJSON::PullParser.new("{\"first\":1,\n\"secret\":\"hidden\"}")
    pull.read_begin_object
    pull.read_object_key.should eq("first")

    retained_value = pull.read(PullTypedRetainsAdapter)
    retained_value.value.should eq(1)
    retained = PullTypedRetainsAdapter.retained
    retained.kind.should eq(JSON::PullParser::Kind::EOF)
    retained.read_next.should eq(JSON::PullParser::Kind::EOF)

    pull.kind.should eq(FusedJSON::PullParser::Kind::String)
    pull.read_object_key.should eq("secret")
    pull.read(String).should eq("hidden")
    pull.read_end_object
    pull.finish

    boundary_location = retained.location_i64
    boundary_location.should eq({2_i64, 1_i64})
    retained.kind.should eq(JSON::PullParser::Kind::EOF)
    retained.read_next.should eq(JSON::PullParser::Kind::EOF)
    retained.location_i64.should eq(boundary_location)
    expect_raises(FusedJSON::ParseError) { retained.bool_value }
    expect_raises(FusedJSON::ParseError) { retained.int_value }
    expect_raises(FusedJSON::ParseError) { retained.float_value }
    expect_raises(FusedJSON::ParseError) { retained.string_value }
    expect_raises(FusedJSON::ParseError) { retained.raw_value }
    expect_raises(FusedJSON::ParseError) { retained.read_string }
    expect_raises(FusedJSON::ParseError) { retained.read_object_key }
    expect_raises(FusedJSON::ParseError) { retained.read_raw }
    raw_output = IO::Memory.new
    expect_raises(FusedJSON::ParseError) { retained.read_raw(JSON::Builder.new(raw_output)) }
    expect_raises(FusedJSON::ParseError) { retained.skip }
  end

  it "rejects object keys and structural end positions without advancing" do
    pull = FusedJSON::PullParser.new(%q({"value":1}))
    pull.read_begin_object

    before = {pull.kind, pull.byte_offset, pull.location_i64}
    expect_raises(FusedJSON::ParseError, "object key") { pull.read(String) }
    {pull.kind, pull.byte_offset, pull.location_i64}.should eq(before)
    pull.read_object_key.should eq("value")
    pull.read(Int32).should eq(1)

    before = {pull.kind, pull.byte_offset, pull.location_i64}
    expect_raises(FusedJSON::ParseError, "expected a JSON value") { pull.read(Int32) }
    {pull.kind, pull.byte_offset, pull.location_i64}.should eq(before)
    pull.read_end_object
    before = {pull.kind, pull.byte_offset, pull.location_i64}
    expect_raises(FusedJSON::ParseError, "expected a JSON value") { pull.read(Int32) }
    {pull.kind, pull.byte_offset, pull.location_i64}.should eq(before)
    pull.finish
  end

  it "does not return a value when one-event lookahead is malformed" do
    pull = FusedJSON::PullParser.new(%q([{"id":1,"name":"first"},1e]))
    pull.read_begin_array
    value = nil

    expect_raises(FusedJSON::ParseError) do
      value = pull.read(PullTypedSmallRecord)
    end
    value.should be_nil
  end

  it "applies streaming token limits during typed-read lookahead" do
    source = %q([{"id":1,"name":"first"},"oversized"])
    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 2, max_token_bytes: 8)
    pull.read_begin_array
    value = nil

    expect_raises(FusedJSON::ParseError, "token exceeds max_token_bytes") do
      value = pull.read(PullTypedSmallRecord)
    end
    value.should be_nil
    io.closed_called.should be_false
  end

  it "does not traverse the body of the next streaming value" do
    source = %q([{"id":1,"name":"first"},{"id":2,"name":"second","payload":[1,2,3]}])
    sibling_offset = source.index(%q({"id":2)) || raise "missing sibling"
    io = StreamSpecSupport::ChunkedIO.new(
      source,
      max_chunk: 1,
      read_budget: sibling_offset + 1
    )
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)
    pull.read_begin_array

    first = pull.read(PullTypedSmallRecord)

    {first.id, first.name}.should eq({1, "first"})
    pull.kind.should eq(FusedJSON::PullParser::Kind::BeginObject)
    pull.byte_offset.should eq(sibling_offset.to_i64)
    io.bytes_read.should eq(sibling_offset + 1)
    io.closed_called.should be_false
  end

  it "decodes representative nested values at every IO split and with one-byte reads" do
    source = %q({"head":true,"value":{"id":7,"name":"Ada λ"},"tail":[1,2,3]})

    (1...source.bytesize).each do |split|
      io = StreamSpecSupport::ChunkedIO.new(
        source,
        chunks: [split, source.bytesize - split],
        read_budget: source.bytesize + 4
      )
      pull = FusedJSON::PullParser.new(io, buffer_size: 7)
      observed = nil

      pull.read_object do |key|
        case key
        when "head"
          pull.read(Bool).should be_true
        when "value"
          observed = pull.read(PullTypedSmallRecord)
        when "tail"
          pull.read(Array(Int32)).should eq([1, 2, 3])
        else
          pull.skip
        end
      end
      pull.finish
      {observed.try(&.id), observed.try(&.name)}.should eq({7, "Ada λ"}), "source split #{split}/#{source.bytesize}"
      io.closed_called.should be_false
    end

    io = StreamSpecSupport::ChunkedIO.new(source, max_chunk: 1)
    pull = FusedJSON::PullParser.new(io, buffer_size: 1)
    pull.read_object do |key|
      key == "value" ? pull.read(PullTypedSmallRecord).name.should(eq("Ada λ")) : pull.skip
    end
    pull.finish
    io.closed_called.should be_false
  end
end

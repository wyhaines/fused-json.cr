require "./spec_helper"

private class AdapterCompatRawRecord
  include JSON::Serializable

  @[JSON::Field(converter: String::RawConverter)]
  getter raw : String

  getter tail : Int32
end

class AdapterCompatAlpha
  include JSON::Serializable

  getter alpha : String
end

class AdapterCompatBeta
  include JSON::Serializable

  getter beta : Int32
  getter wide : UInt128
end

private class AdapterCompatFieldRules
  include JSON::Serializable

  @[JSON::Field(root: "payload")]
  getter rooted : String

  @[JSON::Field(presence: true)]
  getter optional : String?

  getter retries : Int32 = 3

  @[JSON::Field(ignore: true)]
  getter ignored : String = "local"

  @[JSON::Field(ignore: true)]
  getter? optional_present : Bool
end

private module AdapterCompatNominalConverter
  @@calls = 0
  @@kind = JSON::PullParser::Kind::EOF

  def self.calls : Int32
    @@calls
  end

  def self.kind : JSON::PullParser::Kind
    @@kind
  end

  def self.reset : Nil
    @@calls = 0
    @@kind = JSON::PullParser::Kind::EOF
  end

  def self.from_json(pull : JSON::PullParser) : String
    @@calls += 1
    @@kind = pull.kind
    "converted:#{pull.read_string}"
  end
end

private class AdapterCompatConvertedRecord
  include JSON::Serializable

  @[JSON::Field(converter: AdapterCompatNominalConverter)]
  getter value : String

  getter tail : Int32
end

abstract class AdapterCompatShape
  include JSON::Serializable

  use_json_discriminator "type", {point: AdapterCompatPoint, circle: AdapterCompatCircle}

  getter type : String
end

class AdapterCompatPoint < AdapterCompatShape
  getter x : Int32
  getter y : Int32
end

class AdapterCompatCircle < AdapterCompatShape
  getter radius : Float64
end

describe "typed JSON adapter compatibility" do
  it "supports String::RawConverter through both raw traversal overloads" do
    source = %q({"raw":{"wide":340282366920938463463374607431768211455,"float":1.2300e+04,"huge":1e309,"tiny":2e-324,"array":[null,true,"line\n\u03bb",{"x":-0}]},"tail":7})
    record = FusedJSON.from_json(source, AdapterCompatRawRecord)

    record.raw.should eq(%q({"wide":340282366920938463463374607431768211455,"float":1.2300e+04,"huge":1e309,"tiny":2e-324,"array":[null,true,"line\nλ",{"x":-0}]}))
    record.tail.should eq(7)
  end

  it "replays an ambiguous nonprimitive union from its raw object" do
    value = FusedJSON.from_json(
      %q({"beta":9,"wide":340282366920938463463374607431768211455}),
      AdapterCompatAlpha | AdapterCompatBeta
    )

    beta = value.as(AdapterCompatBeta)
    beta.beta.should eq(9)
    beta.wide.should eq(UInt128::MAX)
  end

  it "honors root, presence, default, and ignored field rules" do
    present = FusedJSON.from_json(
      %q({"ignored":{"nested":[1,true,{"x":"y"}]},"rooted":{"before":0,"payload":"inside","after":[false]},"optional":null}),
      AdapterCompatFieldRules
    )

    present.rooted.should eq("inside")
    present.optional.should be_nil
    present.optional_present?.should be_true
    present.retries.should eq(3)
    present.ignored.should eq("local")

    absent = FusedJSON.from_json(
      %q({"rooted":{"payload":"fallback"},"retries":9}),
      AdapterCompatFieldRules
    )

    absent.rooted.should eq("fallback")
    absent.optional.should be_nil
    absent.optional_present?.should be_false
    absent.retries.should eq(9)
    absent.ignored.should eq("local")
  end

  it "dispatches a converter typed as the nominal stdlib pull parser" do
    AdapterCompatNominalConverter.reset
    record = FusedJSON.from_json(
      %q({"value":"payload","tail":11}),
      AdapterCompatConvertedRecord
    )

    AdapterCompatNominalConverter.calls.should eq(1)
    AdapterCompatNominalConverter.kind.should eq(JSON::PullParser::Kind::String)
    record.value.should eq("converted:payload")
    record.tail.should eq(11)
  end

  it "replays discriminator objects through the raw builder path" do
    point = FusedJSON.from_json(
      %q({"type":"point","x":3,"y":4,"ignored":{"huge":1e309}}),
      AdapterCompatShape
    )
    point.should be_a(AdapterCompatPoint)
    point.as(AdapterCompatPoint).x.should eq(3)

    circle = FusedJSON.from_json(
      %q({"radius":2.5,"type":"circle"}),
      AdapterCompatShape
    )
    circle.should be_a(AdapterCompatCircle)
    circle.as(AdapterCompatCircle).radius.should eq(2.5)
  end
end

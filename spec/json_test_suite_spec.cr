require "./spec_helper"
require "./support/json_test_suite"

describe "JSONTestSuite parsing conformance" do
  it "contains the complete pinned parsing corpus" do
    JSONTestSuiteSupport.names("y").size.should eq(95)
    JSONTestSuiteSupport.names("n").size.should eq(188)
    JSONTestSuiteSupport.names("i").size.should eq(35)
  end

  it "accepts every y_ fixture" do
    failures = [] of String

    JSONTestSuiteSupport.names("y").each do |name|
      FusedJSON.load(JSONTestSuiteSupport.source(name))
    rescue error
      failures << "#{name}: #{error.class}: #{error.message}"
    end

    failures.should be_empty
  end

  it "rejects every n_ fixture with a parse error" do
    failures = [] of String

    JSONTestSuiteSupport.names("n").each do |name|
      FusedJSON.load(JSONTestSuiteSupport.source(name))
      failures << "#{name}: accepted"
    rescue FusedJSON::ParseError
    rescue error
      failures << "#{name}: #{error.class}: #{error.message}"
    end

    failures.should be_empty
  end

  it "explicitly classifies every i_ fixture" do
    JSONTestSuiteSupport::I_ACCEPT.should_not be_empty
    JSONTestSuiteSupport::I_ACCEPT.&(JSONTestSuiteSupport::I_REJECT).should be_empty
    (JSONTestSuiteSupport::I_ACCEPT + JSONTestSuiteSupport::I_REJECT).sort.should eq(JSONTestSuiteSupport.names("i"))
  end

  it "accepts the implementation-defined fixtures selected by policy" do
    failures = [] of String

    JSONTestSuiteSupport::I_ACCEPT.each do |name|
      FusedJSON.load(JSONTestSuiteSupport.source(name))
    rescue error
      failures << "#{name}: #{error.class}: #{error.message}"
    end

    failures.should be_empty
  end

  it "rejects the implementation-defined fixtures selected by policy" do
    failures = [] of String

    JSONTestSuiteSupport::I_REJECT.each do |name|
      FusedJSON.load(JSONTestSuiteSupport.source(name))
      failures << "#{name}: accepted"
    rescue FusedJSON::ParseError
    rescue error
      failures << "#{name}: #{error.class}: #{error.message}"
    end

    failures.should be_empty
  end
end

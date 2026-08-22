require "./spec_helper"
require "./support/json_test_suite"
require "./support/pull_helpers"

private def pull_rejection(source : String, *, skip : Bool) : String?
  begin
    if skip
      PullSpecHelpers.skip(source)
    else
      PullSpecHelpers.to_any(source)
    end
    "accepted"
  rescue FusedJSON::ParseError
    nil
  rescue error
    "#{error.class}: #{error.message}"
  end
end

describe "pull JSONTestSuite conformance" do
  it "builds and skips every required-valid fixture" do
    failures = [] of String

    JSONTestSuiteSupport.names("y").each do |name|
      source = JSONTestSuiteSupport.source(name)
      begin
        expected = JSON.parse(source)
        FusedJSON.load(source).should eq(expected)
        PullSpecHelpers.to_any(source).should eq(expected)
        PullSpecHelpers.skip(source)
      rescue error
        failures << "#{name}: #{error.class}: #{error.message}"
      end
    end

    failures.should be_empty
  end

  it "rejects every required-invalid fixture while building and skipping" do
    failures = [] of String

    JSONTestSuiteSupport.names("n").each do |name|
      source = JSONTestSuiteSupport.source(name)
      if error = pull_rejection(source, skip: false)
        failures << "#{name} build: #{error}"
      end
      if error = pull_rejection(source, skip: true)
        failures << "#{name} skip: #{error}"
      end
    end

    failures.should be_empty
  end

  it "applies the implementation-defined policy while building and skipping" do
    failures = [] of String

    JSONTestSuiteSupport::I_ACCEPT.each do |name|
      source = JSONTestSuiteSupport.source(name)
      begin
        PullSpecHelpers.to_any(source).should eq(FusedJSON.load(source))
        PullSpecHelpers.skip(source)
      rescue error
        failures << "#{name}: #{error.class}: #{error.message}"
      end
    end

    JSONTestSuiteSupport::I_REJECT.each do |name|
      source = JSONTestSuiteSupport.source(name)
      if error = pull_rejection(source, skip: false)
        failures << "#{name} build: #{error}"
      end
      if error = pull_rejection(source, skip: true)
        failures << "#{name} skip: #{error}"
      end
    end

    failures.should be_empty
  end
end

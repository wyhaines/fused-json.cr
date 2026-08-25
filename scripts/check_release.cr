require "semantic_version"
require "yaml"

require "../src/fused_json"

abort "usage: #{PROGRAM_NAME} VERSION" unless ARGV.size == 1
version = ARGV.first
begin
  parsed_version = SemanticVersion.parse(version)
rescue ArgumentError
  abort "release version must be a semantic version without a v prefix"
end
abort "release version must use canonical semantic-version syntax" unless parsed_version.to_s == version

manifest = YAML.parse(File.read(File.expand_path("../shard.yml", __DIR__)))
manifest_version = manifest["version"].as_s
manifest_name = manifest["name"].as_s
manifest_repository = manifest["repository"].as_s
manifest_homepage = manifest["homepage"].as_s

abort "shard.yml version is #{manifest_version}, expected #{version}" unless manifest_version == version
abort "shard.yml name is #{manifest_name}, expected fused_json" unless manifest_name == "fused_json"
expected_url = "https://github.com/wyhaines/fused-json.cr"
abort "shard.yml repository is #{manifest_repository}, expected #{expected_url}" unless manifest_repository == expected_url
abort "shard.yml homepage is #{manifest_homepage}, expected #{expected_url}" unless manifest_homepage == expected_url
abort "FusedJSON::VERSION is #{FusedJSON::VERSION}, expected #{version}" unless FusedJSON::VERSION == version

readme = File.read(File.expand_path("../README.md", __DIR__))
readme_version = "version: ~> #{version}"
unless readme.each_line.any? { |line| line.strip == readme_version }
  abort "README installation must contain #{readme_version.inspect}"
end

changelog = File.read(File.expand_path("../CHANGELOG.md", __DIR__))
release_heading = /^## #{Regex.escape(version)} - \d{4}-\d{2}-\d{2}$/
unless changelog.each_line.any? { |line| release_heading.matches?(line) }
  abort "CHANGELOG is missing a dated #{version} release heading"
end

puts "Release version #{version} is synchronized"

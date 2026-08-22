require "../src/fused_json"

directory = ARGV[0]? || abort "usage: #{PROGRAM_NAME} FIXTURE_DIRECTORY"
files = Dir[File.join(directory, "*.json")].sort
mismatches = [] of String

files.each do |path|
  source = File.read(path)
  stdlib = begin
    JSON.parse(source)
  rescue JSON::ParseException
    nil
  end
  candidate = begin
    FusedJSON.load(source)
  rescue FusedJSON::ParseError
    nil
  end

  unless (stdlib.nil? && candidate.nil?) || (!stdlib.nil? && !candidate.nil? && stdlib == candidate)
    mismatches << File.basename(path)
  end
end

puts "checked=#{files.size} mismatches=#{mismatches.size}"
puts mismatches.join('\n')
exit 1 unless mismatches.empty?

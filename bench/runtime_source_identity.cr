require "digest/sha256"

# Invoked at compile time by the attribution benchmarks. A commit identifies
# the parent revision; this digest also identifies uncommitted runtime changes.
if file = ARGV.first?
  puts Digest::SHA256.hexdigest(File.read(File.join(__DIR__, file))).inspect
  exit
end

root = File.expand_path("../src", __DIR__)
manifest = Dir.glob(File.join(root, "**", "*.cr")).sort.map do |path|
  "#{Path[path].relative_to(root)}:#{Digest::SHA256.hexdigest(File.read(path))}\n"
end.join
puts Digest::SHA256.hexdigest(manifest).inspect

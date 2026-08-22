require "../src/fused_json"

source = %({"name":"Crystal","values":[1,2,3]})

document = FusedJSON.load(source)
raise "unexpected name" unless document["name"].as_s == "Crystal"

# Key caching is useful only when object keys repeat heavily.
cached = FusedJSON.load(source, cache_keys: true)
raise "cached parse differs" unless cached == document

# IO input is consumed as one complete document and remains caller-owned.
io = IO::Memory.new(source)
streamed = FusedJSON.load(io, buffer_size: 8)
raise "streaming parse differs" unless streamed == document

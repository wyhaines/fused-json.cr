require "../src/fused_json"

struct LogEvent
  include JSON::Serializable

  getter id : Int64
  getter message : String
end

source = %({"id":1,"message":"started"}\n{"id":2,"message":"done"}\n)
input = IO::Memory.new(source)
reader = FusedJSON.documents(
  input,
  LogEvent,
  framing: FusedJSON::DocumentFraming::NDJSON,
  cache_keys: true
)

reader.each do |event|
  puts "#{event.id}: #{event.message}"
end
reader.finish

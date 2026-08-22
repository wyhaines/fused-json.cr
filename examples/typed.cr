require "../src/fused_json"

struct Event
  include JSON::Serializable

  getter id : UInt64
  getter tags : Array(String)
end

source = %({"id":42,"tags":["crystal","json"]})
expected = Event.new(JSON::PullParser.new(source))

event = FusedJSON.from_json(source, Event)
raise "typed parse differs" unless event == expected

io = IO::Memory.new(source)
streamed = FusedJSON.from_json(io, Event, buffer_size: 8)
raise "streaming typed parse differs" unless streamed == expected

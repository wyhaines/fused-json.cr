require "../src/fused_json"

source = %({"name":"Crystal","data":[1,2,3]})
pull = FusedJSON::PullParser.new(source)

pull.read_begin_object
raise "unexpected key" unless pull.read_object_key == "name"
raise "unexpected value" unless pull.read_string == "Crystal"
raise "unexpected key" unless pull.read_object_key == "data"
pull.skip_value
pull.read_end_object
pull.finish

# The same event API reads incrementally from caller-owned IO.
io = IO::Memory.new(%(["one","two"]))
stream = FusedJSON::PullParser.new(io, buffer_size: 4)
values = [] of String
stream.read_array { values << stream.read_string }
stream.finish
raise "unexpected streamed values" unless values == ["one", "two"]

# Typed reads materialize one selected value and leave the outer cursor ready
# for structural traversal.
struct PullExampleRecord
  include JSON::Serializable

  getter id : UInt64
  getter name : String
end

typed = FusedJSON::PullParser.new(%({"metadata":{"ignored":true},"record":{"id":7,"name":"selected"}}))
records = [] of PullExampleRecord
typed.read_object do |key|
  key == "record" ? records << typed.read(PullExampleRecord) : typed.skip
end
typed.finish
raise "unexpected typed value" unless records.first.name == "selected"

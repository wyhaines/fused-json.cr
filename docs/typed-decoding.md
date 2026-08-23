# Typed Decoding

Typed decoding is experimental. `FusedJSON.from_json` consumes one complete
`String` or `IO` document; `PullParser#read(T)` decodes one selected value at
the current cursor. Both construct the requested Crystal type without first
building a `JSON::Any` tree:

```crystal
require "fused_json"

struct Event
  include JSON::Serializable

  getter id : UInt64
  getter tags : Array(String)
end

source = %({"id":42,"tags":["crystal","json"]})
event = FusedJSON.from_json(source, Event, cache_keys: true)

event = File.open("event.json") do |io|
  FusedJSON.from_json(io, Event, buffer_size: 64 * 1024)
end
```

The entry point is:

```text
FusedJSON.from_json(source : String, type : T.class, *,
                    max_nesting : Int = 512,
                    cache_keys : Bool = false,
                    limits : Limits = Limits::DEFAULT) : T
FusedJSON.from_json(source : IO, type : T.class, *,
                    buffer_size : Int = 32 * 1024,
                    max_nesting : Int = 512,
                    cache_keys : Bool = false,
                    max_token_bytes : Int? = nil,
                    limits : Limits = Limits::DEFAULT) : T
pull.read(type : T.class) : T
pull.read_array(type : T.class, & : T ->) : Nil
```

`from_json` decodes a complete document. `PullParser#read(T)` applies the same
typed constructor to exactly one value at the current cursor, which can be
nested inside an array or object:

```crystal
require "fused_json"

struct SelectedEvent
  include JSON::Serializable

  getter id : UInt64
  getter name : String
end

pull = FusedJSON::PullParser.new(%({"metadata":{"skip":true},"event":{"id":42,"name":"selected"}}))
events = [] of SelectedEvent
pull.read_object do |key|
  key == "event" ? events << pull.read(SelectedEvent) : pull.skip
end
pull.finish
event = events.first
```

To stream a selected array without retaining the complete collection, use the
typed block overload:

```crystal
require "fused_json"

struct StreamedEvent
  include JSON::Serializable

  getter id : UInt64
end

pull = FusedJSON::PullParser.new(%({"events":[{"id":1},{"id":2}]}))
ids = [] of UInt64
pull.read_object do |key|
  key == "events" ? pull.read_array(StreamedEvent) { |event| ids << event.id } : pull.skip
end
pull.finish
```

After a successful `read(T)`, the native cursor is on the next sibling,
enclosing end event, or EOF. The compatibility adapter shows the constructor an
isolated one-value document, preventing it from consuming a sibling. Object
keys and end events are not values. Constructors that consume nothing or only
part of the value are rejected.

`max_typed_value_bytes` limits the selected raw JSON span. It includes
container punctuation and internal whitespace but excludes surrounding
whitespace and sibling lookahead. `read_array(T)` gives each element a fresh
budget. The root passed to `from_json` is one selected value.

The implementation uses internal `JSON::PullParser` compatibility adapters, so
standard Crystal constructors, generated `JSON::Serializable` code, and
converters that accept `JSON::PullParser` can consume native FusedJSON events.
Separate concrete adapters keep the `String` and `IO` native parser types
statically known.

## Supported Features

| Area | Current support |
| --- | --- |
| Scalars | `Nil`, `Bool`, `String`, all fixed-width integers, `BigInt`, `BigFloat`, `BigDecimal`, `Float32`, `Float64` |
| Collections | `Array`, `Hash`, `Tuple`, `NamedTuple` |
| Alternatives | Nilable values, primitive unions, tested structured-union replay |
| Other standard types | Enums |
| `JSON::Serializable` | Required and default fields, nilable fields, renamed keys, converters, roots, presence tracking, ignored fields, discriminators |
| Field policies | Default unknown-field skipping, `Strict`, `Unmapped`, duplicate-last or limits-based rejection |
| Raw values | `String::RawConverter`, including nested arrays and objects |

`FusedJSON.from_json` requires its input to contain exactly one value. Trailing
non-whitespace content is an error, including the second-scalar case currently
accepted by some Crystal stdlib paths. A cursor read instead consumes only its
selected value. Unknown fields are still fully syntax-checked when skipped.

Integer tokens retain their exact source range. Narrow integer targets use the
normal `Int64` path; `UInt64`, `Int128`, and `UInt128` use Crystal's standard
raw-number constructors and therefore allocate one numeric string.
Arbitrary-precision integers and floating values, plus exact decimal values,
are available when the application loads Crystal's adapter:

```crystal
require "fused_json"
require "big/json"

value = FusedJSON.from_json(
  "1234567890123456789012345678901234567890",
  BigInt
)
decimal = FusedJSON::PullParser.new("1234567890.000000000000000001").read(BigDecimal)
```

This is explicit typed decoding; `load` retains Crystal's dynamic `JSON::Any`
domain and rejects integers outside `Int64`. The public pull reader recognizes
wide numbers without converting them, but direct integer reads still require
`Int64`. Floating tokens are syntax-checked before use; converting one to
`Float32` or `Float64` applies Crystal's standard constructor path and
FusedJSON's finite-`Float64` policy. Raw converters and skipped fields may
preserve a valid token outside that range. Direct and union `Float32`
conversions intentionally follow their respective Crystal stdlib paths.
`BigInt`, `BigFloat`, and `BigDecimal` consume the exact raw token rather than a
prior `Int64` or `Float64` conversion. `cache_keys` remains local to one native
reader and is useful for documents with repeated object keys. With duplicate
rejection off, structural skipping leaves keys inside the skipped value
unmaterialized. Duplicate rejection is a separate per-object check, applies to
unknown and skipped data, and must decode those keys. If caching is also on,
the decoded keys enter the pool.

Native syntax, type, and structural failures raise `FusedJSON::ParseError`;
generated serializers may wrap them in `JSON::SerializableError` and retain
the native error as the cause. Standard target constructors and custom
converters can raise their documented conversion exceptions. Locations are
one-based line and column values, while `ParseError#byte_offset` is zero-based.
For a transcoding `IO`, byte offsets refer to decoded UTF-8 bytes.

Typed cursor reads perform the native reader's normal one-event lookahead. A
malformed or oversized following string or number can therefore fail a read
before its completed value is returned. Failures are not transactional: no
partial `T` is returned, but constructor side effects and input consumption
cannot be undone. Discard the reader after any typed constructor or read error.

The same lookahead applies between typed array callbacks. A callback is invoked
only after its element and the next event are recognized; a malformed next
string or number can therefore prevent the completed element from being
yielded. Callbacks must not advance the shared reader. Exceptions and early
block exits do not drain the array, so output that requires whole-document
validity must be staged until `finish` succeeds.

## IO Behavior

`buffer_size` applies only to `IO`, defaults to 32 KiB, and must be between 1
byte and 16 MiB. The input is borrowed and never closed. Decoding starts at its
current position and may read ahead. `FusedJSON.from_json` strictly requires EOF
after the target constructor consumes one value; a cursor read stops after its
selected value and one-event lookahead. Positive short reads are supported; a
zero-byte read is permanent EOF.

`FusedJSON::Limits` applies to typed decoding from `String` and `IO`.
`max_token_bytes` bounds raw scalar scratch, including unknown fields that are
skipped, while `max_typed_value_bytes` bounds the complete selected source
span. A scalar is scanned before `read(T)` selects it, and a retrospective
streaming string or number error may copy that token into location scratch.
Set both limits when each allocation path must be bounded. These source-byte
limits do not cap the heap used by the constructed `T`. See
[Streaming Input](streaming.md) for ownership, memory, and encoding details.

## Deferred

Lazy iterators, automatic arbitrary-precision values in dynamic `JSON::Any`,
and a public adapter object are not yet supported contracts. A type must
eagerly consume one value through
`new(pull : JSON::PullParser)`; the facade verifies source exhaustion and a
cursor read verifies completion of the selected value.

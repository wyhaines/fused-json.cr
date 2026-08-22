# Typed Decoding

Typed decoding is experimental. It consumes one complete `String` or `IO`
document and constructs the requested Crystal type without first building a
`JSON::Any` tree:

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
                    cache_keys : Bool = false) : T
FusedJSON.from_json(source : IO, type : T.class, *,
                    buffer_size : Int = 32 * 1024,
                    max_nesting : Int = 512,
                    cache_keys : Bool = false,
                    max_token_bytes : Int? = nil) : T
```

The implementation uses internal `JSON::PullParser` compatibility adapters, so
standard Crystal constructors, generated `JSON::Serializable` code, and
converters that accept `JSON::PullParser` can consume native FusedJSON events.
Separate concrete adapters keep the `String` and `IO` native parser types
statically known.

## Supported Features

| Area | Current support |
| --- | --- |
| Scalars | `Nil`, `Bool`, `String`, all fixed-width integers, `BigInt`, `Float32`, `Float64` |
| Collections | `Array`, `Hash`, `Tuple`, `NamedTuple` |
| Alternatives | Nilable values, primitive unions, tested structured-union replay |
| Other standard types | Enums |
| `JSON::Serializable` | Required and default fields, nilable fields, renamed keys, converters, roots, presence tracking, ignored fields, discriminators |
| Field policies | Default unknown-field skipping, `Strict`, `Unmapped`, duplicate-last |
| Raw values | `String::RawConverter`, including nested arrays and objects |

All input must contain exactly one value. Trailing non-whitespace content is an
error, including the second-scalar case currently accepted by some Crystal
stdlib paths. Unknown fields are still fully syntax-checked when skipped.

Integer tokens retain their exact source range. Narrow integer targets use the
normal `Int64` path; `UInt64`, `Int128`, and `UInt128` use Crystal's standard
raw-number constructors and therefore allocate one numeric string. Typed
arbitrary-precision integers are also available when the application loads
Crystal's adapter:

```crystal
require "fused_json"
require "big/json"

value = FusedJSON.from_json(
  "1234567890123456789012345678901234567890",
  BigInt
)
```

This is explicit typed decoding; `load` and the public pull reader retain
Crystal's dynamic `JSON::Any` domain and reject integers outside `Int64`.
Floating tokens are syntax-checked before use; converting one to `Float32` or
`Float64` applies Crystal's standard constructor path and FusedJSON's
finite-`Float64` policy. Raw converters and skipped fields may preserve a valid
token outside that range. Direct and union `Float32` conversions intentionally
follow their respective Crystal stdlib paths. `cache_keys` remains local to one
decode and is useful for documents with repeated object keys.

Native syntax, type, and structural failures raise `FusedJSON::ParseError`;
generated serializers may wrap them in `JSON::SerializableError`. Standard
target constructors and custom converters can raise their documented
conversion exceptions. Locations are one-based line and column values, while
`ParseError#byte_offset` is zero-based. For a transcoding `IO`, byte offsets
refer to decoded UTF-8 bytes.

## IO Behavior

`buffer_size` applies only to `IO`, defaults to 32 KiB, and must be between 1
byte and 16 MiB. The input is borrowed and never closed. Decoding starts at its
current position, may read ahead, and strictly requires EOF after the target
constructor consumes one value. Positive short reads are supported; a
zero-byte read is permanent EOF. `max_token_bytes` can bound each raw string or
number token, including unknown fields that typed decoding skips. See
[Streaming Input](streaming.md) for memory and encoding details.

## Deferred

Lazy iterators, automatic arbitrary-precision values in dynamic `JSON::Any`,
and a public adapter object are not yet supported contracts. A type must eagerly
consume one value through `new(pull : JSON::PullParser)`; the factory verifies
source exhaustion immediately afterward.

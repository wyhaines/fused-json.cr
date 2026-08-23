# Streaming Input

FusedJSON can parse one complete JSON document directly from an `IO`. The
streaming entry points use the same strict grammar, numeric behavior, nesting
rules, and duplicate-key behavior as their `String` counterparts.

## Entry Points

```text
FusedJSON::PullParser.new(io : IO, *, buffer_size : Int = 32 * 1024,
                          max_nesting : Int = 512, cache_keys : Bool = false,
                          max_token_bytes : Int? = nil,
                          limits : Limits = Limits::DEFAULT)
FusedJSON.load(io : IO, *, buffer_size : Int = 32 * 1024,
               max_nesting : Int = 512, cache_keys : Bool = false,
               max_token_bytes : Int? = nil,
               limits : Limits = Limits::DEFAULT) : JSON::Any
FusedJSON.parse(io : IO, *, buffer_size : Int = 32 * 1024,
                max_nesting : Int = 512, cache_keys : Bool = false,
                max_token_bytes : Int? = nil,
                limits : Limits = Limits::DEFAULT) : JSON::Any
FusedJSON.from_json(io : IO, type : T.class, *, buffer_size : Int = 32 * 1024,
                    max_nesting : Int = 512, cache_keys : Bool = false,
                    max_token_bytes : Int? = nil,
                    limits : Limits = Limits::DEFAULT) : T
pull.read(type : T.class) : T
pull.read_array(type : T.class, & : T ->) : Nil
```

Use the pull reader when values should be processed incrementally:

```crystal
require "fused_json"

File.open("events.json") do |io|
  pull = FusedJSON::PullParser.new(io, buffer_size: 32 * 1024)
  pull.read_array do
    # Consume exactly one complete element per iteration.
    puts pull.read_string
  end
  pull.finish
end
```

Construction primes the reader on its first semantic event. After consuming
the root value, call `finish` to require end of input. `skip` and `skip_value`
still validate the complete skipped value.

`read(T)` materializes one typed value at the current cursor without requiring
document EOF, then leaves the native reader on the next sibling or enclosing
end event. This supports structural navigation around selected typed values.
The typed constructor cannot cross that value boundary. If it raises or does
not consume exactly one complete value, discard the reader.

`read_array(T)` consumes a current array and synchronously yields each decoded
element without retaining it. The callback must not advance the shared reader.
If the callback raises or exits early, the parser does not drain the remainder;
discard it and recreate the input if another pass is required.

At a numeric event, `raw_number_value` returns the exact token without
advancing, while `read_raw_number` returns it and advances once. Neither method
performs numeric conversion. Direct integer and float reads retain their checked
conversion limits, and dynamic tree construction still uses `Int64` and finite
`Float64` values.

The dynamic-tree overloads build `JSON::Any`; `parse` is an alias for `load`:

```crystal
require "fused_json"

value = File.open("document.json") { |io| FusedJSON.load(io) }
value = File.open("document.json") { |io| FusedJSON.parse(io) }
```

Typed decoding avoids an intermediate `JSON::Any` tree:

```crystal
require "fused_json"

struct Record
  include JSON::Serializable

  getter id : Int64
end

record = File.open("record.json") do |io|
  FusedJSON.from_json(io, Record, cache_keys: true)
end
```

All entry points accept an immutable `FusedJSON::Limits`. It can bound the
decoded document stream, individual string and number tokens, each selected
typed value, the total value count, entries per container, and the local key
cache. It can also reject duplicate decoded keys. The
[API contract](api.md#entry-points-and-options) defines each counter.

`buffer_size` defaults to 32 KiB and must be between 1 byte and 16 MiB.
Existing `max_nesting` and `max_token_bytes` keywords remain available. If a
legacy keyword and `limits` constrain the same resource, the smaller value
wins. Invalid options raise `ArgumentError` before input is read; limit
violations originate as `FusedJSON::ParseError`. Generated
`JSON::Serializable` constructors may wrap the native error in
`JSON::SerializableError` and retain it as the cause.

`max_document_bytes` charges bytes as the parser logically consumes them from
the decoded UTF-8 stream. Input fetched into a read-ahead buffer does not count
until it is consumed. If pull traversal stops early, an unread tail is neither
charged nor validated.

## IO Ownership and Exhaustion

The input is borrowed. FusedJSON never closes it; the caller remains
responsible for its lifetime on success and on every error path. FusedJSON may
read ahead into its refill buffer, and a caller-supplied IO or encoding wrapper
may buffer farther independently. Do not rely on the underlying IO being
positioned immediately after the current event. The facade APIs consume to
EOF. In the pull API, advancing after the root scans trailing whitespace and
probes EOF; `finish` then asserts that EOF was reached. These APIs are therefore
for one document per IO, not concatenated documents.

Advancing a typed value performs the same one-event lookahead as every other
pull read. A following string or number is scanned completely; if that token is
malformed or exceeds `max_token_bytes`, the typed read fails before returning
the completed value. A following array or object stops at its opening event and
does not traverse its contents. Global document, token, value-count, entry,
cache, and duplicate checks apply during lookahead. The prior value's
`max_typed_value_bytes` budget does not.

Short positive reads are supported. Following Crystal's `IO` contract, a
zero-length read means permanent EOF and is not retried. An IO representing
temporary unavailability must wait or signal that state without returning
zero. Strict exhaustion can block on a source that has delivered a complete
JSON value but has not yet reached EOF.

Input is obtained through `IO#read_utf8`. With the default UTF-8 encoding,
`ParseError#byte_offset` is the zero-based input byte offset. If the IO has a
different encoding configured, it is decoded first and offsets count bytes in
the resulting UTF-8 stream, not bytes in the underlying encoded source.
Lines and columns are one-based; columns count decoded Unicode code points for
valid non-ASCII input.

## Memory Bounds

FusedJSON's reusable decoded input buffer is bounded by `buffer_size`, but
total memory is not always bounded by that option. Caller-owned IO and encoding
buffers are outside this limit.

- A string or number spanning refills needs scratch storage proportional to
  that current token. Set `max_token_bytes` when input is untrusted. Internal
  buffers grow geometrically, so this is a logical token limit rather than an
  exact total-memory cap. Completed scratch up to
  `max(2 * buffer_size, 64 KiB)` is reused; larger scratch is released for GC
  when the reader advances. Returned strings are owned values. Each
  `raw_number_value` or `read_raw_number` call allocates an owned string
  proportional to the current token.
- `cache_keys: true` retains one pooled copy of each distinct materialized key
  for the parser's lifetime. With duplicate rejection off, an untyped pull
  `skip` leaves keys inside the skipped value unmaterialized and does not insert
  them. Duplicate rejection must decode skipped keys; with caching also on,
  they enter the pool. `max_cached_keys` bounds pool insertions, not the
  duplicate sets.
- Duplicate rejection retains one decoded key per distinct member in each open
  object until that object closes. `max_container_entries` bounds each set,
  but nested sets add together. Pair it with `max_token_bytes` when the input
  is untrusted.
- `load(IO)` and `parse(IO)` necessarily allocate the complete `JSON::Any`
  result tree.
- Typed targets allocate their own result. String-returning raw operations—used
  by `String::RawConverter`, ambiguous non-primitive unions, and JSON
  discriminators—materialize the selected complete subtree before replaying
  it. A caller-supplied raw builder can instead receive events incrementally.
  Wide numeric constructors may also allocate the current numeric token.

For bounded processing of large arrays or objects, prefer `PullParser` and
consume or skip each value before advancing. `read_array(T)` bounds parser
retention by the current value when the callback does not retain results; a
typed outer item can still be large, so navigate structurally to a smaller
nested array when necessary.

Document, token, and typed-value byte limits count parser-visible decoded
source spans. They are not exact Crystal heap limits. They do not include raw
compressed ingress, caller-owned IO and decompressor buffers, allocator
capacity, returned values, or data retained by callbacks. A scalar event is
already scanned when `read(T)` selects it. Locating a retrospective typed-value
failure for a string or number may copy that current token into error-reporting
scratch. Use `max_token_bytes` as well as `max_typed_value_bytes` to bound the
initial scan and this copy.

# Resource limits API decision

Status: accepted for large-document Milestone 5.

## Public API

All parsing entry points accept an immutable `FusedJSON::Limits` value:

```crystal
require "fused_json"

limits = FusedJSON::Limits.new(
  max_nesting: 64,
  max_token_bytes: 1 * 1024 * 1024,
  max_document_bytes: 8_i64 * 1024 * 1024 * 1024,
  max_typed_value_bytes: 16 * 1024 * 1024,
  max_total_values: 50_000_000,
  max_container_entries: 5_000_000,
  max_cached_keys: 10_000,
  reject_duplicate_keys: true
)
```

`max_nesting` defaults to 512. Every other numeric limit defaults to `nil`,
meaning no separate limit, and duplicate rejection defaults to `false`.
Nesting remains in `1..512`; token bytes remain in `1..Int32::MAX`. The new
byte and count limits accept `0..Int64::MAX`; zero permits no matching byte,
value, entry, or cached key.

`buffer_size` and `cache_keys` remain separate parser options. Existing
`max_nesting` and streaming `max_token_bytes` keywords remain source
compatible. When a legacy keyword and `limits` both constrain the same
resource, the smaller value wins; neither form can loosen the other. Every
supplied option is validated before an `IO` is read. A cache limit is already
satisfied and has no effect when `cache_keys` is false.

## Counting rules

- `max_document_bytes` counts bytes in the parser-visible decoded UTF-8 stream
  from the input's current position. It includes leading and trailing JSON
  whitespace, punctuation, keys, values, and invalid trailing data. It does
  not count transport bytes or bytes fetched into a buffer but not logically
  consumed. Gzip input therefore counts decompressed bytes; transcoding IO
  counts its UTF-8 output.
- `max_token_bytes` retains its existing meaning: raw bytes in one string or
  number token, including string quotes and escape spelling. Object keys and
  skipped tokens count. Its error points to the token opening byte.
- `max_typed_value_bytes` covers the raw span from the first byte through the
  last byte of each value selected by `from_json` or `PullParser#read(T)`.
  Container punctuation and internal whitespace count; surrounding whitespace
  and sibling lookahead do not. `read_array(T)` starts a fresh budget for each
  element. Structural reads, scalar reads, and `skip` do not select a value.
- `max_total_values` counts the root and every scalar, array, and object once.
  Object keys and end events do not count. Values encountered while skipping,
  decoding unknown fields, or performing lookahead do count.
- `max_container_entries` is independent for every container. Each array
  element or object member counts once; duplicate members count.
- `max_cached_keys` counts distinct decoded strings inserted into the
  parser-local key pool. Repeats and escape-equivalent spellings count once.

Document-sized counters and offsets use `Int64`. Adapters and tree builders do
not count values a second time; the native scanner is authoritative.

## Duplicate keys and errors

Duplicate rejection compares decoded keys using case-sensitive `String`
equality without Unicode normalization. It is scoped to one object, applies
to skipped and typed data, and rejects the second key before its value is
consumed. It is independent of document-wide key caching.

A document- or typed-value-byte error points to the first forbidden byte. A
total-value error points to the opening byte of the first disallowed value.
Container-entry errors point to the extra element or key opening; cache and
duplicate errors point to the offending key quote. Existing nesting and token
locations do not change. Native limit violations raise
`FusedJSON::ParseError`. Generated `JSON::Serializable` code may wrap it in
`JSON::SerializableError`, preserving the native error as the cause.

When byte limits overlap, the first forbidden source boundary wins. At an
equal boundary, document bytes take precedence over typed-value bytes, and
either source-span limit takes precedence over token bytes. A limit at an
already forbidden byte is reported before a syntax error at that byte. Normal
pull lookahead may encounter a global limit before returning the prior typed
value, but the prior value's typed-byte budget ends before that lookahead.

## Memory and implementation constraints

Duplicate rejection retains one decoded key per distinct member in every open
object until that object closes. `max_container_entries` bounds each such set,
but nested sets add together, and `max_cached_keys` does not bound them. Token,
document, and typed-value byte limits describe source spans, not Crystal heap
usage. Returned values, raw converters, parser and decompressor buffers,
caller retention, allocator capacity, and GC timing remain separate.

Streaming byte limits must stop before appending forbidden bytes to token or
raw-value scratch. A scalar event is already scanned when `read(T)` selects it,
so its typed-value limit is checked retrospectively before `T.new`. Syntax,
document, or token failures during the initial scan occur first. Locating a
retrospective streaming string or number failure may copy the current token
into error-reporting scratch; callers must also set `max_token_bytes` to bound
the scan and this copy. Container typed values are checked incrementally, and
their scope closes before sibling lookahead. Disabled extended limits allocate
no counter or duplicate-key state, and their release-build overhead must be
measured against the Milestone 4 baseline before closeout.

# Migration Guide

FusedJSON is a strict parser, not a complete port of Ruby Oj or a replacement
for Crystal's JSON generator.

| Existing call | FusedJSON equivalent |
| --- | --- |
| `JSON.parse(source)` | `FusedJSON.load(source)` |
| `T.from_json(source)` | `FusedJSON.from_json(source, T)` |
| `JSON::PullParser.new(source)` | `FusedJSON::PullParser.new(source)` |
| `T.new(json_pull)` at the current cursor | `fused_pull.read(T)` |
| `Array(T).new(json_pull) { |value| ... }` | `fused_pull.read_array(T) { |value| ... }` |
| Ruby `Oj.load(source, mode: :strict)` | `FusedJSON.load(source)` |

Add `fused_json` to `shard.yml`, run `shards install`, and require
`"fused_json"`. Replace one parser boundary at a time and compare complete
results on representative documents before enabling `cache_keys`.

## Behavioral Differences

- Exactly one JSON document is required; trailing content is rejected.
- Dynamic integers returned by `load` or `parse` are limited to `Int64`, and
  dynamic floats must be finite `Float64`. Typed fixed-width integers may use
  their wider target domain; typed `BigInt`, `BigFloat`, and `BigDecimal` are
  available after `require "big/json"`.
- Native syntax failures raise `FusedJSON::ParseError`, not every exception
  type used by Crystal's standard parser or Ruby Oj. Generated
  `JSON::Serializable` constructors may wrap it in `JSON::SerializableError`
  and retain the native error as the cause. Exact English messages differ.
- Duplicate object fields keep the last value in dynamic and typed results,
  and the pull reader exposes every key event. Set
  `reject_duplicate_keys: true` in `FusedJSON::Limits` to reject the second
  decoded key instead.
- Oj compatibility modes, dumping, arbitrary class construction, comments,
  `NaN`, infinity, and trailing commas are not supported.

For `IO`, the caller retains ownership and the parser requires EOF after one
document. Review buffering, read-ahead, transcoding offsets, and resource limits
in the [streaming guide](streaming.md) before migrating network input.

## Resource limits

Pass one immutable `FusedJSON::Limits` value to `load`, `parse`, `from_json`,
or `PullParser`. It can constrain parser-consumed document bytes, raw string
and number tokens, selected typed values, total values, entries per container,
and cached keys. It can also reject duplicate keys in materialized, unknown,
and skipped objects.

Existing `max_nesting` and streaming `max_token_bytes` keywords remain valid.
When a legacy keyword and `limits` cover the same resource, the smaller value
wins. `max_cached_keys` limits actual insertions into the optional local pool;
with duplicate rejection off, an untyped pull `skip` leaves keys inside the
skipped value uncached. Duplicate rejection must decode skipped keys; if
caching is also on, they enter the pool. Its separate per-object sets are
bounded only when container entries and key token size are also bounded.

Document, token, and typed-value byte limits count parser-visible source spans,
not Crystal heap. They do not include raw compressed input, caller-owned IO or
decompressor buffers, returned values, or application retention. Review the
[resource-limits decision](resource-limits-decision.md) before applying these
limits to untrusted input.

## Pull Number Migration

The pull reader now recognizes and skips grammar-valid numbers without forcing
them into the dynamic numeric domain. Code that relied on construction or
`skip` to reject a wide integer or a token outside the finite `Float64` domain
must call `read_int`, `read_float`, or a dynamic facade instead. Use
`raw_number_value` to inspect the current spelling without advancing, or
`read_raw_number` to return that spelling and consume the event. Both raw
methods can return values wider than every fixed-width Crystal integer.

## Typed Cursor Reads

Use `pull.read(T)` to decode one selected value while navigating a larger
document with FusedJSON's pull API. It uses the same Crystal typed semantics as
`from_json`, but completion means the selected value ended rather than the
whole document ended. The cursor then points at the next sibling or enclosing
end event.

Do not pass the native FusedJSON reader directly to code expecting a
`JSON::PullParser`; adapter-backed `read(T)` calls supply the private
compatibility adapter and prevent the constructor from crossing into a
sibling. Built-in scalar fast paths consume exactly one event. A typed-read
error is not recoverable: discard the reader because parsing and constructor
side effects cannot be rolled back.

Use `pull.read_array(T)` when the current value is an array that should be
processed element by element. It preserves source order and does not retain
elements, but the callback must not advance `pull`. A callback exception or
early exit leaves the remainder unchecked; discard the reader and recreate
the caller-owned input for another pass. Call `finish` before committing any
staged output that depends on complete-document validation.

# Migration Guide

FusedJSON is a strict parser, not a complete port of Ruby Oj or a replacement
for Crystal's JSON generator.

| Existing call | FusedJSON equivalent |
| --- | --- |
| `JSON.parse(source)` | `FusedJSON.load(source)` |
| `T.from_json(source)` | `FusedJSON.from_json(source, T)` |
| `JSON::PullParser.new(source)` | `FusedJSON::PullParser.new(source)` |
| `T.new(json_pull)` at the current cursor | `fused_pull.read(T)` |
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
- Invalid syntax raises `FusedJSON::ParseError`, not every exception type used
  by Crystal's standard parser or Ruby Oj. Exact English messages differ.
- Duplicate object fields keep the last value in dynamic and typed results;
  the pull reader exposes every key event.
- Oj compatibility modes, dumping, arbitrary class construction, comments,
  `NaN`, infinity, and trailing commas are not supported.

For `IO`, the caller retains ownership and the parser requires EOF after one
document. Review buffering, read-ahead, transcoding offsets, and resource limits
in the [streaming guide](streaming.md) before migrating network input.

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
document with FusedJSON's pull API. It uses the same Crystal typed constructors
as `from_json`, but completion means the selected value ended rather than the
whole document ended. The cursor then points at the next sibling or enclosing
end event.

Do not pass the native FusedJSON reader directly to code expecting a
`JSON::PullParser`; `read(T)` supplies the private compatibility adapter and
prevents the constructor from crossing into a sibling. A typed-read error is
not recoverable: discard the reader because parsing and constructor side
effects cannot be rolled back.

# Migration Guide

FusedJSON is a strict parser, not a complete port of Ruby Oj or a replacement
for Crystal's JSON generator.

| Existing call | FusedJSON equivalent |
| --- | --- |
| `JSON.parse(source)` | `FusedJSON.load(source)` |
| `T.from_json(source)` | `FusedJSON.from_json(source, T)` |
| `JSON::PullParser.new(source)` | `FusedJSON::PullParser.new(source)` |
| Ruby `Oj.load(source, mode: :strict)` | `FusedJSON.load(source)` |

Add `fused_json` to `shard.yml`, run `shards install`, and require
`"fused_json"`. Replace one parser boundary at a time and compare complete
results on representative documents before enabling `cache_keys`.

## Behavioral Differences

- Exactly one JSON document is required; trailing content is rejected.
- Dynamic integers are limited to `Int64`; dynamic floats must be finite
  `Float64`. Typed fixed-width integers may use their wider target domain, and
  typed `BigInt` is available after `require "big/json"`.
- Invalid syntax raises `FusedJSON::ParseError`, not every exception type used
  by Crystal's standard parser or Ruby Oj. Exact English messages differ.
- Duplicate object fields keep the last value in dynamic and typed results;
  the pull reader exposes every key event.
- Oj compatibility modes, dumping, arbitrary class construction, comments,
  `NaN`, infinity, and trailing commas are not supported.

For `IO`, the caller retains ownership and the parser requires EOF after one
document. Review buffering, read-ahead, transcoding offsets, and resource limits
in the [streaming guide](streaming.md) before migrating network input.

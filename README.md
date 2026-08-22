[![CI](https://github.com/wyhaines/fused-json.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/wyhaines/fused-json.cr/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/release/wyhaines/fused-json.cr.svg)](https://github.com/wyhaines/fused-json.cr/releases)

# FusedJSON

FusedJSON is an experimental, strict JSON parser for Crystal. It provides a fast in-memory `String` path and incremental `IO` parsing without first copying the complete input. Both paths avoid the standard parser's intermediate lexer.

Version 0.1 includes dynamic tree parsing, direct typed decoding, pull parsing, and streaming `IO`. All paths enforce strict JSON, validated UTF-8, Unicode escapes, and nesting limits. Optional key caching can reduce allocation when object keys repeat. Crystal 1.21 through 1.x is supported.

## Installation

Add the shard to your application's `shard.yml`:

```yaml
dependencies:
  fused_json:
    github: wyhaines/fused-json.cr
    version: ~> 0.1.0
```

Run `shards install`, then `require "fused_json"` in application code.

## Usage

```crystal
require "fused_json"

source = %({"name":"Crystal","values":[1,2,3]})
document = FusedJSON.load(source)
document["name"].as_s # => "Crystal"

# Can reduce allocation when a document repeats object keys extensively.
cached = FusedJSON.load(source, cache_keys: true)

# Parse one complete document from a caller-owned IO.
streamed = File.open("document.json") { |io| FusedJSON.load(io) }
```

The complete [basic example](examples/basic.cr) is compiled in CI and can be run from a checkout with `crystal run examples/basic.cr`.

`FusedJSON.parse` is an alias for `load`. Invalid input raises `FusedJSON::ParseError`, which includes byte offset, line, and column data. `String` and `IO` inputs must contain exactly one document. `max_nesting` accepts values from 1 through 512. `IO` overloads also accept `buffer_size`, which defaults to 32 KiB, and an optional `max_token_bytes` limit for raw string and number tokens; see the [streaming guide](docs/streaming.md) for ownership, exhaustion, and memory details.

Key caching is local to one parser and remains off by default. It hashes every materialized object key and reuses equal key strings; the pool retains one copy of every distinct key for the parser's lifetime, so measure both throughput and allocation before enabling it on a workload.

### Typed decoding

Decode directly into standard collections or `JSON::Serializable` types without building a dynamic tree first:

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

See the compile-checked [typed example](examples/typed.cr) for a runnable
`String` and `IO` decode.

This API is experimental and requires the requested type to consume a `JSON::PullParser`. See the [typed decoding guide](docs/typed-decoding.md) for the tested feature matrix, `BigInt`, `BigFloat`, and `BigDecimal` support through `big/json`, and current limitations.

### Pull parsing

`FusedJSON::PullParser` consumes a document without building a dynamic tree. It starts on the first value, returns owned strings, and exposes object keys as string events:

```crystal
require "fused_json"

pull = FusedJSON::PullParser.new(%({"name":"Crystal","data":[1,2,3]}))
pull.read_begin_object
pull.read_object_key # => "name"
pull.read_string     # => "Crystal"
pull.read_object_key # => "data"
pull.skip_value      # validates the array without materializing it
pull.read_end_object
pull.finish
```

Use `kind`, the scalar and container `read_*` methods, `read_array`, `read_object`, `read_next`, and `skip_value`/`skip` to advance. Invalid input or an incompatible read raises `FusedJSON::ParseError`. This reader intentionally has its own type; it is not a drop-in `JSON::PullParser` subclass.

`pull.read(Event)` decodes exactly one value at the current position through the same typed constructors as `FusedJSON.from_json`, then leaves the cursor on the next sibling or enclosing end event. This makes it possible to navigate a large outer document structurally while materializing only selected values. If a typed constructor raises or fails to consume exactly one value, discard that reader.

At an integer or float event, `raw_number_value` returns the exact JSON token without advancing and `read_raw_number` returns it while advancing once. These methods do not narrow the value, so they can preserve decimal spelling or integers wider than `Int128`. Direct `read_int` and `read_float` calls still perform checked `Int64` and finite-`Float64` conversion.

Pass an `IO` instead of a `String` to use the same event API incrementally:

```crystal
require "fused_json"

File.open("events.json") do |io|
  pull = FusedJSON::PullParser.new(io, buffer_size: 32 * 1024)
  pull.read_array { puts pull.read_string }
  pull.finish
end
```

The [pull example](examples/pull.cr) exercises both in-memory and streaming readers and is compiled on every supported Crystal version.

## Development

```console
$ shards install
$ shards build ameba
$ bin/ameba
$ crystal tool format src spec bench examples scripts
$ crystal spec
$ crystal spec -Dfused_json_force_portable_float
$ crystal spec -Dfused_json_force_scalar_string_scan
$ crystal spec -Dfused_json_force_portable_float -Dfused_json_force_scalar_string_scan
$ crystal spec spec/json_test_suite_spec.cr
$ crystal build --release --no-debug bench/parse.cr -o bin/parse-bench
$ bin/parse-bench path/to/document.json
$ crystal build --release --no-debug bench/pull.cr -o bin/pull-bench
$ bin/pull-bench path/to/document.json
$ crystal build --release --no-debug bench/typed.cr -o bin/typed-bench
$ bin/typed-bench path/to/twitter.json
$ crystal build --release --no-debug bench/stream.cr -o bin/stream-bench
$ bin/stream-bench path/to/document.json
$ crystal run bench/fixture_parity.cr -- path/to/fixture-directory
$ crystal run scripts/check_doc_examples.cr
```

For a current-checkout Ruby/Oj comparison, build Oj and run `OJ_ROOT=/path/to/oj ruby bench/parse_oj.rb document.json`.

## Performance Snapshot

CPU-pinned `--release --no-debug` measurements on a Ryzen 9 7940HS with Crystal 1.22.0-dev `[2e13e6a73]` provide directional evidence, not release guarantees. The cited commits belong to the former development repository, are not part of this repository's history, and predate the rename to FusedJSON. At `07d7c9e`, three-run medians put the default fused `load` path between 1.54x and 2.16x Crystal `JSON.parse` on all five canonical corpora, with a 1.77x geometric mean. At `6dbba52`, seven independent samples per backend and corpus, with backend order alternated, showed the word-at-a-time string scanner 6.5% faster geometrically than its forced scalar fallback; CITM was flat within 0.2%, while ActivityPub and Twitter improved by about 12%. Each sample used one second of warmup and two seconds of timed work.

At `9f614df`, five-process medians on the same host put direct typed decoding at 1.129x Crystal's typed decoder on the Twitter corpus, or 1.209x with local key caching. Cached typed decoding used 0.468x its managed allocation. Pull-to-tree ran at 0.532x to 0.871x the fused `load` path, while validating root skips used only 380 to 852 managed B/op. Three-process streaming medians put event drain at 0.602x to 0.748x the in-memory pull reader. These API-specific tradeoffs, RSD values, corpus sizes, and reproduction commands are recorded in the [reference results](docs/benchmark-results.md).

`bench/parse.cr` verifies complete result equality before timing and reports MiB/s, relative standard deviation, and managed bytes per operation. Repeat the executable in independent processes before drawing conclusions on another machine.

## Roadmap

Version 0.1.0 contains the core dynamic, pull, typed, and streaming parsers. Current priorities are:

- Block-based typed array iteration is next, building on the available `PullParser#read(T)` and exact `raw_number_value`/`read_raw_number` APIs. It will let named arrays inside very large root objects be processed without building the complete collection in memory. This work is defined in the [large-document specification](docs/large-document-processing.md) and [implementation plan](docs/large-document-plan.md). A separate reader will later handle NDJSON or repeated JSON documents and reuse its buffers between records. `load` and `parse` will remain eager, strict, single-document operations.
- An opt-in dynamic value type that can hold integers beyond `Int64`, exact decimals, or the original number spelling. The existing `JSON::Any` API will keep its Crystal-compatible numeric behavior. Explicit typed decoding already supports `BigInt`, `BigFloat`, and `BigDecimal` after loading `big/json`.
- One limits configuration across all parsing APIs, covering document size, token size, total value count, entries per container, and key-cache growth. Applications will also be able to reject duplicate keys when parsing untrusted input. Returned values will still require memory proportional to their size.
- Fewer allocations in dynamic and typed decoding. Streaming tree construction will build values directly from `IO` instead of routing them through pull events. Reproducible release benchmarks will cover stable Crystal on x86-64, then expand to ARM64 when suitable runners are available.
- Expanded fuzz testing and broader platform coverage, beginning with ARM64 and macOS. The word scanner will be tested on real 32-bit and big-endian hardware when practical CI runners are available. The compiler-private float hook will either be replaced or moved behind a stable upstream API, while the tested public fallback remains available.

Application feedback will shape the typed and pull interfaces before 1.0. The 1.0 release will define stable contracts for limits, numbers, errors, and compiler compatibility.

FusedJSON will remain a fast, strict, Crystal-native JSON parser. JSON generation, JSON5 extensions, Ruby-specific Oj modes, and a rewrite in C are not currently planned.

The [design specification](docs/design.md), [implementation history](docs/plan.md), and [public API contract](docs/api.md) contain the technical details. Benchmark methodology and results are documented in the [benchmarking guide](docs/benchmarking.md) and [reference results](docs/benchmark-results.md). See the [migration guide](docs/migration.md) when replacing Crystal's parser and the [release guide](docs/releasing.md) when publishing a new version.

The design is informed by Oj and Crystal's standard JSON implementation. See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution.

## License

Original FusedJSON code is MIT licensed. Adapted Crystal standard-library portions remain under Apache-2.0; see [third-party notices](THIRD_PARTY_NOTICES.md) and the included `LICENSES/` texts.

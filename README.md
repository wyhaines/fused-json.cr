[![CI](https://github.com/wyhaines/fused-json.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/wyhaines/fused-json.cr/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/release/wyhaines/fused-json.cr.svg)](https://github.com/wyhaines/fused-json.cr/releases)

# FusedJSON

FusedJSON is an experimental, strict JSON parser for Crystal. It provides a fast in-memory `String` path and incremental `IO` parsing without first copying the complete input. Both paths avoid the standard parser's intermediate lexer.

Version 0.3 adds reusable readers for NDJSON and whitespace-separated JSON
streams. Version 0.2 added typed reads at a pull cursor, non-accumulating typed
arrays, exact raw-number access, and one resource-limit policy across dynamic,
typed, pull, and streaming entry points. All paths enforce strict JSON,
validated UTF-8, Unicode escapes, and nesting limits. Crystal 1.21 through the
current stable 1.x release is supported.

## Installation

Add the shard to your application's `shard.yml`:

```yaml
dependencies:
  fused_json:
    github: wyhaines/fused-json.cr
    version: ~> 0.3.0
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
limits = FusedJSON::Limits.new(
  max_document_bytes: 8_i64 * 1024 * 1024 * 1024,
  max_token_bytes: 1024 * 1024,
  max_total_values: 50_000_000,
  reject_duplicate_keys: true
)
streamed = File.open("document.json") { |io| FusedJSON.load(io, limits: limits) }
```

The complete [basic example](examples/basic.cr) is compiled in CI and can be run from a checkout with `crystal run examples/basic.cr`.

`FusedJSON.parse` is an alias for `load`. Native parsing failures raise
`FusedJSON::ParseError`, which includes byte offset, line, and column data.
Generated `JSON::Serializable` constructors may wrap that error in
`JSON::SerializableError` and preserve it as the cause. `String` and `IO`
inputs must contain exactly one document. The immutable
`FusedJSON::Limits` configuration works with every parsing entry point and can
bound document bytes, tokens, typed values, value counts, container entries,
and cached keys. It can also reject duplicate object keys. See the
[API contract](docs/api.md) for exact counting rules.

The existing `max_nesting` keyword remains available, as does
`max_token_bytes` on `IO`. If a legacy keyword and `limits` cover the same
resource, the smaller value wins. `buffer_size` remains an `IO` option and
defaults to 32 KiB.

Key caching is local to one single-document parse or repeated-document reader
and remains off by default. It hashes every materialized object key and reuses
equal key strings. With duplicate rejection off, an untyped pull `skip` leaves
keys inside the skipped value
unmaterialized, so they do not consume `max_cached_keys`. Duplicate rejection
must decode those keys; when key caching is also on, they enter both the
per-object duplicate set and the parser-wide pool. The pool retains its entries
for the parser's lifetime. Measurements found that caching repeated schemas
reduced typed managed allocation by 28-33%, while caching unique keys increased
allocation by 9-10% and time by 22-29%. Leave it off for unknown or
high-cardinality input, and set `max_cached_keys` for untrusted input. See the
[key-cache results](docs/post-0.2-key-cache-results.md) for the workload details.

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

`pull.read_array(Event) { |event| ... }` consumes the current array and yields
one fully decoded element at a time. The callback must not advance `pull` and
should retain only the values it needs. Call `finish` after normal traversal;
an exception or early block exit leaves the remainder unchecked, so discard
that reader.

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

The [pull example](examples/pull.cr) exercises both in-memory and streaming
readers. The compile-checked [TiC streaming example](examples/tic_streaming.cr)
shows typed root arrays, nested typed arrays, caller-wrapped gzip input, staged
output, and two-pass input recreation.

### NDJSON and repeated documents

`FusedJSON.documents` reuses one streaming parser across a sequence instead of
splitting it into lines and constructing a parser for every record. Supply a
type to decode each document directly, or omit it to receive `JSON::Any`:

```crystal
require "fused_json"

struct LogEvent
  include JSON::Serializable

  getter id : Int64
  getter message : String
end

input = IO::Memory.new(%({"id":1,"message":"started"}\n{"id":2,"message":"done"}\n))
reader = FusedJSON.documents(
  input,
  LogEvent,
  framing: FusedJSON::DocumentFraming::NDJSON,
  cache_keys: true
)
reader.each { |event| puts "#{event.id}: #{event.message}" }
reader.finish
```

`DocumentFraming::NDJSON` accepts one complete JSON value per LF- or
CRLF-terminated record. A complete final record may omit its newline, but blank
records and multiline values are rejected.
`DocumentFraming::WhitespaceSeparated` accepts multiline JSON values and
requires at least one JSON whitespace byte between them. The framing argument
is required and is never guessed.

The reader borrows the `IO`, may read ahead, and never closes it. Per-document
limits reset at each framing boundary. With `cache_keys: true`, the key cache
is retained across documents and `max_cached_keys` bounds that reader-wide
pool. See the [repeated-document guide](docs/repeated-document-reader.md) for
completion, early-exit, error-location, and memory details. A runnable version
is in [examples/documents.cr](examples/documents.cr).

### Large documents

FusedJSON borrows an `IO` and never closes it. It does not detect compression;
the caller opens the file and supplies a `Compress::Gzip::Reader` when needed.
Every pass must use a freshly opened source and a fresh decompressor. A normal
root traversal reaches EOF, after which `finish` asserts complete-document
validation. `finish` does not drain unread input: an exception or early block
exit leaves the remaining JSON and any gzip trailer unchecked, so discard that
reader and do not commit staged output.

When callbacks and constructors do not retain values, streaming retention is
driven by the input and decompressor buffers, nesting and key state, the largest
current or lookahead token, and one current decoded value—not total document
length. `read_array(T)` still constructs each complete `T` before yielding it;
navigate structurally to a smaller nested array when an outer item can itself be
very large. See [Streaming Input](docs/streaming.md) for the full ownership and
memory contract and the [migration guide](docs/migration.md#pull-number-migration)
for numeric choices.

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
$ crystal build --release --no-debug bench/document_reader.cr -o bin/document-reader-bench
$ bin/document-reader-bench
$ crystal build --release --no-debug bench/document_reader_memory.cr -o bin/document-reader-memory
$ crystal build --release --no-debug bench/tic_fixture.cr -o bin/tic-fixture
$ crystal build --release --no-debug bench/tic.cr -o bin/tic-bench
$ crystal build --release --no-debug bench/typed_cursor_cost.cr -o bin/typed-cursor-cost
$ crystal run bench/fixture_parity.cr -- path/to/fixture-directory
$ crystal run scripts/check_doc_examples.cr
$ crystal run --release --no-debug scripts/check_large_offset.cr
```

For a current-checkout Ruby/Oj comparison, build Oj and run `OJ_ROOT=/path/to/oj ruby bench/parse_oj.rb document.json`.

## Performance

On the benchmark machine, FusedJSON is about 1.9 times as fast as
`JSON.parse` when both build a `JSON::Any` tree from a `String`. Its advantage is
larger when decoding a large `IO` directly into typed records, where it delivers
about 2.7 to 3.3 times Crystal's throughput.

| Operation | Throughput compared with Crystal | Memory |
| --- | --- | --- |
| Dynamic `JSON::Any` from String | 1.70x to 2.10x across five corpora; 1.91x geometric mean | Managed allocation ranged from 0.67x to 1.37x Crystal, depending on the document |
| Streaming typed decode, many small records | 3.23x to 3.29x | 2.17x Crystal's cumulative managed allocation |
| Streaming typed decode, wide records | 2.69x to 2.71x | 2.31x Crystal's cumulative managed allocation |
| Typed decode with all selected output retained | 2.69x to 2.70x | Median peak RSS was 64.6 to 64.9 MiB, versus 58.5 to 58.7 MiB for Crystal |

Cumulative managed allocation counts every managed byte allocated during a
parse; it is not retained memory. The typed fast paths cut that allocation by
55 to 57 percent, but Crystal still does less allocation work. When parsed
values are discarded, FusedJSON's memory stays bounded: three runs over a
4.06 GiB input peaked below 9.5 MiB of process RSS.

Key caching can reduce FusedJSON's allocation by 28 to 33 percent when a
document repeats a small schema. It is not a general speed switch. On unique
keys it increased allocation by 9 to 10 percent and parsing time by 22 to 29
percent, so it remains disabled by default. Disabled resource limits and an
explicit empty `Limits` value had no material effect in controlled tests.

These figures came from repeated, CPU-pinned release builds on an AMD Ryzen 9
7940HS. Ratios are more useful than absolute MiB/s, and real applications
should benchmark their own documents. See the
[benchmarking guide](docs/benchmarking.md), the
[typed-decoding results](docs/typed-optimization-results.md), and the
[latest optimization report](docs/post-0.2-performance-results.md) for the
commands, compiler versions, raw receipts, and measurement caveats.

## Roadmap

The next planned work is:

- Add an opt-in dynamic value type for integers beyond `Int64`, exact decimals,
  and original number spellings. `JSON::Any` will keep Crystal-compatible
  numeric behavior. Typed decoding already supports `BigInt`, `BigFloat`, and
  `BigDecimal` after loading `big/json`.
- Improve streaming performance by profiling buffer refills, token scanning,
  and escaped-string decoding. An eventless `IO` tree builder was tested, but
  its gains were inconsistent and it made escaped-string workloads slower.
- Expand fuzzing and platform coverage on ARM64 and macOS. The word scanner
  also needs testing on real 32-bit and big-endian hardware. The public float
  fallback will remain available until the compiler-specific fast path can use
  a stable upstream API.
- Refine the experimental typed and pull APIs using feedback from real
  applications. Version 1.0 will define stable contracts for limits, numbers,
  errors, and compiler compatibility.

FusedJSON will stay focused on strict JSON parsing. JSON generation, JSON5,
Ruby-specific Oj modes, and a rewrite in C are not planned.

## Documentation

The [design specification](docs/design.md), [implementation history](docs/plan.md), and [public API contract](docs/api.md) contain the technical details. Benchmark methodology and results are documented in the [benchmarking guide](docs/benchmarking.md) and [reference results](docs/benchmark-results.md). See the [migration guide](docs/migration.md) when replacing Crystal's parser and the [release guide](docs/releasing.md) when publishing a new version.

The design is informed by Oj and Crystal's standard JSON implementation. See [third-party notices](THIRD_PARTY_NOTICES.md) for attribution.

## License

Original FusedJSON code is MIT licensed. Adapted Crystal standard-library portions remain under Apache-2.0; see [third-party notices](THIRD_PARTY_NOTICES.md) and the included `LICENSES/` texts.

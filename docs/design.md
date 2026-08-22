# Parser Design Specification

Status: working specification for the pre-1.0 `0.x` implementation.
When code, tests, and this document disagree, correctness bugs should be fixed
first and the intended behavior clarified here in the same change.

## Purpose

FusedJSON is a Crystal-native JSON parser optimized for high-throughput parsing
into Crystal data structures. Oj informs the performance strategy, but this is
not a line-by-line port of Oj's Ruby extension. The current product is a small,
strict parser with predictable dynamic, pull, typed, and streaming APIs.

The implementation must preserve correctness while reducing parser overhead.
Performance work may eliminate tokens, temporary strings, dispatch, and
avoidable allocation; it must not accept malformed JSON or silently change the
result model.

## Goals

- Parse strict JSON into `JSON::Any` faster than Crystal's `JSON.parse` on
  representative documents.
- Match Crystal's dynamic JSON value model closely enough to serve as a
  practical replacement at call sites.
- Validate all input, including UTF-8, escapes, numeric grammar, and document
  boundaries.
- Keep parser state local to each call so independent calls are thread-safe.
- Provide useful errors without adding work to successful parses.
- Evolve one parsing engine toward pull, typed, and streaming interfaces.
- Remain pure Crystal by default. Native acceleration can be considered only
  when measurements justify its portability and maintenance cost.

## Non-Goals

- Reproducing Oj's Ruby object, Rails, compat, or custom-class modes.
- Instantiating arbitrary classes from JSON metadata.
- Supporting comments, trailing commas, `NaN`, infinity, JSON5, or other
  extensions in the strict API.
- Preserving duplicate object members as separate entries.
- Matching Oj's diagnostics or every historical Oj edge case.
- Making Ruby/Oj throughput a release gate. Cross-runtime comparisons are
  informative, not equivalent measurements.

## Public Contract

The final pre-1.0 names are the `fused_json` shard and require path and the
`FusedJSON` namespace. The name describes the direct scan-and-build paths
without implying that this strict Crystal-native subset is a drop-in Ruby Oj
port. The supported surface is the module facade, `ParseError`, `PullParser`,
and `PullParser::Kind`. Concrete tree builders, streaming subclasses, adapters,
scanners, and decoders remain implementation details. [`api.md`](api.md)
defines compatibility policy.

The current API is:

```text
FusedJSON.load(source : String, *, max_nesting : Int = 512,
               cache_keys : Bool = false) : JSON::Any
FusedJSON.load(source : IO, *, buffer_size : Int = 32 * 1024,
               max_nesting : Int = 512,
               cache_keys : Bool = false,
               max_token_bytes : Int? = nil) : JSON::Any
FusedJSON.parse(source : String, *, max_nesting : Int = 512,
                cache_keys : Bool = false) : JSON::Any
FusedJSON.parse(source : IO, *, buffer_size : Int = 32 * 1024,
                max_nesting : Int = 512,
                cache_keys : Bool = false,
                max_token_bytes : Int? = nil) : JSON::Any
```

`parse` is an alias for `load`. Options are keyword-only. `max_nesting` must be
between 1 and 512. The `IO` buffer defaults to 32 KiB and must be between 1 byte
and 16 MiB. An explicit `max_token_bytes` must be between 1 and `Int32::MAX`.
Values outside these ranges raise `ArgumentError`. Invalid JSON or a token that
exceeds its configured limit raises `FusedJSON::ParseError`, a subclass of
`JSON::ParseException`; a token-limit error points to the token's opening byte.

`cache_keys` interns object keys within one parser. It is disabled by default
because its value depends on document shape. The cache must never be global:
unbounded process-wide interning would turn untrusted keys into retained
memory. Callers should opt in for repeated-schema documents; no repetition
heuristic scans the input or changes policy during a parse.

The experimental typed entry point is:

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

It decodes one complete document through Crystal's standard
`new(pull : JSON::PullParser)` constructors without building a `JSON::Any`
tree. The compatibility surface and deferred types are listed in
[`typed-decoding.md`](typed-decoding.md). The internal stdlib adapter is not a
public API.

The experimental pull API is:

```text
FusedJSON::PullParser.new(source : String, *, max_nesting : Int = 512,
                          cache_keys : Bool = false)
FusedJSON::PullParser.new(source : IO, *, buffer_size : Int = 32 * 1024,
                          max_nesting : Int = 512,
                          cache_keys : Bool = false,
                          max_token_bytes : Int? = nil)
```

Construction primes the reader on the first semantic event. `kind` is one of
`Null`, `Bool`, `Int`, `Float`, `String`, `BeginArray`, `EndArray`,
`BeginObject`, `EndObject`, or `EOF`; commas and colons remain internal.
Scalar and container `read_*` methods consume the current event. Object keys
appear as string events. `read_next` advances one event, `skip_value` (also
`skip`) validates and consumes one complete value, and `finish` requires EOF.
Each `read_array` or `read_object` yield must consume at least one complete
value and stay within that container. Reading the wrong kind or violating a
block contract raises `ParseError`; a wrong-kind read does not advance.

The pull API is strict about the complete document. It does not reproduce
Crystal's current behavior of silently ignoring a second scalar root. It uses
the same number grammar, Unicode, and nesting policies as `load`, but recognizes
and skips numbers without immediately converting them. Every object-key event
is exposed, including duplicates; tree and typed consumers apply their
documented last-value policy.

Pull and typed decoding retain an exact source range for every number.
`raw_number_value` observes that spelling and `read_raw_number` returns it while
advancing. Requested typed integers may use the full fixed-width domain through
`UInt128`, or `BigInt` when Crystal's `big/json` adapter is loaded. Direct pull
integer reads remain checked `Int64` conversions, and converting a floating
token retains the finite-`Float64` policy.

Streaming entry points borrow the `IO` and never close it. They read from its
current position through `IO#read_utf8`, accept positive short reads, and treat
the first zero-byte read as permanent EOF. Parsing consumes one complete
document and requires EOF, so reads may run ahead and an open source can block
after delivering a complete root value. IO errors propagate unchanged.

Typed object policies follow the requested Crystal type. `Hash` and
`JSON::Serializable` use the last duplicate field. A normal serializable skips
and validates unknown fields, `JSON::Serializable::Strict` rejects them, and
`JSON::Serializable::Unmapped` materializes them as `JSON::Any` values.

## JSON Semantics

One document contains exactly one JSON value, optionally surrounded by JSON
whitespace: space, tab, line feed, or carriage return. Comments, trailing
content, and trailing commas are errors.

Values map as follows:

| JSON value | Crystal representation |
| --- | --- |
| `null` | `JSON::Any.new(nil)` |
| Boolean | `Bool` inside `JSON::Any` |
| String | `String` inside `JSON::Any` |
| Integer syntax | `Int64` inside `JSON::Any` |
| Fraction or exponent syntax | `Float64` inside `JSON::Any` |
| Array | `Array(JSON::Any)` |
| Object | `Hash(String, JSON::Any)` |

Integers outside the `Int64` domain are rejected. Floating-point values that
cannot be represented as a finite `Float64` are rejected. The grammar rejects
leading zeros, missing fraction digits, and incomplete exponents. This domain
is intentionally aligned with Crystal's dynamic JSON model rather than Oj's
arbitrary Ruby numeric options.

Duplicate object keys use the last value, matching assignment into
`Hash(String, JSON::Any)`. Member order and the identity of returned strings
are not public guarantees.

Array and object nesting is counted from one at the outermost container. The
default and maximum supported limit is 512. Callers may select a lower limit.
The parser must fail before recursing beyond it.

## Strings and Unicode

Unescaped non-ASCII content must be well-formed UTF-8. The scanner rejects
overlong encodings, UTF-8 encodings of surrogate code points, code points above
U+10FFFF, incomplete sequences, and raw control bytes.

All JSON escapes are supported. A high UTF-16 surrogate in a `\u` escape must
be followed by a low surrogate; the pair is combined into one Unicode code
point. Isolated low surrogates and incomplete or invalid hexadecimal escapes
are errors.

The common in-memory string path performs no escape decoding: it validates
bytes and copies the completed span once. Plain ASCII spans use bounded
word-at-a-time detection for quotes, backslashes, controls, and high bytes.
Loads copy eight bytes into a local word, normalize big-endian hosts, and never
read beyond the active slice; tails and builds using
`-Dfused_json_force_scalar_string_scan` use the scalar fallback. Encountering a
backslash switches to a builder that copies raw UTF-8 spans between escapes.
Escaped decoding remains scalar because bulk scanning its typically short
segments regressed dense-escape inputs. Streaming strings that cross a refill
are first retained in reusable scratch.

Strings returned by the pull reader are owned `String` values, not borrowed
slices. They remain valid after the reader advances or is collected. Key
pooling, when requested, is local to that reader. Strings are materialized
lazily. The in-memory reader validates skipped strings without decoding,
copying, or interning their contents; the streaming reader must retain a
skipped string in scratch only when it crosses a refill.

## Errors

`FusedJSON::ParseError` exposes a zero-based byte offset and one-based line and
column. In-memory location calculation is deferred until needed; the streaming
reader tracks it across refills. Columns count Unicode code points where the
preceding input is valid UTF-8. For an `IO` configured with another encoding,
byte offsets refer to its decoded UTF-8 stream.

The exception type and location fields are API. Exact English messages remain
diagnostic and may change before 1.0. Malformed input must never cause an
out-of-bounds read, arithmetic overflow, hang, or process crash.

## Security and Resource Limits

The recursive tree builders are capped at 512 containers. Raising that ceiling
is not safe until they use explicit frame stacks; a caller-provided depth must
never be allowed to exhaust the native stack.

The in-memory API does not impose separate limits on source bytes, token bytes,
or container entries; callers must bound an untrusted `String` externally.
Streaming callers can set `max_token_bytes` to limit each raw string or number,
including object keys and skipped values. The limit counts decoded UTF-8 input
bytes, includes string quotes, and rejects a token before writing raw bytes
beyond the configured value. Internal buffer capacity grows geometrically, so
the option is not an exact total-memory cap. It does not bound aggregate source
bytes or entries.

FusedJSON's decoded refill buffer is bounded by `buffer_size`, but reusable
scratch may grow to the current token when no token limit is set; storage in a
caller-supplied IO or encoding wrapper is outside that bound. A materialized
tree, typed target, returned strings, cached keys, and typed raw values require
memory proportional to their own size.

After an event advances, streaming scratch is reused while the completed raw
token is no larger than `max(2 * buffer_size, 64 KiB)` and replaced otherwise.
This avoids repeated growth for tokens up to that threshold without retaining
one unusually large token for the parser's lifetime. Capacity rounding and GC
reclamation remain runtime concerns.

## Architecture

The current implementation has seven layers:

1. `FusedJSON.load`, `parse`, and `from_json` provide `String` and `IO` facades.
2. `ByteScanner` owns the retained `String`, byte cursor, recognition,
   Unicode validation, numeric conversion, errors, and optional key pool;
   `ASCIIStringScanner` accelerates validated plain spans behind a scalar
   fallback.
3. `Parser` retains the recursive, fused `JSON::Any` construction path.
4. `PullParser` uses typed value slots and an explicit container-state stack;
   it does not allocate event objects.
5. `StreamingPullParser` applies that event contract to refillable `IO` input,
   with a bounded input buffer and reusable current-token scratch.
6. `StreamingParser` recursively builds a `JSON::Any` tree from streaming pull
   events.
7. Private concrete adapters for `String` and `IO` mirror native state into the
   nominal stdlib pull-parser type required by generated deserializers; a
   generic shared base keeps each native parser type statically known.

The in-memory parsers dispatch values from the current byte and share byte-level
recognition without lexer tokens. Their structural drivers deliberately differ:
the fused tree path builds arrays and hashes inline, while pull parsing pauses
at semantic boundaries. Streaming pull preserves those boundaries across
refills. The complete conformance corpus runs through in-memory and streaming
paths to prevent grammar drift. Integers accumulate into a checked `UInt64`
magnitude before conversion to `Int64`.

In-memory pull locations are tracked lazily with a monotonic cursor, so
requesting every object-key location remains linear in source size. Streaming
locations use absolute `Int64` offsets and incremental line and column state.
In-memory syntax-error locations may scan from the beginning because they are
off the success path.

Numeric recognition returns a source range before conversion. The tree path
immediately enforces the dynamic Int64/Float64 domain. Public and typed pull
paths convert lazily or materialize an exact raw spelling only when the caller
or a stdlib constructor requires it. Crystal's `UInt64`, `Int128`, `UInt128`,
and `BigInt` constructors currently require that raw `String`, so those typed
paths allocate one numeric substring.

`Float64Decoder` isolates Crystal's compiler-internal pointer-range `fast_float`
machinery. Crystal versions from 1.21 through the reviewed range below 1.23-dev
use that zero-substring path after the parser validates number syntax. Other
versions, or builds using
`-Dfused_json_force_portable_float`, use the public `String#to_f64?` API. Both
paths must run the same numeric and conformance specs.

Recursive tree construction is acceptable under the current depth limit.
The fused builders remain separate from pull traversal because pull-to-tree
measurement showed a material state-machine cost. An iterative fused builder
would need its own partial-collection frames and is deferred until a supported
platform fails at the 512 limit or a higher limit becomes a requirement.

Dynamic arrays, hashes, and pull frames start without guessed capacity and use
Crystal's geometric growth. JSON does not reveal an entry count before a
container is consumed; pre-scanning violates the one-pass design, while fixed
or source-size estimates overallocate empty, small, nested, string-heavy, and
duplicate-key inputs. Typed collection allocation remains controlled by
Crystal's generated constructors.

## Performance Rules

- Correctness tests are mandatory for every optimized path.
- Successful parsing should make one forward pass over input, apart from bytes
  copied into results.
- Do not allocate lexer tokens or numeric substrings on the normal path.
- Error reporting may scan already-consumed input because it is off the success
  path.
- Output values necessarily allocate; benchmarks must distinguish result-tree
  allocation from avoidable parser allocation.
- Key caching stays opt-in unless corpus evidence shows a safe universal win.
- SIMD, `libc`, or C code requires a scalar fallback and measurements across
  short, long, ASCII, escaped, and Unicode strings.
- A faster result is invalid unless semantic preflight matches the oracle.

## Typed and Streaming Integration

Typed decoding reuses each pull engine through a private subclass adapter for
Crystal's nominal `JSON::PullParser`; the public pull type remains independent.
The adapter initializes private base state, then overrides value access,
advancement, raw traversal, skipping, locations, and errors. Separate concrete
adapters avoid adding union dispatch to the in-memory path. Adapter dispatch,
annotations, raw replay, converters, discriminators, and strict trailing
content remain tested on every supported compiler.

Streaming scanning preserves tokens split at any byte boundary, including
UTF-8 sequences, escapes, literals, and exponents. It retains parser state, a
bounded input buffer, and the current token in addition to requested output.
Returned strings are owned. Large tokens, cached keys, raw replay, typed
targets, and materialized result trees can still use proportional memory. The
full IO contract is documented in [`streaming.md`](streaming.md).

## Compatibility and Change Control

Until 1.0, new APIs may change, but strict parsing semantics should only change
to fix a correctness issue or deliberately align with Crystal. The current
minimum is Crystal 1.21. CI is configured to test that minimum, the latest
stable compiler, and nightly; supported versions must be tested rather than
inferred from syntax compatibility.

When behavior is unclear, prefer, in order: valid strict JSON, memory safety,
agreement with Crystal's dynamic value model, a simple public contract, and
then speed. Record material decisions in this document and add an executable
test in the same change.

Oj's design influence and license are recorded in
[`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

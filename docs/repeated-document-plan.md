# Repeated-document reader implementation plan

Status: implemented for 0.4.0. This plan records how FusedJSON implemented and
validated the contracts in the
[repeated-document reader specification](repeated-document-reader.md).

## Working rules

- Preserve all existing single-document behavior before adding the new public
  entry point.
- Establish framing and error parity before optimizing.
- Keep one input buffer for the reader's lifetime; do not implement NDJSON as
  `IO#each_line` plus a fresh parser.
- Reuse the existing scanner, number, string, Unicode, typed-adapter, key-cache,
  and resource-limit code. Do not add another JSON grammar.
- Keep format-specific branches at document boundaries where possible rather
  than inside ordinary token and container traversal.
- Keep public documentation synchronized with executable behavior.
- Measure complete workloads. Microbenchmarks can explain a cost but cannot
  justify a production optimization on their own.

## Lock the framing contract with fixtures

Add deterministic fixture builders and focused specs before changing parser
state. The fixtures should be generated in tests rather than stored as a large
corpus.

NDJSON coverage must include:

- empty input; one record; several records; and a final record without LF;
- LF and CRLF, including a CRLF split across refills;
- every JSON root kind;
- leading and trailing space or tab;
- escaped `\\n` and `\\r` in strings;
- rejected empty and whitespace-only lines;
- rejected raw LF or CR inside arrays and objects;
- rejected trailing content on a record;
- malformed and truncated records at every position; and
- one-byte reads, positive short reads, and every boundary split for compact
  representative records.

Whitespace-separated coverage must include:

- empty and whitespace-only input;
- every JSON whitespace byte as a separator;
- multi-line arrays and objects;
- rejected adjacent roots without a separator;
- malformed later documents after earlier documents were delivered;
- delayed separator validation on `next` and `finish`; and
- numeric records whose completion depends on a following separator or EOF.

Build a small reference oracle by parsing each known record independently
with the existing single-document String path. The new reader's results and
errors should agree with that oracle after accounting for absolute stream
locations and framing errors.

Acceptance: the tests state every framing decision in the specification and
can distinguish an implementation that loses read-ahead bytes, splits on raw
lines, accepts blank NDJSON records, or accepts adjacent whitespace-framed
roots.

## Separate root completion from physical EOF

Refactor the pull reader's root-completion path so a private streaming
specialization can stop at a document boundary without changing the public
single-document reader. The existing path must continue to skip trailing JSON
whitespace, probe physical EOF, and reject trailing content exactly as it does
today.

The repeated-document specialization needs explicit states for:

- seeking the first document;
- decoding a root;
- waiting for or validating the next separator;
- clean physical exhaustion; and
- terminal failure.

It must preserve `@input_position`, `@input_size`, the input buffer, absolute
offsets, and line tracking across documents. Starting a document resets pull
frames, lazy scalar state, document counters, typed-value scope, and
duplicate-key state. The optional key pool remains reader-wide.

The implementation should use a root-completion hook or private specialization
rather than checking a framing enum on every event. Any unavoidable dispatch
occurs once per document, not once per byte or nested value.

Add private instrumentation in specs, if needed, to prove that the same input
buffer survives several documents and that bytes already fetched after one
root become the next root's input.

Acceptance: all existing parser and streaming specs pass unchanged, including
trailing-content errors and open-IO behavior. The private cursor can traverse
multiple roots at every tested refill split without reconstructing its input
buffer.

## Implement framing at the streaming boundary

Implement NDJSON framing without allocating a complete line. The scanner must
treat LF or CRLF as a root-level record terminator, reject them elsewhere in a
record, and retain its existing string escape behavior. Line padding and
terminators may cross input-buffer boundaries.

Implement whitespace-separated framing as a document-boundary policy. After a
root is delivered, the following reader operation must observe at least one
JSON whitespace byte or physical EOF before another root can begin. It should
not probe EOF before yielding a self-delimiting completed root.

Keep framing mechanics separate from JSON token recognition. In particular,
do not weaken number grammar or teach the scanner that arbitrary invalid bytes
are document separators.

Acceptance: the framing matrix passes with buffer sizes 1, 2, 3, 31, 32,
32 KiB, and sizes chosen to place every delimiter byte at a refill boundary.
No NDJSON test allocates a String proportional to its full source line.

## Add dynamic iteration

Add `DocumentFraming`, `DocumentReader(JSON::Any)`, and the dynamic
`FusedJSON.documents` overload. Reuse the existing pull-backed dynamic tree
construction so value mapping and last-duplicate-wins behavior remain
identical to `load(IO)`.

Implement `Iterator#next`, `documents_read`, `exhausted?`, and `finish` with
the lifecycle in the specification. Repeated `next` after exhaustion and
repeated `finish` must be idempotent. `finish` must not consume an unread
document merely to make the reader appear complete.

Differential tests should compare each yielded tree with
`FusedJSON.load(record_string)` across ordinary fixtures, JSONTestSuite valid
cases, duplicate keys, Unicode, escaped strings, numeric boundaries, and
resource policies.

Acceptance: dynamic iteration yields exactly one owned `JSON::Any` per record,
preserves absolute error locations, detects unconsumed documents in `finish`,
and leaves every existing facade unchanged.

## Add typed iteration

Add `DocumentReader(T)` and the typed `FusedJSON.documents` overload. Route
compatible primitives through the existing scalar fast paths and other types
through the existing bounded streaming adapter. Adapt root completion so a
constructor sees synthetic EOF at the end of its current document and cannot
inspect the following document.

Run the existing typed-decoding matrix per record, including:

- all fixed-width integer and floating types;
- `Nil`, `Bool`, `String`, arrays, hashes, tuples, and named tuples;
- `JSON::Serializable`, strict and unmapped modes, defaults, converters,
  discriminators, and raw converters;
- `BigInt`, `BigFloat`, and exact `BigDecimal` with `big/json` loaded;
- constructors that consume zero, part of one, or more than one value;
- retained adapter references and constructor exceptions; and
- result types containing `Nil`, proving exhaustion uses `Iterator::Stop`
  rather than a nil sentinel.

A failed constructor leaves the reader discard-only. A successful return must
leave it at the framing boundary before the value reaches the caller's block.

Acceptance: decoding each isolated record through `from_json` and through the
new reader produces equal results and equivalent errors. A typed constructor
cannot observe or consume any byte as part of a subsequent document.

## Apply limits, caching, and lifecycle rules

Reset per-document resource state at the precise framing boundaries defined in
the specification. Test each limit immediately below, at, and above its
boundary in both formats and with tiny buffers. Include a later valid document
after each successful boundary case to prove state reset.

Keep one key pool when `cache_keys` is enabled. Test repeated plain, escaped,
decoded-equivalent, and non-ASCII keys across documents. Verify that
`max_cached_keys` permits existing pooled keys at capacity and rejects only a
new distinct key, even when that key first appears in a later document.

Exercise early `Iterator#each` exit, callback exceptions, explicit resumption,
early `finish`, repeated completion calls, IO errors, and calls after terminal
parse failure. Document and test that the IO remains caller-owned and may have
been read ahead.

Acceptance: limits have their documented per-document or reader-wide scope,
no state leaks between objects or documents, and abandoned or failed readers
never claim that unread input was validated.

## Fuzz and run compatibility suites

Create a sequence mutator that varies record order, root type, whitespace,
line ending, UTF-8, escapes, numeric spelling, and every byte split. Compare
accepted records with isolated existing-parser results and require stable
absolute error offsets for rejected sequences.

Run the normal JSONTestSuite fixtures individually and in generated sequences.
Run default, portable-float, scalar-string-scanner, and combined fallback
suites. Exercise Linux x86-64 in required CI and retain ARM64 and macOS as
report-only until platform baselines are established, matching current policy.

Acceptance: every existing conformance case keeps its classification when
framed correctly, sequence-only mutations fail at the documented boundary,
and no platform changes single-document behavior.

## Measure reuse and end-to-end performance

Add a deterministic benchmark generator with these profiles:

- many small typed records with a repeated schema;
- the same records with unique high-cardinality keys;
- escape-heavy strings crossing refills;
- mixed scalar roots;
- one periodically wide record among small records; and
- dynamic records retained one at a time versus intentionally accumulated.

Compare the new reader with `IO#each_line` plus existing FusedJSON dynamic and
typed calls, and with the equivalent Crystal standard-library line loop.
Measure decoded throughput, records per second, first-record latency,
cumulative managed allocation per record and per MiB, live heap after full GC,
and process peak RSS. Measure cache-disabled and cache-enabled repeated-schema
cases separately.

Freeze fixtures, compiler, CPU placement, process order, and screening gates
before optimizing. Correctness lands independently; performance changes need
their own focused commits and the repository's existing paired measurement
method. At minimum, accepted evidence must show:

- no material regression in existing single-document String, IO, pull, or
  typed benchmarks;
- lower per-record parser allocation than the `IO#each_line` workaround;
- stable no-retention RSS as a fixed-shape stream grows; and
- no escape-heavy or unique-key regression hidden by a repeated-schema
  aggregate.

If buffer reuse alone does not produce a material throughput improvement, the
feature remains useful for correctness and allocation, but the documentation
must report that result without calling it a speedup.

## Complete public documentation and release checks

The completed public documentation and release checks include:

- add executable examples to `README.md`, `docs/api.md`, and
  `docs/streaming.md`;
- update `docs/design.md`, `docs/migration.md`, and `CHANGELOG.md`;
- describe framing media types, final-newline behavior, blank-line policy,
  absolute locations, limit reset rules, key-cache lifetime, early exit, and
  caller-owned IO;
- compile-check every new public example;
- build API documentation and verify the intended reader and framing types are
  visible without exposing private scanner or adapter types; and
- run all release metadata, formatting, lint, workflow, archive, and link
  checks.

Acceptance: public documentation describes implemented behavior rather than
the work plan, all examples compile, the complete CI matrix passes, and the
release notes identify the new API as experimental until application feedback
has tested its contracts.

## Completion criteria

The repeated-document work is complete only when:

1. Both framing modes pass their full boundary and malformed-input matrices.
2. Dynamic and typed results match isolated single-document parsing.
3. Existing single-document APIs and performance gates remain unchanged.
4. Per-document limits reset correctly and the optional key cache remains
   bounded across the reader lifetime.
5. The reader reuses buffered storage and never loses read-ahead bytes.
6. No-retention memory remains bounded as document count grows.
7. Benchmark claims have reproducible receipts and appropriate controls.
8. Public API, examples, design documents, migration guidance, and changelog
   agree.

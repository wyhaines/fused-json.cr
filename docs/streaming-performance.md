# Streaming performance specification

Status: in progress. The runtime reference is
`1d7e5e0ea88940946fd1ea25d30241331442b344`, after the repeated-document
reader was added. The accompanying
[implementation plan](streaming-performance-plan.md) describes how candidates
will be built and evaluated, and the
[measurement protocol](streaming-performance-protocol.md) freezes the first
candidate's workloads and acceptance gates.

## Objective

Improve parsing from `IO` by reducing work in the shared streaming scanner,
especially when strings or numbers cross refill boundaries. The work should
benefit dynamic trees, pull traversal, typed decoding, and repeated-document
readers without changing their public APIs or JSON behavior.

The earlier eventless tree prototype is not the starting point. It improved
nested documents but reached only a 1.064x geometric-mean speedup and slowed
every escaped-string profile. This work instead measures and improves the
costs that remain common to all streaming consumers:

- obtaining and accounting for refill spans;
- retaining boundary-spanning tokens;
- scanning ASCII, UTF-8, numbers, and escapes; and
- materializing decoded strings, particularly escaped strings.

A private microbenchmark can explain a cost. We will claim an improvement only
when complete public operations also become faster.

## Affected entry points

The optimization boundary is `StreamingPullParser` and its private consumers.
The performance and regression matrix therefore covers:

- `FusedJSON.load(io)` and `FusedJSON.parse(io)`;
- `FusedJSON::PullParser.new(io)`, including materialized and skipped values;
- `FusedJSON.from_json(io, T)` and pull `read(T)`/`read_array(T)`;
- dynamic and typed `FusedJSON.documents` readers; and
- both the ordinary unlimited path and paths with active resource limits.

The fused `String` parser is an unaffected control. A shared scanner helper may
be changed only when its in-memory performance and portable fallback remain
within the regression gates below.

## Behavior that must not change

This project adds no public option and changes no documented result. In
particular:

- JSON grammar, UTF-8 validation, Unicode escape and surrogate handling,
  duplicate-key behavior, numeric domains, and complete-document validation
  remain identical.
- `ParseError` byte offsets, lines, and columns remain exact, including after
  refills, after `2^32`, and for transcoding `IO` sources. Exact diagnostic
  prose is not frozen.
- Input remains caller-owned and is read through `IO#read_utf8`. Positive short
  reads are accepted, the first zero-byte read is permanent EOF, read-ahead is
  allowed, and IO failures propagate unchanged.
- Pull construction still primes only the first semantic event. Strings and
  numbers remain lazily materialized; skipping validates them without creating
  returned values. A returned string or raw number remains owned and valid
  after the reader advances.
- `max_token_bytes`, `Limits`, nesting checks, duplicate rejection, and key
  cache bounds fail at their current logical boundaries. The no-limits path
  must not acquire general limit-state overhead.
- Parser-managed input memory remains bounded by `buffer_size`. Current-token
  scratch may grow to the token limit, follows the existing retention policy,
  and does not retain prior documents or values.
- NDJSON and whitespace-separated framing, per-document limit resets, reader
  lifecycle, and the reader-wide optional key cache remain unchanged.

An optimization that needs borrowed output strings, delayed validation, a new
EOF convention, relaxed error locations, or duplicated JSON grammar is outside
this specification.

## Questions the measurements must answer

The baseline must distinguish costs that the existing whole-tree benchmark
combines:

1. How much time is spent per refill when no token crosses the boundary?
2. What additional copying and allocation occurs when a plain string, escaped
   string, UTF-8 sequence, integer, or float crosses one or several refills?
3. How much of escaped-string cost belongs to validation, raw-token retention,
   decoded-size over-allocation, and the second decoding pass?
4. Do materialized, skipped, typed, and dynamic consumers pay different costs
   for the same scanned token?
5. Does an active token or document limit materially change which loop is hot?
6. Is the 32 KiB default buffer still a reasonable throughput, latency, and
   memory compromise after scanner changes?

These questions are attribution requirements, not assumptions about which
implementation should win.

## Benchmark workloads

All generated inputs and result checksums must be deterministic. Tokens must be
placed both wholly inside one input buffer and across known refill boundaries.

| Workload family | Required variants | What it isolates |
| --- | --- | --- |
| Structure and scalars | integers, floats, literals, small objects, nested objects | Refill and event overhead without string decoding dominating |
| Plain strings | short ASCII, long ASCII, raw multibyte UTF-8 | Fast span scanning, UTF-8 validation, and boundary retention |
| Escaped strings | sparse simple escapes, dense simple escapes, `\u` escapes, surrogate pairs | Validation and decoded output construction at different escape densities |
| Object keys | repeated and unique, escaped and plain, cache off and on | Key materialization without conflating cache policy |
| Consumer behavior | dynamic tree, pull materialize, pull skip, typed read, document reader | Whether a scanner change helps public operations and preserves laziness |
| Limits | none, token limit, document limit, duplicate rejection | Fast-path isolation and bounded-path parity |

The primary transport matrix uses ordinary `IO::Memory` reads and deterministic
4 KiB positive short reads with the default 32 KiB parser buffer. Buffer sizes
of 4 KiB and 256 KiB are sensitivity checks. One-byte and irregular reads are
correctness tests rather than headline throughput workloads. File-backed and
transcoding input are report-only because host storage and decoder costs can
dominate the parser.

Existing `small-objects`, `nested`, and `escaped-strings` tree profiles remain
end-to-end controls. The new token-focused diagnostic must not replace them.

## Measurements

Every performance receipt records source and result hashes, full source and
candidate commits, benchmark-source hash, compiler and LLVM versions, target
triple, CPU placement, GC settings, buffer and chunk sizes, operation, workload,
process order, and relative standard deviation.

The required outcomes are:

- throughput in MiB/s and nanoseconds per decoded input byte;
- operations or records per second for small-document workloads;
- cumulative managed allocation per operation and per input byte;
- first-value latency for pull and repeated-document readers;
- input read count and delivered bytes; and
- peak RSS in fresh-process no-retention and retained-output checks.

Benchmark-only instrumentation may count refills, boundary-spanning tokens,
scratch growth, and copied raw or decoded bytes. Instrumented results explain a
cost but cannot establish a production speed claim. Sampling profiles and
hardware counters are likewise diagnostic.

## Rules for accepting a change

The benchmark source, target profiles, controls, environment, and process
schedule are frozen before timing a runtime candidate. Baseline and candidate
binaries use the same supported Crystal release compiler and byte-identical
benchmark source.

Each focused candidate first receives five alternating baseline/candidate
pairs. It proceeds only when:

- all semantic, identity, and receipt checks pass;
- its predeclared target geometric mean is at least 1.05x baseline;
- no target profile median is below 0.98x;
- the complete streaming guardrail matrix has a geometric mean of at least
  0.99x and no individual median below 0.97x; and
- unaffected String controls have a geometric mean of at least 0.99x.

A candidate that passes screening receives 20 paired samples, balanced for
process order. Its target geometric mean must remain at least 1.05x, with a
one-sided 95% paired-bootstrap lower bound of at least 1.02x. The guardrail and
control floors above still apply.

Managed allocation may not rise by more than the greater of 4 KiB per operation
or 0.1% in any guardrail profile. Median peak RSS may not rise by more than the
greater of 1 MiB or 2%. First-value latency may not regress by more than 2% in
either ordinary or short-read input. A deliberate throughput-for-memory
tradeoff requires a separately reviewed contract rather than an exception to
these gates.

Several independently accepted candidates are measured again as one combined
tree. Only the combined result supports the final performance claim.

## Correctness and portability checks

Any shared streaming change must pass:

- every-byte-split differential tests for valid and malformed tokens;
- one-byte, irregular positive short-read, premature EOF, injected IO failure,
  encoded-IO, and caller-ownership tests;
- String, streaming pull, dynamic tree, typed, repeated-document,
  JSONTestSuite, resource-limit, raw-number, and duplicate-key suites;
- default, portable-float, scalar-string-scan, and combined fallback builds;
- exact offsets beyond `2^32` and bounded no-retention large-input checks; and
- the supported stable compiler and the current development compiler.

ARM64 and macOS results are required before describing a scanner change as
portable across those targets. Until those runners have stable baselines, they
are correctness and report-only performance evidence. Real 32-bit and
big-endian validation remains a separate platform roadmap item.

## Expected output

The repository will gain:

- a token-focused streaming diagnostic and reproducible paired runner;
- a frozen measurement protocol and baseline attribution report;
- focused production commits only for candidates that clear their gates;
- archived patches and receipts for rejected candidates;
- a combined closeout report with correctness, allocation, latency, and RSS
  results; and
- updated benchmarking, design, streaming, README, changelog, and release
  documentation for any accepted change.

The project is done when the named costs have been attributed, every candidate
chosen in the baseline report has an evidence-backed accept or reject decision,
the combined tree has passed all checks, and retained receipts support every
public claim. The project may end without a production parser change if no
candidate passes those checks.

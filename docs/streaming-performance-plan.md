# Streaming performance implementation plan

Status: paused at 0.4.0 during escaped-string acceptance; the
[specification](streaming-performance.md#status-at-040) records what shipped
and what remains. This plan implements the contracts in the
[streaming performance specification](streaming-performance.md). The
[measurement protocol](streaming-performance-protocol.md) freezes the first
runtime candidate's benchmark target and controls.

## Working rules

- Preserve the public API and all existing parser semantics.
- Measure complete public operations before and after every candidate.
- Keep diagnostic instrumentation out of production builds and out of formal
  timing binaries.
- Change one hot-path mechanism at a time so its result can be attributed.
- Keep rejected prototypes and their receipts out of production source while
  preserving enough evidence to avoid repeating them.
- Re-run the complete matrix after combining accepted candidates; improvements
  are not assumed to compose.

## Build the attribution tools

Add `bench/streaming_token_cost.cr` as a deterministic token-focused diagnostic.
It should generate the workload families in the specification and expose one
operation per process. At minimum it needs these consumer modes:

- in-memory pull as an unaffected scanner control;
- streaming pull with every value materialized;
- streaming pull with values skipped;
- dynamic `IO` tree construction;
- streaming typed decoding; and
- typed and dynamic repeated-document iteration.

The generator must control token length, escape density, raw UTF-8 content,
starting alignment, parser buffer size, and delivered chunk pattern. Each run
must verify a checksum against the existing String path and report read calls,
bytes delivered, throughput, allocation, and first-value latency in a
machine-readable receipt.

Extend `bench/streaming_tree_cost.cr` only where an existing end-to-end profile
is missing a required control. Do not turn it into the low-level diagnostic.
Keep the current object and escaped-string histories comparable.

Add a checked-in paired runner that:

- invokes baseline and candidate binaries in balanced alternating order;
- pins each child to the selected CPU with single-threaded GC settings;
- validates commit, benchmark, fixture, compiler, and environment identity;
- retains failed and noisy attempts with an explicit disposition;
- calculates per-pair ratios, geometric means, allocation deltas, and bootstrap
  bounds; and
- emits a checksummed artifact manifest.

CI should syntax-check and self-audit the runner, build the diagnostic with the
minimum and current stable compilers, and execute a small receipt-producing
smoke test.

Acceptance: every workload detects a deliberately incorrect result, every
receipt can be traced to its binary and source, and repeated runs can distinguish
within-buffer tokens from boundary-spanning tokens without runtime source
changes.

## Record the baseline and choose targets

Commit the harness, runner, and their tests without changing `src/`. That
benchmark-only commit becomes the timing baseline and remains runtime-equivalent
to `1d7e5e0ea88940946fd1ea25d30241331442b344`. Record fresh results on the
established Ryzen 9 7940HS host with Crystal 1.21.0. Use Crystal 1.22
development builds for correctness, not performance claims, unless the minimum
supported compiler changes first.

Collect the complete workload matrix once, then use shorter focused runs,
sampling profiles, and benchmark-only counters to answer the attribution
questions in the specification. Compare:

- tokens wholly inside a buffer with tokens crossing one and several refills;
- ordinary reads with 4 KiB short reads at a 32 KiB parser buffer;
- materialization with skip, and dynamic with typed consumers;
- simple escapes with Unicode escapes and surrogate pairs; and
- default traversal with active token and document limits.

Write `docs/streaming-performance-protocol.md` after calibrating iteration
counts but before testing a runtime candidate. It freezes the primary matrix,
candidate-specific target subsets, controls, CPU, compiler, environment gates,
sample schedule, and analysis version. Record the observations and candidate
ordering in `docs/streaming-performance-baseline.md`.

Acceptance: the report identifies a measured cost for each proposed candidate.
If a cost cannot be separated from measurement noise, no production change is
made for it.

## Reduce escaped-string materialization work

The first likely candidate addresses the duplicated work in escaped strings.
The scanner currently validates every escape and surrogate, then
`decode_escaped_string` traverses the raw token again through a
`String::Builder` sized to the encoded token.

Prototype exact decoded-size accounting while validation is already examining
escapes. On materialization, allocate the owned result once at its decoded size
and decode into it. Plain strings must retain their current direct-copy path,
and skipped escaped strings must still avoid allocating a returned value.

The prototype must cover simple escapes, Unicode escapes, surrogate pairs,
mixed raw UTF-8, escaped object keys, cache hits and misses, empty output,
maximum token boundaries, and every split within an escape. Do not retain
escape metadata proportional to escape count unless measurements include that
memory and show it wins.

Screen sparse, dense, Unicode, and boundary-spanning escape targets separately,
then run the full guardrail matrix. Keep the candidate only if it clears the
specification's gates.

Acceptance: decoded strings and error locations are identical; skipped values
remain lazy; returned strings remain owned; allocation does not shift into
retained scratch; and complete escaped-string operations show a qualifying
improvement.

## Reduce boundary-token copying

Use the baseline to determine whether `IO::Memory` scratch growth, span flushes,
or repeated raw-token copying are material contributors. Prototype the smallest
change that addresses the measured cause. Possible candidates include an
explicit growable byte buffer, fewer scratch-position updates, or bulk span
appends at refill boundaries.

The production shape must preserve the existing zero-copy token view when a
token stays inside one refill buffer. It must also preserve lazy materialization
after a token crosses a refill, exact raw-number spelling, retrospective error
locations, token-size checks before growth, and the scratch release threshold.

Measure plain ASCII, raw UTF-8, integers, floats, and escaped strings across one
and several refills. Include skip and materialize consumers: a change that only
moves copying from scan time to read time is not automatically an improvement.
Track peak scratch capacity in diagnostic builds and repeat the oversized-token
release tests.

Acceptance: boundary targets clear the performance gate, within-buffer controls
do not regress, cumulative allocation does not increase, and large-token RSS
returns to the documented bound after the reader advances.

## Improve only scanner loops shown to be hot

After materialization and scratch costs are isolated, profile the remaining
loops. Candidate work may include:

- bulk digit-span detection for long integers, fractions, and exponents;
- faster detection of backslashes in sparse escaped strings;
- reducing duplicated byte and token-limit checks without changing their
  failure position;
- more efficient raw UTF-8 continuation handling across full-buffer spans; or
- compiler annotation changes supported by generated-code inspection.

Keep the unlimited and resource-limited paths distinct when that is what keeps
the ordinary path fast. Do not merge them behind a per-byte optional-limit
branch for code tidiness. Reuse the portable scanner convention already used by
`ASCIIStringScanner`; any word-at-a-time operation needs bounded loads, endian
handling, and a scalar fallback.

Each scanner candidate receives its own target subset and fresh screening. A
microbenchmark win is insufficient if tree, typed, pull, or document-reader
operations do not improve.

Acceptance: the targeted public workload clears the gate, malformed boundaries
retain the same offsets, the scalar fallback agrees at every split, and all
unaffected controls stay within their floors.

## Re-evaluate refill and buffer policy

Once per-byte work is improved, repeat the buffer sensitivity matrix at 4 KiB,
32 KiB, and 256 KiB over ordinary, chunked, file-backed, and repeated-document
input. Separate parser refill cost from the caller's IO, decompressor, or
transcoder cost.

First optimize refill bookkeeping that is expensive even with an unchanged
buffer size. Change the public 32 KiB default only if broad file and memory
workloads improve enough to justify the additional per-reader memory and if
first-value latency, small streams, and many concurrent readers remain within
their gates. Buffer-size tuning is not required to complete this project.

`IO#read_utf8` is part of the encoding contract. Replacing it with raw `read`
is not an eligible optimization unless a separate public API explicitly gives
up transcoding support.

Acceptance: any refill change helps more than a synthetic tiny-read case and
does not alter short-read, zero-read EOF, encoded input, read-ahead, or IO
ownership behavior.

## Combine accepted changes

Build one candidate containing only individually accepted production changes.
Run the complete frozen matrix against the runtime reference in balanced pairs.
Repeat the comparison against each individual candidate to detect destructive
interactions.

Measure:

- token-focused materialize and skip operations;
- existing streaming trees with cache disabled and enabled;
- typed reads and `read_array(T)`;
- dynamic and typed repeated-document readers;
- String parsing and in-memory pull controls;
- allocation, first-value latency, no-retention RSS, and retained-output RSS;
  and
- representative local file and compressed-input profiles as report-only
  context.

Acceptance: the combined tree passes every formal target and guardrail gate.
The final report attributes the combined result without adding the speedups of
individual patches arithmetically.

## Run correctness and memory closeout

Before reporting a result, run the repository's complete validation on the
minimum supported and development compilers:

```console
$ shards check
$ crystal tool format --check src spec bench examples scripts
$ crystal spec --order=random --error-on-warnings
$ crystal spec -Dfused_json_force_portable_float \
    -Dfused_json_force_scalar_string_scan \
    --order=random --error-on-warnings
$ crystal run scripts/check_doc_examples.cr
```

Also run the individual portable-float and scalar-string configurations, API
documentation, lint, release checks, the exact post-`2^32` offset probe, and the
bounded 4 GiB no-retention workload. Exercise all supported framing and typed
paths with one-byte and irregular reads. Run available ARM64 and macOS
correctness jobs before closeout.

Acceptance: no existing result, error location, limit boundary, ownership rule,
fallback result, or memory bound changes.

## Record decisions and update documentation

Write `docs/streaming-performance-results.md` with baseline attribution,
accepted and rejected candidates, paired estimates, confidence bounds,
allocation and RSS interpretation, compiler and host identity, and links to
checksummed raw receipts. Preserve rejected runtime patches with a clear
disposition, but leave them out of production source.

Update:

- `README.md` with concise user-facing results and the next roadmap item;
- `docs/benchmarking.md` with exact build and reproduction commands;
- `docs/design.md` and `docs/streaming.md` with any changed internal memory or
  scan behavior;
- `CHANGELOG.md` with accepted production changes; and
- release checks or CI only when new files or supported platforms require it.

Do not present diagnostic microbenchmarks as library-wide speedups. Report
dynamic, pull, typed, and repeated-document results separately when their
effects differ.

## Completion criteria

The streaming performance work is complete when:

1. Refill, scan, boundary retention, and escaped decoding costs have separate,
   reproducible baseline measurements.
2. Every candidate selected in the baseline report has an accept or reject
   decision backed by paired public-operation results.
3. Accepted candidates pass the combined throughput, latency, allocation, and
   RSS gates.
4. All parser, fallback, boundary, offset, limits, typed, and framing contracts
   pass on supported compilers.
5. Raw evidence, environment identity, failed attempts, and analysis are
   checksummed and retained.
6. Public documentation states what became faster, what did not, and under
   which measured workloads.

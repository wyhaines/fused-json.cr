# Post-0.2 Performance Plan

This plan covers the next allocation and throughput work after the accepted
typed-decoding optimization at
`4ca865c4e8ad8716041df4069181a5523493de08`. The documentation commit that
records those results has the same runtime source. Work starts by measuring
the remaining costs, then proceeds through two independent production tracks:
residual typed/key allocation and direct streaming `JSON::Any` construction.

Execution status: Stages 0 through 3 are complete. The
[baseline and attribution decisions](post-0.2-performance-baseline.md) freeze
the adapter floor, key-cache findings, and streaming target matrix. The
[Stage 1 results](post-0.2-key-cache-results.md) record the
cache-growth correction, validation, and caller guidance; the correction makes
no performance claim because its unaffected-path controls missed the frozen
screening gate. The [Stage 2 design and result](post-0.2-streaming-tree-design.md)
record the eventless-tree prototype and its rejection at the directional gate.
The [final results](post-0.2-performance-results.md) record the Stage 3
validation, negative-result decisions, and evidence archive.

The goal is not to remove every allocation. It is to remove parser overhead
that is material in complete workloads while preserving FusedJSON's strict
semantics, bounded-memory properties, and private implementation surface.

## Starting point

The completed typed work provides the following baseline:

- Native compatible scalar `read(T)` calls do not allocate a compatibility
  adapter.
- Complex typed values receive a shallow copy of an initialized adapter
  prototype rather than rebuilding unused standard-library parser state.
- A standalone `max_cached_keys` limit no longer enables the general
  per-event resource traversal path.
- Managed allocation on the two 256 MiB typed profiles fell by 55-57%, but
  FusedJSON still allocated 2.17x and 2.31x as many managed bytes as Crystal's
  typed parser in the accepted campaigns.
- The retained-output profile narrowed to 1.105x Crystal's peak RSS. This
  indicates that much of the remaining live memory is requested output, while
  cumulative allocation still has room for investigation.

There are two known architectural facts:

1. Adapter-backed `PullParser#read(T)` must give every custom constructor a
   distinct adapter identity. A constructor can retain that adapter after
   returning, so reusing or pooling the same adapter object is not safe under
   the current contract.
2. `load(String)` scans and constructs its tree directly. `load(IO)` currently
   constructs a `DynamicStreamingPullParser`, emits semantic pull state, and
   then converts those events into a tree. The IO path can potentially avoid
   that intermediate state and dispatch.

These constraints make adapter pooling and a second independent JSON grammar
non-solutions. Any direct streaming builder must share scanner behavior with
the pull path, and any residual adapter work must preserve unique identity.

## Working and measurement rules

- Make benchmark-only changes before production changes. The benchmark commit,
  whose runtime code remains identical to `4ca865c4`, becomes the measurement
  baseline.
- Keep one optimization hypothesis per production commit. Compare it both to
  its direct parent and, at closeout, cumulatively to the runtime baseline.
- Use the same benchmark source, release flags, compiler build, fixture bytes,
  environment, and CPU placement on both sides of a comparison. Receipts must
  record their identities.
- Run semantic preflight before timing. Microbenchmarks may attribute a cost,
  but only end-to-end workloads can justify a production change.
- Alternate candidate/baseline process order. Five alternating pairs are enough
  for directional screening; an accepted performance claim uses a frozen
  schedule of 20 pairs and the existing paired-bootstrap method.
- Treat `Benchmark.memory`, live heap after a full GC, and process peak RSS as
  different measurements. Retain parsed output explicitly whenever live or
  peak output memory is being measured.
- Freeze the exact fixtures, thresholds, toolchain, host policy, and random
  seeds before collecting candidate data. If a protocol changes, discard the
  affected measurements and restart it.

The default merge threshold for a focused production optimization is at least
a 5% end-to-end improvement in targeted throughput or managed allocation. An
unaffected workload's throughput geometric mean must remain at least 0.99x its
parent, no individual median may fall below 0.97x, and managed allocation must
not grow by more than `max(4096 bytes/operation, 0.1%)`. A simpler
implementation may be retained without a 5% gain, but must not be described as
a performance optimization.

The direct streaming builder has a higher maintenance threshold: it must
improve the geometric-mean throughput of the frozen streaming-tree matrix by
at least 10%, keep every member at or above 0.98x, and pass the general
regression gates. If it does not, the current pull-backed builder remains in
place and the prototype result is documented.

## Stage 0: Attribute the remaining costs

Stage 0 changes benchmarks and documentation only. Its output is a baseline
receipt and a short attribution report that ranks costs by bytes per element
and time per element. It must not guess an implementation from aggregate TiC
results.

### Typed and key attribution

Extend `bench/typed_cursor_cost.cr` with a small shape ladder. Each shape must
have equivalent native-cursor, repeated `read(T)`, and `read_array(T)`
operations over both `String` and `IO::Memory` readers:

1. Existing scalar integers, which verify the no-adapter floor.
2. Empty and one-integer records, which isolate adapter and structural cost
   from string output.
3. Records containing repeated string values, which expose requested value
   allocation.
4. Nested records and arrays, which exercise adapter boundary bookkeeping.
5. The existing negotiated-price record, which remains the realistic control.

Run the record ladder with caching disabled, enabled, and enabled with an exact
`max_cached_keys` bound. Add a key-shape matrix with:

- a small repeated schema;
- partially repeated keys;
- unique high-cardinality keys;
- plain, escaped, and non-ASCII spellings, including decoded-equivalent pairs;
  and
- cache capacity at zero, exactly the unique-key count, and one below it.

Report source bytes, element count, unique decoded keys, managed bytes per
element, time per element, and the typed-minus-native delta. A high-cardinality
fixture must remain bounded by `max_cached_keys`; it is not a reason to enable
automatic or global interning. Capacity configurations that intentionally
fail are correctness probes, not timed samples.

### Streaming-tree attribution

Add a dedicated streaming-tree diagnostic rather than overloading
`bench/stream.cr`, whose purpose is pull first-event, drain, skip, and retained
value behavior. The new diagnostic compares the public `load(IO)` operation
between commits and uses `load(String)` and pull-to-tree construction only as
same-commit attribution controls.

Cover deterministic inputs dominated by:

- scalar arrays and many small objects;
- wide objects and repeated keys;
- nested arrays and objects;
- short and long plain strings;
- escaped and non-ASCII strings crossing refill boundaries; and
- the five canonical corpora when locally available.

Correctness runs cover one-byte and irregular short reads, plus boundaries at
`buffer_size - 1`, `buffer_size`, and `buffer_size + 1`. Timed runs use one
small-chunk case, ordinary `IO::Memory`, and file-backed IO at the default
buffer size. Report MiB/s, RSD, managed bytes per operation, source and result
digests, bytes read, and the complete build/environment receipt.

### Stage 0 decision gate

Before production work, answer these questions from measurements:

- How many bytes per complex element remain after subtracting equivalent
  native construction and requested values?
- Does adapter overhead change with nesting or transport?
- At what key-reuse and key-cardinality ranges does caching repay its pool
  overhead?
- How much of `load(IO)` time is absent from direct `load(String)` but present
  in pull event production and consumption?
- Which two typed shapes and which streaming shapes will be the frozen target
  workloads for later gates?

If no separable typed overhead is large enough to meet the merge threshold,
skip Stage 1 production changes and publish the measured compatibility floor.

## Stage 1: Reduce residual typed and key overhead

Use allocation profiles and the Stage 0 shape ladder to inspect only costs
that are above requested output construction. Likely investigation points are:

- state copied into each bounded adapter but never observed by successful
  constructors;
- eager value-boundary location or error bookkeeping that can remain lazy;
- repeated kind synchronization or conversion around complex values;
- key materialization, hashing, and `StringPool` probes; and
- cache-limit checks that profiling shows on a repeated-key hot path.

Implement one measured change at a time. Preserve a fresh adapter object for
every adapter-backed value, standard `JSON::PullParser` constructor behavior,
wrong-kind and partial-consumption errors, exact numeric spelling, cursor
position after successful reads, and discard-only behavior after failures.

Key work has additional constraints:

- caching remains disabled by default and scoped to one parser;
- no input-dependent heuristic may silently change caching policy;
- skipped keys remain unmaterialized unless duplicate rejection requires
  decoding them;
- `max_cached_keys` counts distinct materialized decoded keys at the same
  boundary as today; and
- adversarial unique-key inputs must not gain unbounded retention.

An internal key-cache change is accepted only if profiling attributes the gain
to it and repeated-schema end-to-end results meet the general merge threshold.
Regardless of whether code changes, record a caller-facing decision table for
cache-off, cache-on, and bounded-cache use over the measured reuse/cardinality
ranges.

Stage 1 correctness adds focused specs for custom constructors that retain
their adapter, empty and partially consumed values, nested typed values,
wrong-kind scalars, cached key identity, decoded duplicate keys, and exact
cache-capacity boundaries. Default, forced-float, forced-scalar-string, and
combined portable suites must pass.

## Stage 2: Build streaming trees directly

This is an internal architecture change to `load(IO)` and `parse(IO)`. The
public pull reader and typed streaming reader keep their event interfaces.

### 2A. Choose a shared scanner boundary

Profile the current `StreamingParser` and `StreamingPullParser`, then write a
short design note identifying the smallest refill/token/scalar layer that a
tree builder and pull state machine can share. Evaluate the design in a
throwaway worktree before changing the main line.

The preferred shape is a private streaming scan core that owns buffer refill,
token scratch, byte/line tracking, string and number validation, key caching,
and resource checks. The pull reader adds event/frame state; the tree builder
adds recursive container construction. Do not duplicate number grammar,
Unicode handling, refill rules, or limit accounting between the two consumers.

If extracting a shared core is required, land that refactor separately with no
behavioral change. It must pass the full suite and keep the pull drain/skip
geometric mean at or above 0.99x its parent before the tree builder proceeds.

### 2B. Add the eventless tree path

Implement a private streaming builder that consumes syntax and constructs
`JSON::Any` values without publishing each token as a pull event. Route only
the IO dynamic facade through it after parity and performance gates pass.
String dynamic parsing, public pull parsing, and typed decoding remain on
their existing specialized paths.

The direct builder must preserve:

- caller ownership of the IO, positive short reads, first-zero permanent EOF,
  read-ahead behavior, and unchanged IO error propagation;
- complete-document and trailing-content validation;
- dynamic `Int64`/finite-`Float64` number behavior;
- UTF-8, escape, surrogate, nesting, and token validation;
- byte offset, line, and column reporting at existing public error boundaries;
- last-value duplicate behavior and optional duplicate rejection;
- per-parse key caching and exact `max_cached_keys` behavior;
- every resource limit applicable to dynamic parsing, while a shared scan core
  must also preserve typed-value limit accounting for its typed consumers; and
- bounded input buffers and token scratch. Tree memory may grow with requested
  output, but parser scratch must not grow with total document size.

### 2C. Prove parity at refill boundaries

Compare the direct builder with `load(String)` and the current pull-backed IO
builder for all required-valid and required-invalid JSONTestSuite fixtures.
Add table-driven differential specs that split representative valid and
malformed documents at every byte boundary. Include variable short reads,
zero-byte EOF, injected IO failures, long tokens, malformed UTF-8, escaped
keys, number edges, trailing roots, nesting limits, every resource limit at
`limit - 1`, `limit`, and `limit + 1`, and duplicate-key modes.

Existing exact error-message tests remain exact. Differential tests require
the same acceptance result and error offset/location; where two private
implementations historically use different wording, preserve the documented
public wording rather than broadening the contract.

### Stage 2 decision gate

Run the frozen streaming-tree matrix as paired baseline/candidate processes.
The direct path replaces the pull-backed path only if it clears the 10% gate,
all semantic checks pass, managed allocation and retained-output RSS do not
regress materially, and String, pull, and typed controls pass their regression
gates. Otherwise keep the present implementation and record why the
architectural complexity was not justified.

## Stage 3: Formal validation and closeout

Status: complete. No performance candidate reached formal measurement: the
Stage 1 correctness fix missed an unaffected-path screening gate and the Stage
2 prototype failed its directional gate. The closeout therefore preserves
those screening results and runs correctness, portability, large-streaming,
and compatibility validation without manufacturing a candidate-versus-
baseline claim. See the [final results](post-0.2-performance-results.md).

Run formal validation only after directional screening selects the final
candidate. Use a fresh worktree for the runtime baseline and separately built
binaries for baseline and candidate; never infer candidate-versus-baseline
improvement from each commit's independent ratio to Crystal.

Required validation is:

1. `shards check`, formatting, lint, documentation examples, the randomized
   default suite, and the combined portable suite.
2. Release builds for every benchmark and example affected by the changes.
3. Twenty paired processes for each frozen targeted workload, with the
   predeclared schedule, bootstrap seed, environmental admission, and
   invalidation policy.
4. The five canonical dynamic String controls and pull drain/skip controls.
5. Both typed 256 MiB profiles, retained-output snapshots, and the dynamic
   parser gate when Stage 1 or shared scanner code changes.
6. One-byte streaming checks, exact post-`2^32` offset validation, and the
   bounded no-retention large-document gate whenever shared streaming or typed
   code changes.
7. Local Sunlight compatibility when the corpus is available.
8. Correctness on the minimum supported Crystal release and current
   development compiler. The newest supported stable compiler on x86-64 is
   the performance authority; ARM64 and macOS workflows are report-only until
   a repeatable host protocol is established.

Archive accepted and invalid attempts, source and fixture hashes, build
attestation, environment logs, raw receipts, analysis code, and a checksummed
artifact manifest. The closeout report must distinguish cumulative managed
allocation, live heap after GC, process peak RSS, and requested output memory.

## Proposed commit sequence

Keep the sequence flexible enough to omit experiments that fail their gates:

1. `Add performance attribution benchmarks`
2. `Record post-0.2 performance baseline`
3. One focused commit for each accepted typed or key optimization
4. `Document key caching tradeoffs`
5. `Refactor streaming scan core`, only if the chosen design requires it
6. `Build streaming trees directly`, only after parity and the 10% gate
7. `Record post-0.2 performance results`

Rejected spikes stay out of the production history. Their hypothesis,
measurement, and rejection reason belong in the closeout report so the same
idea is not repeated without new evidence.

## Completion criteria

The plan is complete when:

- remaining typed overhead is either reduced by accepted changes or recorded
  as requested output and compatibility cost;
- key-cache guidance is based on measured reuse and cardinality rather than a
  universal recommendation;
- `load(IO)` either uses a validated direct builder or has a recorded result
  showing that the pull-backed design remains preferable;
- every accepted production change has same-toolchain paired evidence and
  portable correctness coverage; and
- the final report and checksummed receipts make both positive and negative
  results reproducible.

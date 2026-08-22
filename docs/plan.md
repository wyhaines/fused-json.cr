# Version 0.1.0 Implementation History

Milestone record completed: 2026-08-21. This document records the milestones
completed for version 0.1.0. It describes the implementation sequence and the
evidence used at milestone closeout; the README contains the current roadmap.

## Working Rules

- Correctness takes priority over throughput. Every optimization includes tests
  for the path it changes.
- Keep semantic changes separate from performance changes when practical.
- Use Crystal's `JSON.parse` as the dynamic-result oracle for their shared
  domain. Test strict acceptance independently so shared bugs are detectable.
- Benchmark release builds, consume results, and verify equality before timing.
- Record compiler version, commit, CPU, corpus, command, throughput, and
  allocation data with published results.
- Keep commits focused, with short, direct messages and no attribution trailers.
- Update [`design.md`](design.md) whenever a decision changes the public
  contract or architecture.

## Milestone 0: Baseline and Feasibility — Complete

The initial investigation identified Crystal's character-oriented lexer and
temporary numeric strings as useful targets. Oj's byte scanner informed the
approach, but Ruby-specific construction and compatibility modes were excluded.

Five representative Oj corpora now cover key-heavy, float-heavy, Unicode, URL,
and nested object workloads. Benchmarks compare in-memory parsing into a fully
materialized dynamic tree.

Acceptance evidence:

- Candidate and oracle values match on all five corpora.
- Ruby/Oj comparison uses the current Oj checkout rather than an installed gem.
- Benchmarks include warmup, sustained measurement, live result consumption,
  MiB/s, and bytes or objects allocated per operation.

## Milestone 1: Strict Dynamic Parser — Complete

The parser directly produces `JSON::Any` from a `String`. It includes strict
numeric grammar, checked `Int64` conversion, direct-range `Float64` conversion,
UTF-8 validation, escape decoding, surrogate handling, nesting limits, lazy
error locations, and optional per-parse object-key caching.

Current evidence:

- 14 specs pass, including 500 deterministic generated documents.
- 31 Oj JSON fixtures have zero mismatches against `JSON.parse`.
- Boundary tests cover string lengths around common scanner boundaries,
  malformed UTF-8, numeric limits, and nesting at 512/513.
- A release build completes and the candidate is faster than `JSON.parse` on
  each canonical corpus in the initial local measurements.

## Milestone 2: Conformance and Portability — Complete

The strict `String -> JSON::Any` implementation now has an independently
licensed conformance corpus, retained mutation coverage, guarded recursion, a
portable float fallback, and a compiler test matrix.

Completed work:

1. Vendored the complete 318-file JSONTestSuite parsing corpus at pinned commit
   `1ef36fa01286573e846ac449e8683f8833c5b26a`, with its MIT license and
   provenance. All 35 implementation-defined cases have an explicit policy.
2. Added exact error-location checks, long numeric tokens, and a deterministic
   2,000-case mutation harness that exercises invalid bytes and cached keys.
3. Isolated pointer-range float conversion in `Float64Decoder` and added a
   public-API fallback selectable with `-Dfused_json_force_portable_float`.
4. Capped recursive nesting at 512 after reproducing native stack exhaustion
   with an unsafe caller-selected depth. Oversized integer limits are rejected
   before narrowing.
5. Audited cursor, UTF-8, and integer arithmetic paths. No reachable
   out-of-bounds read or unchecked integer accumulation was found.
6. Set Crystal 1.21 as the minimum and added CI jobs for 1.21, latest stable,
   and nightly, including formatting, both float backends, specs, and a release
   benchmark build.
7. Kept byte, token, and entry budgets outside the current `String` API. Callers
   must bound untrusted source size; consistent granular budgets wait for the
   streaming design.

Acceptance evidence:

- All 95 required-valid fixtures are accepted and all 188 required-invalid
  fixtures raise `FusedJSON::ParseError`.
- Crystal 1.21.0 and 1.22-dev pass 30 default-backend examples and 31
  forced-fallback examples with no failures.
- Both compilers build the release benchmark and satisfy shard metadata.
- The release fast path still inlines to the same pointer-range `fast_float`
  call. Corpus validation remains faster than `JSON.parse` on all five inputs;
  publish throughput only from a controlled low-load run.
- The compiler-internal float reference is confined to one guarded adapter.

## Milestone 3: Reusable Parse Engine and Pull API — Complete

Scalar recognition now lives in `ByteScanner`, while the specialized recursive
tree builder remains the implementation behind `FusedJSON.load`. The new
in-memory `FusedJSON::PullParser` uses typed value slots and an explicit frame
stack rather than event objects.

Completed work:

1. Defined primed semantic events, owned-string behavior, exact advancement,
   source locations, strict document completion, and wrong-kind errors.
2. Extracted the byte cursor, UTF-8 and escape validation, numeric conversion,
   string materialization, and lazy errors without virtual per-byte dispatch.
3. Added scalar and container readers, block helpers, `read_next`, `finish`, and
   validating `skip_value`/`skip` operations.
4. Made pull strings lazy and added a validation-only scan path, so ignored
   strings are neither decoded nor interned, including scalar roots.
5. Compared Crystal integration strategies. The native reader remains
   independent; a private `JSON::PullParser` subclass adapter is the preferred
   typed-compatibility experiment because Crystal's APIs require the nominal
   stdlib type.
6. Added a release benchmark for pull-to-tree, event draining, and whole-root
   skipping. CI builds both benchmark programs.

Acceptance evidence:

- Pull construction and skipping pass all 95 required-valid JSONTestSuite cases,
  reject all 188 required-invalid cases, and apply the existing explicit policy
  to all 35 implementation-defined cases.
- Focused tests cover every event and scalar, nested helpers, duplicate keys,
  independent readers, owned strings, wrong reads, exact error locations,
  nesting limits, strict trailing content, and malformed skipped subtrees.
- Crystal 1.21.0 and 1.22-dev pass 54 default-backend and 55 portable-backend
  examples with no failures.
- `FusedJSON.load` retains its fused path and showed no material regression in
  an alternating baseline/current release-build check. Pull-to-tree paid a
  preliminary 16–44% state-machine cost on the five corpora, so it does not
  replace `load`. In the same loaded-host diagnostic, whole-root skipping was
  roughly 1.5–3.5x faster than building the tree and allocated under 0.4 KiB
  per operation instead of 0.1–8.5 MiB. A separate 1 MiB scalar-string probe
  stayed at 224 bytes per skip, confirming allocation does not scale with
  ignored string size. The timing figures justify the separate interface but
  are not publishable benchmark claims; controlled low-load runs remain
  required for README results.

## Milestone 4: Typed Decoding — Complete

Typed deserialization now consumes the native pull engine through a private
`JSON::PullParser` subclass adapter. The experimental public entry point is
`FusedJSON.from_json(source, Type)`, with the existing nesting and local key
cache options.

Completed work:

1. Split numeric grammar recognition from conversion and retained exact source
   ranges. Dynamic parsing still eagerly enforces Int64/finite Float64, while
   typed raw traversal and unknown-field skipping can preserve wider valid
   tokens.
2. Added a nominal stdlib adapter with strict source-exhaustion checking,
   delegated locations and errors, lazy strings, validating skips, and both raw
   replay methods.
3. Covered every fixed-width integer through UInt128, floats, strings, nulls,
   booleans, arrays, hashes, tuples, named tuples, enums, nilable and primitive
   unions, and tested structured-union replay.
4. Covered `JSON::Serializable` required/default/nilable/renamed fields,
   converters, roots, presence, ignore, default/strict/unmapped unknown-field
   policies, duplicate-last behavior, raw converters, and discriminators.
5. Documented the supported matrix and explicit deferred contracts in
   [`typed-decoding.md`](typed-decoding.md).
6. Added a release typed benchmark using the canonical Twitter corpus, with
   independent stdlib, default, and cached typed sinks plus a separate
   dynamic-tree allocation comparison.

Acceptance evidence:

- Differential examples exercise every claimed core category against
  Crystal's typed decoder. Adapter-focused tests cover nominal converter
  dispatch, both raw paths, annotations, structured unions, and discriminator
  replay.
- Crystal 1.21.0 and 1.22-dev pass the default and portable-float suites; the
  exact final example counts are recorded with the implementation commits.
- In a short loaded-host release diagnostic on `twitter.json`, default typed
  decoding ran near stdlib typed throughput and cached decoding slightly above
  it. Default and cached typed allocation were about 20% and 7% of
  `JSON.parse` tree construction respectively. These figures establish the
  allocation gate but are not publishable benchmark claims.
- Deferred APIs are explicit: lazy iterators, automatic arbitrary-precision
  dynamic values, and a public adapter. Explicit typed `BigInt` decoding is
  available through Crystal's `big/json` adapter. The factory requires eager
  consumption and rejects incomplete custom constructors through its
  exhaustion check.

## Milestone 5: Streaming Input — Complete

`IO` parsing now consumes one complete document without first copying it into a
`String`, while preserving the specialized in-memory paths.

Completed work:

1. Added `StreamingPullParser` with a configurable 1-byte to 16-MiB input
   buffer, positive short-read support, explicit zero-read EOF behavior, and
   `IO#read_utf8` decoding.
2. Preserved strings, escapes, UTF-8, literals, and numbers across refills.
   Reusable scratch grows only to the current token; returned strings are owned.
3. Added `IO` overloads for pull, dynamic `load`/`parse`, and typed `from_json`.
   Separate concrete typed adapters preserve static dispatch on the `String`
   path.
4. Defined caller ownership, strict exhaustion, error propagation, decoded
   UTF-8 byte offsets, and one-based Unicode-aware lines and columns across
   refills.
5. Added a release streaming benchmark with semantic preflight, first-event
   latency, drain and skip throughput, managed allocations, and separate
   file-backed peak-RSS workloads.

Acceptance evidence:

- Streaming pull build and skip paths accept all 95 required-valid
  JSONTestSuite cases, reject all 188 required-invalid cases, and apply the 35
  recorded implementation-defined policies with one-byte reads and tiny parser
  buffers.
- Focused tests split a representative document at every byte boundary, run
  scalar roots one byte at a time, exercise long tokens with tiny awkward
  chunks, and cover malformed EOF, invalid UTF-8, short and zero-byte reads, IO
  failures, strict trailing content, caller ownership, and exact locations.
- Dynamic and typed `IO` facades match their in-memory counterparts with
  one-byte and deliberately awkward chunk sizes, including wide integers, raw
  replay, converters, unknown-field skipping, and nesting limits.
- Crystal 1.21.0 and 1.22-dev pass 102 default-backend and 103 portable-backend
  examples with warnings treated as errors. Both compilers format-check and
  release-build the streaming benchmark.
- A local release-build `/usr/bin/time -v` probe used constant-depth arrays of
  short tokens and `file-stream-skip` with the default 32-KiB buffer. Maximum
  RSS remained between 4,936 and 5,108 KiB as inputs grew from 1 to 64 MiB;
  equivalent preloaded-`String` runs grew from 5,948 to 70,584 KiB. Checksums
  matched at every size. This is directional acceptance evidence, not a
  portable performance claim. Current-token scratch, requested output, cached
  keys, and caller-owned IO buffers remain documented exceptions.

## Milestone 6: Systematic Optimization — Complete

Completed work:

1. Profiled all canonical inputs. ActivityPub is 90.4% string payload, with
   long ASCII spans and only 59 escaped strings, making string recognition the
   useful target rather than Ruby/Oj API emulation.
2. Added bounded word-at-a-time quote, backslash, control, and high-byte
   detection for in-memory and streaming readers. The implementation uses safe
   local-word copies, normalizes big-endian hosts, handles tails scalarly, and
   has a forced scalar build for portability and differential testing.
3. Kept escaped decoding scalar after bulk scanning short escape-separated
   spans regressed the dense-escape control corpus.
4. Changed streaming scratch retention to
   `max(2 * buffer_size, 64 KiB)`. This avoids repeated growth for completed
   tokens up to that threshold while still discarding unusually large ones.
5. Added optional streaming `max_token_bytes` enforcement to pull, dynamic,
   and typed IO entry points, including keys and skipped values.
6. Kept key caching explicit and disabled by default. It is a per-parser
   allocation tradeoff for repeated schemas, not an automatic speed policy;
   global or adaptive pools remain rejected.
7. Rejected unconditional collection capacity hints. JSON supplies no count
   without a pre-scan, and fixed hints overallocate the common small-container
   case. The earlier pull-to-tree experiment was 16–44% slower, so it did not
   justify replacing the fused recursive builders under the tested depth-512
   cap.
8. Extended the parse benchmark to report relative standard deviation and
   managed bytes per operation alongside throughput.

Acceptance evidence:

- Scanner tests exhaust every special byte, position, alignment, and
  adjacent-byte pair, and compare deterministic random slices with a scalar
  oracle. Additional cases cover malformed boundaries across dynamic, pull,
  skip, and typed paths, plus every streaming split of one mixed
  escaped/Unicode string.
- On Crystal 1.21.0 and 1.22-dev, the default and scalar builds pass 118
  examples; the portable-float and combined-fallback builds pass 119. Warnings
  are errors, and both compilers format-check and release-build the parse and
  streaming tools.
- On a Ryzen 9 7940HS with Crystal 1.22.0-dev `[2e13e6a73]`, seven independent
  samples per backend and corpus, with backend order alternated, showed a 6.5%
  geometric-mean word/scalar gain across the five corpora. ActivityPub and
  Twitter improved about 12%, Ohai 6%, Canada 4%, and CITM was flat within
  0.2%. Short-string, Unicode, and dense-escape controls changed by -0.2%,
  +4.4%, and +1.1% respectively.
- With one-byte reads on ActivityPub, scratch reuse reduced managed allocation
  from 511,201 to 101,871 B/op for event drain and from 415,242 to 5,850 B/op
  for root skip. Directional throughput improved 33% and 39% in the same
  focused comparison.
- Key-cache characterization found 45, 6, 321, 394, and 94 distinct keys in
  ActivityPub, Canada, CITM, Ohai, and Twitter. Caching reduced allocation by
  about 11%, 19%, and 19% on the three high-reuse corpora, was neutral on
  Canada, and increased it 12% on Ohai; timing varied with GC pressure.
- Capacity 4 raised the geometric mean of canonical allocation by 14.5% for a
  noisy 1.3% throughput change; capacities 8 and 16 regressed both throughput
  and allocation. Empty and two-member controls made the eager-allocation cost
  explicit, while only the wide-array control benefited consistently.
- The controlled pre-optimization baseline at `07d7c9e` already exceeded
  Crystal `JSON.parse` on every canonical corpus, with a 1.77x geometric mean.
  Ruby/Oj remains comparison context, not a correctness or release gate.

Local experiment provenance:

The named experiment commits predate the pre-release rename to FusedJSON. Their
exact commands therefore retain the historical `oj_crystal` build flags and
`OJ_CRYSTAL_*` environment variables; current checkouts use `fused_json` and
`FUSED_JSON_*` respectively.

- Baseline and scanner comparisons used Crystal 1.22.0-dev `[2e13e6a73]` on a
  Ryzen 9 7940HS, x86_64, pinned to CPU 4. Release binaries at `07d7c9e` and
  `6dbba52` used one second of warmup, two seconds of measurement, semantic
  preflight, and three or seven independent process samples respectively. The
  scalar comparison built the same source with
  `-Doj_crystal_force_scalar_string_scan`.
- The scratch comparison built `bench/stream.cr` at `6dbba52` and `c027827`,
  then ran ActivityPub with `OJ_CRYSTAL_STREAM_CHUNK=1`,
  `OJ_CRYSTAL_STREAM_BUFFER=1`, `OJ_CRYSTAL_BENCH_WARMUP=0.2`,
  `OJ_CRYSTAL_BENCH_TIME=0.5`, and `OJ_CRYSTAL_BENCH_ALLOCATIONS=50` on CPU 4.
- Key-cache and capacity figures are local directional decision diagnostics at
  `c6d1f54`, not release claims. Each used the same compiler and machine with
  five alternating release-process samples on CPU 4. The key runs used
  0.25-second warmup and 0.5-second timing;
  capacity runs temporarily changed both dynamic constructors to 0, 4, 8, or
  16 and used 0.1-second warmup, 0.15-second timing, canonical corpora, and
  empty, two-member, wide, and repeated-small-container controls. Allocation
  used `GC.stats.total_bytes`; key samples measured one result-retained parse,
  while capacity samples divided a result-retained timed loop by its iteration
  count.

The accepted scanner and scratch paths can be reproduced with the checked-in
runners from worktrees at the named commits. Repeat each timed command in a
fresh process and alternate comparison order; `OJ_ROOT` names an Oj checkout
containing the five source corpora:

```console
$ crystal build --release --no-debug bench/parse.cr -o /tmp/oj-word
$ crystal build --release --no-debug -Doj_crystal_force_scalar_string_scan bench/parse.cr -o /tmp/oj-scalar
$ env OJ_CRYSTAL_BENCH_WARMUP=1 OJ_CRYSTAL_BENCH_TIME=2 taskset -c 4 /tmp/oj-word $OJ_ROOT/test/data/{activitypub,canada,citm_catalog,ohai,twitter}.json
$ env OJ_CRYSTAL_BENCH_WARMUP=1 OJ_CRYSTAL_BENCH_TIME=2 taskset -c 4 /tmp/oj-scalar $OJ_ROOT/test/data/{activitypub,canada,citm_catalog,ohai,twitter}.json

$ crystal build --release --no-debug bench/stream.cr -o /tmp/oj-stream-before  # at 6dbba52
$ crystal build --release --no-debug bench/stream.cr -o /tmp/oj-stream-after   # at c027827
$ env OJ_CRYSTAL_STREAM_CHUNK=1 OJ_CRYSTAL_STREAM_BUFFER=1 OJ_CRYSTAL_BENCH_WARMUP=0.2 OJ_CRYSTAL_BENCH_TIME=0.5 OJ_CRYSTAL_BENCH_ALLOCATIONS=50 taskset -c 4 /tmp/oj-stream-before $OJ_ROOT/test/data/activitypub.json
$ env OJ_CRYSTAL_STREAM_CHUNK=1 OJ_CRYSTAL_STREAM_BUFFER=1 OJ_CRYSTAL_BENCH_WARMUP=0.2 OJ_CRYSTAL_BENCH_TIME=0.5 OJ_CRYSTAL_BENCH_ALLOCATIONS=50 taskset -c 4 /tmp/oj-stream-after $OJ_ROOT/test/data/activitypub.json
```

Release-facing benchmark procedure remains: compile with
`--release --no-debug`, pin a CPU core on a quiet host, run semantic preflight,
use at least one second of warmup, and take multiple sustained process-level
samples. Report median MiB/s, relative speed, and bytes per operation.
Specialized controls supplement but never replace the five canonical corpora.

The release target remains a geometric-mean throughput of at least 1.5x
Crystal `JSON.parse` for default dynamic `String` parsing, with no canonical
corpus materially slower than the standard library. Hardware-independent CI
checks semantics and portable fallbacks rather than absolute MiB/s.

## Milestone 7: Release Preparation — Complete

Completed work:

1. Finalized the compiler range `>= 1.21.0, < 2.0.0` and, after milestone
   closeout, renamed the unreleased project to repository `fused-json.cr`, shard
   and require path `fused_json`, and namespace `FusedJSON`.
2. Defined the supported API, option validation, error and location behavior,
   and pre-1.0 compatibility policy. Implementation types are hidden from
   generated API documentation.
3. Added compile-checked public examples, installation and migration guidance,
   changelog, contribution and security policies, third-party notices, exact
   license texts, and release instructions.
4. Pinned CI actions and added a manual least-privilege release workflow that
   validates the exact version, ref, and supported compilers before creating a
   tag and GitHub release.
5. Documented explicit typed `BigInt` decoding through Crystal's `big/json`
   adapter for both `String` and `IO`. Dynamic `JSON::Any` and the public pull
   reader deliberately retain their `Int64` domain.
6. Collected five alternating-order pull and typed samples and three streaming
   samples, then recorded the complete method, medians, RSD, and managed
   allocation results in [`benchmark-results.md`](benchmark-results.md).

Acceptance evidence:

- Crystal 1.21.0 and 1.22.0-dev pass 126 default and scalar examples and 127
  portable-float and combined-fallback examples with warnings treated as
  errors. The focused typed suites include positive, negative, and one-byte-IO
  arbitrary-precision integer cases.
- Both compilers pass shard metadata and formatting checks, compile all three
  standalone examples and nine documentation examples, expose exactly the four
  documented public API types, synchronize release version `0.1.0`, and build
  all five release benchmark targets.
- The controlled reference run identifies commit, compiler, LLVM, target, CPU,
  corpus paths and sizes, build flags, benchmark order, durations, sample
  counts, variability, and managed allocations. High-variance samples are
  called out rather than generalized into release guarantees.
- No known correctness or memory-safety defect is deferred for performance.
  Publishing remains a deliberate operator action through the documented
  release workflow; no remote push, tag, or GitHub release was created during
  implementation.

## Ideas Recorded at Version 0.1.0 Closeout

These were the follow-up ideas recorded before version 0.1.0 was published.
The README contains the current roadmap.

1. Exercise the word scanner on real big-endian and 32-bit runners when they
   become available; retain forced-scalar CI coverage meanwhile.
2. Re-run controlled benchmarks on stable Crystal releases and additional CPUs
   before broadening performance claims.
3. Let application feedback guide any expansion of the experimental typed and
   pull APIs, including a custom dynamic value type if automatic arbitrary
   precision becomes important.

## Open Decisions

- How long to retain Crystal 1.21 after newer stable releases.
- When a newly reviewed compiler can join the zero-substring float range.
- Whether native acceleration earns its additional build complexity.

Until resolved, choose the conservative path: strict JSON, Crystal-compatible
dynamic values, pure Crystal, per-parse state, and no expansion of stable public
API without tests and documentation.

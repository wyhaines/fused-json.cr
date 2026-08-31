# Streaming performance protocol

Status: frozen for the first runtime candidate, with the build-root amendment
below. This protocol was written at the benchmark-only commit
`773124b6c9a0e0ab9e659c27edc5a37cd6cbaeda`, before any streaming runtime
change was measured.

## Build-root amendment

Crystal embeds absolute paths derived from `__FILE__` and `__DIR__`. The first
prepared baseline binary was built in
`/tmp/fused-json-baseline-773124b`, while the first two candidate binaries were
built in the repository worktree. This changed read-only section sizes and
code placement in otherwise unchanged String-parser controls. Candidate
`726f862a1163966ed47da863631d9ac4a398e381`, for example, cleared both target
throughput floors but failed the unaffected sparse-String control. Inspection
then confirmed different embedded build roots and different placement for the
identical control code.

Those campaigns remain checksummed evidence, but they are build-root
confounded and cannot accept or reject a runtime candidate. The attribution
baseline and comparisons are recollected from binaries built sequentially in
the same absolute worktree, `/tmp/fused-json-streaming-build`. The compiler,
build command, cache configuration, and benchmark/support sources remain
unchanged. Both binaries must contain that exact embedded root, verified with
`strings`, before a campaign starts. No throughput or acceptance threshold is
changed by this amendment.

## Fixed-binary control amendment

Campaign format version 2 ran each unaffected String profile once from the
baseline binary and once from the candidate binary. The build-root correction
removed one source of layout drift, but the unchanged String scanner still
moved as streaming methods changed size and inlining. The resulting control
ratios measured executable layout as well as host drift, even though the
candidate did not change the String parser.

Campaign format version 3 therefore runs the baseline binary in both balanced
positions of every `string-control` pair. Receipts retain the `baseline` and
`candidate` order labels but each observation also records
`binary_role: baseline`, and campaign identity checks enforce that policy.
These controls now answer their intended question: whether performance drifted
between the two time slots. Target and guardrail entries still compare separate
baseline and candidate binaries. A candidate remains ineligible if it changes
the String parser source; source review and the complete String correctness
suite enforce that restriction. The existing version-2 cross-binary controls
remain diagnostic evidence, but they do not decide acceptance. Thresholds and
target membership are unchanged.

## Reference build and host

- Runtime reference: `1d7e5e0ea88940946fd1ea25d30241331442b344`.
- Runtime-equivalent benchmark baseline:
  `773124b6c9a0e0ab9e659c27edc5a37cd6cbaeda`. The commits between these two
  references change benchmarks, tests, CI, and documentation, but not `src/`.
- Performance compiler: Crystal 1.21.0 `[57cf7da50]`, LLVM 20.1.8, target
  `x86_64-unknown-linux-gnu`.
- Correctness compiler: Crystal 1.22.0-dev `[6c6a5e988]`, LLVM 21.1.8, target
  `x86_64-pc-linux-gnu`.
- Host: AMD Ryzen 9 7940HS, Linux 7.0.11-76070011-generic, x86-64.
- Benchmark placement: logical CPU 4 with its sibling CPU 5 left idle.
- Runtime environment: `taskset -c 4`, `GC_NPROCS=1`, `GC_MARKERS=1`,
  `LANG=C`, `LC_ALL=C`, and `TZ=UTC`.
- CPU policy at protocol freeze: `amd-pstate-epp`, `powersave` governor,
  `balance_performance` energy preference. Baseline and candidate campaigns
  must record the same policy.

Baseline and candidate binaries are built sequentially in
`/tmp/fused-json-streaming-build` with `--release --no-debug` using the same
compiler. Their benchmark and support source hashes must match byte for byte.
Commit identities, binary hashes, compiler details, fixture hashes, process
order, GC settings, CPU policy, and the shared build root are recorded with the
campaign artifact.

## Quiet-host requirement

The campaign runner refuses to start unless the one-minute load average is at
most 2 and both logical CPUs in the selected physical core are at least 90%
idle during a one-second sample. It performs this check before creating the
output directory. A formal run may not relax either threshold.

The per-observation load records are reviewed after collection. A campaign is
invalid if unrelated work begins during it, the CPU policy changes, thermal or
power behavior is visibly unstable, or noise prevents an attributable result.
An invalid campaign is retained with its disposition; individual profiles are
not selectively discarded.

Two pre-protocol calibration passes were rejected. Their one-minute load
ranged from 14.89 to 18.64, and 13 of 51 observations in the first pass and 48
of 51 in the second exceeded 10% relative standard deviation. A Warp
application scope was using roughly 15 CPU cores, including CPU 4. Those runs
changed the fixture sizes and led to the automatic quiet-host gate; none of
their throughput figures are baseline evidence.

## Frozen attribution matrix

The `attribution` matrix contains 51 profiles. It uses a 32 KiB parser buffer,
4 KiB deterministic short reads, no key cache unless named, and no active
limits unless named.

| Work | Fixture size | Transports or variants |
| --- | --- | --- |
| Integers and floats | 20,000 values | String, ordinary memory IO, 4 KiB short reads |
| Short plain strings | 10,000 values | String, ordinary memory IO, 4 KiB short reads |
| Long plain, raw UTF-8, sparse escapes, dense escapes, Unicode escapes, surrogate escapes | 1,000 values, 512 requested token bytes | String, ordinary memory IO, 4 KiB short reads |
| Boundary-spanning tokens | 8 values, 65,536 requested token bytes | Plain and four escape forms over ordinary and short-read IO |
| Consumer attribution | 1,000 sparse-escape values | Pull skip, dynamic tree, typed read, dynamic documents, typed documents |
| Object keys | 2,000 objects, 96 requested value bytes | Repeated and unique, plain and escaped, cache off; repeated keys also cache on |
| Active policies | 1,000 sparse-escape values | Exact token limit, exact document limit, duplicate-key checking |

The runner labels the nine String profiles `string-control` and the other 42
profiles `guardrail`. Ordinary 512-byte tokens stay within a refill buffer;
the 65,536-byte fixtures cross several refills. Boundary correctness is also
covered separately at every split within escapes and UTF-8 sequences.

The initial baseline collection uses three fresh processes per profile, 0.5
seconds of warmup, 1 second of measurement, three allocation iterations, and
50 one-value latency iterations:

```console
$ node scripts/streaming_performance_campaign.mjs \
    --mode=collect \
    --output=docs/benchmark-data/streaming-performance/baseline-773124b \
    --binary=/tmp/fused-json-streaming-token-cost-773124b \
    --commit=773124b6c9a0e0ab9e659c27edc5a37cd6cbaeda \
    --matrix=attribution \
    --samples=3 \
    --cpu=4 \
    --max-load=2 \
    --min-core-idle-percent=90 \
    --warmup=0.5 \
    --time=1 \
    --allocations=3 \
    --latency-iterations=50
```

The baseline is diagnostic. It reports medians and noise, but it does not by
itself accept an optimization.

## First candidate: escaped-string materialization

The first candidate may only account for decoded size during the existing
streaming validation pass and use that information to build an owned decoded
string. It must not change the String parser, public API, skip behavior, JSON
grammar, cache policy, or error locations.

The `escaped` comparison matrix declares 12 targets:

- sparse, dense, Unicode, and surrogate escapes over ordinary memory IO;
- the same four forms over deterministic 4 KiB short reads; and
- sparse escapes through dynamic trees, typed reads, dynamic document readers,
  and typed document readers.

The four matching String pull profiles are unaffected controls and are not
included in the target average. Screening uses five alternating
baseline/candidate pairs with 0.5 seconds of warmup, 1 second of measurement,
three allocation iterations, and 50 latency iterations. The candidate proceeds
only when:

- every receipt and semantic identity check passes;
- the target geometric mean is at least 1.05x baseline;
- every target median is at least 0.98x;
- the four String controls have a geometric mean of at least 0.99x and no
  median below 0.97x; and
- managed allocation does not increase by more than the greater of 4 KiB per
  operation or 0.1%.

If screening passes, the complete `attribution` matrix receives five paired
runs. Its 42 streaming guardrails must have a geometric mean of at least 0.99x
and no median below 0.97x. The nine String controls use the same floors stated
above. Existing `small-objects`, `nested`, and `escaped-strings` tree profiles
over ordinary and 4 KiB short-read IO remain end-to-end controls, with caching
both off and on.

A candidate that clears screening receives 20 pairs, evenly balanced for
process order, with 1 second of warmup, 2 seconds of measurement, five
allocation iterations, and 100 latency iterations. The target geometric mean
must remain at least 1.05x and its one-sided 95% paired-bootstrap lower bound
must be at least 1.02x. The analysis uses campaign format version 3, 10,000
resamples, and seed `0x5eed2026`.

First-value latency may not regress by more than 2% in either ordinary or
short-read IO. Fresh-process peak RSS may not rise by more than the greater of
1 MiB or 2%. Returned strings must remain valid after the reader advances, and
the scratch-retention bound must remain unchanged.

## Later candidates

Boundary copying is considered only after the escaped-string result is known.
Its current target set is the ten-profile `boundary` matrix: long plain ASCII,
raw UTF-8, sparse escapes, dense escapes, and floats over ordinary and
short-read IO. A more specific target subset may replace it only in a committed
protocol amendment made before that candidate's runtime code is written.

Scanner-loop and refill-policy work requires the same kind of predeclared
amendment after profiles or counters identify a separable cost. The acceptance
thresholds do not change. A microbenchmark result without an improvement in a
complete pull, tree, typed, or document operation is not sufficient.

## Correctness and memory closeout

Every candidate runs the focused split and ownership specs first, followed by
the complete suite on Crystal 1.21.0 and the development compiler. The required
configurations are default, portable float, scalar string scan, and both
fallbacks together. Closeout also includes formatting, Ameba, documentation
examples and API docs, JSONTestSuite, exact post-`2^32` offsets, one-byte and
irregular reads, encoded input, resource limits, duplicate keys, all document
framings, and the bounded 4 GiB no-retention workload.

Raw accepted and invalid campaigns live under
`docs/benchmark-data/streaming-performance/`. Each campaign must pass
`sha256sum -c SHA256SUMS`. The baseline report records attribution and candidate
ordering; the final results report records every accepted and rejected runtime
experiment without treating diagnostic token rates as library-wide speedups.

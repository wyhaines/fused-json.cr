# Post-0.2 Performance Protocol

This protocol freezes the measurements used to execute the
[post-0.2 performance plan](post-0.2-performance-plan.md). It was written
after the benchmark-only commits ending at
`8cd68bf8f20f5703166c96894739df91d4b79364`
and before any candidate runtime change.

## Authority and environment

- Runtime-equivalent baseline: `8cd68bf8f20f5703166c96894739df91d4b79364`.
- Performance compiler: Crystal 1.21.0 `[57cf7da50]`, LLVM 20.1.8,
  target `x86_64-unknown-linux-gnu`.
- Development correctness compiler: Crystal 1.22.0-dev `[6c6a5e988]`,
  LLVM 21.1.8, target `x86_64-pc-linux-gnu`.
- Host: AMD Ryzen 9 7940HS, Linux x86-64.
- Benchmark CPU: 4. Its sibling CPU 5 must remain idle except for unavoidable
  kernel work.
- Every benchmark child uses `taskset -c 4`, `GC_NPROCS=1`, and
  `GC_MARKERS=1`.
- Baseline and candidate binaries are built separately with
  `--release --no-debug` by the same compiler. The benchmark sources must be
  byte-identical and their SHA-256 hashes are recorded.

Generated receipts and summaries live under
`docs/benchmark-data/post-0.2-performance/`. Invalid attempts are retained
with their disposition and do not contribute to accepted estimates.
The accepted Stage 0 figures and decisions are recorded in the
[baseline report](post-0.2-performance-baseline.md).

## Stage 0 attribution

The typed shape ladder uses:

- 20,000 scalar elements and 5,000 record elements;
- partial-key cardinality 16;
- a 16 KiB streaming buffer;
- 0.25 seconds of warmup and 0.75 seconds of measurement per operation;
- five allocation iterations; and
- two complete processes in alternating operation order.

The accepted attribution passes select the `uncached,cached` profiles. The
bounded profile remains a separate correctness probe: the first reverse-order
attempt exposed a baseline `StringPool` rehash lookup defect and is retained
as invalid evidence. Stage 1 must resolve that defect before exact-capacity
timing is accepted.

This is a diagnostic rather than a performance gate. Report median
nanoseconds and managed bytes per element for native cursor, repeated
`read(T)`, and `read_array(T)`. The typed-minus-native delta attributes
adapter overhead only when both operations construct and checksum equivalent
values.

Streaming attribution uses 50,000 generated records for `small-objects`,
`nested`, and `escaped-strings`. It measures `string`, `io-memory`,
`chunked-memory` with 4 KiB reads, and `pull-tree`, all with a 32 KiB parser
buffer and caching disabled. Each profile gets three fresh processes with 0.5
seconds of warmup, 1 second of measurement, and three allocation iterations.
One additional run per generated shape enables boundary preflight.

Stage 0 may select a smaller set of typed target shapes after reviewing the
complete ladder. It may not change the Stage 2 matrix after candidate data
exists.

## Directional candidate screening

A production experiment first receives five alternating baseline/candidate
pairs. Each child uses 0.5 seconds of warmup, 1 second of measurement, and
three allocation iterations. Reject the experiment without formal measurement
when:

- a semantic or receipt-identity check fails;
- any target median is below 0.98x baseline;
- the target geometric mean does not improve by at least 5%; or
- an unaffected control's geometric mean is below 0.99x.

The direct streaming builder has the stricter plan threshold and proceeds to
formal measurement only when its target geometric mean improves by at least
10%.

## Frozen Stage 2 matrix

The direct streaming tree matrix contains 12 profiles:

- shapes: `small-objects`, `nested`, and `escaped-strings`;
- transports: `io-memory` and `chunked-memory`;
- cache policy: disabled and enabled; and
- 50,000 generated records, a 32 KiB parser buffer, and 4 KiB chunks.

String parsing and public streaming pull-to-tree construction over the same
three shapes are unaffected controls with caching disabled. The ordinary
`bench/stream.cr` drain and skip operations remain the public pull controls.
Canonical file-backed IO and the local Sunlight corpus are report-only
compatibility measurements because their availability is host-dependent.

## Formal Stage 2 schedule and gates

Each frozen target profile receives 20 baseline/candidate pairs. Ten pairs run
baseline first and ten run candidate first in a predetermined alternating
schedule. Every child uses 1 second of warmup, 2 seconds of measurement, and
five allocation iterations. Pair IDs and order positions are bound into each
receipt.

Analyze one candidate/baseline throughput ratio per pair. For the 12-profile
matrix:

- the geometric mean of profile geometric means must be at least 1.10x;
- every profile median must be at least 0.98x;
- the one-sided 95% paired-bootstrap lower bound for the matrix geometric mean
  must be at least 1.05x after 10,000 resamples with seed `20260826`;
- each unaffected control geometric mean must be at least 0.99x, with no
  individual median below 0.97x; and
- managed allocation may not exceed baseline by more than
  `max(4096 bytes/operation, 0.1%)` in any profile.

Peak RSS is measured in fresh processes for the three `io-memory` cache-off
profiles with parsed output retained. The candidate median may not exceed the
baseline median by more than `max(1024 KiB, 2%)`.

## Correctness and closeout

Before formal performance collection, candidate code must pass:

```console
$ shards check
$ crystal tool format --check src spec bench examples scripts
$ crystal spec --order=random --error-on-warnings
$ crystal spec -Dfused_json_force_portable_float \
    -Dfused_json_force_scalar_string_scan \
    --order=random --error-on-warnings
$ crystal run scripts/check_doc_examples.cr
```

The minimum supported compiler and development compiler both run the default
and combined-portable suites. Refill differential tests, all resource-limit
boundaries, JSONTestSuite, exact post-`2^32` offsets, and the bounded
no-retention large-document check run whenever their shared paths change.

The final report names accepted and rejected experiments, pairs every claimed
improvement directly against the runtime-equivalent baseline, and separates
cumulative managed allocation, live heap after GC, peak RSS, and requested
output memory.

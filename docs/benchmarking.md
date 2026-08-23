# Benchmarking

Benchmark only optimized builds and verify semantics before measuring. The
programs under `bench/` abort on result mismatches and retain results in
observable sinks.

```console
$ crystal build --release --no-debug bench/parse.cr -o bin/parse-bench
$ taskset -c 4 bin/parse-bench path/to/document.json
$ crystal build --release --no-debug bench/pull.cr -o bin/pull-bench
$ crystal build --release --no-debug bench/typed.cr -o bin/typed-bench
$ crystal build --release --no-debug bench/stream.cr -o bin/stream-bench
$ crystal build --release --no-debug bench/typed_cursor_cost.cr -o bin/typed-cursor-cost
$ crystal build --release --no-debug bench/limits_overhead.cr \
    -o bin/limits-overhead-default
$ crystal build --release --no-debug -Dfused_json_limits_api \
    bench/limits_overhead.cr -o bin/limits-overhead-limits-api
```

For in-process microbenchmarks, use a quiet host, pin one CPU, and set
`GC_NPROCS=1` and `GC_MARKERS=1` so Boehm GC does not place its helper threads
on that CPU. Allow at least one second of warmup and take multiple sustained
samples in independent processes. Alternate comparison order by setting
`FUSED_JSON_BENCH_REVERSE=1` on every other sample. Report medians, MiB/s,
relative standard deviation, and managed bytes per operation; use a separate
process-level RSS tool for peak memory. The one-shot TiC modes intentionally
have no internal warmup and rely on a separately warmed page cache.

`typed-cursor-cost` compares native structural reads, repeated `read(T)`, and
`read_array(T)` for scalar and representative record arrays over streaming
`IO::Memory`. It verifies equal counts and checksums, then reports time and
managed bytes per element:

```console
$ FUSED_JSON_BENCH_COMMIT=$(git rev-parse HEAD) \
    taskset -c 4 bin/typed-cursor-cost
```

Control its fixture sizes with `FUSED_JSON_CURSOR_SCALARS` and
`FUSED_JSON_CURSOR_RECORDS`, its parser buffer with
`FUSED_JSON_CURSOR_BUFFER`, and sampling with the standard
`FUSED_JSON_BENCH_*` variables. This is an adapter-cost diagnostic, not the
large-document release gate; use the end-to-end TiC modes for Crystal
comparisons.

`limits-overhead` measures the cost of introducing the Milestone 5 API when no
extended limit is enabled. Both configurations avoid allocating counter and
duplicate-key state. The tool generates and verifies one deterministic
mixed-value fixture, then runs one workload and one configuration per process.
Pair `default` (the `limits` keyword omitted) with `explicit-empty` (`limits:
FusedJSON::Limits.new`) for each String and IO variant of dynamic, pull, skip,
and typed parsing:
`string-dynamic`, `io-dynamic`, `string-pull`, `io-pull`, `string-skip`,
`io-skip`, `string-typed`, and `io-typed`.

Build the candidate both ways. Use the unflagged binary for its default-only
comparison with Milestone 4 so both sides have the same benchmark build shape.
Use one flagged candidate binary for both sides of the default/explicit-empty
comparison. For a Milestone 4 baseline, place the same benchmark source in an
`eb7b377` worktree and build it without `-Dfused_json_limits_api`; that binary
intentionally accepts only `--configuration=default`:

```console
$ crystal build --release --no-debug bench/limits_overhead.cr \
    -o bin/limits-overhead-m4
```

```console
$ GC_NPROCS=1 GC_MARKERS=1 \
    FUSED_JSON_BENCH_COMMIT=$(git rev-parse HEAD) taskset -c 4 \
    bin/limits-overhead-limits-api \
    --workload=io-pull --configuration=default >default.json
$ GC_NPROCS=1 GC_MARKERS=1 \
    FUSED_JSON_BENCH_COMMIT=$(git rev-parse HEAD) taskset -c 4 \
    bin/limits-overhead-limits-api \
    --workload=io-pull --configuration=explicit-empty >empty.json
```

Repeat pairs in fresh processes and alternate which configuration runs first.
For same-commit default/explicit-empty pairs, require the receipt `pairing_key`,
build, host, and environment to agree. For Milestone 4/candidate default pairs,
require the pairing key, compiler, host, and environment to agree; build commit
is the intentional difference, and both receipts must report `limits_api:
false`. Compare median iterations per second and managed bytes per operation.
The timing estimator divides total timed iterations by total timed batch
elapsed; the approximately 100 ms batch rates are used only for the reported
relative standard deviation. Control fixture size and IO buffering with
`FUSED_JSON_LIMITS_RECORDS` and
`FUSED_JSON_LIMITS_BUFFER`; the standard `FUSED_JSON_BENCH_*` variables control
sampling. The tool records source and semantic checksums, compiler and host
details, arguments, and all relevant environment settings in each JSON receipt.

The Milestone 5 acceptance campaign uses all eight workloads with 10,000
records, a 32 KiB IO buffer, 0.5 seconds of warmup, 1.5 seconds of measurement,
and 20 allocation-sample operations. Run every observation in a fresh,
CPU-pinned process on one quiet host with `GC_NPROCS=1` and `GC_MARKERS=1`.
Preschedule a balanced AB/BA order.

Admit the reference host only after 60 continuous seconds of two-second
samples with one- and five-minute load averages no greater than 0.5 and 1.0,
no more than two runnable tasks, and CPU `Tctl` no greater than 70 C. Start
within ten seconds. Continue sampling from a non-benchmark CPU and invalidate
the complete campaign if `Tctl` reaches 85 C, the one-minute load exceeds 1.5
twice consecutively, runnable tasks exceed three twice consecutively, or the
monitor loses its temperature source or has a gap longer than five seconds.
Keep the complete environment log. Never retain only the quiet pairs from an
invalid campaign; receipt RSD is diagnostic and is not an exclusion rule.

For each workload, collect 20 paired M4-default and candidate-default samples.
Both the median and geometric mean of the paired candidate/M4 throughput ratios
must be at least 0.98. Using bootstrap seed `20260822`, the one-sided 95% paired
bootstrap lower bound on the geometric mean must be at least 0.97 after 10,000
resamples. Candidate median managed B/op must not exceed the M4 median by more
than `max(4096 B, 0.1% of the M4 median)`. This allocation gate rejects hidden
per-element growth while allowing fixed measurement noise.

For each candidate-default and explicit-empty workload, collect 10 fresh paired
samples. Both the median and geometric mean of the paired explicit/default
throughput ratios must be at least 0.99. The same bootstrap procedure must give
a lower bound of at least 0.98. Apply the same allocation tolerance, using the
candidate-default median as the baseline. Record every receipt, the complete
prescheduled order, bootstrap seed, analysis output, and pass/fail result.

Every published result must identify the FusedJSON commit, Crystal version and
LLVM, CPU and target, exact corpus path and size, command, environment options,
warmup/calculation duration, and sample count. The five canonical Oj corpora are
`activitypub.json`, `canada.json`, `citm_catalog.json`, `ohai.json`, and
`twitter.json`. Specialized inputs supplement rather than replace them.

Dynamic parsing must retain a geometric-mean throughput of at least 1.5x
Crystal `JSON.parse`, with no canonical corpus materially slower. Ruby Oj is
useful cross-runtime context, not a release gate. Do not copy a local number
into release notes unless the commit and procedure are reproducible.

The controlled [reference results](benchmark-results.md) record the commit,
host, commands, medians, variability, and managed allocation data used for the
Milestone 7 release review.

The [TiC large-document benchmark guide](tic-benchmarking.md) covers generated
streaming fixtures, semantic verification, decompression baselines, one-shot
parser receipts, and external peak-RSS measurements.

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

Prefer a quiet host for in-process microbenchmarks. When that is unavailable,
freeze campaign-specific admission and invalidation rules before collecting
results. Pin one CPU and set `GC_NPROCS=1` and `GC_MARKERS=1` so Boehm GC does
not place helper threads on that CPU. Unless a frozen campaign below specifies
otherwise, allow at least one second of warmup and take multiple sustained
samples in independent processes. Alternate comparison order by setting
`FUSED_JSON_BENCH_REVERSE=1` on every other sample. Report
medians, MiB/s, relative standard deviation, and managed bytes per operation;
use a separate process-level RSS tool for peak memory. The one-shot TiC modes
intentionally have no internal warmup and rely on a separately warmed page
cache.

`typed-cursor-cost` compares native structural reads, repeated `read(T)`, and
`read_array(T)` for scalar and representative record arrays. It measures both
an owned `String` reader and `IO::Memory` through the streaming reader; record
profiles run with key caching disabled, enabled, and enabled with an exact
`max_cached_keys` bound. It verifies equal counts and checksums, then reports
time and managed bytes per element. The scalar profile exposes scalar fast-path
overhead; the record profiles expose the remaining fresh adapter-object cost
and its interaction with key caching:

```console
$ FUSED_JSON_BENCH_COMMIT=$(git rev-parse HEAD) \
    taskset -c 4 bin/typed-cursor-cost
```

Control its fixture sizes with `FUSED_JSON_CURSOR_SCALARS` and
`FUSED_JSON_CURSOR_RECORDS`, its streaming parser buffer with
`FUSED_JSON_CURSOR_BUFFER`, and sampling with the standard
`FUSED_JSON_BENCH_*` variables. Each transport and cache policy is reported as
a separate shape so adapter allocation can be distinguished from input-buffer
and key-allocation costs. This is an adapter-cost diagnostic, not the
large-document release gate; use the end-to-end TiC modes for Crystal
comparisons.

`limits-overhead` measures the cost of carrying a disabled limits policy. Both
configurations avoid allocating counter and duplicate-key state. The tool
generates and verifies one deterministic mixed-value fixture. The Milestone 4
comparison runs one workload and one default configuration in each fresh
process. The same-commit API comparison runs both `default` (the `limits`
keyword omitted) and `explicit-empty` (`limits: FusedJSON::Limits.new`) in one
fresh child and emits one paired receipt. Both comparisons cover each String
and IO variant of dynamic, pull, skip, and typed parsing:
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
    --workload=io-pull --configuration=paired \
    --paired-order=default,explicit-empty --pair-id=0 >pair.json
```

For Milestone 4/candidate comparisons, pair separate fresh default-only
processes and require matching pairing keys, compiler, host, and environment;
the build commit is the intentional difference and both receipts report
`limits_api: false`. For the same-commit API comparison, require both
measurements to come from one flagged binary, fixture, process, and atomic
paired receipt. The child calibrates both operations with the same sink-clear
and full-GC treatment, then measures approximately 100 ms batches in repeating
ABBA cycles. The requested A/B mapping is balanced across children. Allocation
probes are primed, cleared, collected, and measured symmetrically. One paired
child, not an internal batch, is an independent observation.

The timing estimator divides total timed iterations by total timed batch
elapsed; batch rates are used only for the reported relative standard
deviation. Control fixture size and IO buffering with
`FUSED_JSON_LIMITS_RECORDS` and `FUSED_JSON_LIMITS_BUFFER`; the standard
`FUSED_JSON_BENCH_*` variables control sampling. The tool records source and
semantic checksums, compiler and host details, arguments, and all relevant
environment settings in each JSON receipt.

The Milestone 5 acceptance campaign uses all eight workloads with 10,000
records, a 32 KiB IO buffer, and 20 operations per allocation sample. The M4
comparison uses 0.5 seconds of warmup, 1.5 seconds of measurement, and 20
prescheduled two-process AB/BA pairs per workload. Each side of the paired API
comparison uses 0.5 seconds of warmup and 0.75 seconds of interleaved timed
batches. It uses the 20 paired children per workload described below. Every
child is fresh and CPU-pinned with `GC_NPROCS=1` and `GC_MARKERS=1`.

The shared-host protocol pins the runner to CPU 0, the benchmark to CPU 3, and
watches its sibling CPU 2. Admit the M4 campaign only after 60 continuous
seconds of two-second samples with one- and five-minute load averages no
greater than 2.5, `Tctl` no greater than 70 C, and CPU 2 and CPU 3 each no more
than 10% busy. Start within ten seconds. Start every later M4 child from a
fresh post-observation sample at or below 70 C, allowing at most 60 seconds to
cool. Because a paired API child runs both configurations, its corresponding
thermal admission and start ceiling is 60 C and its cooldown allowance is 180
seconds. All other environmental limits are shared.

Invalidate the complete campaign if `Tctl` reaches 95 C, one-minute load
exceeds 4.0 twice consecutively, CPU 2 exceeds 20% busy twice consecutively, a
required environment read fails, the monitor has a gap longer than five
seconds, or a child reports less than 99% task CPU. Keep the complete
environment and task-audit logs. Never retain only quiet pairs from an invalid
campaign; receipt RSD and CPU-frequency samples are diagnostic and are not
exclusion or normalization rules.

For each workload, collect 20 paired M4-default and candidate-default samples.
Both the median and geometric mean of the paired candidate/M4 throughput ratios
must be at least 0.98. Using bootstrap seed `20260822`, the one-sided 95% paired
bootstrap lower bound on the geometric mean must be at least 0.97 after 10,000
resamples. Candidate median managed B/op must not exceed the M4 median by more
than `max(4096 B, 0.1% of the M4 median)`. This allocation gate rejects hidden
per-element growth while allowing fixed measurement noise.

For each candidate-default and explicit-empty workload, collect 20 fresh paired
children: ten begin with `default` as A and ten with `explicit-empty` as A in a
frozen balanced schedule. Analyze one explicit-empty/default throughput ratio
per child and bootstrap those 20 ratios. Both the median and geometric mean
must be at least 0.99, and the same fixed-seed bootstrap procedure must give a
lower bound of at least 0.98. Apply the same allocation tolerance, using the
candidate-default median as the baseline. Record CPU 3 `scaling_cur_freq` as
diagnostic metadata only; it is not an admission, invalidation, exclusion,
normalization, or adjustment rule. Record every paired receipt, the complete
prescheduled order, bootstrap seed, analysis output, and pass/fail result.

The accepted campaigns, exact runners, and complete record of performance
failures and environmentally invalid attempts are retained in the
[Milestone 5 benchmark results](milestone-5-benchmark-results.md).

Every published result must identify the FusedJSON commit, Crystal version and
LLVM, CPU and target, exact corpus path and size, command, environment options,
warmup/calculation duration, and sample count. The five canonical Oj corpora are
`activitypub.json`, `canada.json`, `citm_catalog.json`, `ohai.json`, and
`twitter.json`. Specialized inputs supplement rather than replace them.

Dynamic parsing must retain a geometric-mean throughput of at least 1.5x
Crystal `JSON.parse`, and every canonical corpus median must be at least
0.98x. The formal Milestone 6 runner uses five fresh, alternating-order
processes on CPU 3 and owns admission from CPU 0; its exact command is in the
[Milestone 6 protocol](milestone-6-protocol.md). Ruby Oj is useful
cross-runtime context, not a release gate. Do not copy a local number into
release notes unless the commit and procedure are reproducible.

The controlled [reference results](benchmark-results.md) preserve early
development measurements. They are useful historical context, not current
release evidence.

The [TiC large-document benchmark guide](tic-benchmarking.md) covers generated
streaming fixtures, semantic verification, decompression baselines, one-shot
parser receipts, and external peak-RSS measurements.
The [Milestone 6 validation protocol](milestone-6-protocol.md) freezes its
formal paired schedules, generated sizes, environmental rules, statistical
gates, and scale-RSS ceiling before observations begin.
The [accepted Milestone 6 results](milestone-6-benchmark-results.md) preserve
both complete campaigns, the independent audit, additional gates, and every
invalid attempt. They are comparative measurements from a hot shared host,
not quiet-host or peak-throughput estimates.
The [Milestone 7 stable release review](milestone-7-release-review.md) records
the 0.2.0 candidate's stable-compiler correctness, bounded-RSS gate, exact
offset check, and diagnostic three-pair timing. It does not replace Milestone
6's formal throughput evidence.

## Reproduce a Large-document Release Review

Use three distinct levels of evidence:

1. Normal CI generates and verifies a 65,537-byte fixture across plain, gzip,
   raw-number, typed, retained, and two-pass paths. This is a correctness smoke,
   not a performance result.
2. The scheduled `Large-document reports` workflow runs a 256 MiB typed fixture
   on Linux x86-64, Linux ARM64, and macOS ARM64 and retains its manifest, JSON
   receipts, and platform metadata. These moving shared runners are report-only:
   never gate a release or compare runs from different hosts as if they were
   paired samples.
3. Publishable x86-64 measurements use the complete attested builds, fixture
   sizes, CPU pinning, paired schedules, RSS rules, and commands in the
   [Milestone 6 protocol](milestone-6-protocol.md). The dedicated release host
   must use the stable supported Crystal compiler and run 256 MiB, 1 GiB, and
   greater-than-4-GiB no-retention profiles. Freeze the release-specific
   procedure before measuring, as in the
   [Milestone 7 review](milestone-7-release-review.md).

For a quick local check, build the two tools, verify semantics, then run each
backend in a fresh process. One pair is diagnostic, not an acceptance result:

```console
$ FUSED_JSON_COMMIT=$(git rev-parse HEAD)
$ crystal version
$ crystal build --release --no-debug bench/tic_fixture.cr -o bin/tic-fixture
$ crystal build --release --no-debug bench/tic.cr -o bin/tic-bench
$ bin/tic-fixture --profile many-small --bytes 268435456 --seed 7 \
    --field-order providers-first --output /tmp/tic-256m.json \
    --manifest /tmp/tic-256m.meta.json
$ bin/tic-bench verify --input /tmp/tic-256m.json \
    --manifest /tmp/tic-256m.meta.json >verify.json
$ GC_NPROCS=1 GC_MARKERS=1 bin/tic-bench run \
    --input /tmp/tic-256m.json --manifest /tmp/tic-256m.meta.json \
    --mode fused-typed --commit "$FUSED_JSON_COMMIT" >fused.json
$ GC_NPROCS=1 GC_MARKERS=1 bin/tic-bench run \
    --input /tmp/tic-256m.json --manifest /tmp/tic-256m.meta.json \
    --mode crystal-typed --commit "$FUSED_JSON_COMMIT" >crystal.json
```

Record the clean commit, exact compiler/LLVM and target, fixture manifest,
commands, environment, process order, every receipt, and GNU-time RSS output.
Alternate backend order across fresh pairs. Do not discard a slow sample after
seeing its result or infer a new gate result from this quick recipe.

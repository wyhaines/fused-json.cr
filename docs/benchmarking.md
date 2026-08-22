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
```

For in-process microbenchmarks, use a quiet host, pin one CPU, allow at least
one second of warmup, and take multiple sustained samples in independent
processes. Alternate comparison order by setting
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

# Reference Benchmark Results

These measurements are a directional reference for the first public release,
not a throughput guarantee. They were collected on 2026-08-21 from commit
`9f614df0bb18b7db22ea70714a0f6d025678a86d` with Crystal 1.22.0-dev
`[2e13e6a73]`, LLVM 21.1.8, target `x86_64-pc-linux-gnu`, and an AMD Ryzen 9
7940HS pinned to CPU 4. Every executable used `--release --no-debug`.

The benchmark commit belongs to the former development repository and is not
part of this repository's history. It also predates the rename from `OjCrystal`
to FusedJSON. The tables use the current name; the historical output used
`OjCrystal`. The commands below preserve its `OJ_CRYSTAL_*` environment names;
current checkouts use the equivalent `FUSED_JSON_*` names.

The corpus root was
`/media/wyhaines/home/wyhaines/ghq/github.com/ohler55/oj/test/data` at Oj commit
`cf84edb13d3ad170afc1e1a6ec0249cf9227e03c`.
Each process used one second of warmup, two seconds of measurement, and 20
allocation operations. Pull and typed results are medians of five independent
processes ordered normal/reverse/normal/reverse/normal; streaming results use
three processes ordered normal/reverse/normal. Values in parentheses are the
median within-process RSD. The highest individual RSD was 28.00% for pull,
16.93% for typed, and 20.29% for streaming, so small differences should not be
generalized. Allocation figures are managed bytes from `Benchmark.memory`, not
peak RSS.

Reproduce one sample after building the programs as shown in
[Benchmarking](benchmarking.md):

```console
$ OJ_CRYSTAL_BENCH_WARMUP=1 OJ_CRYSTAL_BENCH_TIME=2 OJ_CRYSTAL_BENCH_ALLOCATIONS=20 OJ_CRYSTAL_BENCH_REVERSE=0 taskset -c 4 bin/pull-bench /path/to/oj/test/data/{activitypub,canada,citm_catalog,ohai,twitter}.json
$ OJ_CRYSTAL_BENCH_WARMUP=1 OJ_CRYSTAL_BENCH_TIME=2 OJ_CRYSTAL_BENCH_ALLOCATIONS=20 OJ_CRYSTAL_BENCH_REVERSE=0 taskset -c 4 bin/typed-bench /path/to/oj/test/data/twitter.json
$ OJ_CRYSTAL_BENCH_WARMUP=1 OJ_CRYSTAL_BENCH_TIME=2 OJ_CRYSTAL_BENCH_ALLOCATIONS=20 OJ_CRYSTAL_BENCH_REVERSE=0 taskset -c 4 bin/stream-bench /path/to/oj/test/data/{activitypub,canada,citm_catalog,ohai,twitter}.json
```

Change `OJ_CRYSTAL_BENCH_REVERSE` to `1` on alternating samples.

## Pull Parsing

Throughput is median MiB/s with median RSD. `tree/load` is the median paired
ratio printed by each process.

| Corpus (bytes) | `load` | Pull to `JSON::Any` | `tree/load` | Event drain | Root skip |
| --- | ---: | ---: | ---: | ---: | ---: |
| ActivityPub (58,160) | 333.11 (1.65%) | 194.43 (1.95%) | 0.579x | 417.38 (2.77%) | 1,596.16 (1.96%) |
| Canada (2,251,051) | 263.82 (3.95%) | 230.35 (6.06%) | 0.871x | 408.06 (10.84%) | 422.76 (10.10%) |
| CITM (1,727,204) | 384.38 (5.05%) | 227.36 (4.35%) | 0.575x | 696.94 (3.91%) | 940.46 (2.78%) |
| Ohai (32,444) | 400.27 (12.39%) | 232.41 (2.53%) | 0.532x | 554.38 (1.42%) | 1,021.57 (2.30%) |
| Twitter (631,514) | 425.55 (2.55%) | 226.20 (1.90%) | 0.537x | 555.38 (1.90%) | 1,028.20 (2.02%) |

Managed allocation medians:

| Corpus | `load` B/op | Pull tree B/op | Event drain B/op | Root skip B/op |
| --- | ---: | ---: | ---: | ---: |
| ActivityPub | 222,506 | 222,645 | 128,101 | 852 |
| Canada | 8,962,249 | 8,962,649 | 1,025 | 380 |
| CITM | 4,252,881 | 4,253,481 | 866,350 | 494 |
| Ohai | 127,570 | 128,112 | 50,923 | 572 |
| Twitter | 2,385,485 | 2,386,669 | 858,822 | 501 |

## Typed Decoding

The typed benchmark decodes the 631,514-byte Twitter corpus. Ratios are paired
per process; allocation ratios use Crystal's typed decoder as the baseline.

| Implementation | Median MiB/s (RSD) | Speed/stdlib | Managed B/op | Bytes/stdlib |
| --- | ---: | ---: | ---: | ---: |
| `JSON T.from_json` | 329.41 (1.35%) | 1.000x | 287,872 | 1.000x |
| FusedJSON typed | 370.56 (1.34%) | 1.129x | 382,269 | 1.328x |
| FusedJSON cached | 398.40 (5.15%) | 1.209x | 134,847 | 0.468x |

For dynamic-tree context, median allocation was 1,889,928 B/op for
`JSON.parse` and 2,386,179 B/op for `FusedJSON.load`. Default and cached typed
decoding used median paired ratios of 0.202x and 0.071x the `JSON.parse`
allocation.

## Streaming Pull Parsing

Streaming used 4,096-byte reads and a 32,768-byte parser buffer. Throughput is
median MiB/s with median RSD; each ratio is the median paired
streaming/in-memory value.

| Corpus | Drain memory | Drain stream | Ratio | Skip memory | Skip stream | Ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ActivityPub | 303.04 (4.20%) | 227.49 (11.08%) | 0.748x | 1,507.14 (12.57%) | 590.02 (8.73%) | 0.405x |
| Canada | 428.41 (5.41%) | 258.92 (11.10%) | 0.602x | 442.92 (2.05%) | 256.85 (3.58%) | 0.580x |
| CITM | 619.78 (8.94%) | 368.43 (5.53%) | 0.618x | 789.13 (15.10%) | 482.67 (10.37%) | 0.598x |
| Ohai | 459.60 (5.21%) | 297.94 (2.10%) | 0.653x | 921.78 (9.16%) | 476.85 (10.29%) | 0.517x |
| Twitter | 419.71 (3.58%) | 281.56 (9.10%) | 0.681x | 1,023.06 (1.87%) | 498.74 (11.47%) | 0.487x |

First-event latency includes constructing the streaming input and filling its
first buffer. Streaming read 4,096 bytes in every sample.

| Corpus | Memory microseconds (RSD) | Stream microseconds (RSD) | Stream/memory latency |
| --- | ---: | ---: | ---: |
| ActivityPub | 0.27 (3.65%) | 14.19 (3.67%) | 53.667x |
| Canada | 0.16 (10.11%) | 10.39 (7.55%) | 63.736x |
| CITM | 0.17 (3.96%) | 6.16 (5.63%) | 34.950x |
| Ohai | 0.14 (10.76%) | 2.68 (3.66%) | 20.271x |
| Twitter | 0.18 (8.66%) | 16.57 (10.40%) | 86.038x |

Managed allocation medians are shown as in-memory/streaming B/op. Parentheses
contain the median paired streaming/in-memory ratio.

| Corpus | First event | Event drain | Root skip |
| --- | ---: | ---: | ---: |
| ActivityPub | 259 / 33,713 (130.166x) | 132,278 / 133,513 (1.009x) | 874 / 37,242 (42.795x) |
| Canada | 330 / 33,726 (102.200x) | 966 / 34,306 (35.463x) | 631 / 34,148 (54.027x) |
| CITM | 517 / 33,658 (65.103x) | 866,619 / 899,677 (1.038x) | 715 / 34,086 (47.438x) |
| Ohai | 355 / 33,639 (94.842x) | 50,965 / 84,352 (1.655x) | 460 / 34,188 (74.322x) |
| Twitter | 290 / 33,640 (116.000x) | 862,338 / 832,822 (0.966x) | 557 / 34,792 (62.190x) |

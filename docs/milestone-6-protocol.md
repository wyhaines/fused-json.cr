# Milestone 6 validation protocol

Status: completed and accepted at
`b7a54566de0faabc492cae37df92ea0028cdc151`. The
[Milestone 6 results](milestone-6-benchmark-results.md) record both accepted
campaigns and all unsuccessful attempts. The remainder of this document is the
immutable `busy-pinned-v2` protocol frozen before any formal timed observation.
The original quiet-host policy was superseded before timing because persistent
shared GUI work could not satisfy its admission gate. Any later change to a
gate, fixture, schedule, validity rule, build, or runner starts a new complete
campaign. A failed or invalid campaign is retained in full; individual
observations are never rerun selectively.

## Build and host

Build `bench/tic_fixture.cr`, `bench/tic.cr`, and `bench/parse.cr` once with
the current Crystal compiler using `--release --no-debug`.
`scripts/m6_build_attestation.mjs` refuses a dirty checkout and records the
commit and tree, compiler and LLVM versions, build commands, source
entrypoints, and SHA-256 of each binary. Both acceptance campaigns use those
exact artifacts on the same host. The campaign, dynamic, and compatibility
receipts separately bind their runners and runtime tools by SHA-256.

Pin the campaign runner to CPU 0 and every measured child to CPU 3. CPU 2 is
CPU 3's SMT sibling; persistent background work on it is permitted only within
the frozen bounds below. Children receive `GC_NPROCS=1`,
`GC_MARKERS=1`, `CRYSTAL_WORKERS=1`, and `OMP_NUM_THREADS=1`; leave all
other recorded GC and allocator variables unset. Use a 32 KiB benchmark buffer
and nesting limit 512. FusedJSON uses that parser buffer; Crystal uses the same
`File` buffer while retaining its internal lexer buffer. Receipts bind Node,
GNU `time`, and `taskset` identities. The untimed semantic preflight runs
outside environmental admission and is shared unchanged by both campaigns.

Before the first observation, require 60 continuous seconds of two-second
samples with one- and five-minute load averages at most 5.0, Tctl at most 94 C,
CPU 2 at most 25% busy, and CPU 3 at most 10% busy. Tctl may span no more than
5 C across that window. Before every later block, require six continuous
seconds under the same limits, waiting at most 180 seconds. A throughput block
has one gate before its page-cache warm and a second gate after that warm and
before its first parser child. Both the admitted sample and the runner's
evaluation of that sample must occur within the 180-second deadline.

Invalidate the complete campaign if any of these occurs:

- Tctl reaches 100 C;
- one-minute load exceeds 7.0 twice consecutively;
- CPU 2 exceeds 35% busy twice consecutively;
- an environment read fails or monitoring has a gap over five seconds; or
- a measured parser child receives less than 99% task CPU according to GNU
  `time`.

Immediately before and after every child, record Tctl and the raw CPU 2
`/proc/stat` counters. Recompute CPU 2 busy time across the exact child window
and invalidate the campaign when it exceeds 25%. A boundary Tctl at or above
100 C also invalidates immediately. These synchronous boundaries add thermal
endpoint evidence and exact-interval sibling-CPU accounting. They cannot rule
out a Tctl excursion between recorded samples.

CPU 3 frequency is diagnostic only. It is not an admission, exclusion,
normalization, or adjustment rule. Warp and other shared-host activity are
tolerated only when the frozen rules remain satisfied. Results from this
protocol are comparative measurements under a hot, shared host. They are not
quiet-host or peak parser throughput.

### Policy revision rationale

No formal timed observation was made under the superseded policy. A controlled
30-second pre-observation baseline found load1 3.54-3.83, load5 4.00-4.05,
Tctl 88.6-92.5 C, CPU 2 averaging 16.46% busy, and CPU 3 averaging 3.84% busy.
A separate 20-second CPU 2 sample averaged 21.8% and peaked at 23.71%. A
non-measurement pilot that moved the parser to CPU 2 was rejected: background
work migrated to CPU 3, which averaged 16.44% busy. The v2 gates bound the
observed shared workload and add exact child-window sibling accounting rather
than claiming isolation. The earlier semantic preflight remains preserved as
superseded evidence; the clean v2 commit requires a new build attestation,
binaries, and preflight before timing.

## Generated inputs

Generate exact plain sizes with seed 7 and verify every manifest, whole-file
SHA-256, structural digest, typed digest, and raw-number digest before timing.
Generate reproducible gzip only for the 256 MiB many-small input.

| Name | Profile and order | Exact bytes | Use |
| --- | --- | ---: | --- |
| `many-small-64m` | many-small, providers first | 67,108,864 | retained-output RSS |
| `many-small-256m` | many-small, providers first | 268,435,456 | throughput and baseline RSS |
| `wide-item-256m` | wide-item, rates first | 268,435,456 | throughput and wide-item RSS |
| `many-small-1g` | many-small, providers first | 1,073,741,824 | baseline RSS |
| `many-small-4g-plus` | many-small, providers first | 4,362,076,160 | greater-than-4-GiB RSS |

Fixture files are local inputs, not repository artifacts. Receipts retain
their manifests, paths, sizes, hashes, inode metadata, and verification
results. A changed input identity invalidates the campaign.

## Paired throughput gate

Use `fused-typed` and `crystal-typed` on the plain 256 MiB inputs. Before each
pair, run `plain-drain` to warm that profile's page-cache pages. Predeclare 20
pairs for each profile and interleave profiles. Each profile has ten AB and ten
BA pairs; every side is a fresh process wrapped by GNU `/usr/bin/time -v`.
One child result is one observation.

For each pair, calculate
`log(Fused decompressed MiB/s / Crystal decompressed MiB/s)`. Report the
geometric mean ratio and a one-sided 95% paired-bootstrap lower bound from
10,000 resamples with seed `20260824`. Each profile passes only when:

- the geometric mean is at least 1.05; and
- the bootstrap lower bound is strictly greater than 1.0.

First-price latency, process RSS, task CPU, and managed allocations are
reported from these children but do not alter the throughput gate.

## Bounded RSS gate

Run plain `fused-typed` with no retained values, a constant-size count and
digest sink, `cache_keys: false`, duplicate rejection disabled, and the same
parser, GC, and host settings. Each campaign includes five fresh 256 MiB runs
and five fresh 1 GiB runs. Let `baseline_max` be the maximum RSS across those
ten processes, in KiB. Before any larger run, calculate and freeze:

```text
ceiling_kib = baseline_max + max(16384, ceil(baseline_max * 0.25))
```

All three fresh `many-small-4g-plus` runs must remain strictly below that ceiling.
The runner may calculate this formula after the ten prescheduled baselines;
there is no discretionary ceiling selection.

The following report-only RSS series remain separate from the bounded gate:

- two plain-drain observations, one for each 256 MiB profile;
- three `wide-item-256m` `fused-typed` observations;
- three `gzip-drain` observations;
- six balanced pairs of `fused-gzip-typed` and `crystal-gzip-typed`;
- six balanced pairs of plain FusedJSON and Crystal two-pass typed parsing; and
- four balanced pairs of FusedJSON and Crystal retained-output parsing on
  `many-small-64m`.

Retained modes keep every selected provider record, provider ID, and price
record reachable through receipt emission under policy
`all-selected-typed-values-v1`. No process peaks are subtracted.

## Additional gates and compatibility

Run `crystal run --release --no-debug scripts/check_large_offset.cr` at the
measured commit and retain its exact post-`2^32` result. Recheck dynamic parsing
on the five canonical Oj corpora with five fresh alternating-order processes,
one second of warmup, two seconds of measurement, and 20 allocation operations.
Apply the same `busy-pinned-v2` admission, block-start, global invalidation,
child-window CPU 2, boundary Tctl, and task CPU rules used by the TiC campaigns.
The geometric mean of the five per-corpus median FusedJSON/Crystal ratios must
be at least 1.5; no corpus may have a median ratio below 0.98.

When `FUSED_JSON_TIC_CORPUS` names Sunlight's local `data/raw/payer-cache`,
freeze the sorted in-network file list and an Oj-derived, versioned per-file
count and semantic digest receipt before running FusedJSON. Index files are
`excluded_index`; allowed-amount files are `unsupported_allowed_amount` and do
not count as empty in-network files. The FusedJSON compatibility pass must
match every accepted file and the corpus digest. The corpus remains local and
is never copied into this repository or required by CI. Each accepted top-level
item has a 64 MiB retained-state cap by default; `item_too_large` and
`unparseable` are compared as explicit per-file outcomes.

## Formal execution

Run the harness self-audits before building:

```console
$ for tool in scripts/m6_build_attestation.mjs scripts/tic_campaign.mjs scripts/tic_campaign_audit.mjs scripts/dynamic_gate.mjs; do node --check "$tool" && node "$tool" --self-audit >/dev/null; done
```

From a clean checkout, create one external artifact directory and build the
three attested programs:

```console
$ M6_ROOT=/tmp/fused-json-m6-formal-v2
$ M6_COMMIT=$(git rev-parse HEAD)
$ CRYSTAL_BIN=$(command -v crystal)
$ mkdir -p "$M6_ROOT/bin" "$M6_ROOT/fixtures" "$M6_ROOT/receipts"
$ "$CRYSTAL_BIN" build --release --no-debug bench/tic_fixture.cr -o "$M6_ROOT/bin/tic-fixture"
$ "$CRYSTAL_BIN" build --release --no-debug bench/tic.cr -o "$M6_ROOT/bin/tic-bench"
$ "$CRYSTAL_BIN" build --release --no-debug bench/parse.cr -o "$M6_ROOT/bin/parse-bench"
$ node scripts/m6_build_attestation.mjs \
    --repo="$PWD" --crystal="$CRYSTAL_BIN" \
    --tic-fixture="$M6_ROOT/bin/tic-fixture" \
    --tic-bench="$M6_ROOT/bin/tic-bench" \
    --parse-bench="$M6_ROOT/bin/parse-bench" \
    --tic-fixture-command="$CRYSTAL_BIN build --release --no-debug bench/tic_fixture.cr -o $M6_ROOT/bin/tic-fixture" \
    --tic-bench-command="$CRYSTAL_BIN build --release --no-debug bench/tic.cr -o $M6_ROOT/bin/tic-bench" \
    --parse-bench-command="$CRYSTAL_BIN build --release --no-debug bench/parse.cr -o $M6_ROOT/bin/parse-bench" \
    --output="$M6_ROOT/receipts/build-attestation.json"
```

Generate the frozen fixture names and sizes. Only the 256 MiB many-small input
has a gzip companion:

```console
$ "$M6_ROOT/bin/tic-fixture" --profile=many-small --bytes=67108864 --seed=7 --field-order=providers-first --output="$M6_ROOT/fixtures/many-small-64m.json" --manifest="$M6_ROOT/fixtures/many-small-64m.meta.json"
$ "$M6_ROOT/bin/tic-fixture" --profile=many-small --bytes=268435456 --seed=7 --field-order=providers-first --output="$M6_ROOT/fixtures/many-small-256m.json" --gzip-output="$M6_ROOT/fixtures/many-small-256m.json.gz" --manifest="$M6_ROOT/fixtures/many-small-256m.meta.json"
$ "$M6_ROOT/bin/tic-fixture" --profile=wide-item --bytes=268435456 --seed=7 --field-order=rates-first --output="$M6_ROOT/fixtures/wide-item-256m.json" --manifest="$M6_ROOT/fixtures/wide-item-256m.meta.json"
$ "$M6_ROOT/bin/tic-fixture" --profile=many-small --bytes=1073741824 --seed=7 --field-order=providers-first --output="$M6_ROOT/fixtures/many-small-1g.json" --manifest="$M6_ROOT/fixtures/many-small-1g.meta.json"
$ "$M6_ROOT/bin/tic-fixture" --profile=many-small --bytes=4362076160 --seed=7 --field-order=providers-first --output="$M6_ROOT/fixtures/many-small-4g-plus.json" --manifest="$M6_ROOT/fixtures/many-small-4g-plus.meta.json"
```

Run the shared semantic preflight, both complete CPU-pinned campaigns, and the
independent cross-campaign auditor. Output paths must not already exist.

```console
$ node scripts/tic_campaign.mjs --preflight-output="$M6_ROOT/receipts/preflight.json" --binary="$M6_ROOT/bin/tic-bench" --fixture-dir="$M6_ROOT/fixtures" --commit="$M6_COMMIT"
$ taskset -c 0 node scripts/tic_campaign.mjs --campaign-id=1 --output="$M6_ROOT/receipts/campaign-1.json" --preflight="$M6_ROOT/receipts/preflight.json" --binary="$M6_ROOT/bin/tic-bench" --fixture-dir="$M6_ROOT/fixtures" --commit="$M6_COMMIT"
$ taskset -c 0 node scripts/tic_campaign.mjs --campaign-id=2 --output="$M6_ROOT/receipts/campaign-2.json" --preflight="$M6_ROOT/receipts/preflight.json" --binary="$M6_ROOT/bin/tic-bench" --fixture-dir="$M6_ROOT/fixtures" --commit="$M6_COMMIT"
$ node scripts/tic_campaign_audit.mjs --campaign-1="$M6_ROOT/receipts/campaign-1.json" --campaign-2="$M6_ROOT/receipts/campaign-2.json" --build-attestation="$M6_ROOT/receipts/build-attestation.json" --output="$M6_ROOT/receipts/campaign-acceptance.json"
```

Then run the independent dynamic and large-offset gates:

```console
$ taskset -c 0 node scripts/dynamic_gate.mjs --output="$M6_ROOT/receipts/dynamic-gate.json" --binary="$M6_ROOT/bin/parse-bench" --corpus-dir=/path/to/oj/test/data --commit="$M6_COMMIT"
$ "$CRYSTAL_BIN" run --release --no-debug scripts/check_large_offset.cr > "$M6_ROOT/receipts/large-offset.txt"
```

When the Sunlight checkout and local corpus are available, build the scanner
and freeze the Oj result before invoking FusedJSON. Use Sunlight's bundle so
the exact Oj dependency is recorded:

```console
$ "$CRYSTAL_BIN" build --release --no-debug bench/sunlight_compat_scan.cr -o "$M6_ROOT/bin/sunlight-compat-scan"
$ SUNLIGHT_ROOT=/path/to/sunlight FUSED_JSON_TIC_CORPUS=/path/to/sunlight/data/raw/payer-cache BUNDLE_GEMFILE=/path/to/sunlight/Gemfile bundle exec ruby scripts/sunlight_compat.rb oracle --output="$M6_ROOT/receipts/sunlight-oj.json"
$ SUNLIGHT_ROOT=/path/to/sunlight FUSED_JSON_TIC_CORPUS=/path/to/sunlight/data/raw/payer-cache BUNDLE_GEMFILE=/path/to/sunlight/Gemfile bundle exec ruby scripts/sunlight_compat.rb fused --scanner="$M6_ROOT/bin/sunlight-compat-scan" --oracle-receipt="$M6_ROOT/receipts/sunlight-oj.json" --output="$M6_ROOT/receipts/sunlight-fused.json"
$ SUNLIGHT_ROOT=/path/to/sunlight BUNDLE_GEMFILE=/path/to/sunlight/Gemfile bundle exec ruby scripts/sunlight_compat.rb compare "$M6_ROOT/receipts/sunlight-oj.json" "$M6_ROOT/receipts/sunlight-fused.json" > "$M6_ROOT/receipts/sunlight-compare.json"
```

## Required evidence

The campaign runner writes a generation-zero partial, append-only journals, and
a composite final receipt. Preserve the frozen schedule, every child receipt,
complete GNU-time stderr, environment samples, admission and validity state,
bootstrap inputs and result, RSS ceiling calculation, diagnostics, identities,
and final pass/fail state. Each campaign contains exactly 173 observations in
77 logical blocks and 117 block-admission gate events; throughput blocks have
separate pre-warm and post-warm gates. The shared preflight contains five
verifications.

Run campaign IDs 1 and 2 completely with identical artifacts. The paired
campaign is accepted only when both receipts are valid and pass both gates and
`campaign-acceptance.json` reports a valid cross-audit. Milestone 6 closeout
also requires a valid, passing dynamic receipt, the exact post-`2^32` result,
and a matching Sunlight receipt when that local corpus is available. Preserve
every failed, invalid, or interrupted receipt; do not select successful
observations from different campaigns.

## Closeout record

Campaign 1 attempt 3 and campaign 2 attempt 2 completed all 173 observations
and passed independently. The cross-campaign audit, five-process dynamic gate,
post-`2^32` offset check, and local Sunlight comparison also passed. The
[results report](milestone-6-benchmark-results.md) gives the accepted estimates
and dispositions of every earlier attempt.

The durable [artifact manifest](benchmark-data/milestone-6/artifact-manifest.json)
describes the archive and its attempt dispositions.
[`SHA256SUMS`](benchmark-data/milestone-6/SHA256SUMS) indexes and verifies every
preserved final receipt, partial, event journal, and environment journal.
Compiled binaries, generated fixture payloads, and the local Sunlight corpus
are omitted because they are large or local inputs; their commands and
cryptographic identities remain bound by the receipts.

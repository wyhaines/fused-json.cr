# Milestone 6 Benchmark Results

Milestone 6 is accepted at
`b7a54566de0faabc492cae37df92ea0028cdc151`. Both complete campaigns passed
the typed-throughput and bounded-RSS gates. The independent campaign audit,
dynamic-parser gate, exact post-`2^32` offset check, and Sunlight compatibility
comparison also passed.

## Scope and interpretation

These are paired comparative measurements under the frozen `busy-pinned-v2`
controls on a hot, shared Ryzen 9 7940HS host. Persistent background work was
permitted only within the recorded gates. The ratios support within-block
FusedJSON-versus-Crystal comparisons; the absolute MiB/s values are neither
quiet-host nor peak-throughput estimates and should not be generalized beyond
this compiler, host, fixtures, and parser configuration.

The attested programs were built once with Crystal 1.22.0-dev `[6c6a5e988]`,
LLVM 21.1.8, and target `x86_64-pc-linux-gnu`. The runner used CPU 0, measured
children used CPU 3, and CPU 2 was monitored as CPU 3's SMT sibling. Parser
buffers were 32 KiB, typed results were discarded unless a diagnostic
explicitly retained them, and each measured parser child received one GC
worker. FusedJSON key caching and duplicate-key rejection were disabled;
Crystal's standard key pool remained enabled.

## Typed throughput gate

Each profile contributed 20 predetermined pairs per campaign: ten Fused-first
and ten Crystal-first. Every side was a fresh process reading a page-cache-warm
256 MiB plain file. Ratios greater than one favor FusedJSON. Acceptance
required a geometric mean of at least 1.05 and a one-sided 95% paired-bootstrap
lower bound greater than 1.0. The bootstrap used 10,000 resamples and fixed seed
`20260824`.

| Campaign | Profile | Fused MiB/s | Crystal MiB/s | Median ratio | Geometric mean | 95% lower | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | many-small | 204.485 | 79.084 | 2.583x | 2.592x | 2.561x | pass |
| 1 | wide-item | 158.077 | 74.202 | 2.134x | 2.127x | 2.109x | pass |
| 2 | many-small | 206.192 | 80.001 | 2.600x | 2.568x | 2.526x | pass |
| 2 | wide-item | 157.447 | 74.076 | 2.118x | 2.130x | 2.115x | pass |

The MiB/s columns are separate medians of 20 fresh children; the ratio columns
come from paired observations. Cumulative managed allocation was materially
higher for FusedJSON even though live process RSS stayed flat:

| Campaign | Profile | Fused allocation | Crystal allocation | Ratio |
| --- | --- | ---: | ---: | ---: |
| 1 | many-small | 1,407 MiB | 280 MiB | 5.03x |
| 1 | wide-item | 1,906 MiB | 370 MiB | 5.15x |
| 2 | many-small | 1,407 MiB | 280 MiB | 5.03x |
| 2 | wide-item | 1,906 MiB | 370 MiB | 5.15x |

These are median managed bytes allocated while parsing one 256 MiB document,
not retained heap. Allocation was report-only in this milestone, but reducing
that churn remains material optimization work.

The cross-campaign auditor independently replayed the schedules, artifact and
fixture identities, environmental rules, child chronology, task-CPU checks,
statistics, and RSS calculations. All checks passed. Its combined AB/BA order
contrasts were 0.999 for many-small and 0.989 for wide-item; these are
diagnostics, not acceptance adjustments.

## Bounded process RSS

Each campaign ran five fresh 256 MiB and five fresh 1 GiB many-small baselines.
The frozen ceiling was the maximum baseline plus 16 MiB, which was larger than
the alternative 25% headroom. All three fresh 4.0625 GiB runs then had to
remain strictly below that ceiling.

| Campaign | Baseline maximum | Frozen ceiling | 4.0625 GiB peaks | Result |
| --- | ---: | ---: | --- | --- |
| 1 | 8,924 KiB | 25,308 KiB | 8,860; 8,824; 8,820 KiB | pass |
| 2 | 8,960 KiB | 25,344 KiB | 8,872; 8,900; 8,796 KiB | pass |

These are end-to-end GNU `time` process peaks, not estimates of parser-only
memory. Page-cache pages are not process RSS. The stable no-retention series
supports the documented bounded-memory contract; it does not apply when a
caller retains decoded values.

## Report-only diagnostics

These modes had no acceptance threshold and were never subtracted from parser
time or memory.

| Diagnostic | Campaign 1 | Campaign 2 |
| --- | ---: | ---: |
| gzip typed FusedJSON/Crystal geometric mean | 2.180x | 2.183x |
| plain two-pass FusedJSON/Crystal geometric mean | 3.170x | 3.184x |
| retained-output FusedJSON/Crystal geometric mean | 1.754x | 1.754x |
| maximum wide-item FusedJSON RSS | 8,868 KiB | 8,920 KiB |
| maximum gzip-drain RSS | 8,656 KiB | 8,472 KiB |

The retained-output profile deliberately kept all selected values reachable.
Its FusedJSON peaks were about 84-85 MiB, versus about 57-59 MiB for Crystal,
showing why caller retention must be considered separately from streaming
parser memory.

## Additional acceptance gates

- The shared semantic preflight verified all five generated fixtures and their
  manifests, whole-file hashes, structural digests, typed digests, and raw
  number digests.
- The exact large-offset check passed at byte offset `4294967333`, after
  `4294967337` bytes and 257 reads.
- Five fresh dynamic-parser processes, each using one second of warmup, two
  seconds of measurement, and 20 allocation operations, passed every canonical
  corpus floor. The median FusedJSON/Crystal ratios were 2.193x for
  ActivityPub, 1.781x for Canada, 1.903x for CITM, 1.972x for Ohai, and 1.672x
  for Twitter. Their geometric mean was 1.896x, above the 1.5 gate.
- The Sunlight comparison accepted 65 local TiC files, explicitly excluded one
  index, and matched 5,654 provider references and 4,318,578 prices. Oj and
  FusedJSON produced the same corpus digest,
  `81267911499a62264cc39a425899f356c0f7f79f9d605f3263454080a020f8c2`.
  This local corpus did not exercise allowed-amount, `item_too_large`, or
  unparseable outcomes.

Across the accepted campaigns, monitored load1 never exceeded 3.98. The
maximum sampled Tctl was 98.5 C in campaign 1 and 99.625 C in campaign 2; exact
child-boundary maxima were 98.75 C and 99.875 C. Every measured parser child
met the inclusive 99% task-CPU requirement, and every exact sibling-CPU child
window remained at or below 25%. The inclusive sibling limit was reached six
times in campaign 1 and twice in campaign 2. Campaign 2's boundary maximum was
0.125 C below thermal invalidation; it never reached the 100 C boundary. These
are two-second monitor samples and child endpoint readings, not a continuous
thermal trace, so they cannot rule out an excursion between recorded samples.

## Complete attempt record

No invalid, interrupted, or valid-but-failing observation contributes to an
accepted estimate. The two accepted campaigns are complete and analyzed
independently; observations were not selected or pooled across attempts.

The original quiet-host policy was superseded before formal timing because the
persistent GUI workload could not satisfy its admission gate. The frozen v2
protocol records the pre-observation rationale. Formal v2 attempts were:

| Receipt | Disposition | Observations | Reason |
| --- | --- | ---: | --- |
| `campaign-1.json` | invalid | 0 | Tctl reached 100 C during initial admission |
| `campaign-1-run-2.json` | invalid | 0 | load1 exceeded 7 twice during initial admission |
| `campaign-1-run-3.json` | accepted | 173/173 | complete and passed |
| `campaign-2.json` | invalid | 34/173 | sibling CPU reached 40% during a page-cache warm window |
| `campaign-2-run-2.json` | accepted | 173/173 | complete and passed |
| `dynamic-gate.json` | accepted | 5/5 processes | complete and passed without retry |

The invalid campaign-2 warm command reported 25.952 ms of benchmark wall time;
the exact sibling-CPU boundary window was 36.288 ms and contained two busy
ticks out of five, or 40%. Scheduler tick granularity can dominate such a short
interval, but the frozen rule nevertheless invalidated the whole attempt. It
was not a measured parser child, and none of the attempt's observations were
reused.

Accepted receipt identities:

- [campaign 1](benchmark-data/milestone-6/formal-v2-b7a5456/receipts/campaign-1-run-3.json):
  `9e6d5bf2738d10b46db883a4c0a3b652516cd3c0286e9e2d6cc055b2cc5e5fa6`
- [campaign 2](benchmark-data/milestone-6/formal-v2-b7a5456/receipts/campaign-2-run-2.json):
  `206c2566ab595f9d33306b131b4ea0ae4f492f10f000bed67987791a05a22eff`
- [cross-campaign audit](benchmark-data/milestone-6/formal-v2-b7a5456/receipts/campaign-acceptance.json):
  `e72a3b29f143ff990236c475381e440ba871b213706f87736ddfe958229a6785`
- [dynamic gate](benchmark-data/milestone-6/formal-v2-b7a5456/receipts/dynamic-gate.json):
  `6d8c2c96d4a4150f7998b9c407b4b03168d7ff0f6f6aa6a49afcf8b06724fe44`

## Evidence and reproduction

The [artifact manifest](benchmark-data/milestone-6/artifact-manifest.json)
indexes accepted and invalid attempts. The adjacent
[`SHA256SUMS`](benchmark-data/milestone-6/SHA256SUMS) covers every preserved
final receipt, partial, append-only journal, and environment journal. Verify it
from `docs/benchmark-data/milestone-6` with:

```console
$ sha256sum -c SHA256SUMS
```

Compiled binaries, generated fixtures, and the local Sunlight corpus are not
repository artifacts. Their identities and commands remain bound inside the
receipts. The frozen [validation protocol](milestone-6-protocol.md) contains
the complete reproduction procedure and acceptance rules.

Disclosure note: the receipts are unredacted. They contain absolute machine
paths, host and CPU metadata, inode and timestamp data, environment telemetry,
and the 66-name Sunlight file inventory with sizes and hashes. No credential
markers were found, and no corpus payload is present. Review this metadata
before publishing or redistributing the archive.

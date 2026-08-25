# Typed-decoding Optimization Results

The typed-decoding optimization work is validated at
`4ca865c4e8ad8716041df4069181a5523493de08`. Two complete campaigns
passed the frozen Milestone 6 typed-throughput and bounded-RSS gates. The
independent cross-campaign audit, dynamic-parser gate, exact post-`2^32`
offset check, and local Sunlight compatibility comparison also passed.

## Scope and interpretation

The candidate replaces repeated compatibility-adapter initialization with
prototype copies, uses native reads for compatible built-in scalar values,
keeps a cache-only `max_cached_keys` bound off the per-event limits traversal
path, and adds opt-in retained-memory snapshots. Public typed-decoding
semantics and parser limits are unchanged.

The comparison baseline is the accepted Milestone 6 commit
`b7a54566de0faabc492cae37df92ea0028cdc151`. Between that commit and the
optimization's parent, the only runtime-source change was the version constant
from 0.1.0 to 0.2.0.

Candidate campaigns reused the immutable `busy-pinned-v2` controls and exact
fixtures from the [Milestone 6 protocol](milestone-6-protocol.md). The
attested programs used Crystal 1.22.0-dev `[6c6a5e988]`, LLVM 21.1.8, target
`x86_64-pc-linux-gnu`, and the same Ryzen 9 7940HS host. The candidate's
within-block FusedJSON/Crystal ratios and bootstrap bounds are the formal
measurements. Candidate-versus-baseline percentage changes are descriptive:
the two commits were measured in separate campaigns rather than paired within
the same blocks.

## Typed throughput

Each profile contributed 20 predetermined pairs per campaign, balanced between
Fused-first and Crystal-first order. Every side was a fresh process reading a
page-cache-warm 256 MiB file.

| Campaign | Profile | Fused MiB/s | Crystal MiB/s | Median ratio | Geometric mean | 95% lower | Result |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | many-small | 263.967 | 80.741 | 3.287x | 3.286x | 3.260x | pass |
| 1 | wide-item | 199.257 | 73.868 | 2.704x | 2.707x | 2.685x | pass |
| 2 | many-small | 262.854 | 81.000 | 3.254x | 3.230x | 3.167x | pass |
| 2 | wide-item | 199.741 | 74.603 | 2.698x | 2.685x | 2.662x | pass |

The separate commit-level comparison shows the improvement repeated in both
campaigns:

| Campaign | Profile | Baseline Fused MiB/s | Candidate Fused MiB/s | Fused change | Baseline paired geo. mean | Candidate paired geo. mean | Ratio change |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | many-small | 204.485 | 263.967 | +29.09% | 2.592x | 3.286x | +26.80% |
| 1 | wide-item | 158.077 | 199.257 | +26.05% | 2.127x | 2.707x | +27.30% |
| 2 | many-small | 206.192 | 262.854 | +27.48% | 2.568x | 3.230x | +25.80% |
| 2 | wide-item | 157.447 | 199.741 | +26.86% | 2.130x | 2.685x | +26.03% |

The independent auditor replayed the schedules, artifact and fixture
identities, environmental rules, child chronology, CPU checks, statistics, and
RSS calculations. Every audit check passed. Its combined AB/BA order contrasts
were 1.022 for many-small and 0.996 for wide-item; these are diagnostics, not
acceptance adjustments.

## Managed allocation

Cumulative managed allocation while parsing one 256 MiB document fell by
56.85% for many-small and 55.22% for wide-item. Values below are medians and
are not retained heap.

| Campaign | Profile | Baseline Fused MiB | Candidate Fused MiB | Reduction | Candidate Crystal MiB | Candidate Fused/Crystal |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | many-small | 1,407.15 | 607.21 | 56.85% | 279.54 | 2.17x |
| 1 | wide-item | 1,905.83 | 853.37 | 55.22% | 369.82 | 2.31x |
| 2 | many-small | 1,407.15 | 607.21 | 56.85% | 279.54 | 2.17x |
| 2 | wide-item | 1,905.83 | 853.37 | 55.22% | 369.82 | 2.31x |

The remaining gap no longer includes rebuilding unused stdlib parser internals
for every adapter. It still includes shallow-copied adapter objects, decoded
typed values, and keys. The new cursor-cost benchmark separates native scalar
reads, `read(T)`, and `read_array(T)` across String and streaming transports,
with uncached, cached, and bounded-cache record profiles for future
attribution.

## Retained output

The frozen report-only retained series kept all 315,812 selected typed values
from the 64 MiB fixture reachable. Adapter changes reduced cumulative FusedJSON
allocation from 395.41 MiB to 195.43 MiB in both campaigns. External peak RSS
also narrowed materially:

| Campaign | Baseline Fused median peak | Candidate Fused median peak | Reduction | Candidate Crystal median peak | Candidate Fused/Crystal |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 84.957 MiB | 64.879 MiB | 23.63% | 58.695 MiB | 1.105x |
| 2 | 85.023 MiB | 64.592 MiB | 24.03% | 58.480 MiB | 1.105x |

The retained-output paired throughput ratio rose from 1.754x in both baseline
campaigns to 2.689x and 2.702x in the candidate campaigns.

A separate four-pair, balanced-order diagnostic enabled the new internal
snapshots. It is report-only and did not alter the frozen campaign:

| Parser | Managed allocation | Process peak | Current RSS after full GC | GC heap after full GC | Free / unmapped after full GC |
| --- | ---: | ---: | ---: | ---: | ---: |
| FusedJSON | 195.427 MiB | 67.385 MiB | 65.264 MiB | 56.670 MiB | 10.684 / 8.896 MiB |
| Crystal | 113.505 MiB | 58.256 MiB | 56.188 MiB | 47.984 MiB | 7.301 / 5.512 MiB |

The output remained reachable during the forced collection. GC heap, free, and
unmapped counters are allocator diagnostics, not an exact retained-object
size. Snapshot collection occurred after parser timing and could affect the
process peak. The matched diagnostic's paired throughput geometric mean was
2.720x.

## Bounded no-retention RSS

The ordinary streaming typed path remained flat through the 4.0625 GiB input:

| Campaign | Baseline maximum | Frozen ceiling | 4.0625 GiB peaks | Result |
| --- | ---: | ---: | --- | --- |
| 1 | 8,972 KiB | 25,356 KiB | 8,888; 8,936; 8,796 KiB | pass |
| 2 | 8,956 KiB | 25,340 KiB | 8,972; 8,800; 8,804 KiB | pass |

These are end-to-end GNU `time` process peaks. They confirm that the
optimization did not trade reduced allocation for document-size-dependent
retention.

## Additional gates

- The semantic preflight verified all five generated fixtures, whole-file
  hashes, structural digests, typed digests, and raw-number digests.
- The exact large-offset check passed at byte `4294967333`, after
  `4294967337` generated bytes and 257 reads.
- The five-process dynamic-tree gate passed with a 1.905x geometric mean. The
  per-corpus medians were 2.100x for ActivityPub, 1.781x for Canada, 1.957x for
  CITM, 2.024x for Ohai, and 1.695x for Twitter.
- The local Sunlight comparison accepted 65 in-network files, excluded one
  index, and matched 5,654 provider references and 4,318,578 prices. Oj and
  FusedJSON produced the same corpus digest,
  `81267911499a62264cc39a425899f356c0f7f79f9d605f3263454080a020f8c2`.

## Complete attempt record

No observation from an invalid attempt contributes to the accepted estimates,
and observations were not pooled across attempts.

| Receipt | Disposition | Observations | Reason |
| --- | --- | ---: | --- |
| `campaign-1.json` | invalid | 0 | CPU 2 exceeded 35% for two consecutive initial-admission samples |
| `campaign-1-run-2.json` | invalid | 133 | boundary Tctl reached 100 C after `rss-large-2` |
| `campaign-1-run-3.json` | invalid | 0 | CPU 2 exceeded 35% for two consecutive initial-admission samples |
| `campaign-1-run-4.json` | accepted | 173/173 | complete and passed |
| `campaign-2.json` | invalid | 6 | CPU 2 exceeded 35% for two consecutive block-start samples |
| `campaign-2-run-2.json` | invalid | 40 | exact page-warm child window reached 40% CPU 2 busy |
| `campaign-2-run-3.json` | accepted | 173/173 | complete and passed |
| `dynamic-gate.json` | accepted | 5/5 processes | complete and passed |

Accepted receipt identities:

- [campaign 1](benchmark-data/typed-optimization-4ca865c/receipts/campaign-1-run-4.json):
  `57eaa37767177e3617eb32773840e8404fe556bf0c9a358b38c7e1ba9dc33b54`
- [campaign 2](benchmark-data/typed-optimization-4ca865c/receipts/campaign-2-run-3.json):
  `e81ce57abf3267814afc2c4c883d92ece22018166e749957a02b4d2f18e25924`
- [cross-campaign audit](benchmark-data/typed-optimization-4ca865c/receipts/campaign-acceptance.json):
  `6412c4e9f9c62aeb1aa2a4dfe51c7ec01cdd9b6229920f85c1dae3819d7395ca`
- [dynamic gate](benchmark-data/typed-optimization-4ca865c/receipts/dynamic-gate.json):
  `d51afa03efc4f557265c2877d4a5373004b2277da38b44906f16bd0dbbaa84b2`

## Evidence

The [artifact manifest](benchmark-data/typed-optimization-4ca865c/artifact-manifest.json)
indexes all accepted and invalid attempts, generated fixture manifests, and
the separate retained-snapshot diagnostic. The adjacent
[`SHA256SUMS`](benchmark-data/typed-optimization-4ca865c/SHA256SUMS) covers
every preserved artifact. Verify it from
`docs/benchmark-data/typed-optimization-4ca865c` with:

```console
$ sha256sum -c SHA256SUMS
```

Compiled binaries, generated fixture payloads, and external corpora are
omitted. Their commands and cryptographic identities remain bound by the
receipts.

Disclosure note: receipts are unredacted and contain absolute machine paths,
host and CPU metadata, inode and timestamp data, environment telemetry, and
the local Sunlight filename inventory. No credential markers or corpus payloads
are present.

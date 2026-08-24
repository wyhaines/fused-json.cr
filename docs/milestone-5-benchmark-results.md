# Milestone 5 Benchmark Results

Milestone 5 is accepted. The resource-limits implementation passed its
correctness checks and both frozen performance campaigns on 2026-08-24. The
Milestone 4 baseline was `eb7b377ee6b8588d4060405e68b13b9704ffffa5`; the
limits candidate was `ebcc1bd9ce47e71b30c9cbb42e75bdfe12753867`. The paired
API campaign ran from `331a7fc8fd78c6392e5657c5a08ec029a7a0cb03`. Parser
sources did not change between the candidate and that checkout; only benchmark
code and its documented timing protocol changed.

## Method

Both campaigns used optimized Crystal 1.22.0-dev builds on an AMD Ryzen 9
7940HS. The runner was pinned to CPU 0, benchmark children to CPU 3, and sibling
CPU 2 was monitored. Each workload contributed 20 independent process-level
pairs. The eight workloads cover String and IO dynamic parsing, pull traversal,
root skipping, and typed decoding.

The M4 comparison used separate candidate and baseline processes in a balanced
AB/BA schedule. Its throughput gates were 0.98 for the median and geometric
mean and 0.97 for the one-sided 95% paired-bootstrap lower bound. The API
comparison measured `limits:` omitted against `limits: FusedJSON::Limits.new`
in one fresh process with balanced initial order and interleaved ABBA batches.
Its corresponding gates were 0.99, 0.99, and 0.98. Both campaigns limited
candidate median managed allocation to the baseline median plus
`max(4096 B, 0.1%)`.

The accepted M4 campaign reached 92.625 C; the accepted API campaign reached
92.25 C. Every child reported 99% or 100% task CPU, and neither campaign
breached its frozen load, sibling-core, monitor-gap, or environment-read rules.

## Candidate versus Milestone 4

Ratios greater than one favor the Milestone 5 candidate.

| Workload | Median | Geometric mean | 95% lower |
| --- | ---: | ---: | ---: |
| `string-dynamic` | 1.0040x | 1.0000x | 0.9888x |
| `io-dynamic` | 1.0266x | 1.0215x | 1.0111x |
| `string-pull` | 1.0036x | 1.0034x | 1.0005x |
| `string-skip` | 0.9832x | 0.9844x | 0.9813x |
| `io-pull` | 1.0438x | 1.0443x | 1.0393x |
| `io-skip` | 1.0838x | 1.0814x | 1.0756x |
| `string-typed` | 1.0708x | 1.0892x | 1.0736x |
| `io-typed` | 1.0607x | 1.0595x | 1.0521x |

Every throughput and allocation gate passed.

## Explicit-empty limits versus default

Ratios greater than one favor an explicit empty `Limits` value.

| Workload | Median | Geometric mean | 95% lower |
| --- | ---: | ---: | ---: |
| `string-dynamic` | 1.0030x | 1.0057x | 1.0014x |
| `io-dynamic` | 0.9979x | 0.9977x | 0.9946x |
| `string-pull` | 1.0003x | 0.9993x | 0.9973x |
| `string-skip` | 1.0011x | 1.0021x | 1.0003x |
| `io-pull` | 1.0011x | 1.0005x | 0.9986x |
| `io-skip` | 1.0001x | 1.0024x | 0.9995x |
| `string-typed` | 1.0003x | 1.0009x | 0.9992x |
| `io-typed` | 0.9988x | 0.9994x | 0.9985x |

Every throughput and allocation gate passed. The accepted receipt contains all
160 prescheduled children, with ten default-first and ten explicit-empty-first
processes for each workload.

## Complete campaign record

Unsuccessful runs remain part of the record and were not pooled with accepted
campaigns. The earlier `f9aff59`, `4fa0c57`, `b031dab`, and `4167057` receipts
are valid performance failures from earlier implementations. The two
cross-process API campaigns at `ebcc1bd` are also valid failures: the first
failed the `io-typed` bootstrap gate, while the second failed `string-dynamic`
and `io-typed` gates. Their symmetric slow-process modes motivated the
common-process paired protocol.

The first final M4 attempt at `ebcc1bd` was environmentally invalid when Tctl
reached 96.625 C. Paired API v1 was invalid at 97.5 C. Before collecting a new
campaign, the paired measurement window was shortened prospectively from 1.5
to 0.75 seconds per side. The 95 C invalidation ceiling, admission policy,
sample count, acceptance gates, and allocation tolerance were unchanged.

Accepted evidence:

- [M4 comparison receipt](benchmark-data/milestone-5-m4-vs-ebcc1bd.json)
  (`e15fcb009e16a9c5954e6b755f8ff3aef36c8593a28df9f84024ec6402c89d0e`)
- [paired API receipt](benchmark-data/milestone-5-api-paired-331a7fc.json)
  (`4c01de4b6a559bf8019177fba68bd03cce56354b2c8aad0e12073e11033ce740`)
- [M4 campaign runner](benchmark-data/milestone-5-campaign-ebcc1bd.mjs) and
  [paired API runner](benchmark-data/milestone-5-api-paired-campaign-331a7fc.mjs)
- [targeted dynamic](benchmark-data/milestone-5-string-dynamic-ebcc1bd.json)
  and [targeted typed](benchmark-data/milestone-5-string-typed-ebcc1bd.json)
  checks used before the complete campaign

Retained unsuccessful evidence:

- [environmentally invalid M4 attempt](benchmark-data/milestone-5-m4-vs-ebcc1bd-invalid.json)
- [valid API failure 1](benchmark-data/milestone-5-api-ebcc1bd-failed-1.json)
  and [valid API failure 2](benchmark-data/milestone-5-api-ebcc1bd-failed-2.json)
- [environmentally invalid paired API v1](benchmark-data/milestone-5-api-paired-8126166-invalid.json)
  and its [exact runner](benchmark-data/milestone-5-api-paired-campaign-8126166-invalid.mjs)
- the earlier failed receipts and their exact runners in `benchmark-data/`

Each receipt embeds its schedule, commands, binary identities, fixture hashes,
raw observations, environment log, bootstrap seed, final validity state, and,
for valid campaigns, statistical analysis. See the
[benchmarking guide](benchmarking.md) for the frozen protocol and build steps.

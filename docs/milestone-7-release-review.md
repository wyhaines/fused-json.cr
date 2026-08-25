# Milestone 7 Stable Release Review

Status: complete; the stable review passed for candidate
`fbe44913e6ebc8fc19bf627254a56806e50e622e`.

This review supplements, rather than replaces, the accepted
[Milestone 6 campaigns](milestone-6-benchmark-results.md). Milestone 6 supplies
the formal paired performance evidence on Crystal 1.22.0-dev. This review checks
the `0.2.0` candidate on the supported stable Crystal 1.21.0 compiler and repeats
the large-document RSS boundary. Its one-shot timing is diagnostic and must not
be presented as a new statistical acceptance campaign.

## Frozen inputs and build

- Measure the clean commit containing this protocol. Record its full SHA in
  every receipt.
- Use official bundled Crystal 1.21.0 `[57cf7da50]`, LLVM 20.1.8. Verify the
  Linux x86-64 archive SHA-256 as
  `cc407bd071915cc7b5d9348281e669a911d20a1f4b9fac52a62088660eb22208`.
- Build `bench/tic_fixture.cr`, `bench/tic.cr`, and `bench/parse.cr` with
  `--release --no-debug`; retain a build attestation.
- Reuse the immutable generated fixtures from the accepted Milestone 6 run:
  many-small at 256 MiB, 1 GiB, and 4,362,076,160 bytes, plus wide-item at
  256 MiB. Retain their manifests and cryptographic identities, not payloads.
- Pin children to CPU 3 with `GC_NPROCS=1`, `GC_MARKERS=1`,
  `CRYSTAL_WORKERS=1`, and `OMP_NUM_THREADS=1`. Record host/load/temperature
  context, but do not exclude an observation after seeing its timing.

## Correctness and diagnostic throughput

Run the complete spec suite in the default, portable-float, scalar-string, and
combined fallback configurations. Run the release metadata check,
documentation examples, API docs, Ameba, workflow lint, and all harness
self-audits.

Strongly verify the many-small and wide-item 256 MiB fixtures before timing.
For each profile, run three fresh typed pairs in this fixed order:

1. FusedJSON, Crystal
2. Crystal, FusedJSON
3. FusedJSON, Crystal

Report every decompressed MiB/s value, paired FusedJSON/Crystal ratio, geometric
mean ratio, managed bytes per typed value, and peak live-memory caveats. There
is no throughput threshold in this abbreviated review; the formal Milestone 6
gate remains authoritative.

## Stable large-document RSS gate

Run three fresh FusedJSON no-retention typed processes at each many-small size:
256 MiB, 1 GiB, and greater than 4 GiB. Capture peak RSS with GNU
`/usr/bin/time -v`. Freeze the ceiling as:

```text
max(peak RSS across the six 256 MiB and 1 GiB runs)
  + max(16 MiB, 25% of that maximum)
```

All three greater-than-4-GiB peaks must be strictly below that ceiling. Also run
the generated post-`2^32` offset check on Crystal 1.21.0. Preserve every
receipt and GNU-time record, including any failure or interruption.

## Platform reports

The scheduled `Large-document reports` workflow generates a 256 MiB case on
Linux x86-64, Linux ARM64, and macOS ARM64 and uploads only its manifest,
receipts, and platform metadata. Those moving shared-runner results are
report-only and can first run after the candidate is pushed. Their absence from
this local review is not a release gate; a platform correctness failure must
nevertheless be investigated.

## Measured identity and validation

The clean candidate tree was built from
`fbe44913e6ebc8fc19bf627254a56806e50e622e` with the attested Crystal 1.21.0
`[57cf7da50]`, LLVM 20.1.8, and `x86_64-unknown-linux-gnu`. The official
compiler archive matched the frozen SHA-256. The
[build attestation](benchmark-data/milestone-7/stable-fbe4491/receipts/build-attestation.json)
binds the source tree, build commands, and three binaries.

All four stable-compiler spec configurations passed: default and scalar-string
ran 235 examples each; portable-float and combined fallbacks ran 236 each.
Release metadata, formatting, dependency checks, 14 documentation examples,
API docs, four public examples, and Ameba's 55-file inspection passed.
Actionlint 1.7.12 found no workflow errors, and all four benchmark harness
self-audits passed. A clean path-based consumer installed the 0.2.0 candidate
as `fused_json` and required it successfully. The stable Sunlight scanner
passed its Ruby/Oj self-test, and the generated 65,537-byte release fixture
verified typed, raw-number, and gzip paths. The
[validation summary](benchmark-data/milestone-7/stable-fbe4491/receipts/validation.json)
records the checks and setup attempts.

Both 256 MiB inputs passed strong structural, typed, raw-number, checksum, and
whole-file verification. Gzip was also verified for many-small; the wide-item
fixture intentionally had no gzip companion.

## Diagnostic typed throughput

Every entry below is one fresh process. Ratios favor FusedJSON.

| Profile | FusedJSON MiB/s | Crystal MiB/s | Paired ratios | Geometric mean |
| --- | --- | --- | --- | ---: |
| many-small | 243.612; 237.129; 234.924 | 82.589; 81.440; 80.990 | 2.950x; 2.912x; 2.901x | 2.921x |
| wide-item | 176.247; 176.004; 154.689 | 77.125; 77.491; 77.515 | 2.285x; 2.271x; 1.996x | 2.180x |

The third wide-item FusedJSON result was about 12% below the first two. It had
99% task CPU and no receipt or configuration anomaly, so it remains in the
result. These three-pair values are diagnostic, not a new throughput gate; the
larger Milestone 6 campaigns remain the formal performance evidence.

| Profile | Median cumulative allocation, FusedJSON | Median cumulative allocation, Crystal | Median managed B/typed value, Fused/Crystal | Process peak RSS, Fused/Crystal |
| --- | ---: | ---: | ---: | --- |
| many-small | 1,407.149 MiB | 279.531 MiB | 1,168.038 / 232.031 | 9,548-9,724 / 9,576-9,728 KiB |
| wide-item | 1,905.833 MiB | 369.817 MiB | 1,072.030 / 208.022 | 9,604-9,732 / 9,556-9,640 KiB |

Allocation is cumulative managed work, not retained or peak memory. GNU-time
RSS is an end-to-end process peak, not parser heap. The near-equal peaks
therefore do not erase FusedJSON's roughly 5.0x-5.2x allocation churn.

## Stable large-document RSS result

The no-retention FusedJSON runs produced:

| Document size | Process peak RSS |
| --- | --- |
| 256 MiB | 9,580; 9,564; 9,612 KiB |
| 1 GiB | 9,560; 9,604; 9,736 KiB |
| 4,362,076,160 bytes | 9,592; 9,720; 9,552 KiB |

The baseline maximum was 9,736 KiB. Its 25% component was 2,434 KiB, so the
required 16,384 KiB minimum margin set a frozen ceiling of 26,120 KiB.
All three greater-than-4-GiB peaks were strictly below it. This passes the
stable bounded-RSS gate for discarded typed output; it says nothing about
caller-retained values.

## Offset, attempts, and platform status

The stable post-`2^32` check passed at offset `4294967333`, after
`4294967337` bytes and 257 reads. All 12 throughput and nine RSS observations
completed; none failed, was interrupted, or was excluded. Manually sampled
load and temperature context and its limitations are retained with the
receipts.

The report-only platform workflow is defined but cannot run for this unpushed
candidate. When dispatched after a push, it retains the manifest, JSON
receipts, and platform metadata, but not the generated payload. No local ARM64
or macOS result is claimed here.

## Evidence and checksums

The [artifact manifest](benchmark-data/milestone-7/artifact-manifest.json)
indexes four fixture manifests and 49 build, verification, measurement,
GNU-time, context, and validation files. The adjacent
[`SHA256SUMS`](benchmark-data/milestone-7/SHA256SUMS) covers the complete
archive. Verify it from `docs/benchmark-data/milestone-7`:

```console
$ sha256sum -c SHA256SUMS
```

Generated payloads and binaries are omitted; their identities remain in the
manifests and build attestation. The unredacted receipts contain absolute
machine paths plus host and CPU metadata, but no corpus payload or external
corpus filename inventory. The verification-receipt schema has no commit
field; the candidate-scoped artifact manifest and checksums bind those
unmodified receipts to this review.

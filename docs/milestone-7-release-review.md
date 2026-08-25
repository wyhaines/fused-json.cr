# Milestone 7 Stable Release Review

Status: protocol frozen; observations pending.

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
Linux x86-64, Linux ARM64, and macOS ARM64 and uploads only its manifest and
receipts. Those moving shared-runner results are report-only and can first run
after the candidate is pushed. Their absence from this local review is not a
release gate; a platform correctness failure must nevertheless be investigated.

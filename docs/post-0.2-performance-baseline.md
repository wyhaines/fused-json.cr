# Post-0.2 Performance Baseline

Stage 0 is complete at the runtime-equivalent benchmark commit
`8cd68bf8f20f5703166c96894739df91d4b79364`. The measurements use the
compiler, host, fixture, and sampling controls frozen in the
[protocol](post-0.2-performance-protocol.md). They are attribution diagnostics,
not release claims.

## Typed adapter floor

The table reports medians of the forward- and reverse-order processes. Managed
allocation is the repeated `read(T)` operation minus equivalent native cursor
construction. Both operations construct and checksum the same values.

| Shape, uncached | String native ns | String typed ns | String delta B/element | Streaming native ns | Streaming typed ns | Streaming delta B/element |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Empty record | 14.84 | 57.36 | 160.04 | 36.19 | 60.20 | 144.08 |
| One integer | 73.38 | 120.79 | 160.06 | 104.15 | 135.70 | 143.78 |
| One string | 91.93 | 145.15 | 160.08 | 101.91 | 130.39 | 143.78 |
| Nested record | 344.86 | 461.46 | 160.14 | 465.23 | 492.80 | 144.03 |
| Negotiated price | 491.99 | 629.99 | 159.95 | 529.64 | 545.45 | 144.14 |

The delta is constant within measurement noise across output shapes. It is the
fresh bounded compatibility-adapter object: 160 bytes for the in-memory class,
which also stores source bytes for lazy boundary locations, and 144 bytes for
the streaming class. `read_array(T)` has the same allocation floor as a
manual repeated `read(T)` loop.

Compatible scalar reads allocate no managed bytes per element. Streaming
`Int64` reads are 1.04x native cursor time. The String scalar diagnostic is
1.53x native cursor time but remains allocation-free; its absolute difference
is about 14 ns per element.

The adapter object cannot be pooled under the existing contract because a
custom constructor may retain it. There is no separable incidental allocation
above the object size, so Stage 1 will not attempt another adapter
micro-optimization. The measured bytes are recorded as the compatibility floor.

## Key-cache attribution

These comparisons use repeated `read(T)` over the String and streaming
transports. Negative changes are improvements from enabling the per-parse key
cache.

| Shape | Transport | Uncached B/element | Cached B/element | Allocation change | Time change |
| --- | --- | ---: | ---: | ---: | ---: |
| One integer, one repeated key | String | 192.12 | 160.23 | -16.6% | -1.5% |
| Negotiated price, five repeated keys | String | 496.06 | 336.07 | -32.3% | -0.8% |
| Negotiated price, five repeated keys | Streaming | 483.57 | 323.42 | -33.1% | -3.6% |
| Sixteen partially repeated keys | String | 224.04 | 160.51 | -28.4% | -3.7% |
| Sixteen partially repeated keys | Streaming | 211.54 | 147.99 | -30.0% | -1.2% |
| One unique key per record | String | 224.03 | 244.70 | +9.2% | +28.8% |
| One unique key per record | Streaming | 211.41 | 231.94 | +9.7% | +22.4% |

Caching is worthwhile for a small schema repeated across many objects. It is a
clear loss for high-cardinality keys. The default therefore remains off.
Callers that know a repeated schema can enable caching and set
`max_cached_keys` at or above the expected decoded schema cardinality. The
bound is a rejection limit, not an eviction policy.

The first bounded reverse-order attempt found a baseline defect. Crystal
1.21's `StringPool` computes an insertion slot before growing its table, then
uses that old slot after growth. Depending on the process hash seed, the entry
inserted at that transition can become unreachable by normal probing.
FusedJSON then sees a later occurrence as a new key and can reject an exact
`max_cached_keys` bound. The failed attempt is preserved, and Stage 1 will
replace this dependency with a private corrected cache plus regression tests.

## Streaming-tree attribution

Each entry is the median of three fresh stable-compiler processes over 50,000
generated records. Allocation is cumulative managed bytes per complete parse.

| Shape | String MiB/s | IO MiB/s | 4 KiB chunks MiB/s | Pull-to-tree MiB/s | String/IO | IO/pull |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small objects | 200.04 | 119.99 | 118.73 | 118.14 | 1.667x | 1.016x |
| Nested | 150.17 | 95.35 | 95.75 | 94.25 | 1.575x | 1.012x |
| Escaped strings | 281.37 | 259.28 | 251.94 | 243.75 | 1.085x | 1.064x |
| Geometric mean | — | — | — | — | 1.418x | 1.030x |

The current public IO builder and an explicit public pull-to-tree traversal are
nearly equivalent. Small reads reduce the IO geometric mean by only 1.2%.
Direct String construction has a large advantage on object-heavy inputs and a
smaller advantage on escape-heavy strings. The gap includes both streaming
scanner costs and pull event state, so it is an opportunity bound rather than
a prediction for the direct builder.

Managed allocation for IO, chunked IO, and pull-to-tree matched within fixed
measurement noise. String and IO allocation also matched on the object-heavy
fixtures. Escape-heavy String parsing allocated 35.82 MB versus 17.44 MB for
IO, so Stage 2 must not assume the String path is the allocation model for
streamed escaped tokens.

All three boundary preflights passed one-byte, irregular, and
buffer-adjacent read patterns.

## Stage decisions

1. Record the fresh adapter allocation as a required compatibility floor and
   skip speculative adapter changes.
2. Replace the faulty standard-library key pool privately, prove decoded-key
   identity and exact-capacity behavior across multiple growth transitions,
   then screen its repeated- and unique-key performance. Keep the change as a
   correctness fix even if it does not meet the 5% optimization threshold.
3. Proceed with the direct streaming-tree prototype. Freeze small objects,
   nested values, and escaped strings over ordinary and chunked IO with cache
   disabled and enabled, as defined by the protocol.

Raw accepted and invalid receipts are checksummed under
`docs/benchmark-data/post-0.2-performance/baseline-8cd68bf/`.

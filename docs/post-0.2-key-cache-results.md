# Post-0.2 Key-cache Results

Stage 1 is complete at
`5a706fd339bc58a0c29b67084dc5abfd23768244`. The fresh typed adapter is the
compatibility floor identified by Stage 0, so the only production change in
this stage is the key-cache growth correction.

## Correctness result

FusedJSON now uses a private per-parser cache adapted from Crystal's
`StringPool`. It preserves the same open-addressed table and probing sequence,
but grows the table before computing the new entry's insertion slot. This
prevents the growth-transition entry from becoming unreachable under some
process hash seeds.

Regression coverage inserts and repeats 64 decoded keys across four capacity
transitions through both String and one-byte streaming parsers. It verifies
object identity for every repeated key, including an escape-equivalent
spelling, acceptance at an exact `max_cached_keys: 64` bound, and rejection of
key 65 at its source offset.

The focused default suite, the complete randomized default and combined
portable suites, dependency, formatting, and documentation checks all passed.
Ten additional fresh Stable 1.21 benchmark processes completed the partial,
unique, and decoded-equivalent key shapes with exact bounds.

## Directional performance result

Five alternating Stable 1.21 baseline/candidate pairs screened cached partial-
and unique-key workloads. Benchmark source, compiler, fixture, CPU, and GC
settings matched. Ratios below are geometric-mean candidate/baseline
throughput:

| Shape and operation | String | Streaming |
| --- | ---: | ---: |
| Partially repeated, `read(T)` | 1.098x | 1.002x |
| Partially repeated, `read_array(T)` | 1.061x | 1.027x |
| Partially repeated, native cursor | 0.962x | 1.058x |
| Unique keys, `read(T)` | 1.024x | 1.020x |
| Unique keys, `read_array(T)` | 1.026x | 1.008x |
| Unique keys, native cursor | 0.973x | 1.072x |

Managed allocation was unchanged within diagnostic noise. The String native
controls missed the predeclared 0.99x unaffected-path gate, while other paths
were neutral or faster. The change therefore carries no performance claim and
does not proceed to a 20-pair Stage 1 campaign. It is retained because it fixes
the public identity and exact-capacity contracts.

The first attempted screening loop ran only candidate children because a zsh
scalar containing two side names was not word-split. Those files are preserved
as invalid and contribute to no estimate.

## Cache guidance

The Stage 0 allocation results remain the caller-facing decision basis:

- Leave caching off for one-off objects, mostly unique keys, or unknown
  high-cardinality input.
- Enable caching for documents that repeat a small, known schema across many
  objects. The measured negotiated-price and partially repeated shapes reduced
  typed managed allocation by 28-33%.
- Set `max_cached_keys` at or above the expected number of distinct decoded
  schema keys when parsing untrusted input. It rejects excess cardinality; it
  does not evict old entries.
- Count decoded keys rather than source spellings. Plain and Unicode-escaped
  spellings of the same key occupy one cache entry.
- Measure the actual document shape. Caching unique keys increased managed
  allocation by about 9-10% and time by 22-29% in the Stage 0 diagnostic.

The cache remains parser-local, opt-in, and disabled by default. No adaptive
or process-global policy is introduced.

Raw accepted and invalid receipts are checksummed under
`docs/benchmark-data/post-0.2-performance/key-cache-5a706fd/`.

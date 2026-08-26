# Post-0.2 Performance Results

Stages 0 through 3 are complete. The work started from the accepted typed
optimization at `4ca865c4e8ad8716041df4069181a5523493de08` and closed against
the clean runtime and benchmark tree at
`5224d095cd1d58fb5ae27a5a3433de21be9c6efa`. It accepts one key-cache
correctness repair, rejects the direct streaming-tree prototype, and makes no
new throughput claim beyond the earlier typed result.

## Decisions

| Area | Evidence | Decision |
| --- | --- | --- |
| Typed adapters | Repeated `read(T)` has a shape-independent floor of about 160 managed bytes per String value and 144 bytes per streaming value. A custom constructor may retain its distinct adapter. | Preserve the fresh-adapter identity contract. Pooling is unsafe without an API change. |
| Scalar fast paths | Compatible scalar reads allocate no managed bytes per element. Streaming `Int64` was 1.04x native cursor time; the String scalar diagnostic's 1.53x ratio represented about 14 ns per element. | Keep the existing native scalar paths. There is no material allocation left to remove here. |
| Key caching | Repeated schemas reduced managed allocation by 28-33%. Unique keys increased it by 9-10% and increased time by 22-29%. | Keep caching parser-local, opt-in, bounded when appropriate, and disabled by default. |
| Cache implementation | Crystal 1.21's `StringPool` could lose an entry inserted across a growth transition, violating repeated-key identity and exact cache bounds. | Retain FusedJSON's corrected private cache as a correctness fix. Its screening controls did not support a performance claim. |
| Direct `IO` tree construction | The eventless prototype passed semantic checks but reached only 1.064x matrix throughput against a 1.10x gate. Escaped-string profile medians were 0.936-0.960x against a 0.98x floor. | Reject the prototype and retain the pull-backed `load(IO)` path. |
| Retained output | The accepted typed work reduced retained-profile peak RSS to 1.105x Crystal while keeping 315,812 requested values reachable. | Treat most remaining live memory in this profile as requested output or allocator state, not automatically removable parser overhead. |

The [Stage 0 attribution](post-0.2-performance-baseline.md),
[Stage 1 cache result](post-0.2-key-cache-results.md), and
[Stage 2 prototype result](post-0.2-streaming-tree-design.md) contain the
detailed measurements and links to their raw receipts.

## Production outcome

The only parser implementation retained by this follow-on is `KeyCache`, a
private open-addressed cache that grows before calculating the insertion slot.
Tests cover 64 decoded keys across four growth transitions through both String
and one-byte streaming parsers, repeated object identity, escape-equivalent key
spellings, exact-capacity acceptance, and rejection of key 65 at its source
offset. The public API and the default cache policy are unchanged.

The direct builder existed only as a measured prototype. Its exact patch and
binary identity are archived, and production source was restored before
closeout. The retained benchmark-only lint correction changes a Boolean getter
name but produces the same Stable 1.21 release binary as the pre-correction
source.

No candidate qualified for a formal 20-pair campaign. Stage 1 stopped when
unaffected String native controls missed their 0.99x gate. Stage 2 stopped when
the mixed matrix and escaped-string floors failed. Skipping the formal
campaigns is the predeclared protocol result, not missing evidence; running
them after a directional failure would not create an admissible positive
claim.

## Closeout validation

The clean `5224d09` tree passed the following checks:

- `shards check`, Crystal formatting, Ameba over 57 files, release metadata,
  API documentation, and 14 compile-checked documentation examples.
- Four randomized spec configurations on Stable Crystal 1.21.0
  `[57cf7da50]` and Crystal 1.22.0-dev `[6c6a5e988]`: default, portable float,
  scalar string scan, and both fallbacks together. Each compiler ran 242 or
  243 examples per configuration with no failures.
- Release builds of the affected attribution benchmarks on both compilers,
  plus the Stable TiC and Sunlight compatibility programs.
- A path-dependency consumer compiled and ran on both compiler versions.
- The exact post-`2^32` check passed at offset 4,294,967,333 after
  4,294,967,337 bytes and 257 reads.
- Three no-retention typed parses each consumed all 4,362,076,160 bytes and
  produced the expected checksum. Peak RSS was 9,652, 9,628, and 9,504 KiB,
  well below the frozen 26,120 KiB ceiling.
- FusedJSON and Oj produced the same compatibility corpus digest over the
  current 66-file local Sunlight corpus with a 64 MiB item cap.

The initial closeout lint run found the benchmark getter naming defect. That
failure is preserved, the benchmark was corrected in `5224d09`, and the full
common validation then passed. The Sunlight archive also preserves an invalid
Ruby 3 invocation and the deliberate rejection of an older Oj receipt after
the local corpus checkout changed. A fresh Ruby 4.0.5/Oj 3.17.1 oracle was
generated before the passing comparison.

## Memory interpretation

The large no-retention run illustrates why the memory measures remain
separate. Each parse cumulatively allocated 10,345,861,184 managed bytes while
processing 4,362,076,160 input bytes, but the GC heap counter sampled after
parsing was 1,052,672 bytes and the process peak was below 9.5 MiB. Cumulative
allocation measures churn; the heap counter measures allocator-managed arena
state at its sampling point; peak RSS includes the whole process. Only the
separate retained-memory diagnostic samples again after a full GC. None of
these counters is an estimate of output size.

Conversely, the retained-output profile deliberately keeps parsed values
reachable. Those values are requested memory. An optimization may reduce
temporary allocation or allocator slack around them, but eliminating the
values themselves would change the requested result or require a different
output representation.

## Next useful hypotheses

Further adapter work needs a deliberate change to the custom-constructor
identity contract before object reuse is safe. Key-cache work should begin from
real repeated-schema workloads rather than enabling caching universally.

For streaming dynamic parsing, the prototype suggests that removing structural
pull events is too narrow: it helped nested documents but regressed every
escaped-string profile. A future experiment should first attribute shared
refill, scan/decode, and token-materialization costs, especially for escaped
strings and boundary-spanning tokens. Any shared-scanner change must preserve
lazy pull/skip behavior and repeat the existing String, pull, typed, boundary,
offset, and bounded-memory gates.

The checksummed Stage 3 evidence is under
`benchmark-data/post-0.2-performance/closeout-5224d09/`. Compiled binaries and
the generated 4 GiB fixture are omitted; their source, build identities,
fixture manifest hash, and output receipts are retained.

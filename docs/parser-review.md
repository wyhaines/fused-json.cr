# Parser review at 0.4.0

Two independent code reviews of `e06ba59` found unnecessary work in typed cursor reads and escaped-key interning. The figures below compare the original parser with the fixes on a Dell XPS 15 9520 (Core i9-12900HK), using Crystal 1.22.3 in release mode.

| Workload | Before (µs) | After (µs) | Paired speedup | Managed bytes per parse, before → after |
| --- | ---: | ---: | ---: | ---: |
| 2,048 typed Int64 values, String | 89.46 | 66.95 | 1.338× | 288 → 288 |
| Int64 after skipping 32 KiB, String | 78.27 | 5.16 | 15.166× | 288 → 288 |
| Int32 after skipping 32 KiB, String | 83.47 | 5.17 | 16.140× | 288 → 288 |
| 2,048 typed Int32 values, IO | 167.36 | 167.70 | 1.000× | 33,665 → 33,664 |
| End positions for 2,048 typed objects, String | 14,556.92 | 199.67 | 72.943× | 327,964 → 295,201 |
| 512 distinct escaped keys, String | 367.11 | 346.44 | 1.064× | 398,498 → 283,809 |
| 512 distinct escaped keys, IO | 370.73 | 335.49 | 1.092× | 333,841 → 219,154 |
| 512 distinct plain keys, String | 147.90 | 145.15 | 1.027× | 185,504 → 185,504 |
| 2,048 integers into a dynamic tree, String | 59.80 | 59.85 | 0.998× | 140,976 → 140,976 |

Each workload used six alternating pairs of fresh processes pinned to CPU 2. Each process warmed up for at least a second before timing at least a second of complete public API calls. The time columns give independent medians. The speedup column gives the median of the six baseline-to-candidate time ratios. Managed bytes measure allocation traffic. Both binaries used the same build path, compiler flags, inputs and expected results. Three samples fell below the 95% idle threshold for the sibling CPU and were repeated after the host passed another quiet check. The archive records all three alongside the 108 accepted samples.

The 32 KiB case selects an integer after skipping one long string. Previously the typed integer reader walked the skipped bytes again to calculate coordinates for a possible conversion error. The object workload uses a custom constructor that asks for the end position of every element. The former implementation walked the input from byte zero for each query. Forward requests now share the native cursor. A retained adapter can still recover an older position on demand.

The key fixtures enable caching. Each key contains a field number and a 192-byte suffix. On a miss the cache now keeps an already-decoded string. It still copies borrowed input bytes before a streaming buffer can be reused.

An initial integer change slowed streaming Int32 reads in all six pairs. The final implementation uses streaming coordinates already available at the current event and resolves String coordinates on conversion errors. The evidence archive includes both runs and the interrupted diagnostic that preceded them. [Measurements, harness, runtime patch and reproduction commands](benchmark-data/parser-review-e06ba59.tar.gz)

## Correctness checks

- Numeric records at an exact document byte limit accept LF or CRLF in NDJSON. In whitespace-separated streams, the separator counts against the following document. A lone NDJSON carriage return reports its own byte offset and Unicode column.
- Supplying `JSON::Any` explicitly selects typed decoding and enforces `max_typed_value_bytes`. Omitting the type still selects the dynamic reader.
- Token and tree benchmark workers embed their harness hashes at compile time. New campaigns verify source identity within each benchmark family. Earlier receipts retain their original interpretation.

The development checkout included nine additional experimental specs. On Crystal 1.21.0 and 1.22.3, its default and scalar-scanner suites each passed 302 examples. The portable-float and combined-fallback suites each passed 303. The standalone review changes passed all 293 default specs on Crystal 1.22.3. The documentation check compiled 17 examples, Ameba reported zero failures, and the streaming offset check reported the expected byte 4,294,967,333.

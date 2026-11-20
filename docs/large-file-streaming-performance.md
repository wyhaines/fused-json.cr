# Large-file streaming performance

On the complete Aetna in-network file, the optimized parser used 27.0% less CPU time than `7d48dc5` with Boehm and 26.1% less with gcry. Including single-core gzip decompression, wall time fell 18.5% and 17.6%, respectively.

## Aetna, whole file

The input was `2026-10-05_pl-5b7-tr25_Aetna-Life-Insurance-Company.json.gz`, SHA-256 `355e2c8f25692c58f7a5b14fc01a5599e6dbf676ea6332f1ff813dbfb07fecec`. The 1,050,199,136-byte gzip expanded to 18,904,745,400 bytes. Every run found 67,237,517 negotiated rate keys and returned checksum `aac3a2613c1340b6`.

| Parser | Collector | Pipeline wall (s) | Parser CPU (s) | Parser peak RSS (MiB) | Input MiB/s |
| --- | --- | ---: | ---: | ---: | ---: |
| v0.4.0 | Boehm 8.3.0 | 241.74 | 162.69 | 3.20 | 74.6 |
| v0.4.0 | gcry 0.40.0 | 237.21 | 158.29 | 17.70 | 76.0 |
| Main at `7d48dc5` | Boehm 8.3.0 | 248.51 | 169.38 | 3.23 | 72.6 |
| Main at `7d48dc5` | gcry 0.40.0 | 241.64 | 162.68 | 17.72 | 74.6 |
| Optimized | Boehm 8.3.0 | 202.63 | 123.62 | 3.17 | 89.0 |
| Optimized | gcry 0.40.0 | 199.08 | 120.19 | 17.70 | 90.6 |

Against the released v0.4.0, the median paired reduction in wall time was 16.2% with Boehm and 16.1% with gcry. Across the full parse runs, gzip used 78.7–79.0 CPU seconds per build. The separate gzip-only pass took 81.08 s.

## UHC, first GiB

A second input came from `2026-11-01_UMR--Inc-_Third-Party-Administrator_MONUMENT-HEALTH-UHC-CSP_WEST-VIRGINIA-CCP-WEST-VIRGINIA-UNIVERSITY_-GUM_PEDW_in-network-rates.json.gz` (14,945,948,747 bytes compressed). A streaming extractor copied its first GiB to the next comma outside a string, then closed the open containers and recompressed the sample with `gzip -1`. The resulting 1,073,741,845-byte document was verified to EOF by all six builds (checksum `95660aed40e201f3`). The prefix contained 3,154,202 integers and 3,498,398 negotiated rate keys. These results describe the prefix.

| Parser | Collector | Pipeline wall (s) | Parser CPU (s) | Parser peak RSS (MiB) | Input MiB/s |
| --- | --- | ---: | ---: | ---: | ---: |
| v0.4.0 | Boehm 8.3.0 | 11.57 | 6.97 | 2.99 | 88.5 |
| v0.4.0 | gcry 0.40.0 | 11.38 | 6.79 | 14.60 | 90.0 |
| Main at `7d48dc5` | Boehm 8.3.0 | 11.94 | 7.36 | 3.14 | 85.8 |
| Main at `7d48dc5` | gcry 0.40.0 | 11.56 | 6.96 | 14.61 | 88.6 |
| Optimized | Boehm 8.3.0 | 10.05 | 5.46 | 3.11 | 101.9 |
| Optimized | gcry 0.40.0 | 9.83 | 5.24 | 14.57 | 104.2 |

On this prefix, pipeline wall time relative to the previous main was 15.8% lower with Boehm and 15.0% lower with gcry. Parser CPU time was 25.8% lower and 24.8% lower, respectively.

## What changed

A sampling profile of a 384 MiB Aetna prefix identified time spent constructing token slices, scanning strings, skipping whitespace, and updating container frames. On the prefix, median parser CPU time went from 3.42 s to 2.56 s across three fresh-process observations per build. The streaming reader now processes a plain ASCII string within the input buffer in one pass and copies the decoded value directly into its owned String. Strings with escapes or raw UTF-8 and strings split across refills use the general decoder.

The buffer index supplies the byte offset and the ASCII portion of the column. The parser adjusts the bases on refills, newlines and UTF-8 continuation bytes. It consumes recognized punctuation directly and changes an array’s frame state on the first element. These changes apply to the existing streaming API.

## Measurement

The Dell XPS 15 9520 used its Core i9-12900HK, Crystal 1.22.3, and LLVM 22.1.3. Each release binary was built from the same absolute directory. The versions were v0.4.0 (`e06ba59`), main (`7d48dc5`), and main with the archived runtime patch. The gcry build used release 0.40.0 (`0fcca95`), `-Dgc_none`, and an early require of the collector.

The identical worker read every key and scalar with a 32 KiB buffer and `cache_keys: false`, retained counts and a checksum, and called `finish` at EOF. Each pipeline ran alone, with both `gzip -dc` and the parser pinned to logical CPU 2. GNU time measured user plus system CPU and maximum RSS of the parser separately from gzip. The table gives medians for two fresh processes per configuration. Percentages pair builds within each of the two reverse-order rounds.

The Aetna campaign accepted 12 measurements and recorded 0 retries for host activity. The UHC prefix accepted 12 measurements with 0 retries. Neither campaign wrote uncompressed JSON to disk.

## Verification and controls

The candidate matched the previous implementation in 7,632 streaming comparisons over all 318 JSONTestSuite fixtures, including event traces, decoded values, error offsets, and line/column coordinates. In a standalone checkout, the default and scalar-scanner suites each passed 302 specs on Crystal 1.21.0 and 1.22.3. The portable-float and combined-fallback suites each passed 303. The development checkout also passed its nine additional experimental specs in each configuration. The gcry release build passed all 302 default specs, and the generated 4 GiB test verified positions beyond a 32-bit column.

A separate Dell run used the project’s smaller token benchmarks to check workloads with different characteristics. Ratios are candidate/baseline throughput across four paired rounds.

| Token fixture | Input | Consumer | Median throughput ratio | Range |
| --- | --- | --- | ---: | ---: |
| plain-short | io-memory | pull-materialize | 1.073× | 1.064–1.107 |
| plain-long | io-memory | pull-skip | 1.447× | 1.422–1.470 |
| raw-utf8 | chunked-memory | pull-materialize | 0.970× | 0.964–0.977 |
| escape-dense | io-memory | dynamic-tree | 1.026× | 1.021–1.039 |
| key-repeated-plain | io-memory | typed | 1.121× | 1.109–1.133 |
| floats | io-memory | pull-materialize | 1.110× | 1.107–1.128 |
| integers | string | dynamic-tree | 1.051× | 1.026–1.057 |
| surrogate-escape | io-memory | dynamic-tree | 1.161× | 1.149–1.175 |
| unicode-escape | chunked-memory | pull-materialize | 1.010× | 1.009–1.016 |
| key-unique-escaped | io-memory | dynamic-tree | 1.048× | 1.037–1.197 |
| key-unique-plain | string | pull-materialize | 1.020× | 1.010–1.029 |

The lowest median throughput ratio in these controls was raw UTF-8 in 13-byte reads, at 0.970× (3.0% lower throughput). All four pairs were slower.

The archive contains individual process receipts, the unchanged worker, candidate patch, profiling and extraction tools, and reproduction instructions. [Benchmark evidence](benchmark-data/large-file-streaming-7d48dc5.tar.gz)

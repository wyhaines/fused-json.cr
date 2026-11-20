# Streaming the Aetna TiC file

On a Dell XPS 15 9520, four optimized Crystal builds streamed the same 18,904,745,400-byte JSON document from `gzip -dc`. The table gives the median and range across 2 fresh processes per build. The parser and decompressor shared logical CPU 2, and only one pipeline ran at a time.

| fused-json.cr | Collector | Pipeline wall, s (range) | Parser CPU, s (range) | Parser peak RSS, MiB (range) | Input MiB/s |
| --- | --- | ---: | ---: | ---: | ---: |
| 0.4.0 (`e06ba59`) | Boehm 8.3.0 | 240.77 (238.40–243.14) | 161.63 (159.33–163.93) | 3.29 (3.15–3.42) | 74.9 |
| 0.4.0 (`e06ba59`) | gcry 0.40.0 | 237.44 (237.35–237.53) | 158.41 (158.29–158.52) | 17.69 (17.66–17.72) | 75.9 |
| main (`7d48dc5`) | Boehm 8.3.0 | 248.73 (247.86–249.60) | 169.53 (168.64–170.43) | 3.28 (3.27–3.30) | 72.5 |
| main (`7d48dc5`) | gcry 0.40.0 | 241.80 (241.64–241.96) | 162.78 (162.61–162.96) | 17.73 (17.73–17.73) | 74.6 |

## Comparing the builds

Percentages use the timing or RSS ratio within each round.

- With Boehm, main’s wall time was 3.3% higher than v0.4.0, parser CPU time was 4.9% higher, and peak parser RSS was within 0.05% of the release.
- With gcry, main’s wall time was 1.8% higher than v0.4.0, parser CPU time was 2.8% higher, and peak parser RSS was 0.2% higher.
- On v0.4.0, gcry used 5.39× the parser peak RSS of Boehm. Its pipeline wall time was 1.4% lower and parser CPU time was 2.0% lower.
- On main, gcry used 5.40× the parser peak RSS of Boehm. Its pipeline wall time was 2.8% lower and parser CPU time was 4.0% lower.

## Input and verification

The input was `2026-10-05_pl-5b7-tr25_Aetna-Life-Insurance-Company.json.gz`. Its compressed size was 1,050,199,136 bytes and its SHA-256 digest was `355e2c8f25692c58f7a5b14fc01a5599e6dbf676ea6332f1ff813dbfb07fecec`. A separate full pass through `gzip -dc | wc -c` took 80.85 s and established the decompressed byte count independently.

The worker opens a native FusedJSON pull parser on standard input with a 32 KiB buffer and `cache_keys: false`. It reads each object key and scalar, incorporates the decoded values and container boundaries into a 64-bit checksum, then calls `finish` at EOF. It retains only counters, the current values, and the checksum. Every measured pass produced `aac3a2613c1340b6` and counted 67,237,517 `negotiated_rate` keys. Both pipeline processes exited successfully in each run.

## Timing and memory

The runs used Crystal 1.22.3, LLVM 22.1.3, GNU gzip 1.10, Linux 7.2.15-76070215-generic, and the Dell's powersave CPU governor. Each binary used `--release --no-debug --threads 1` at the same build path. The gcry builds also required gcry at startup and used `-Dgc_none`. The baseline linked libgc 8.3.0. The gcry builds identified themselves as 0.40.0. The evidence includes the dynamic-library list for each executable. [gcry integration at v0.40.0](https://github.com/sdogruyol/gcry/blob/v0.40.0/docs/INTEGRATION.md)

Pipeline wall time includes decompression, scheduling, checksum work and parsing. Parser CPU adds user and system CPU time for the parser process. GNU time measures each process separately. Peak parser RSS includes the executable, runtime, heap and buffers. Gzip and the OS file cache are outside that figure. Input throughput uses decompressed bytes divided by wall time.

The collector verified AC power, CPU availability and NVMe activity before starting each run. `GC_NPROCS=1` and `GC_MARKERS=1` were set. gcry used its defaults within the single-CPU affinity. Input pages were warmed by a compressed-file checksum and the byte-count pass. The controller collected 8 accepted parser runs and recorded 0 host-condition retries. The archive includes all observations, individual per-process time and RSS receipts, and the scripts for repeating the measurement. [Raw receipts, worker and reproduction commands](benchmark-data/aetna-streaming-7d48dc5.tar.gz)

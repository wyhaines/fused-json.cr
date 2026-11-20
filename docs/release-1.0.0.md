# 1.0.0 release verification

The release check uses the stable Crystal 1.22.3 compiler on the Dell XPS 15 9520. Build the TiC fixture generator, TiC reader benchmark and large-offset check from the 1.0.0 candidate with `--release --no-debug --threads 1`. Record the commit, executable hashes, compiler version and host details.

Generate `many-small` fixtures of 268,435,456, 1,073,741,824 and 4,362,076,160 bytes with seed 7 and `providers-first` field order. Verify the typed, structural and raw-number results on the 256 MiB fixture before measuring. The separate small fixture in the release workflow also checks gzip.

Run three fresh `fused-typed` RSS processes per size with output retention off. Pin each process to CPU 2 and set `GC_NPROCS`, `GC_MARKERS`, `CRYSTAL_WORKERS` and `OMP_NUM_THREADS` to 1. Capture each process's peak RSS with GNU time and retain all nine observations. The three largest-input peaks must each be below the largest of the six smaller-input peaks plus the greater of 16 MiB or 25% of that peak. This repeats the [stable release memory check](milestone-7-release-review.md#stable-large-document-rss-gate). Run the post-2³² offset check on the same build.

## Results

All nine runs passed on commit `7cbad94` with Crystal 1.22.3 and LLVM 22.1.3. The 256 MiB fixture passed structural, typed and raw-number verification. The large-offset check reported byte 4,294,967,333 and verified key iteration and typed map conversion beyond a 32-bit column.

| Generated input | Peak RSS over three fresh processes (KiB) |
| --- | ---: |
| 256 MiB | 8,684 / 8,744 / 8,828 |
| 1 GiB | 8,788 / 8,784 / 8,600 |
| 4 GiB + 64 MiB | 8,732 / 8,756 / 8,740 |

The highest peak on the largest input was 8,756 KiB (8.55 MiB), below the 25,212 KiB ceiling. Each run returned the expected checksum. [Manifests, measurements and reproduction commands](benchmark-data/release-1.0.0.tar.gz)

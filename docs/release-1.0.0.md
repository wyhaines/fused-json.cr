# 1.0.0 release verification

The release check uses the stable Crystal 1.22.3 compiler on the Dell XPS 15 9520. Build the TiC fixture generator, TiC reader benchmark and large-offset check from the 1.0.0 candidate with `--release --no-debug --threads 1`. Record the commit, executable hashes, compiler version and host details.

Generate `many-small` fixtures of 268,435,456, 1,073,741,824 and 4,362,076,160 bytes with seed 7 and `providers-first` field order. Verify the typed, structural and raw-number results on the 256 MiB fixture before measuring. The separate small fixture in the release workflow also checks gzip.

Run three fresh `fused-typed` RSS processes per size with output retention off. Pin each process to CPU 2 and set `GC_NPROCS`, `GC_MARKERS`, `CRYSTAL_WORKERS` and `OMP_NUM_THREADS` to 1. Capture each process's peak RSS with GNU time and retain all nine observations. The three largest-input peaks must each be below the largest of the six smaller-input peaks plus the greater of 16 MiB or 25% of that peak. This repeats the [stable release memory check](milestone-7-release-review.md#stable-large-document-rss-gate). Run the post-2³² offset check on the same build.

# TiC large-document benchmarks

The TiC tools generate and measure large, repeatable JSON documents without
loading a complete document into memory. The fixtures resemble insurance
Transparency in Coverage files, but they do not claim conformance with a
particular CMS schema version.

## Build

Build both programs in release mode before recording measurements:

```console
$ crystal build --release --no-debug bench/tic_fixture.cr -o bin/tic-fixture
$ crystal build --release --no-debug bench/tic.cr -o bin/tic-bench
```

## Generate a fixture

`--bytes` is the exact decompressed JSON size. It accepts a decimal `Int64`
without unit suffixes.

```console
$ bin/tic-fixture \
    --profile many-small \
    --bytes 1073741824 \
    --seed 7 \
    --field-order providers-first \
    --output /tmp/tic-1g.json \
    --gzip-output /tmp/tic-1g.json.gz \
    --manifest /tmp/tic-1g.meta.json
```

The profiles exercise different parser costs:

| Profile | Shape |
| --- | --- |
| `many-small` | Many small `in_network` items with one price each |
| `wide-item` | One large outer item containing many nested prices |
| `skip-heavy` | Small selected records surrounded by ignored nested data |
| `unicode-boundary` | Raw UTF-8 code points split across fixed input boundaries |

`--field-order` accepts `providers-first` or `rates-first`. This option changes
root member order without changing the generated values or semantic digest.
The default is `rates-first` for `wide-item` and `unicode-boundary`, and
`providers-first` for the other profiles.

For `unicode-boundary`, `--boundary-bytes` selects the fixed split boundary
(default 32768; allowed range 64 through 16777216). Pass that same value as
`--buffer-size` to `verify`, `run`, or `rss`; the benchmark rejects a mismatch.

The manifest records the seed, root key order, exact byte counts, logical item
counts, maximum nesting, largest token and array item, Unicode split offsets,
document SHA-256, and canonical price projection SHA-256. It also records the
low-overhead normalized projection checksum used by timed parser runs and a
separately versioned checksum that includes each negotiated-rate token's exact
spelling. The established `fnv1a64-fields-v1` checksum remains unchanged; raw
number verification uses `fnv1a64-fields-raw-number-v2`. String token sizes
include their quotes and escapes. The generator writes padding in fixed chunks
to reach the requested size.

Gzip output uses compression level 6, modification time 0, OS byte 255, and no
optional header fields. Repeated generation is byte-identical when the inputs
and zlib version match. The manifest records the zlib version and treats its
64-bit decompressed size as authoritative.

## Verify before measuring

Verification streams each input to EOF. It checks the plain document hash,
validates the gzip trailer when present, and compares structural and typed
FusedJSON/Crystal traversals with the manifest.

```console
$ bin/tic-bench verify \
    --input /tmp/tic-1g.json \
    --gzip-input /tmp/tic-1g.json.gz \
    --manifest /tmp/tic-1g.meta.json
```

Both parsers count the same TiC containers and hash the same fixed-order JSON
Lines projection. Each projection row includes the selected item metadata,
provider group ID, negotiated price, billing class, and service code.
Provider-reference contents and ignored fields remain covered by strict JSON
validation and the whole-document hash. The typed verification additionally
decodes provider-reference records, scalar provider IDs, and negotiated-price
records. A root-order-independent provider checksum verifies fields that are
not part of the price projection.

Verification also makes a separate pass through each parser that reads every
negotiated rate as a raw number. Its checksum includes the exact source lexeme,
so spellings such as `123.4500` and `1.234500e2` remain distinguishable. The
FusedJSON pass exercises `read_raw_number`; this raw-number pass is not a timed
benchmark mode. Manifests created by Milestone 1 remain usable: verification
skips the raw pass when both v2 fields are absent and records
`raw_number_verified: false`. Regenerate the fixture to add raw-number coverage.

## Record one workload

Each `run` or `rss` invocation performs one workload. It does not run the
cross-parser verification step in the measured process.

| Mode | Transport | Passes | Parsing unit |
| --- | --- | ---: | --- |
| `plain-drain` | Plain | 1 | Bytes only |
| `gzip-drain` | Gzip | 1 | Decompressed bytes only |
| `fused-pull`, `crystal-pull` | Plain | 1 | Structural pull events |
| `fused-typed`, `crystal-typed` | Plain | 1 | Nested typed values |
| `fused-gzip-typed`, `crystal-gzip-typed` | Gzip | 1 | Decompression plus nested typed values |
| `fused-two-pass-typed`, `crystal-two-pass-typed` | Plain | 2 | Reopened provider pass plus rate pass |

```console
$ FUSED_JSON_COMMIT=$(git rev-parse HEAD)
$ bin/tic-bench run --input /tmp/tic-1g.json \
    --manifest /tmp/tic-1g.meta.json --mode fused-pull \
    --commit "$FUSED_JSON_COMMIT"
$ bin/tic-bench run --input /tmp/tic-1g.json \
    --manifest /tmp/tic-1g.meta.json --mode crystal-pull \
    --commit "$FUSED_JSON_COMMIT"
$ bin/tic-bench run --input /tmp/tic-1g.json \
    --manifest /tmp/tic-1g.meta.json --mode plain-drain \
    --commit "$FUSED_JSON_COMMIT"
$ bin/tic-bench run --input /tmp/tic-1g.json \
    --gzip-input /tmp/tic-1g.json.gz \
    --manifest /tmp/tic-1g.meta.json --mode gzip-drain \
    --commit "$FUSED_JSON_COMMIT"
$ bin/tic-bench run --input /tmp/tic-1g.json \
    --manifest /tmp/tic-1g.meta.json --mode fused-typed \
    --commit "$FUSED_JSON_COMMIT"
$ bin/tic-bench run --input /tmp/tic-1g.json \
    --gzip-input /tmp/tic-1g.json.gz \
    --manifest /tmp/tic-1g.meta.json --mode fused-gzip-typed \
    --commit "$FUSED_JSON_COMMIT"
$ bin/tic-bench run --input /tmp/tic-1g.json \
    --manifest /tmp/tic-1g.meta.json --mode fused-two-pass-typed \
    --commit "$FUSED_JSON_COMMIT"
```

Run the matching `crystal-*` mode in a fresh process for comparison. Both typed
implementations decode each root provider reference as a typed record, keep
the outer `in_network` item structural, and decode each negotiated price as a
typed record. FusedJSON decodes provider IDs with `read_array(Int64)`; the
Crystal baseline constructs the same typed scalars in its untyped array loop.
This keeps the `wide-item` profile bounded by a nested price instead of
materializing its document-scale outer item.

Gzip typed modes include file opening, decompression, parsing, complete input
validation, and trailer validation. They are end-to-end transport results, not
parser-only measurements. Two-pass modes reopen the plain file, select
providers on the first complete traversal and rates on the second, and include
the first pass in first-price latency.

Set `FUSED_JSON_COMMIT` to the full 40-character commit SHA being measured. The
JSON receipt includes wall and CPU time, throughput, first projected-price
latency for parser modes, cumulative managed allocation, compiler and LLVM
versions, zlib, host CPU, affinity, and buffer settings. Typed receipts also
record actual typed record/scalar counts, the provider checksum, per-pass wall
times, typed values per second, and managed bytes per typed value. Timed parser
modes compare a compact field checksum with the manifest; the stronger
projection SHA-256 belongs to the untimed verification pass. Drain modes report
byte counts and a bounded, chunk-dependent observer value. They do not report
semantic items, and their observer values should not be compared across buffer
sizes.

For a two-pass receipt, `processed_bytes` is twice the decompressed document
size and `decompressed_mib_per_second` uses that work denominator.
`logical_document_mib_per_second` uses the document size once; wall time is the
elapsed time for one logical two-pass import. One-pass modes report both rates
with the same denominator.

Use GNU `time` for a separate process peak-RSS record:

```console
$ /usr/bin/time -v bin/tic-bench rss \
    --input /tmp/tic-1g.json \
    --manifest /tmp/tic-1g.meta.json \
    --mode fused-pull \
    --commit "$FUSED_JSON_COMMIT" >run.json 2>run.time
```

Each receipt's `configuration.input_buffering` describes the path actually
used by that mode. Plain FusedJSON modes use an unbuffered `File` plus the
configured parser buffer. Plain Crystal modes set the `File` buffer to the
same size, but its lexer does not expose an equivalent parser-buffer option.
Gzip modes use an unbuffered compressed file and a gzip reader; drain modes use
the explicit benchmark drain buffer instead of either parser.

Typed parsing, gzip plus parsing, and the two-pass workflow are available now.
The paired statistical release gates and multi-size RSS campaigns remain part
of Milestone 6; do not infer them from a single shared-host run.

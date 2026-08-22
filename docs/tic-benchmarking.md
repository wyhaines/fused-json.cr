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

The manifest records the seed, root key order, exact byte counts, logical item
counts, maximum nesting, largest token and array item, Unicode split offsets,
document SHA-256, and canonical price projection SHA-256. It also records the
low-overhead projection checksum used by timed parser runs. String token sizes
include their quotes and escapes. The generator writes padding in fixed chunks
to reach the requested size.

Gzip output uses compression level 6, modification time 0, OS byte 255, and no
optional header fields. Repeated generation is byte-identical when the inputs
and zlib version match. The manifest records the zlib version and treats its
64-bit decompressed size as authoritative.

## Verify before measuring

Verification streams each input to EOF. It checks the plain document hash,
validates the gzip trailer when present, and compares both pull parsers with
the manifest.

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
validation and the whole-document hash.

## Record one workload

Each `run` or `rss` invocation performs one workload. It does not run the
cross-parser verification step in the measured process.

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
```

Set `FUSED_JSON_COMMIT` to the full 40-character commit SHA being measured. The
JSON receipt includes wall and CPU time, throughput, first projected-price
latency for parser modes, cumulative managed allocation, compiler and LLVM
versions, zlib, host CPU, affinity, and buffer settings. Timed parser modes
compare a compact field checksum with the manifest; the stronger projection
SHA-256 belongs to the untimed verification pass. Drain modes report byte
counts and a bounded, chunk-dependent observer value. They do not report
semantic items, and their observer values should not be compared across buffer
sizes.

Use GNU `time` for a separate process peak-RSS record:

```console
$ /usr/bin/time -v bin/tic-bench rss \
    --input /tmp/tic-1g.json \
    --manifest /tmp/tic-1g.meta.json \
    --mode fused-pull \
    --commit "$FUSED_JSON_COMMIT" >run.json 2>run.time
```

FusedJSON uses an unbuffered `File` plus its configured parser buffer. Crystal's
pull parser uses a `File` buffer of the same size; its lexer does not expose an
equivalent parser-buffer option. Do not describe these as identical internal
buffers.

These Milestone 1 modes use structural pull parsing. Typed parsing, gzip plus
parsing, the two-pass TiC workflow, statistical release gates, and multi-size
RSS campaigns belong to later milestones.

# Large-document typed streaming implementation plan

Status: in progress. Milestones 1 through 5 are implemented. Milestone 6,
controlled performance and scale validation, is now in progress. This plan
implements the requirements in the
[Large-document typed streaming specification](large-document-processing.md).

## Working rules

- Establish semantic parity before optimizing.
- Keep the in-memory fused tree path separate from the pull and streaming
  changes.
- Measure plain parsing, decompression, and consumer retention independently.
- Do not commit TiC corpus files, download them automatically, or require
  proprietary or very large inputs.
- Keep each implementation commit focused and update public documentation with
  the behavior it introduces.

## Milestone 1: Fixtures and baselines (implemented)

Add a deterministic, streaming TiC-shaped generator at
`bench/tic_fixture.cr`. It must produce a manifest with the seed, exact byte
sizes, item counts, largest token and item, field order, and a canonical result
digest. Define that digest as SHA-256 over a versioned JSON Lines projection of
the fields used by the benchmark, with fixed key order and number spelling.
Profiles should cover many small items, one wide nested item,
skip-heavy data, Unicode at buffer boundaries, and both orders of
`provider_references` and `in_network`. Optional gzip output must be
reproducible.

Add `bench/tic.cr` with initial modes for plain drain, gzip
decompress-and-drain, current FusedJSON pull traversal, and equivalent Crystal
pull traversal. Milestones 3 and 4 add plain typed parsing, gzip plus typed
parsing, and the two-pass TiC workflow when those APIs exist. Every parse mode
must use the same fields and observable count. Untimed preflight verifies the
projection SHA-256. Timed parser modes use the same fields with a compact
checksum so digest construction does not dominate the result.

Capture compiler, LLVM, CPU, OS, zlib, buffer size, compressed and decompressed
bytes, wall and CPU time, first projected-price latency, and projected prices
per second. Managed allocation is cumulative work even when values are
discarded, so report it as bytes per projected price or per decompressed MiB.
Record process peak RSS as a separate series. Never derive parser time or
memory by subtracting two modes. A two-pass rate uses twice the decompressed
byte count and also reports elapsed time per logical document.

The proposed command shape is:

```console
$ crystal build --release --no-debug bench/tic_fixture.cr -o bin/tic-fixture
$ crystal build --release --no-debug bench/tic.cr -o bin/tic-bench
$ bin/tic-fixture --profile many-small --bytes 1073741824 --output /tmp/tic-1g.json --manifest /tmp/tic-1g.meta.json
$ bin/tic-bench verify --input /tmp/tic-1g.json --manifest /tmp/tic-1g.meta.json
$ FUSED_JSON_COMMIT=$(git rev-parse HEAD)
$ /usr/bin/time -v bin/tic-bench rss --input /tmp/tic-1g.json --manifest /tmp/tic-1g.meta.json --mode fused-pull --commit "$FUSED_JSON_COMMIT"
```

Acceptance: generated receipts verify before timing, the Crystal and FusedJSON
baselines agree, and no benchmark builds the complete document.

## Milestone 2: Range-neutral pull numbers (implemented)

Separate number recognition from numeric materialization in the public pull
path. Scanning or skipping a valid wide number must not narrow it. Direct
`Int64` and `Float64` access retains the current checked conversions, and
dynamic `load` and `parse` behavior does not change.

Expose `raw_number_value` and `read_raw_number` on `PullParser`. The first
method observes the current numeric lexeme without advancing; the second
returns it and advances once. Cover integer and float spellings, exponents,
negative zero, values beyond fixed-width integer ranges, repeated observation,
wrong event kinds, token limits, and tiny stream buffers. Keep whole-value raw
replay private.

Extend the TiC traversal with a raw-number verification case. It must include
the exact lexeme in its result checksum so the public path used by Sunlight is
tested against generated large input rather than only isolated tokens. Give
that checksum a new algorithm version instead of changing
`fnv1a64-fields-v1` semantics.

Add focused tests for wide integer and floating tokens at the root and within
containers, including reads, skips, wrong-type failures, and tiny stream
buffers. Change `read_int` and the integer branch of `read_float` to use the
lazy checked getters rather than the previously eager value slots. Integer to
float reads continue to reject values outside `Int64`. Update the pull
contract, migration guide, and changelog in the same change.

Acceptance: raw number methods preserve every byte of the numeric lexeme and
consume exactly as documented without narrowing. All existing dynamic, pull,
typed, conformance, portable-float, and scalar-scanner suites pass. Existing
dynamic benchmark gates show no material regression.

## Milestone 3: Typed reads at the cursor (implemented)

Add borrowed variants of the private Crystal pull adapters that expose exactly
one current value while preserving the unbounded owning adapters used by
`from_json`. Give each borrowed adapter a value-boundary guard: it presents EOF
after that value, rejects incomplete constructors, and never exposes a sibling.
Keep separate concrete String and IO specializations so neither hot path gains
union dispatch.

Add `PullParser#read(T)`. Exercise every type and `JSON::Serializable` feature
already promised by `from_json`, plus nested positions, sequential mixed
types, `BigInt`, `BigFloat`, exact `BigDecimal`, raw converters,
discriminators, unknown fields, constructor errors, and attempts to consume
zero or multiple values. Reuse the native raw-number bridge for Crystal's
`raw_value` contract without exposing whole-value replay on the native reader.

Acceptance: decoding the same isolated value through `read(T)` and
`from_json` has equal results and errors. Representative streaming values pass
at every byte split and with one-byte reads. A failed read never yields a
partial value.

## Milestone 4: Typed array blocks and TiC workflow (implemented)

Add `PullParser#read_array(T)`. Implement it on `read(T)` and preserve the
existing untyped overload. Test empty arrays, item order, nested arrays,
duplicate object members, early block exit, callback exceptions, malformed
later items, malformed one-token lookahead, and malformed document suffixes.
Measure per-element adapter cost for representative records and scalar arrays.
Retained-reference safety forbids adapter reuse; any lighter initialization or
primitive fast path must preserve the same one-value boundary semantics.

Add a compile-checked large-document example that:

1. opens plain or caller-wrapped gzip IO;
2. walks a root object without assuming member order;
3. captures a root scalar;
4. streams one named array as typed values and skips the others; and
5. calls `finish` before committing staged output.

Add a second example or test that walks an outer item structurally and streams
a nested typed array. It must place parent metadata both before and after the
nested array, use sequence IDs with separate metadata and child sinks, and
retain no complete outer item. Include a two-pass example or test that
recreates the IO for each pass. Do not add CMS field names to the library
itself.

Acceptance: lookahead tests prove that the first plain-input object is yielded
without traversing the next object or document tail. Scalar arrays may scan
one complete next token before yielding, as specified. Truncation, trailing
garbage, invalid UTF-8, and a bad gzip trailer are all detected on a complete
traversal. IO ownership remains unchanged.

## Milestone 5: Resource limits (implemented)

The accepted [resource-limits decision](resource-limits-decision.md) defines
one immutable limits object for the existing nesting and token controls plus
decoded document bytes, a selected typed value, total values, entries per
container, cached keys, and duplicate-key rejection. It specifies each counter,
duplicate-tracking memory, and error locations. Document-sized counters use
`Int64`. Document limits and container typed-value limits are checked as input
is consumed; the scalar typed-value scratch caveat is described in the
decision.

Existing limit keywords remain source compatible during 0.x, and the smaller
value wins when a keyword and `Limits` overlap. `bench/limits_overhead.cr`
measures the cost of the default and explicit-empty policies on every parser
path.

Acceptance: ordinary boundary tests cover the accepted limits on String and IO
for skipped and typed values. A generated IO places a known token or error
after byte `2^32` and verifies its exact offset without constructing a 4 GiB
String. The default-path campaign uses the eight workloads and fixed parameters
in [`benchmarking.md`](benchmarking.md). For candidate/M4 pairs, median and
geometric-mean throughput ratios must be at least 0.98 and the one-sided 95%
paired-bootstrap lower bound must be at least 0.97. For explicit-empty/default
pairs, the corresponding gates are 0.99 and 0.98. Managed B/op must remain
within the documented fixed-or-0.1% tolerance. Record the complete campaign
before marking this milestone implemented. The memory guide states that byte
limits do not equal an exact Crystal heap limit.

The large-offset check is separate from the fast spec suite:

```console
$ crystal run --release --no-debug scripts/check_large_offset.cr
```

The default-path and explicit-empty campaigns passed every throughput,
bootstrap, and managed-allocation gate. Accepted receipts and all unsuccessful
attempts are recorded in the
[Milestone 5 benchmark results](milestone-5-benchmark-results.md).

## Milestone 6: Performance and scale validation (in progress)

Use attested release builds and the CPU-pinned, predeclared host policy in the
[Milestone 6 validation protocol](milestone-6-protocol.md). The current
`busy-pinned-v2` campaign bounds persistent background load, temperature, the
benchmark CPU, and its SMT sibling before and during every child. Its results
are comparative measurements under a hot shared host, not peak quiet-host
throughput. Predeclare at least 20 paired blocks per profile. Each block
contains one fresh FusedJSON process and one fresh Crystal process in a
predetermined, balanced AB/BA order. One process result is one observation;
iterations within a process are not
independent samples. Retain every valid run and define exclusions before the
campaign starts. Use plain inputs from a warmed page cache and identical parser
buffers for the throughput gate; the plain-drain mode records the storage and
copying ceiling without being subtracted from parse time.

For each pair, compute `log(Fused throughput / Crystal throughput)`. Report its
geometric mean ratio and a one-sided 95% paired-bootstrap lower bound using at
least 10,000 fixed-seed resamples. On both many-small and wide-item profiles,
the geometric mean must be at least 1.05 and the lower bound must exceed 1.0.
Treat gzip end-to-end throughput, first-item latency, and Ruby/Oj as reported
measurements until stable baselines exist.

Measure end-to-end process peak RSS with GNU `/usr/bin/time -v` in fresh
processes. The bounded series uses plain files, typed parsing, no retained
values, a constant-size count and digest sink, fixed item width and key
vocabulary, `cache_keys: false`, duplicate rejection disabled, and fixed
parser, GC, and host settings. Run at least five fresh processes at both 256
MiB and 1 GiB. Before any larger run, freeze a ceiling of
`maximum baseline RSS + max(16 MiB, 25% of maximum baseline RSS)`. At least
three fresh runs over 4 GiB must remain below it. Record wide-item, gzip-only,
gzip-plus-parse, and retained-output RSS as separate series and never subtract
process peaks.

Set `FUSED_JSON_TIC_CORPUS` to a local Sunlight
`data/raw/payer-cache` directory for an opt-in compatibility run. Freeze
per-file counts and digests from the existing Oj pipeline before comparison.
Do not copy the corpus into FusedJSON or make it a public CI dependency. The
scale-only manifest, when available, is
`data/raw/tic/palm_beach/florida_blue/manifest.json` in the Sunlight checkout;
its large raw files are not retained locally.

Acceptance: semantic digests match, exact post-`2^32` offsets match, and
current canonical dynamic-parser gates still pass. Run two prescheduled
complete performance and memory campaigns on the same compiler and host, keep
all receipts, and require both to pass. Do not rerun selected failures until a
passing pair appears.

## Milestone 7: Documentation and release review

Update `README.md`, `docs/api.md`, `docs/design.md`, `docs/streaming.md`,
`docs/typed-decoding.md`, `docs/benchmarking.md`, and `CHANGELOG.md`. Document
normal completion, unchecked early exit, two-pass input ownership, gzip
composition, numeric migration, largest-current-value memory, and reproducible
benchmark commands.

CI should run small generated cases and all correctness suites. A scheduled
job may run a 256 MiB generated case and retain measurement artifacts, but
shared-runner timing does not gate releases. The dedicated release host runs
256 MiB, 1 GiB, and greater-than-4-GiB profiles. Add ARM64 and macOS as
reported measurements until dedicated baselines exist.

Close the work only after the documented API, tests, examples, and benchmark
receipts agree. Repeated-document and NDJSON support then returns as a separate
roadmap item.

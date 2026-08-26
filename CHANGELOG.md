# Changelog

All notable changes to FusedJSON are recorded here. The project follows semantic versioning, with the pre-1.0 compatibility policy described in [`docs/api.md`](docs/api.md).

## Unreleased

## 0.2.0 - 2026-08-25

### Added

- Exact `PullParser#raw_number_value` and `#read_raw_number` access for integer and float tokens.
- `PullParser#read(T)` for decoding one typed value at the current String or IO cursor without exposing its sibling to the typed constructor.
- `PullParser#read_array(T)` for synchronous, non-accumulating typed array processing from String or IO cursors.
- Immutable `FusedJSON::Limits` policies for nesting, token and document bytes,
  selected typed-value bytes, total values, per-container entries, and cached
  keys.
- Optional decoded duplicate-key rejection across dynamic, typed, and pull
  parsing, including skipped objects.
- Typed `BigFloat` and exact `BigDecimal` coverage through Crystal's `big/json` adapter, alongside `BigInt`.
- Compile-checked TiC-style plain, caller-wrapped gzip, nested-array, and two-pass workflows, plus typed TiC benchmark modes and cursor-cost diagnostics.
- A release-mode generated-IO check for exact resource-limit offsets after
  byte `2^32` without constructing a 4 GiB `String`.
- Scheduled, report-only large-document measurements on Linux x86-64, Linux
  ARM64, and macOS ARM64.

### Changed

- Compatible built-in scalar `PullParser#read(T)` calls now avoid allocating a
  per-value `JSON::PullParser` adapter on both String and IO cursors.
- Adapter-backed typed reads now copy valid initialized prototypes, preserving
  fresh adapter identity without repeatedly allocating unused stdlib parser
  internals.
- A standalone `max_cached_keys` bound now stays on the fast traversal path and
  checks capacity only when materializing a key; the bound remains inert when
  key caching is disabled.
- Pull traversal and skipping no longer narrow valid numbers until a numeric value is requested. Dynamic `load` and `parse` behavior is unchanged.
- Existing limit keywords remain supported; when they overlap a
  `FusedJSON::Limits` policy, the smaller limit wins.
- Public completion, abandoned-traversal, gzip composition, multi-pass input,
  and large-document memory contracts are now explicit.

### Fixed

- Per-parse key caching now preserves every decoded key across table growth, so
  repeated keys retain identity and exact `max_cached_keys` bounds remain
  reliable beyond the initial cache capacity.

## 0.1.0 - 2026-08-22

### Added

- Strict dynamic parsing into `JSON::Any` from `String` and `IO`.
- Forward-only pull parsing with validating skip operations.
- Typed decoding through Crystal's `JSON::Serializable` constructors, including `BigInt` when `big/json` is loaded.
- UTF-8 validation, bounded nesting, optional key caching, and streaming token limits.
- JSONTestSuite conformance coverage, portable scanner and float fallbacks, release benchmarks, and Crystal 1.21/latest/nightly CI.

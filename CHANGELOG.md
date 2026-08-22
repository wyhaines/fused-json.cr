# Changelog

All notable changes to FusedJSON are recorded here. The project follows semantic versioning, with the pre-1.0 compatibility policy described in [`docs/api.md`](docs/api.md).

## Unreleased

### Added

- Exact `PullParser#raw_number_value` and `#read_raw_number` access for integer and float tokens.
- `PullParser#read(T)` for decoding one typed value at the current String or IO cursor without exposing its sibling to the typed constructor.
- Typed `BigFloat` and exact `BigDecimal` coverage through Crystal's `big/json` adapter, alongside `BigInt`.

### Changed

- Pull traversal and skipping no longer narrow valid numbers until a numeric value is requested. Dynamic `load` and `parse` behavior is unchanged.

## 0.1.0 - 2026-08-22

### Added

- Strict dynamic parsing into `JSON::Any` from `String` and `IO`.
- Forward-only pull parsing with validating skip operations.
- Typed decoding through Crystal's `JSON::Serializable` constructors, including `BigInt` when `big/json` is loaded.
- UTF-8 validation, bounded nesting, optional key caching, and streaming token limits.
- JSONTestSuite conformance coverage, portable scanner and float fallbacks, release benchmarks, and Crystal 1.21/latest/nightly CI.

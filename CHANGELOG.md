# Changelog

All notable changes to FusedJSON are recorded here. The project follows
semantic versioning, with the pre-1.0 compatibility policy described in
[`docs/api.md`](docs/api.md).

## Unreleased

### Added

- Strict dynamic parsing into `JSON::Any` from `String` and `IO`.
- Forward-only pull parsing with validating skip operations.
- Typed decoding through Crystal's `JSON::Serializable` constructors,
  including `BigInt` when `big/json` is loaded.
- UTF-8 validation, bounded nesting, optional key caching, and streaming token
  limits.
- JSONTestSuite conformance coverage, portable scanner and float fallbacks,
  release benchmarks, and Crystal 1.21/latest/nightly CI.

### Changed

- Renamed the pre-release project from OjCrystal to FusedJSON.

The first published release will be `0.1.0`.

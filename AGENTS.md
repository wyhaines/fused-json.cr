# Repository Guidelines

## Project Structure & Module Organization

`src/fused_json.cr` is the public entry point and `FusedJSON` facade. Parser, scanner, pull, typed-adapter, and streaming implementations live under `src/fused_json/`; keep implementation details there unless they are intentionally public. Specs follow the same concerns in `spec/*_spec.cr`, with shared helpers in `spec/support/` and conformance data in `spec/fixtures/`. Runnable usage lives in `examples/`, performance tools in `bench/`, design and API contracts in `docs/`, and release/documentation checks in `scripts/`.

## Build, Test, and Development Commands

- `shards check` verifies dependency resolution.
- `crystal tool format src spec bench examples scripts` formats all Crystal code; add `--check` in CI-style validation.
- `crystal spec --order=random --error-on-warnings` runs the complete randomized suite.
- `crystal spec -Dfused_json_force_portable_float -Dfused_json_force_scalar_string_scan --order=random --error-on-warnings` exercises both portable fallback paths.
- `crystal spec spec/fused_json_spec.cr` runs one focused spec file.
- `crystal run scripts/check_doc_examples.cr` compile-checks documented examples.
- `crystal build --release --no-debug bench/parse.cr -o bin/parse-bench` builds the primary benchmark; see `docs/benchmarking.md` before reporting results.

## Coding Style & Naming Conventions

Use Crystal's formatter and its standard two-space indentation. Name files, methods, and local variables in `snake_case`; use `CamelCase` for modules, classes, structs, and enums. Keep public APIs behind the `FusedJSON` namespace and document them with `#` comments. Preserve strict JSON behavior and the contracts in `docs/design.md` and `docs/api.md`; avoid exposing scanners, adapters, or concrete tree builders without an explicit API decision.

## Testing Guidelines

Use Crystal Spec (`describe`, `it`, and `.should`) and name files `<subject>_spec.cr`. Every behavioral fix needs a focused regression. Cover malformed boundaries as well as successful parsing, and test relevant string, pull, typed, and streaming paths. Parser optimizations must prove result parity before measuring performance. Keep third-party fixture provenance and license files intact.

## Commit & Pull Request Guidelines

History is currently minimal (`Initial commit`), so follow `CONTRIBUTING.md`: make focused commits with short, direct subjects. Pull requests should explain the behavior changed, identify affected APIs, and list validation commands run. Link relevant issues and update public docs or `CHANGELOG.md` when contracts change. Performance claims require reproducible commands and measurements following `docs/benchmarking.md`.

## Security

Report vulnerabilities through the process in `SECURITY.md`, not a public issue. Do not weaken nesting, token-size, UTF-8, or complete-document validation without explicit tests and documentation.

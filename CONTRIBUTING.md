# Contributing

FusedJSON accepts focused fixes, tests, documentation, portability work, and
measured parser improvements. Crystal 1.21 through the current stable 1.x
release is supported.

Before opening a pull request, run:

```console
$ shards install
$ shards build ameba
$ shards check
$ bin/ameba
$ crystal tool format --check src spec bench examples scripts
$ crystal spec --order=random --error-on-warnings
$ crystal spec -Dfused_json_force_portable_float -Dfused_json_force_scalar_string_scan --order=random --error-on-warnings
$ crystal run scripts/check_doc_examples.cr
$ crystal docs --error-on-warnings --output=/tmp/fused-json-docs src/fused_json.cr
```

Add a focused regression for every behavioral fix. Parser optimizations must
verify equal results before timing and cover malformed boundaries affected by
the changed path. Follow [`docs/benchmarking.md`](docs/benchmarking.md) before
making performance claims.

Keep commits focused with short, direct subjects. Do not add attribution
trailers. Pull requests should explain the behavioral change, identify affected
APIs/platforms, link relevant issues, and list validation commands. Update the
changelog and public guides when caller-visible behavior changes.

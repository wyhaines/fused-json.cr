# Release Process

Releases are created deliberately through the manual GitHub `Release` workflow.
The workflow validates the exact selected commit on Crystal 1.21 and latest
stable before creating a `vX.Y.Z` tag and GitHub release. It uploads no
binaries; Shards resolves library releases from Git tags.

The repository's `release` environment must have a required reviewer. The
publish job targets that environment, but the workflow cannot configure its
protection rules.

1. Start from a clean tree and review third-party notices.
2. Set the same version in `shard.yml` and `FusedJSON::VERSION`.
3. Move the relevant changelog entries under a dated version heading.
4. Run `crystal run scripts/check_release.cr -- X.Y.Z`, the full CI matrix,
   documentation checks, the small generated TiC verification, and release
   benchmark builds.
5. On the dedicated release host and stable supported Crystal, run the 256 MiB,
   1 GiB, and greater-than-4-GiB no-retention profiles described in
   [`benchmarking.md`](benchmarking.md). Confirm every release-facing claim names
   its commit and procedure. Scheduled ARM64 and macOS artifacts are report-only.
6. Push the reviewed commit, then manually run the `Release` workflow with the
   version (without `v`) and exact commit SHA. Approve the protected `release`
   environment only after both supported-compiler validation jobs pass.
7. Confirm `vX.Y.Z` and the generated GitHub release point to that SHA, then
   install the tag from a clean sample application and compile a public example.

For a prerelease version containing `-`, the workflow marks the GitHub release
as a prerelease. Never rerun a successful version; release tags are immutable.

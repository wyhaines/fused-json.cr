# Public API and Compatibility

FusedJSON's supported pre-1.0 surface is the `FusedJSON` facade,
`FusedJSON::ParseError`, `FusedJSON::PullParser`, and
`FusedJSON::PullParser::Kind`. The shard name and require path are
`fused_json`; the namespace is `FusedJSON`. Parser, adapter, scanner, and
stream-builder classes not listed here are implementation details even if
Crystal's constant lookup can reach them.

## Entry Points and Options

`load` and its `parse` alias return `JSON::Any`. `from_json` constructs the
requested type, while `PullParser` exposes forward-only events. Every input
must contain exactly one strict JSON document.

| Option | Inputs | Default | Accepted values |
| --- | --- | --- | --- |
| `max_nesting` | `String`, `IO` | `512` | `1..512` |
| `cache_keys` | `String`, `IO` | `false` | `Bool` |
| `buffer_size` | `IO` | `32 * 1024` | `1..16 MiB` |
| `max_token_bytes` | `IO` | `nil` | `nil` or `1..Int32::MAX` |

Options are keyword-only. Key caching is scoped to one parse. The token limit
counts raw bytes for each string or number, including string quotes and escape
spellings; it is not a document-size or result-size limit.

## Error Contract

Invalid option ranges raise `ArgumentError` before an `IO` is read. Invalid
JSON, nesting overflow, token-limit overflow, incompatible pull reads, and pull
block contract violations raise `FusedJSON::ParseError`, a
`JSON::ParseException`. It exposes a zero-based `byte_offset`; inherited line
and column values are one-based. For transcoding IO, offsets count decoded
UTF-8 bytes. IO failures propagate unchanged. Typed constructors and
converters may raise or wrap their own documented exceptions.

Exception classes and location semantics are API. Exact English error messages
are diagnostics and may change.

## Version and Compiler Policy

The supported compiler range is Crystal 1.21 through the current stable 1.x
release. CI tests the exact minimum and latest stable on changes and weekly;
nightly is a non-gating early-warning target, not a supported release. A
minimum-version increase will be recorded in the changelog and made only in a
minor release.

During `0.x`, patch releases preserve documented APIs and behavior. Minor
releases may revise the experimental typed and pull surfaces with changelog and
migration notes. The dynamic facade, option meanings, and error-location
contract are intended to remain source-compatible throughout `0.x`.

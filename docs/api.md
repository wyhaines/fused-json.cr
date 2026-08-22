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

## Typed Pull Reads

`PullParser#read(type : T.class) : T` decodes exactly one value at the current
cursor through `T.new(pull : JSON::PullParser)`. It accepts root values and
values nested in arrays or objects, then leaves the native cursor on the next
sibling, enclosing end event, or document EOF. Object keys, container ends,
and EOF are not value positions and raise `ParseError` without advancing.

The private compatibility adapter presents EOF immediately after the selected
value, so a custom constructor cannot inspect or consume its sibling. Returning
without consuming the complete value is an error. Advancement still performs
the pull reader's normal one-event lookahead, so a malformed or oversized next
string or number can fail the current read before it returns.

A failed typed read never returns a partial `T`, but it is not transactional:
constructor side effects and bytes already consumed cannot be rolled back.
Discard the reader after any constructor or typed-read error. Whole-value raw
converters, ambiguous unions, and discriminators may allocate storage
proportional to the selected value.

`PullParser#read_array(type : T.class, & : T ->) : Nil` consumes the current
array and applies `read(T)` to each element in source order. The parser does
not retain yielded values. A normally returning callback must not advance the
native reader; doing so raises `ParseError` rather than silently skipping an
element.

Normal completion consumes the array end. A callback exception, `break`, or
non-local return does not drain the array or validate the remaining document.
Discard the reader in those cases. Earlier callback effects cannot be rolled
back, so stage output and commit it only after the complete traversal and
`finish` succeed.

## Pull Number Access

The pull reader recognizes a valid JSON number without immediately converting
it. At an `Int` or `Float` event, `raw_number_value : String` returns the exact
source token without advancing. `read_raw_number : String` returns the same
spelling and advances once. Surrounding whitespace is excluded, non-number
events raise `ParseError`, and streaming token limits still apply. Each call
returns an owned `String` proportional to the token; repeated observations need
not return the same object.

`int_value` and `read_int` perform checked `Int64` conversion. `float_value` and
float-event `read_float` require a finite `Float64`; reading an integer event as
a float first performs the checked `Int64` conversion. Skipping or advancing
past a number does not convert it. The dynamic `load` and `parse` APIs retain
their existing `JSON::Any` numeric limits.

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

# Public API and Compatibility

FusedJSON's supported pre-1.0 surface is the `FusedJSON` facade,
`FusedJSON::Limits`, `FusedJSON::ParseError`, `FusedJSON::PullParser`, and
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
| `limits` | `String`, `IO` | `FusedJSON::Limits::DEFAULT` | `FusedJSON::Limits` |

Options are keyword-only. Existing `max_nesting` and streaming
`max_token_bytes` calls remain valid. When one of those keywords and `limits`
both constrain a resource, the smaller value wins. All supplied values are
validated before an `IO` is read.

`FusedJSON::Limits` is immutable and has these fields:

| Field | Default | Meaning |
| --- | --- | --- |
| `max_nesting` | `512` | Container depth, in `1..512` |
| `max_token_bytes` | `nil` | Raw bytes in one string or number token |
| `max_document_bytes` | `nil` | Parser-consumed decoded UTF-8 bytes |
| `max_typed_value_bytes` | `nil` | Raw span of one value selected for typed decoding |
| `max_total_values` | `nil` | Root and each nested scalar, array, or object, once |
| `max_container_entries` | `nil` | Elements or members in each container |
| `max_cached_keys` | `nil` | Distinct decoded keys inserted into the local key pool |
| `reject_duplicate_keys` | `false` | Reject a repeated decoded key within one object |

New byte and count limits accept `0..Int64::MAX`; zero permits no matching
byte, value, entry, or cached key. Token limits remain in
`1..Int32::MAX`. String tokens include their quotes and escape spellings.
Document bytes start at the beginning of a `String` or the current `IO`
position and include whitespace, punctuation, keys, and trailing input. Bytes
fetched into a buffer but not consumed are excluded. Values encountered while
skipping or decoding unknown fields still count. Every array element and object
member counts as one container entry, including duplicate members. The full
contract is recorded in the
[resource-limits decision](resource-limits-decision.md).

Key caching is scoped to one parse. `max_cached_keys` counts actual pool
insertions. With duplicate rejection off, an untyped pull `skip` does not
materialize keys inside the skipped value and therefore does not use that
budget. Duplicate rejection must decode keys even while skipping; when
`cache_keys` is also true, those keys enter the pool and count. The duplicate
sets remain independent of the pool and may retain the same decoded keys in
every open object. The cache limit has no effect when `cache_keys` is false.
Duplicate comparison is case-sensitive and does not normalize Unicode.

## Typed Pull Reads

`PullParser#read(type : T.class) : T` decodes exactly one value at the current
cursor with Crystal's typed semantics. Compatible built-in scalar events use a
native fast path; other values use `T.new(pull : JSON::PullParser)`. It accepts
root values and values nested in arrays or objects, then leaves the native
cursor on the next sibling, enclosing end event, or document EOF. Object keys,
container ends, and EOF are not value positions and raise `ParseError` without
advancing.

For adapter-backed values, the private compatibility adapter presents EOF
immediately after the selected value, so a custom constructor cannot inspect
or consume its sibling. Returning without consuming the complete value is an
error. Scalar fast paths and adapters both perform the pull reader's normal
one-event lookahead, so a malformed or oversized next string or number can
fail the current read before it returns.

`max_typed_value_bytes` counts the selected value's raw span, including
container punctuation and internal whitespace. It excludes surrounding
whitespace and sibling lookahead. `read_array(T)` starts a new budget for each
element. Structural and scalar reads do not select a typed value.

The native reader scans a scalar event before `from_json` or `read(T)` starts
its typed-value budget. The typed limit is then checked retrospectively before
conversion or `T.new`. A syntax, document, or token failure encountered during
that initial scan therefore wins before the typed-value check, even if the
typed boundary would have been earlier.

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

## Pull Completion and Abandonment

A normal root traversal advances through trailing JSON whitespace to EOF. Call
`finish` afterward to assert that state. `finish` is not a drain operation: it
does not consume unread values, complete an abandoned block, or validate a
remaining document tail.

A normally completed nested `read_array` or `read_object` leaves the cursor on
the following sibling or enclosing end event, so continue the enclosing
traversal before calling `finish`. An exception, `break`, non-local return, or
typed-constructor failure can leave unread JSON. Discard the reader in that
case; its caller-owned `IO` may also have been read ahead. For gzip input, the
unread portion includes an unchecked trailer. Stage side effects and commit
them only after every required pass and `finish` succeed.

FusedJSON never closes an input. It does not detect compression or rewind for a
second pass. The caller must open a fresh source and, for compressed data, a
fresh decompressor for each pass. See the
[streaming guide](streaming.md#compressed-and-multi-pass-input).

## Error Contract

Invalid option ranges raise `ArgumentError` before an `IO` is read. Native JSON
syntax, duplicate-key, limit, incompatible-read, and pull-block failures raise
`FusedJSON::ParseError`, a `JSON::ParseException`. Generated
`JSON::Serializable` code may wrap it in `JSON::SerializableError`, with the
native error retained as the cause. Other typed constructors and converters may
raise or wrap their own documented exceptions. IO failures propagate
unchanged.

`ParseError#byte_offset` is zero-based; inherited line and column values are
one-based. For transcoding IO, offsets count decoded UTF-8 bytes.

Document- and typed-value-byte errors point to the first forbidden byte.
Token errors retain the token's opening offset. Value-count errors point to the
first disallowed value. Entry, cache, and duplicate errors point to the opening
of the extra element or offending key. These limits measure parser-visible
source spans and counts, not Crystal heap usage.

When document, typed-value, and token byte limits are active together, the
first forbidden source boundary wins. At an equal boundary, document bytes
take precedence over typed-value bytes, and either source-span limit takes
precedence over token bytes. A limit at an already forbidden byte is reported
before a syntax error at that byte. The retrospective scalar rule above still
applies because its typed-value budget was not active during the initial scan.

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

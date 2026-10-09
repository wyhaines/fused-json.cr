# Repeated-document streams

Status: implemented as an experimental API in 0.4.0. The completed
[implementation plan](repeated-document-plan.md) records its validation and
performance requirements.

## Purpose

FusedJSON currently parses one complete JSON document from a `String` or a
caller-owned `IO`. Completing the root value also requires physical EOF. That
contract detects trailing content, but it is unsuitable for an NDJSON file or
a long-lived stream containing many JSON documents.

The repeated-document reader consumes multiple strict JSON documents from
one `IO` while retaining unread bytes and reusing its input and token buffers.
It supports dynamic `JSON::Any` values and direct typed decoding. Existing
single-document entry points remain unchanged and continue to reject a second
root value.

This work addresses framing and parser reuse. It does not make one large JSON
document smaller; callers processing a large array inside one document should
continue to use `PullParser` and typed cursor reads.

## Formats and terminology

A **document** is one strict JSON text as defined by
[RFC 8259](https://www.rfc-editor.org/rfc/rfc8259). A **record** is the framed
region containing one document. A reader has one framing mode for its entire
lifetime.

The API supports two modes:

- `NDJSON` follows the parsing rules of the
  [NDJSON 1.0 specification](https://github.com/ndjson/ndjson-spec): each
  record contains one JSON text and ends with LF or CRLF.
- `WhitespaceSeparated` accepts complete JSON documents separated by one or
  more JSON whitespace bytes. Unlike NDJSON, a document may span lines.

`WhitespaceSeparated` deliberately requires a separator. Inputs such as
`{}[]` and `truefalse` are rejected instead of being split at inferred token
boundaries. This avoids silently accepting malformed single-document input.

[RFC 7464 JSON Text Sequences](https://www.rfc-editor.org/rfc/rfc7464), which
prefix records with ASCII Record Separator and defines optional recovery from
bad records, are a different format. They are not part of the initial reader.
The framing enum leaves room for a later `JSONSequence` mode without changing
the two contracts above.

## Public API

The facade constructs a reader specialized for one result type:

```text
enum FusedJSON::DocumentFraming
  NDJSON
  WhitespaceSeparated
end

FusedJSON.documents(source : IO, *, framing : DocumentFraming,
                    buffer_size : Int = 32 * 1024,
                    max_nesting : Int = 512,
                    cache_keys : Bool = false,
                    max_token_bytes : Int? = nil,
                    limits : Limits = Limits::DEFAULT) : DocumentReader(JSON::Any)

FusedJSON.documents(source : IO, type : T.class, *,
                    framing : DocumentFraming,
                    buffer_size : Int = 32 * 1024,
                    max_nesting : Int = 512,
                    cache_keys : Bool = false,
                    max_token_bytes : Int? = nil,
                    limits : Limits = Limits::DEFAULT) : DocumentReader(T)

class FusedJSON::DocumentReader(T)
  include Iterator(T)

  getter documents_read : Int64

  def next : T | Iterator::Stop
  def exhausted? : Bool
  def finish : Nil
end
```

Illustrative use:

```text
reader = FusedJSON.documents(
  input,
  Event,
  framing: FusedJSON::DocumentFraming::NDJSON
)
reader.each do |event|
  process(event)
end
reader.finish
```

Omitting the type builds one `JSON::Any` tree per document. Supplying a type
uses Crystal's normal JSON constructors without building that intermediate
tree. Fixing the result type when the reader is created gives Crystal a
specialized iteration path and lets `Iterator::Stop` distinguish exhaustion
even when `T` is `Nil` or includes `Nil`.

The framing argument is required. FusedJSON does not guess from a file name,
media type, or initial bytes. The reader accepts `IO` only; callers with an
in-memory sequence can use `IO::Memory`.

The reader does not expose a per-document pull cursor. Dynamic and
typed iteration cover the intended record-processing use case without adding
another borrowed-cursor lifetime contract. That API can be considered later
if real applications need structural traversal within individually large
records.

## NDJSON framing

The NDJSON mode has the following contract:

- Empty input contains zero documents.
- Every nonempty record contains exactly one JSON value. Objects and arrays
  are not privileged; scalars and `null` are valid roots.
- LF and CRLF terminate records. A lone CR is invalid.
- A record's JSON text cannot contain a raw LF or CR. Pretty-printed,
  multi-line JSON therefore belongs in `WhitespaceSeparated` mode. Escaped
  `\\n` and `\\r` inside strings remain ordinary JSON escapes.
- Space and horizontal tab may surround the root value on its line.
- Empty and space-or-tab-only records are errors. The reader does not silently
  skip them in its initial contract.
- Bytes other than space or horizontal tab after the root and before the line
  ending are trailing-content errors.
- A complete final record may end at physical EOF without LF. This documented
  parser extension accepts the common missing-final-newline case even though
  conforming NDJSON writers should emit the terminator.
- The reader consumes and validates the line ending before returning the
  record. A successfully yielded record is therefore known to satisfy its
  framing contract.

The parser processes the line incrementally. It must not allocate a `String`
containing the complete line, and records may be larger than `buffer_size`.

## Whitespace-separated framing

The whitespace-separated mode has the following contract:

- Empty or whitespace-only input contains zero documents.
- Space, horizontal tab, LF, and CR are the only separators.
- At least one separator byte is required between documents. Leading and
  trailing JSON whitespace are allowed.
- Documents may span lines and may use ordinary JSON whitespace internally.
- Each root may be any JSON value.
- Adjacent roots without whitespace are rejected, even when their individual
  boundaries could be inferred.

After a root is decoded, separator validation occurs when `next` is called
again or when `finish` is called. This lets a self-delimiting record be yielded
without probing physical EOF and avoids blocking on an open source that has
not produced its next record. A missing separator is therefore reported on
the next reader operation, after the preceding document may already have been
delivered.

Numbers still require a following non-number byte or physical EOF before the
scanner can know that their token is complete. A producer of an open
whitespace-separated stream must flush at least one separator after a numeric
record if it expects the consumer to receive that record before the stream
closes.

## Iteration and completion

`next` fully validates and decodes one document or returns `Iterator::Stop` at
a clean end of input. `documents_read` counts only successfully returned
documents. While document N is being decoded, its human-readable number is
`documents_read + 1`.

Reaching `Iterator::Stop` marks the reader exhausted. Later `next` calls keep
returning `Iterator::Stop`, and `finish` is idempotent. `finish` does not parse
or discard unread documents. If iteration stopped early, it permits only the
format's legal trailing framing bytes and raises when another document is
present. It may block while establishing physical EOF.

Because a record is decoded before `Iterator#each` invokes the caller's block,
a block exception or `break` leaves the reader at a document boundary. The
caller may resume iteration. This differs from an early exit inside
`PullParser#read_array`, where the callback shares the parser while an outer
container is still open.

A syntax, limit, IO, or typed-constructor failure leaves the reader
discard-only. It does not attempt to find the next line or record. Automatic
recovery would need a separate, explicitly lossy API, particularly because
whitespace framing has no unambiguous recovery marker.

The reader is forward-only and not safe for concurrent or reentrant use.

## Dynamic and typed semantics

Dynamic iteration has the same value mapping as `FusedJSON.load`: integers
must fit `Int64`, floating values must be finite `Float64`, duplicate members
use the last value unless rejected by policy, and the result is `JSON::Any`.

Typed iteration has the same semantics as `FusedJSON.from_json` and
`PullParser#read(T)`. Native compatible scalars use their direct fast paths;
other types receive a bounded Crystal-compatible pull adapter. A constructor
must consume exactly one complete root value and cannot observe the next
document. Crystal converters, discriminators, strict and unmapped serializable
types, raw converters, and `big/json` integrations retain their existing
behavior.

Every document is completely decoded before it is yielded. The parser does
not retain prior results, but the caller may do so. A dynamic result therefore
retains one complete document tree, while a typed result retains whatever its
constructor requested.

## Performance expectations

Parser reuse removes the per-record input `String`, input buffer, and parser
setup of an `IO#each_line` workaround. It does not guarantee higher throughput.
The dynamic reader builds its tree through the streaming pull path, while
`FusedJSON.load(line)` can use the faster fused `String` parser after
`each_line` has allocated the line. In the initial local diagnostic, dynamic
reader reuse reduced managed allocation but was slower than that FusedJSON line
loop. Typed reader reuse reduced managed allocation and was approximately even
to modestly faster on the repeated-schema profile. Key caching changed both
results according to key cardinality.

Those observations are diagnostic, not release-wide performance claims. Use
[`bench/document_reader.cr`](../bench/document_reader.cr) on representative
records to compare throughput, first-record latency, and allocation. Use
[`bench/document_reader_memory.cr`](../bench/document_reader_memory.cr) in
fresh processes to check no-retention peak RSS without holding a generated
input in memory. The [benchmarking guide](benchmarking.md) gives the controls
and reproduction commands.

## IO ownership and buffering

The reader borrows its `IO` and never closes it. It reads through `IO#read_utf8`,
accepts positive short reads, and treats the first zero-byte read as permanent
EOF, matching the existing streaming contract. Compression, decompression
limits, retries, cancellation, and source lifetime remain caller concerns.

One input buffer is allocated when the reader is constructed and reused for
its lifetime. Unread bytes after a document remain in that buffer. Token
scratch is also reused under the existing retention policy: completed scratch
up to `max(2 * buffer_size, 64 KiB)` may remain, while larger scratch is
released for collection after the token advances.

The reader may fetch bytes belonging to later documents. The underlying IO is
not guaranteed to be positioned at a document boundary. A caller that
abandons the reader also abandons any unread bytes held in its buffer and must
not create a new parser on the same IO expecting to resume exactly.

`buffer_size` keeps its existing range of 1 byte through 16 MiB. A record or
token may exceed that size; the buffer is a refill window, not a document-size
limit.

## Resource limits and key caching

Existing `Limits` options apply without adding a second policy object:

- `max_nesting`, `max_token_bytes`, `max_document_bytes`,
  `max_typed_value_bytes`, `max_total_values`, and
  `max_container_entries` reset for each document.
- In NDJSON mode, `max_document_bytes` counts bytes on the record line,
  including leading and trailing space or tab, but excludes LF or CRLF.
- In whitespace-separated mode, `max_document_bytes` counts the separators
  consumed while seeking the next document plus that document's JSON bytes.
  A whitespace-only tail can therefore exceed the pending document budget
  while the reader is establishing exhaustion.
- `max_typed_value_bytes` covers the selected root value itself and excludes
  framing bytes, as it does for a selected value today.
- Duplicate-key tracking is scoped to each object and is naturally released
  as that object closes.
- With `cache_keys: true`, the key pool is intentionally reader-wide so a
  repeated schema can reuse decoded field names across records.
  `max_cached_keys` therefore bounds distinct pooled keys over the reader's
  lifetime, not separately for every document. With caching disabled, the
  limit remains inert.

There is no built-in document-count, total-stream-byte, CPU-time, or wall-time
limit. Callers can stop the iterator, wrap the IO, or apply
external cancellation. Per-document limits prevent one record from consuming
an unexpected amount of parser-managed work or memory.

All options are validated before the first IO read. Legacy `max_nesting` and
`max_token_bytes` keywords merge with `limits` using the existing smaller-value
rule.

## Errors and locations

JSON grammar, framing, duplicate-key, and limit violations raise
`FusedJSON::ParseError`. Its byte offset remains zero-based and absolute from
the reader's initial IO position. Line and column remain one-based and
stream-global. They do not reset for each document. This makes an error point
directly into the original stream or file.

The reader's `documents_read` value identifies the failing record: the error
occurred while attempting `documents_read + 1`, unless it reports a missing
separator after the last successfully delivered document. Generated
`JSON::Serializable` code may wrap a native parse error in
`JSON::SerializableError`, preserving it as the cause, exactly as it does for
single-document typed decoding. IO failures propagate unchanged.

## Compatibility and non-goals

This feature must not change:

- the complete-document requirement of `load`, `parse`, `from_json`, or
  `PullParser#finish`;
- strict number, Unicode, string, container, and duplicate-key behavior;
- the caller-owned IO and first-zero-is-EOF contracts;
- dynamic numeric compatibility with Crystal;
- existing public error types or locations; or
- the default `cache_keys: false` policy.

The reader does not generate NDJSON, detect compression, recover after
a bad record, multiplex result types, parse records concurrently, support
RFC 7464 framing, or expose a borrowed pull cursor per document.

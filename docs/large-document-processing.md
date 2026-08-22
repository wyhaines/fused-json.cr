# Large-document typed streaming specification

Status: accepted for the next 0.x milestone. Milestones 1 and 2 are implemented.

## Purpose

FusedJSON must be able to process JSON documents that are much larger than
available memory while retaining Crystal's typed decoding and FusedJSON's
strict validation. The first production driver is Sunlight, which reads health
insurance Transparency in Coverage (TiC) files.

TiC is a useful design test, not a special format for FusedJSON. Current TiC
files are single JSON objects. In-network files contain large
`provider_references` and `in_network` arrays; allowed-amount files contain a
large `out_of_network` array. Their elements also contain nested arrays.
Root-array iteration alone would not cover this shape.

## Required API

Add typed decoding at the current `FusedJSON::PullParser` position:

```text
pull.read(type : T.class) : T forall T
pull.read_array(type : T.class, & : T ->) : Nil forall T
pull.raw_number_value : String
pull.read_raw_number : String
```

`read(T)` must accept any value position, including values nested in objects
and arrays. It constructs `T` through the same `JSON::PullParser` interface as
`FusedJSON.from_json`, consumes exactly one value, and leaves the native cursor
on the next sibling, enclosing end event, or document EOF. A custom constructor
must not be able to consume a sibling accidentally. Consuming no value or only
part of one is an error.

The typed `read_array` overload consumes the current array and yields each
fully decoded element in source order. It is synchronous, so the caller
controls backpressure and retains only the values it needs. The existing
untyped block overload remains available.

No lazy `Iterator(T)`, JSONPath selector, root-field registry, or new public
adapter is included in this milestone. The pull API already supplies the
needed structural navigation and skipping.

`raw_number_value` returns the current integer or float token without consuming
it. `read_raw_number` returns that token and advances once. Both methods reject
non-number events, preserve the source spelling exactly, and exclude surrounding
whitespace. They support applications that store an exact number for later
conversion, including values outside `Int128` or `UInt128`. They do not add
general raw-value access for strings, arrays, or objects.

## Example TiC workflow

The intended pattern mixes scalar reads, typed elements, and skipped fields:

```text
pull = FusedJSON::PullParser.new(io)

pull.read_object do |key|
  case key
  when "reporting_entity_name"
    reporting_entity = pull.read_string
  when "provider_references"
    pull.read_array(ProviderReference) { |ref| reference_sink.call(ref) }
  when "in_network"
    pull.read_array(InNetworkItem) { |item| rate_sink.call(item) }
  else
    pull.skip
  end
end
pull.finish
```

JSON object order is not significant. A consumer that needs a complete
provider-reference index before reading rates must reopen the source and make
two passes, selecting one array per pass. FusedJSON does not retain or reorder
root members. The caller owns this orchestration and any on-disk index.

When one outer item is itself too large, the same API can stream at a deeper
level. A bounded consumer can assign sequence IDs and write parent metadata and
children to separate sinks:

```text
item_id = 0_i64
pull.read_array do
  item_id += 1
  pull.read_object do |key|
    case key
    when "billing_code"
      metadata_sink.call(item_id, pull.read_string)
    when "negotiated_rates"
      pull.read_array do
        rate_id = next_rate_id.call
        pull.read_object do |rate_key|
          case rate_key
          when "provider_references"
            pull.read_array(UInt64) { |id| provider_sink.call(rate_id, id) }
          when "negotiated_prices"
            pull.read_array(NegotiatedPrice) do |price|
              price_sink.call(item_id, rate_id, price)
            end
          else
            pull.skip
          end
        end
      end
    else
      pull.skip
    end
  end
end
```

This pattern remains correct when metadata follows a nested array because the
sinks join on the sequence IDs. The application, not FusedJSON, owns those
sinks and their storage limits.

For gzip input, the caller wraps a newly opened file in
`Compress::Gzip::Reader` for each pass. FusedJSON remains transport agnostic,
does not detect archive formats, and never closes caller-owned IO.

## Numeric behavior

Typed reads must support the same numeric targets as `from_json`, including
`UInt128` and `Int128`. Loading `big/json` must also support `BigInt`,
`BigFloat`, and exact `BigDecimal` values. This requires pull events to
recognize valid JSON numbers without immediately narrowing them to the dynamic
`JSON::Any` domain.

This means unmaterialized or skipped pull numbers become range neutral.
`read_int` and `int_value` still require `Int64`; `read_float` and
`float_value` still require a finite `Float64`. Reading an integer through
`read_float` first applies the checked `Int64` conversion, matching the current
Crystal pull behavior. `load` and `parse` keep their existing `JSON::Any`
behavior and reject values outside those domains. This is a pre-1.0 revision
to the experimental pull contract and must be documented in the changelog and
migration guide.

Raw-number reads never perform a numeric conversion. They still require a
grammar-valid JSON number, respect `max_token_bytes` on streaming input, and
allocate a `String` proportional to the token. Repeated access need not return
the same `String` object. A TiC consumer that must defer its numeric policy can
therefore pass `pull.read_raw_number` directly to its decimal or database layer
without first converting through `Int64`, `Int128`, or `Float64`.

## Completion and errors

Normal traversal followed by `finish` validates the complete document,
including trailing input and a gzip trailer read by the caller's wrapper.
Malformed syntax, nesting overflow, token-limit overflow, and incompatible
reads continue to raise `FusedJSON::ParseError`. Typed constructors may raise
or wrap their existing conversion errors. Locations retain the current byte,
line, and column contract.

The current parser primes its next event when a value advances. A completed
element may therefore wait for one-event lookahead before it is yielded. For a
next string or number, that lookahead scans the complete token; it does not
traverse a next array or object. A malformed lookahead token can fail the read
before the completed element is yielded. `max_token_bytes` also applies to
this token.

No partial current element is yielded. A later syntax or IO failure cannot
undo callbacks for earlier elements. Applications that require all-or-nothing
behavior must stage their writes and commit them only after `finish` succeeds.

If a typed constructor or callback raises, or a block exits early, FusedJSON
does not drain the array or validate the remaining document. The reader must
be discarded. Its input remains caller-owned and may have been read ahead.

## Memory contract

With a callback that does not retain results, end-to-end working memory may
depend on:

- the configured input buffer and nesting stack;
- the largest current or lookahead token and current decoded value;
- raw-value replay used by converters, unions, or discriminators;
- distinct cached keys when `cache_keys` is enabled; and
- buffers owned by the input, decompressor, and consumer.

With key caching disabled, FusedJSON-owned memory must not depend on total
document size or total array length. The same guarantee holds with caching only
when the distinct-key vocabulary is bounded. Caller-owned wrappers may have
separate growth rules. A typed outer item can still be large, so callers may
navigate to a smaller nested array before using typed reads. Examples and
benchmarks must describe their results as end-to-end process memory, not parser
memory.

The existing `max_nesting` and streaming `max_token_bytes` options remain in
force. A subsequent limits decision must address document, value, entry, total
value, duplicate-key, and key-cache controls through one coherent API. This
milestone must not add an incompatible one-off item-limit keyword.

## Correctness and performance requirements

- Small typed elements must match `FusedJSON.from_json` and Crystal's typed
  decoder for their shared domain.
- Tests must cover both root-field orders, nested typed reads, unknown-field
  skipping, wide numbers, malformed prefixes and suffixes, truncated gzip,
  short IO reads, and every split of representative values.
- First-element delivery must not traverse the remaining plain input. Tests
  must account for the documented one-event lookahead.
- A known token or intentional error after byte `2^32` must report its exact
  `Int64` offset.
- With fixed-size elements, fixed key vocabulary, key caching disabled, and no
  retained output, end-to-end process peak RSS must remain stable as generated
  input grows from 256 MiB to more than 4 GiB. Wide-element tests must show
  separately that memory follows the largest current value.
- On a controlled release host, typed streaming must have a geometric-mean
  throughput ratio of at least 1.05 against an equivalent Crystal
  standard-library pull implementation. Its one-sided 95% paired-bootstrap
  lower bound must exceed 1.0 on both many-small and wide-item profiles.
  Existing dynamic-parser gates remain unchanged. Ruby/Oj is useful context,
  not a release gate.

Plain drain, plain file plus parsing, gzip decompress-and-drain, gzip plus
parsing, and two-pass results must be reported separately. Do not subtract
drain time or process RSS from another mode. Throughput uses decompressed
bytes; compressed ingress and items per second are additional measurements.
Managed allocation is cumulative work, including construction of discarded
values, rather than live-memory growth. Report it per item or per decompressed
MiB.

## Out of scope

FusedJSON will not validate CMS schemas, download files, detect compression,
resolve provider references, store application rows, or choose a multipass
strategy. NDJSON and concatenated-document reading remain a separate roadmap
item because TiC files contain one document.

## Format references

The design was checked against the CMS-maintained [implementation guide](https://github.com/CMSgov/price-transparency-guide),
[in-network schema](https://github.com/CMSgov/price-transparency-guide/blob/v2.2.1/schemas/in-network-rates/in-network-rates.json),
[allowed-amount schema](https://github.com/CMSgov/price-transparency-guide/blob/v2.2.1/schemas/allowed-amounts/allowed-amounts.json),
and [technical clarifications](https://www.cms.gov/healthplan-price-transparency/resources/technical-clarification).
The parser API is intentionally independent of a specific TiC schema version.

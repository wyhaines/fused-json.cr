# Direct Streaming Tree Design

Stage 2 evaluated routing dynamic `IO` parsing through an eventless tree
consumer while leaving public pull traversal and typed decoding unchanged.
The prototype passed semantic preflight but failed the frozen performance gate,
so the production facade remains pull-backed.

## Shared boundary

`StreamingPullParser` already contains the smallest practical shared scanner
boundary. Its protected operations own refill, positive short-read and
first-zero EOF behavior, decoded byte offsets and locations, token scratch,
UTF-8 and escape validation, number grammar and conversion, key caching, and
resource byte checks. Extracting that code into another object would add a
large behavior-neutral refactor without creating a narrower boundary.

The direct builder therefore derives privately from `StreamingPullParser`,
starts it without priming the pull event state machine, and consumes only those
scanner operations. It adds recursive array/object construction and calls the
same `ResourceLimitState` value, entry, container, duplicate-key, and cache
hooks used by the String tree builder and pull reader. It does not duplicate
number parsing, Unicode decoding, refill logic, cache probes, or byte-limit
accounting.

The existing public `StreamingParser` remains a small facade around the
private builder. This avoids widening its public method surface through
inheritance. `StreamingPullParser` gains only an internal option to suppress
event priming; its public constructor still primes exactly as before.

## State and ownership

The direct path maintains only recursive nesting depth in addition to the
shared scanner state. It does not push pull frames or publish kinds, event
context identifiers, or lazy scalar events. Strings and numbers are
materialized immediately, then token scratch is released using the existing
retention policy. Arrays, hashes, strings, and numbers in the returned
`JSON::Any` are requested output memory; input buffering and reusable scratch
retain their existing bounds.

Construction performs an initial non-consuming value check so the existing
empty-input constructor behavior remains intact. Parsing still validates the
complete document and trailing whitespace. The caller owns the IO throughout.

## Risk and acceptance

The principal risk is divergence in structural punctuation handling and the
order of resource-limit hooks. Differential tests therefore compare String,
direct IO, and an explicit pull-to-tree oracle across every byte split for
valid and malformed documents, then exercise exact limit and location
boundaries. Existing streaming, JSONTestSuite, resource, large-offset, and
scratch-retention suites remain authoritative.

The facade was eligible to switch only if the frozen 12-profile matrix cleared
the Stage 2 10% throughput gate with no semantic, allocation, retained-output
RSS, String, pull, or typed regression.

## Prototype result

Five alternating baseline/candidate pairs produced a 1.064x matrix geometric
mean, below the required 1.10x. Nested profiles improved by 1.14-1.20x and
small-object profiles by about 1.07-1.10x. All four escaped-string profile
medians regressed to 0.936-0.960x, below the 0.98x floor. Managed allocation
remained within the diagnostic tolerance.

The candidate therefore stopped before formal measurement and unaffected
control campaigns. Its source patch, raw receipts, and analysis are preserved
under
`benchmark-data/post-0.2-performance/direct-tree-prototype/`. Production
source was restored to the pull-backed implementation. The result indicates
that structural event removal helps nested input, but token scanning and
materialization dominate the string-heavy path and do not justify the added
second structural consumer under the frozen mixed-workload gate.

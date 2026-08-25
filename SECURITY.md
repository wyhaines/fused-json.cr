# Security Policy

Security fixes are provided for the latest published `0.x` release. The main
branch receives fixes first; older pre-1.0 releases are not maintained in
parallel.

Report suspected vulnerabilities privately through the repository's GitHub
Security Advisory form. If that is unavailable, email `wyhaines@gmail.com`.
Do not open a public issue before a fix or coordinated disclosure is ready.
Include the smallest reproducer, Crystal version, target platform, input source
type, parser options, and observed memory or crash behavior. No response-time
SLA is promised.

For untrusted input, pass a `FusedJSON::Limits` policy. It can bound decoded
document bytes, individual string and number tokens on both `String` and `IO`,
selected typed-value spans, value counts, container entries, and key-cache
growth; it can also reject duplicate keys. These counters describe input
visible to the parser, not exact heap use. They do not bound compressed ingress,
decompressor or caller buffers, returned trees and typed values, callback
retention, or CPU and wall time. See the
[streaming resource limits](docs/streaming.md#memory-bounds) and apply external
compressed-size, time, and output limits as needed.

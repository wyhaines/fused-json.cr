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

For untrusted input, remember that `max_token_bytes` covers individual strings
and numbers on `IO` paths only. It does not cap document bytes, container
entries, key-cache growth, result trees, caller buffers, or CPU time. See the
[streaming resource limits](docs/streaming.md#memory-bounds) and apply
application-level limits as needed.

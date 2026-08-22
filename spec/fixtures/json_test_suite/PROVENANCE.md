# JSONTestSuite Parsing Fixtures

These fixtures are the complete `test_parsing` corpus from Nicolas Seriot's
[JSONTestSuite](https://github.com/nst/JSONTestSuite), retrieved on 2026-08-21
at commit `1ef36fa01286573e846ac449e8683f8833c5b26a`.

The corpus contains 318 files (354,024 content bytes): 95 `y_` documents that
must be accepted, 188 `n_` documents that must be rejected, and 35 `i_`
documents whose acceptance is implementation-defined. The full parsing corpus
is included because it is compact and avoids an arbitrary selection that could
hide parser edge cases. JSONTestSuite's parser adapters, generated results,
article, and transformation corpus are excluded because they are not needed by
the FusedJSON conformance spec.

JSONTestSuite is copyright 2016 Nicolas Seriot and distributed under the MIT
License. The unmodified upstream license is included in `LICENSE` beside this
file.

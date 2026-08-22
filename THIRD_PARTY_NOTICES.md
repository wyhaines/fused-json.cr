# Third-Party Notices

## Crystal standard library

The raw-value replay methods in `src/fused_json/json_pull_adapter.cr` are
adapted from Crystal's `JSON::PullParser` at Crystal 1.21.0, commit
`57cf7da5094db6c5d3c058c6d054a757b5ced19e`. They were modified to consume
FusedJSON's native events, preserve exact numeric spellings, and synchronize
the adapter cursor.

Crystal Programming Language

Copyright 2012-2026 Manas Technology Solutions.

This product includes software developed at Manas Technology Solutions
(<https://manas.tech/>).

Crystal is licensed under the Apache License, Version 2.0, with a Runtime
Library Exception. The Apache-2.0 text is included at
`LICENSES/Apache-2.0.txt`; the exception is included at
`LICENSES/Crystal-runtime-exception.txt`.

## Oj

FusedJSON's design was informed by [Oj](https://github.com/ohler55/oj), a JSON
parser by Peter Ohler. Oj is distributed under the following license:

The MIT License (MIT)

Copyright (c) 2012 Peter Ohler

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## JSONTestSuite

The conformance fixtures under `spec/fixtures/json_test_suite/` come from
[JSONTestSuite](https://github.com/nst/JSONTestSuite), copyright 2016 Nicolas
Seriot, at commit `1ef36fa01286573e846ac449e8683f8833c5b26a`.
JSONTestSuite is distributed under the MIT License. Its unmodified license is
included at `spec/fixtures/json_test_suite/LICENSE`.

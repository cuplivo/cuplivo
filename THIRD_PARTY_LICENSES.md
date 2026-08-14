# Third-party licenses

## Pi — OpenAI Codex device-code OAuth implementation

Cuplivo's Codex device-code OAuth flow is adapted from
[`earendil-works/pi`](https://github.com/earendil-works/pi), specifically
`packages/ai/src/auth/oauth/openai-codex.ts`.

Copyright (c) 2025 Mario Zechner

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Offline web transcript renderer

The committed files under `assets/web_transcript/` contain or derive from the
following exact-pinned packages. Runtime packages and KaTeX fonts are bundled
in application assets; build/test-only packages are not shipped in those
assets. Full redistribution notices are shipped in
`assets/web_transcript/THIRD_PARTY_NOTICES.txt`; exact sources are fixed by
`tool/web_transcript/package-lock.json`.

| Package | Version | Use | License / notice |
|---|---:|---|---|
| `markdown-it` | 14.3.0 | Bundled | MIT, Copyright (c) 2014 Vitaly Puzrin, Alex Kocharin |
| `markdown-it-task-lists` | 2.1.1 | Bundled | ISC, Copyright (c) 2016 Revin Guillen |
| `@vscode/markdown-it-katex` | 1.1.2 | Bundled | MIT, Copyright (c) Microsoft Corporation and named upstream contributors |
| `katex` | 0.16.22 | Bundled code and WOFF2 fonts | MIT, Copyright (c) 2013-2020 Khan Academy and other contributors |
| `highlight.js` | 11.12.0 | Bundled | BSD-3-Clause, Copyright (c) 2006 Ivan Sagalaev |
| `dompurify` | 3.4.13 | Bundled | Apache-2.0 OR MPL-2.0; Cuplivo uses the Apache-2.0 option, Copyright Mario Heiderich and contributors |
| `esbuild` | 0.28.2 | Build only | MIT, Copyright (c) 2020 Evan Wallace |
| `jsdom` | 26.1.0 | Test only | MIT, Copyright (c) 2010 Elijah Insua and contributors |

The MIT, ISC, BSD-3-Clause, Apache-2.0, and MPL-2.0 license identifiers above
refer to their standard SPDX texts. The renderer does not fetch third-party
code or fonts at runtime.

## Pi — xAI (Grok) device-code OAuth implementation

Cuplivo's Grok device-code OAuth flow is adapted from
[`earendil-works/pi`](https://github.com/earendil-works/pi), specifically
`packages/ai/src/auth/oauth/xai.ts` and
`packages/ai/src/auth/oauth/device-code.ts`.

Copyright (c) 2025 Mario Zechner

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

# Third-party licenses

## Termux Android terminal libraries

Cuplivo vendors the `terminal-emulator`, `terminal-view`, and `termux-shared`
modules from [`termux/termux-app`](https://github.com/termux/termux-app) at
commit `30ebb2dee381d292ade0f2868cfde0f9f20b89fe`.

- `terminal-emulator` and `terminal-view` contain Android Terminal Emulator
  code distributed under Apache License 2.0.
- `termux-shared` is primarily MIT licensed. Its
  `src/main/java/com/termux/shared/termux/` subtree is GPLv3-only, with the
  MIT, GPLv2-with-Classpath-exception, and Apache-2.0 exceptions documented in
  the vendored `termux-shared/LICENSE.md`.
- The pinned transitive dependency
  [`termux-am-library:v2.0.0`](https://github.com/termux/termux-am-library) is
  distributed under Apache License 2.0.

Cuplivo's integration code is distributed with the rest of Cuplivo under
AGPL-3.0. The upstream license notices and source attribution are retained in
`android/third_party/termux-app/`. Complete Apache-2.0, MIT, GPL-3.0-only, and
GPL-2.0-with-Classpath-exception texts are retained in its `licenses/`
directory.

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

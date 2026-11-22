# Third-party notices

Cuplivo is licensed under the GNU Affero General Public License v3.0 (`LICENSE`). This file
collects the notices for third-party code that is compiled into, or redistributed as a binary
with, Cuplivo, where the license requires the notice to travel with the product.

It complements, and does not replace, the component-specific notices that ship with the
sandboxes:

- [`ios/sandbox/NOTICE`](ios/sandbox/NOTICE) — iOS Linux sandbox (iSH-ARM64, Alpine rootfs).
- [`android/app/src/main/jniLibs/NOTICE`](android/app/src/main/jniLibs/NOTICE) — Android Linux
  sandbox (PRoot binaries).
- [`dependencies/markstream/THIRD_PARTY_NOTICES.md`](dependencies/markstream/THIRD_PARTY_NOTICES.md)
  — notices for the vendored Markdown renderer package.

## tailcat

Upstream: <https://github.com/tailscale/tailcat> (BSD-3-Clause). Cuplivo embeds it through the
`libtailcat` native library, built from the pinned upstream commit
`7dda9877537278cde7ce9e700e8381436acc92a8`.

Tailcat is Tailscale's embeddable WireGuard tunnel library: it gives two processes ordinary TCP
and UDP sockets over an encrypted point-to-point path, using NAT traversal where possible and
Tailscale's DERP relays as the fallback. Cuplivo uses it for the experimental remote-sync
transport only; the LAN sync path does not use it.

Pinned upstream revision: `7dda9877537278cde7ce9e700e8381436acc92a8` (Go 1.27.4, C ABI 1). The
native libraries are not patched beyond the one build overlay described under *libtailcat*
below.

```
BSD 3-Clause License

Copyright (c) 2020 Tailscale Inc & contributors.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## libtailcat (Cuplivo's fork: `cuplivo/libtailcat`)

Fork: <https://github.com/cuplivo/libtailcat> (BSD-3-Clause), forked from the libtailcat Dart
package by Velzosoft and the libtailcat Dart package authors. Cuplivo pins it to upstream tailcat
commit `7dda9877537278`; the prebuilt native libraries used by the app are release
`native-7dda98775372-1`.

`libtailcat` is a small Dart FFI binding plus the C ABI build (`cmd/libtailcat`, ABI version 1) of
the Tailcat repository. It keeps the platform work out of Cuplivo's Dart code: the app gets
`dart:io`-compatible `Socket`/`ServerSocket` objects and keeps its existing TLS endpoints and sync
protocol unchanged. Cuplivo's fork changes exactly one thing relative to the pinned upstream:
`native/patches/android_ifaces.go`, a build overlay that registers a synthetic network interface
on Android. Android denies apps the netlink socket Go's `net.Interfaces` uses
(golang/go#40569), so Tailcat's region probe dereferences a nil interface; the overlay supplies
the outbound source addresses instead. It is Android-only and is expected to disappear once
upstream lands an equivalent fallback.

### Build provenance

The native binaries redistributed inside Cuplivo are **not built on developers' machines**. They
are built by the `cuplivo/libtailcat` GitHub Actions workflow from the pinned commit and
published as a release tag whose name carries that commit: `native-7dda98775372-1` (the `-1` is
the build number for the same upstream pin). Each publication carries:

- `BUILD_INFO.json` — pinned upstream commit, Go toolchain, C ABI version and per-target build
  metadata;
- `SHA256SUMS` for every platform artifact, verified by the Dart build hook against the hashes
  recorded in the package (`lib/src/hook/native_manifest.dart`);
- GitHub build-provenance attestations, verifiable with
  `gh attestation verify <file> --repo cuplivo/libtailcat`.

The native libraries embed Tailcat **and its dependencies** (the Go runtime, `tailscale.com`,
WireGuard and a userspace network stack). Those dependencies' notices ship with each native
release as `THIRD_PARTY_NOTICES`; Cuplivo does not relicense or modify any of that code. If you
redistribute a Cuplivo build, keep this file and that release's `THIRD_PARTY_NOTICES` with it.

The Dart binding source (`libtailcat`) is distributed under the license below. It has no runtime
network service of its own beyond the Tailcat endpoints it dials; the relay infrastructure is
Tailscale's public DERP service, used as documented in the app.

```
BSD 3-Clause License

Copyright (c) 2026, Velzosoft and the libtailcat Dart package authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Trademarks

WireGuard is a registered trademark of Jason A. Donenfeld. Tailscale and Tailcat are projects of
Tailscale Inc.; Cuplivo is not affiliated with or endorsed by Tailscale.

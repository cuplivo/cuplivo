#!/bin/sh
# Rebuild assets/web_chat/app.bundle.js from app.mjs + protocol.mjs.
#
# The web chat shell must ship as a CLASSIC script (IIFE), not an ES module:
# on iOS, loadFlutterAsset() loads index.html via WKWebView loadFileURL, which
# runs under a file:// origin. WKWebView blocks ES module scripts under file://
# (module fetches are CORS-mode, file:// has an opaque origin), which surfaced
# as `shell_ready_timeout` because app.mjs never executed to post `ready`.
# Classic scripts are unaffected, so we bundle with esbuild and load via a
# plain <script defer> tag. Keep the generated bundle committed: the app loads
# assets straight from the Flutter bundle with no web build step.
#
# Usage: npm install -g esbuild  (or: npx esbuild) && tool/build_web_chat_bundle.sh
set -eu
cd "$(dirname "$0")/.."

ESBUILD="${ESBUILD:-esbuild}"
command -v "$ESBUILD" >/dev/null 2>&1 || ESBUILD="npx esbuild"

"$ESBUILD" assets/web_chat/app.mjs \
  --bundle \
  --format=iife \
  --target=es2020 \
  --outfile=assets/web_chat/app.bundle.js

node --check assets/web_chat/app.bundle.js
echo "OK: assets/web_chat/app.bundle.js rebuilt"

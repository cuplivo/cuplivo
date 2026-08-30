# ADR-0052: Mobile Web Viewport Touch Ownership

The Web conversation shell (ADR-0043) renders chat in a platform WebView, but
mobile touch panning must be owned by that WebView, not by the compensation
stack around it. On Android/iOS we never arm the persistent scroll-stop lock
from touch events and never `preventDefault` early touchmoves; only
programmatically clamped locks (virtual-window loading) keep the
position-pinning behavior. Flutter's gesture arena remains the arbiter of the
vertical/horizontal split, and the desktop wheel path is untouched.

## Decision

`assets/web_chat/app.mjs` detects mobile touch devices
(`isIosTouchDevice` / `isAndroidTouchDevice` → `isTouchNativeOwned`), and
every `stopScrolling()` call now carries an explicit origin
(`'touch'` / `'pointer'` / `'programmatic'`):

- `stopScrolling('touch')` never arms the persistent scroll-stop lock on
  mobile — when no lock is already active (any existing `scrollStopLock` means
  a programmatic clamp, which stays honored and enforced);
- `stopScrolling('pointer')` (mouse/pen) and `'programmatic'` (viewport
  commands, Flutter bridge, web-shared calls) keep locking on every platform,
  so the pre-change semantics of every non-touch transport window are
  preserved exactly — the exemption is touch-origin-only;
- the `touchmove` handlers never call `preventDefault` on mobile, in both the
  virtual-window-loading branch and the hold-phase branch;
- all call sites stay: `touchstart`/`pointerdown` pass the event-derived
  origin, `setRenderBlocked`, `flushMountedUpdates`, and the Kotlin
  `flingScroll(0, 0)` momentum cancel are untouched. The Dart bridge forwards
  the origin through `AndroidWebChatController.stopScrolling(origin)` and the
  Kotlin side whitelists it into one of three fixed scripts (no dynamic
  string interpolation into evaluated JS).

Rationale by platform:

- **iOS (WKWebView)**: `preventDefault()` during the hold phase makes WebKit
  classify the gesture as non-scrolling — the page can then never be dragged.
- **Android (Chromium in a Flutter platform view)**: the native touch stream
  is delivered only after Flutter's arena resolves (the vertical recognizer
  wins around 18px of movement), so arming a lock + `preventDefault` replays a
  stale start against the live pan and reads as the reported "jelly" kick.

Asset version bumps per convention (`web-chat-v17` → `web-chat-v18`) with the
Dart mirror constant and test fixtures updated in the same change. A parallel
iOS-only implementation exists on the unmerged remote branch
`fix/ios-webchat-shell-file-url`; it is considered superseded — the combined
guard here is the canonical form.

## Alternatives rejected

- **EagerGestureRecognizer on the Android platform view**: would claim every
  pointer at down and break the `InteractiveDrawer` contract ("child is
  full-screen draggable", pinned by `android_web_chat_view_test.dart`). The
  vertical-only recognizer stays — this is a deliberate arena split.
- **Removing the stop-scroll layers wholesale**: the Kotlin `flingScroll(0, 0)`
  momentum cancel at `ACTION_DOWN` remains required; the four call sites
  target distinct transport windows. Only the persistent JS lock arming was
  narrowed, not the cancellation behavior.
- **Extra throttling now**: `viewportMetrics` per-frame traffic, the 16ms
  streaming flush, and `renderBlocked` during scroll stay as-is. They are not
  the touch-feel culprit; they remain the ordered next levers if hand-feel
  still complains on devices.

## Consequences

- Mobile touch scroll should no longer fight the native pan: less sponge/kick
  on Android, and iOS can pan at all.
- The origin-exemption is behaviorally pinned by
  `assets/web_chat/test/scroll_handling.test.mjs` (VM harness loading the
  actual shell): Android/iOS touch never arming or canceling, desktop legacy
  still locking and canceling, and a programmatically established clamp
  surviving a mobile touch and staying enforced.
- Residual risk: the arena-buffered Android down is inherent to Flutter
  platform views and unchanged by this decision; residual stall (if any must
  be diagnosed on device — not CI-headless).
- The guard is one shared choke point in JS; when the dead iOS branch is
  eventually merged/closed, the two guards coexist with identical semantics.
- Acceptance is device-only: vertical smoothness, horizontal drawer, virtual
  window paging, streaming during scroll (see delivery notes test matrix).

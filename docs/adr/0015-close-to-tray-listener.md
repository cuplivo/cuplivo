# ADR-0015: Close to tray hides the window; the listener stops on exit, not on hide

**Status:** Accepted (2026-10)
**Deciders:** cuplivo

## Context

Issue #1036: on Windows, with the tray icon and "minimize to tray on close" both enabled, clicking the
window's close button hid the window and stopped the LAN sync listener — port 9527 gone, process still
running — and restoring the window did not bring it back. The panel read "listener not running" until
the app was restarted.

The cause was not the listener; it was what the app believed a close meant:

- **Windows delivers the close as an exit request first.** The engine's lifecycle manager registers
  its top-level window proc delegate in the engine's `Initialize`, before any plugin registers theirs
  (`flutter_windows_engine.cc`). On the process's last window it consumes `WM_CLOSE` itself
  (`windows_lifecycle_manager.cc`, `HandleCloseMessage` → `RequestApplicationQuit` → the message is
  handled), asks the framework, and re-dispatches the close only when the answer is `exit`. So the app
  had already been asked to quit by the time the window hid.
- **The app answered `exit` and flushed.** `AppLifecycleListener.onExitRequested` ran the exit-flush
  registry, which contained `SyncProvider.stop`. A window that only hid therefore tore down its own
  listener, and `stop()` left `_stopRequested` set, so every later `start()` returned after the
  identity load and `started` stayed false — the restore path had no way back.
- **The other desktops do not have this shape.** On Linux `window_manager` installs its own
  `delete-event` handler whose return value is `preventClose` (`window_manager 0.5.2`,
  `linux/window_manager_plugin.cc`, `on_window_close`), and it clears `preventClose` itself before
  closing on `destroy()`; a close-to-tray close either reaches that handler, which stops the emission,
  or the engine's handler (attached at realize, `fl_view.cc`'s `realize_cb`) was already disconnected
  by the plugin at registration. Either way `fl_engine_request_app_exit` does not run while
  close-to-tray is on, so `onWindowClose` is Linux's hide path. On macOS the exit request *is* a
  terminate (Cmd+Q, Dock → Quit, and `destroy()` is `NSApp.terminate`), and the red button never
  reaches it.

This supersedes the parenthetical in ADR-0003's slice-16 amendment that the listener's graceful stop
"is the exit flush's job". That sentence assumed an exit request proves the process is going away.

## Decision

1. **A flush is not a shutdown.** `AppExitFlush` keeps only handlers that *drain* state
   (`businessPreferences.flushPendingWrites`, draft and tool-schema queues, generation progress), each
   harmless for a process that keeps running. Resources that belong to the process — the listener, its
   ephemeral-port firewall rule — register with `AppShutdown`, which runs only on a real exit: the
   tray's Exit item, or an exit request that was not answered as a hide. The two registries are
   independent, and a test asserts a flush never runs a shutdown handler.
2. **`exitRequestHidesToTray` is the single rule for "this close means hide"**: tray setting **and**
   close-to-tray on, not quitting, and a platform whose close actually arrives as an exit request —
   Windows only, per the evidence above. The request handler hides the window and answers `cancel`,
   which is also what stops the engine re-dispatching the close, so the framework is never told "exit"
   while the app keeps running. `preventClose` stays set across a hide: the app is staying alive.
3. **A quit lets the close land.** The engine answers an `exit` decision by re-dispatching the OS
   close, and window_manager consumes that message while `preventClose` is set — which would leave the
   process up with its writes flushed and its shutdown already run. Both real-quit paths (the tray's
   Exit item and an exit request answered as a quit) go through `_allowEngineExit`, which clears the
   gate first. `test/desktop/desktop_tray_close_to_tray_test.dart` drives the real controller over a
   mocked `window_manager` channel and asserts all three branches: hide leaves the gate alone, quit
   clears it, and a hide that throws still lets the quit land.
4. **A window that comes back has a listener.** `ensureListening()` (a resume, the panel opening)
   starts the listener when it is down, and `_start` clears `_stopRequested` — a stop is an event, not
   a permanent property of the provider. This is the repair path for the reported step 5, and it holds
   whichever close path a platform uses. The panel asks from `didChangeDependencies`, i.e. during the
   build phase, so its request is scheduled as a microtask: `start()` notifies before its first
   `await`, and notifying the provider's own ancestor from inside a build is what the framework
   refuses ("setState() or markNeedsBuild() called during build"). `sync_panel_body_test.dart` cannot
   catch that — it overrides `panelOpened` — which is why
   `sync_panel_open_during_build_test.dart` mounts the real panel over a real, unstarted provider.

## Rejected alternatives

- *Keep answering `exit` and rely on window_manager swallowing the re-dispatched close.* That is what
  the app did before this ADR: it works only while the message ordering and `preventClose` stay as
  they are, it tells the framework the app is exiting while it is not, and it is exactly the answer
  that killed the listener.
- *Leave `stop` in the flush registry and skip it in the handler.* The registry would still lie about
  what it holds, and any other caller of `flushAll` — the tray's Exit item already is one — would keep
  tearing the listener down.
- *A "start listener" button on the panel.* The listener is the app's, not the panel's; the user
  should not have to visit a settings screen to undo a hide.
- *Keep Linux in `exitRequestHidesToTray` as "defence in depth".* It is a branch no reachable close
  can take, and it would keep the doc claiming a delivery order the plugin's source contradicts. A
  future plugin that stops intercepting the close is what would add the platform back, together with
  the evidence that makes it testable.

## Consequences

- An ephemeral-port firewall rule is deleted only on a real exit (a hard kill leaked it before this
  change too).
- A window that cannot be hidden falls through to a real quit *that lands*, rather than leaving the
  close button dead; that branch needs the mocked channel to reach, which the desktop test provides.
- `stop()` stays public for tests and for shutdown, with "process teardown only" as its documented
  meaning.
- The tray Exit path runs `AppShutdown` and, on a platform whose close comes back through the exit
  request, runs it a second time; every handler is idempotent (`SyncServer.stop` included).

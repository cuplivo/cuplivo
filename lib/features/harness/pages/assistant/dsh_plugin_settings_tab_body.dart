import 'package:flutter/material.dart';

import '../../models/dsh_remote.dart';
import '../../services/dsh_credential_store.dart';
import '../../services/dsh_surface_harvest.dart';
import '../../widgets/dsh_web_ui_view.dart';

/// The body of one plugin-registered settings tab.
///
/// DSH plugins contribute `settings.section` React slots inside the server's
/// single-page app; the Host protocol has no per-section route or RPC (see
/// `docs/cuplivo-dsh/plugin-compat.md` §6.2b). The only honest way to show the
/// section is therefore the Host's own Web UI, opened on that section: the view
/// loads the origin, runs [DshSurfaceHarvest.settingsScript] with the section's
/// harvested label as the landing target, and posts the section list back into
/// [DshSurfaceInventory] so a Host-side change is picked up next time.
///
/// Cuplivo never knows a plugin's name: the tab exists because the official UI
/// listed a section that is not one of DSH's own, and the label is Host text.
class DshPluginSettingsTabBody extends StatefulWidget {
  const DshPluginSettingsTabBody({
    super.key,
    required this.remote,
    required this.section,
    required this.slug,
    required this.credentials,
    this.onRequestReconnect,
  });

  /// The remote whose official settings dialog is embedded.
  final DshRemote remote;

  /// The harvested `settings.section` entry this tab stands for.
  final DshSurfaceEntry section;

  /// Stable ASCII slug derived from [section]'s label; used for the tab id and
  /// the widget keys (the label itself is Host text and may be any language).
  final String slug;

  /// Where the browser cookie comes from; injected so widget tests stay
  /// hermetic (the real page passes the platform credential store).
  final DshCredentialStore credentials;

  /// Switches the settings page to its connection tab (401 recovery).
  final VoidCallback? onRequestReconnect;

  @override
  State<DshPluginSettingsTabBody> createState() =>
      _DshPluginSettingsTabBodyState();
}

class _DshPluginSettingsTabBodyState extends State<DshPluginSettingsTabBody> {
  String? _cookie;
  bool _preparing = true;

  @override
  void initState() {
    super.initState();
    _readCookie();
  }

  @override
  void didUpdateWidget(DshPluginSettingsTabBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remote.id != widget.remote.id) {
      _readCookie();
    }
  }

  Future<void> _readCookie() async {
    String? cookie;
    try {
      cookie = await widget.credentials.readCookie(widget.remote.id);
    } on Object {
      // A locked keychain is not a page failure: the official UI then shows
      // its own login, which is the same state a never-logged-in remote has.
      cookie = null;
    }
    if (!mounted) return;
    setState(() {
      _cookie = cookie;
      _preparing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.section.label;
    return Padding(
      key: ValueKey<String>('dsh-settings-plugin-body-${widget.slug}'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: _preparing
            ? const Center(child: CircularProgressIndicator())
            : DshWebUiView(
                remote: widget.remote,
                cookie: _cookie,
                initialScript: DshSurfaceHarvest.settingsScript(
                  landLabel: label,
                ),
                scriptMessageHandlerName: DshSurfaceHarvest.channelName,
                showHonestyNote: true,
                onScriptMessage: (raw) => DshSurfaceInventory.shared.accept(
                  widget.remote.authority,
                  raw,
                ),
                onRequestReconnect: widget.onRequestReconnect,
              ),
      ),
    );
  }
}

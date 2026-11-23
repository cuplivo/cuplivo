import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_transport.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../utils/url_launcher_ext.dart';
import '../sync_messages.dart';
import 'sync_peer_card.dart';
import 'tailcat_pairing_dialogs.dart';

/// Where "learn more" about the transport goes.
const String _tailcatLearnMoreUrl = 'https://tailscale.com/tailcat';

/// Where a DERP-server offer or any other feedback lands: the project's issues.
const String _projectFeedbackUrl = 'https://github.com/cuplivo/cuplivo';

/// The experimental remote sync half of the sync settings (ADR-0020).
///
/// Its five sections, in order: this device and its remote listener, the pairing
/// entry, the devices that have a remote endpoint, the remote key, and what the
/// transport is. No address is ever drawn here — the remote address is the
/// capability to reach this device and is only ever shown inside the pairing
/// dialog, behind a disclosure.
class TailcatRemotePanel extends StatefulWidget {
  const TailcatRemotePanel({super.key});

  @override
  State<TailcatRemotePanel> createState() => _TailcatRemotePanelState();
}

class _TailcatRemotePanelState extends State<TailcatRemotePanel> {
  bool _startRequested = false;
  bool _resetting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureStartedWhenVisible();
  }

  /// Starts the remote listener the first time this panel is actually visible.
  ///
  /// Visibility, not mount state: a pane can stay mounted off-screen (the
  /// desktop settings surface keeps pages alive in an `IndexedStack`), and
  /// starting a relay — and minting keys on the first run — for a tab nobody is
  /// looking at is a network cost the user did not ask for. The call is
  /// idempotent, so the guard only keeps it to one attempt per panel instance.
  void _ensureStartedWhenVisible() {
    if (!Visibility.of(context)) {
      // Leaving the pane disarms the one-attempt guard: coming back is the
      // natural retry after a start that failed while the tab was open.
      _startRequested = false;
      return;
    }
    if (_startRequested) return;
    _startRequested = true;
    final provider = context.read<SyncProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(provider.ensureRemoteStarted());
    });
  }

  void _showSnack(String message, NotificationType type) {
    try {
      showAppSnackBar(context, message: message, type: type);
    } catch (_) {
      // No overlay above this point; the panel state itself already changed.
    }
  }

  Future<void> _confirmResetKey() async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.remoteSyncResetTitle),
        content: Text(l10n.remoteSyncResetBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            child: Text(l10n.remoteSyncResetKey),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final provider = context.read<SyncProvider>();
    setState(() => _resetting = true);
    try {
      await provider.resetRemoteKeys();
      if (!mounted) return;
      _showSnack(l10n.remoteSyncResetDone, NotificationType.success);
    } catch (_) {
      // The provider reports the scrubbed reason; the raw exception never
      // reaches this snackbar because it can name the remote address.
      if (!mounted) return;
      _showSnack(
        l10n.remoteSyncResetFailed(
          provider.remoteStartError ?? 'remote sync could not reset',
        ),
        NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<SyncProvider>();
    // Only peers that currently carry a remote endpoint: a peer paired over
    // remote sync whose endpoint was dropped (a key reset) keeps its LAN record
    // and belongs to the LAN tab, so it leaves this list with the endpoint.
    final remotePeers = [
      for (final peer in provider.peers)
        if (peer.endpoints.any(
          (endpoint) => isTailcatEndpointHost(endpoint.host),
        ))
          peer,
    ];
    // The pairing buttons stay live unless an attempt is already running:
    // the dialogs start the listener themselves, and a first start that
    // failed leaves the button as the user's retry entry point.
    final starting = provider.remoteStarting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RemoteSectionHeader(text: l10n.remoteSyncThisDevice),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_RemoteThisDevice(provider: provider)],
        ),

        const SizedBox(height: 12),
        _RemoteSectionHeader(text: l10n.remoteSyncPairSectionTitle),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            Text(
              l10n.remoteSyncPairIntro,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: starting
                      ? null
                      : () => showTailcatPairingCodeDialog(context),
                  icon: Icon(Lucide.KeyRound, size: 16),
                  label: Text(l10n.remoteSyncShowCode),
                ),
                OutlinedButton.icon(
                  onPressed: starting
                      ? null
                      : () => showTailcatEnterCodeDialog(context),
                  icon: Icon(Lucide.Link2, size: 16),
                  label: Text(l10n.remoteSyncEnterCode),
                ),
              ],
            ),
          ],
        ),

        const SizedBox(height: 12),
        _RemoteSectionHeader(text: l10n.remoteSyncPairedDevices),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: remotePeers.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    child: Text(
                      l10n.remoteSyncNoDevices,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ]
              : [
                  for (final (index, peer) in remotePeers.indexed) ...[
                    if (index > 0) _divider(),
                    SyncPeerCard(peer: peer),
                  ],
                ],
        ),

        const SizedBox(height: 12),
        _RemoteSectionHeader(text: l10n.remoteSyncKeySection),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          children: [
            Text(
              l10n.remoteSyncKeyIntro,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _resetting ? null : _confirmResetKey,
                style: TextButton.styleFrom(foregroundColor: cs.error),
                icon: Icon(Lucide.RotateCcw, size: 16),
                label: Text(l10n.remoteSyncResetKey),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),
        _RemoteSectionHeader(text: l10n.remoteSyncAboutSection),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            _AboutParagraph(
              text: l10n.remoteSyncAboutTailcat,
              linkText: l10n.remoteSyncLearnMore,
              url: _tailcatLearnMoreUrl,
            ),
            const SizedBox(height: 10),
            _AboutParagraph(
              text: l10n.remoteSyncAboutTransport,
              linkText: l10n.remoteSyncContactUs,
              url: _projectFeedbackUrl,
            ),
            const SizedBox(height: 10),
            Text(
              l10n.remoteSyncMetadataNote,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// This device's row: what it is called and whether its remote listener is up.
///
/// The remote address is deliberately absent: it is a secret, it lives only in
/// the pairing dialog, and "am I reachable" is what this row answers.
class _RemoteThisDevice extends StatelessWidget {
  const _RemoteThisDevice({required this.provider});

  final SyncProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final colors = context.appColors;

    final String status;
    final Color statusColor;
    if (provider.remoteStarted) {
      status = l10n.remoteSyncStatusRunning;
      statusColor = colors.success;
    } else if (provider.remoteStarting) {
      status = l10n.remoteSyncStatusStarting;
      statusColor = cs.onSurface.withValues(alpha: 0.6);
    } else if (provider.remoteStartError != null) {
      status = l10n.remoteSyncStatusFailed(provider.remoteStartError!);
      statusColor = cs.error;
    } else {
      status = l10n.remoteSyncStatusStopped;
      statusColor = cs.onSurface.withValues(alpha: 0.6);
    }
    final failed = provider.remoteStartError != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              syncPlatformIcon(Platform.operatingSystem),
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.deviceName ?? Platform.localHostname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.92),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        status,
                        maxLines: failed ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One section title, matching the LAN panel's headers: the two halves of the
/// sync surface have to read as one screen.
class _RemoteSectionHeader extends StatelessWidget {
  const _RemoteSectionHeader({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: AppFontWeights.semibold,
          color: cs.onSurface.withValues(alpha: 0.8),
        ),
      ),
    );
  }
}

/// A sentence followed by an inline link, opening [url] in the browser.
class _AboutParagraph extends StatelessWidget {
  const _AboutParagraph({
    required this.text,
    required this.linkText,
    required this.url,
  });

  final String text;
  final String linkText;
  final String url;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$text '),
          TextSpan(
            text: linkText,
            style: TextStyle(
              color: cs.primary,
              fontWeight: AppFontWeights.semibold,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () => unawaited(context.openUrl(url)),
          ),
        ],
      ),
      style: TextStyle(
        fontSize: 13,
        height: 1.4,
        color: cs.onSurface.withValues(alpha: 0.7),
      ),
    );
  }
}

Widget _divider() => const Divider(height: 1, thickness: 0.5, indent: 12);

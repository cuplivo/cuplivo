import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../core/services/sync/sync_local_addresses.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import 'sync_pairing_dialogs.dart';
import 'sync_peer_card.dart';

/// The LAN sync panel, shared by the mobile settings page and the desktop
/// pane: this device, the pairing entry, one card per paired device, and the
/// limits that are true of this slice. Each host owns its own chrome (Scaffold
/// and AppBar on mobile, pane container on desktop) and scroll view.
///
/// Stateful for one reason: while it is mounted, the user is looking at the
/// cards, so [SyncProvider.panelOpened]/[panelClosed] gate the app-level
/// arrival announcements — a toast over a panel that shows the same news would
/// be noise.
class SyncPanelBody extends StatefulWidget {
  const SyncPanelBody({super.key});

  @override
  State<SyncPanelBody> createState() => _SyncPanelBodyState();
}

class _SyncPanelBodyState extends State<SyncPanelBody> {
  @override
  void initState() {
    super.initState();
    context.read<SyncProvider>().panelOpened();
  }

  @override
  void dispose() {
    // `read` (not `watch`) is the documented pattern for a teardown lookup;
    // neither half notifies, so a provider that is already disposed cannot
    // assert on it.
    context.read<SyncProvider>().panelClosed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<SyncProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(text: l10n.lanSyncThisDevice),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_ThisDeviceCard(provider: provider)],
        ),

        if (Platform.isWindows && provider.firewallNeedsElevation) ...[
          const SizedBox(height: 12),
          _SectionHeader(text: l10n.lanSyncFirewallTitle),
          SectionCard(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            children: [
              Row(
                children: [
                  Icon(
                    Lucide.Shield,
                    size: 18,
                    color: context.appColors.warning,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.lanSyncFirewallHint(provider.port ?? 0),
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => provider.elevateFirewall(),
                  child: Text(l10n.lanSyncFirewallFix),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 12),
        _SectionHeader(text: l10n.lanSyncPairSectionTitle),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          children: [
            Text(
              l10n.lanSyncPairIntro,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: provider.started
                      ? () => showSyncPairingDialogs(
                          context: context,
                          showCode: true,
                        )
                      : null,
                  icon: Icon(Lucide.KeyRound, size: 16),
                  label: Text(l10n.lanSyncShowCode),
                ),
                OutlinedButton.icon(
                  onPressed: provider.started
                      ? () => showSyncPairingDialogs(
                          context: context,
                          showCode: false,
                        )
                      : null,
                  icon: Icon(Lucide.Link2, size: 16),
                  label: Text(l10n.lanSyncEnterCode),
                ),
              ],
            ),
          ],
        ),

        const SizedBox(height: 12),
        _SectionHeader(text: l10n.lanSyncPairedDevices),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: provider.peers.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    child: Text(
                      l10n.lanSyncNoDevices,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ]
              : [
                  for (final (index, peer) in provider.peers.indexed) ...[
                    if (index > 0) _divider(),
                    SyncPeerCard(peer: peer),
                  ],
                ],
        ),

        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Lucide.TriangleAlert,
                size: 14,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.lanSyncKnownLimits,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.provider});

  final SyncProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = this.provider;
    final endpoints = [
      for (final address in provider.localAddresses)
        if (provider.port != null)
          formatHostPort(address.address, provider.port!),
    ];

    final String state;
    if (provider.starting) {
      state = l10n.lanSyncListenerStarting;
    } else if (provider.started) {
      state = '${l10n.lanSyncPortLabel}: ${provider.port ?? 0}';
    } else if (provider.startError != null) {
      state = l10n.lanSyncListenerFailed(provider.startError!);
    } else {
      state = l10n.lanSyncListenerNotRunning;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Lucide.RefreshCw,
                size: 20,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  Platform.localHostname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.92),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            state,
            style: TextStyle(
              fontSize: 12,
              color: provider.startError != null
                  ? cs.error
                  : cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          if (provider.started && endpoints.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              l10n.lanSyncPairingEndpointHint,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            for (final endpoint in endpoints)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  endpoint,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFontWeights.medium,
                    color: cs.primary,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

Widget _divider() => const Divider(height: 1, thickness: 0.5, indent: 12);

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
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

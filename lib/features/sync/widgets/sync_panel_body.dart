import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/sync_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/format_bytes.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/tip_icon.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../sync_messages.dart';
import 'sync_pairing_dialogs.dart';
import 'sync_peer_card.dart';

/// The LAN sync panel, shared by the mobile settings page and the desktop
/// pane: this device, the pairing entry, one card per paired device. Each host
/// owns its own chrome (Scaffold and AppBar on mobile, pane container on
/// desktop) and scroll view.
///
/// Stateful for one reason: the user is looking at the cards, so
/// [SyncProvider.panelOpened]/[panelClosed] gate the app-level arrival
/// announcements — a toast over a panel that shows the same news would be
/// noise.
class SyncPanelBody extends StatefulWidget {
  const SyncPanelBody({super.key});

  @override
  State<SyncPanelBody> createState() => _SyncPanelBodyState();
}

class _SyncPanelBodyState extends State<SyncPanelBody> {
  /// The provider as resolved while this element was still active. `dispose`
  /// runs after the element has left the tree, where even a `read` is an
  /// ancestor lookup on an inactive element — one the framework forbids — so
  /// the reference `panelClosed` needs is kept here instead (the framework's
  /// own advice: save it in `didChangeDependencies`).
  SyncProvider? _provider;

  /// Whether this panel currently counts as a viewer of the cards.
  bool _isViewer = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provider ??= context.read<SyncProvider>();
    // Visibility, not mount state: the desktop home page keeps its tabs alive
    // in an `IndexedStack`, so once the user has opened Settings → LAN Sync the
    // panel stays mounted — and would keep counting — after they switch back to
    // the chat tab, muting every arrival for the rest of the launch. Every
    // `IndexedStack` child carries a visibility scope, so this is the signal
    // that follows the user rather than the element tree.
    // `didChangeDependencies` re-runs when it changes, which is where the
    // transition belongs.
    _setViewer(Visibility.of(context));
  }

  void _setViewer(bool visible) {
    if (visible == _isViewer) return;
    _isViewer = visible;
    if (visible) {
      _provider!.panelOpened();
    } else {
      _provider!.panelClosed();
    }
  }

  @override
  void dispose() {
    if (_isViewer) _provider?.panelClosed();
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

        // Workspaces: which folders sync their files, how big they are, and the
        // switch that decides whether their *files* ride. The section is absent
        // until this device has counted them — a row it cannot fill would be a
        // promise the panel cannot keep — and a device with no managed
        // workspace has nothing to say here either.
        if (provider.workspaceSummaries
            case final List<SyncWorkspaceSummary> rows
            when rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionHeader(
            text: l10n.lanSyncWorkspaces,
            tip: l10n.lanSyncWorkspaceTip,
            trailing: l10n.lanSyncWorkspaceSyncing(
              rows.where((row) => row.syncing).length,
            ),
          ),
          SectionCard(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, row) in rows.indexed) ...[
                if (index > 0) _divider(),
                _WorkspaceRow(
                  summary: row,
                  onChanged: (value) =>
                      provider.setWorkspaceContentEnabled(row.id, value),
                ),
              ],
            ],
          ),
        ],

        const SizedBox(height: 12),
        _SectionHeader(
          text: l10n.lanSyncPairSectionTitle,
          tip: l10n.lanSyncPairTrustTip,
        ),
        SectionCard(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            Text(
              l10n.lanSyncPairIntro,
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
        _SectionHeader(
          text: l10n.lanSyncPairedDevices,
          tip: l10n.lanSyncEndpointTip,
        ),
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
        const SizedBox(height: 24),
      ],
    );
  }
}

/// This device's row: what it is called, that its listener is up, and the port
/// it is bound to — and no addresses at all.
///
/// The addresses were the longest, least stable and most repeated string on
/// this screen, and they are not what a user acts on here: they belong to the
/// pairing dialog (where someone types them into the other device) and to each
/// peer's tiles (where they are managed). The one thing this row owes is "am I
/// reachable at all", which the listener state and the port answer.
class _ThisDeviceCard extends StatelessWidget {
  const _ThisDeviceCard({required this.provider});

  final SyncProvider provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = this.provider;

    final String state;
    if (provider.starting) {
      state = l10n.lanSyncListenerStarting;
    } else if (provider.started) {
      state =
          '${syncPlatformLabel(l10n, Platform.operatingSystem)} · '
          '${l10n.lanSyncListening} ${provider.port ?? 0}';
    } else if (provider.startError != null) {
      state = l10n.lanSyncListenerFailed(provider.startError!);
    } else {
      state = l10n.lanSyncListenerNotRunning;
    }

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
                  Platform.localHostname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.92),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  state,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: provider.startError != null
                        ? cs.error
                        : cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _divider() => const Divider(height: 1, thickness: 0.5, indent: 12);

/// One workspace: its name, what it holds, its state, and the switch that
/// decides whether its files sync at all.
///
/// The switch governs the *folder* only, in both directions. The workspace's
/// record always travels — a row this device stopped publishing would be read by
/// the peer as a deletion of its own workspace — so "off" here means "my files
/// stay mine": they are never sent, and a peer-driven deletion of the workspace
/// takes the row here without taking the folder (the session report says how
/// many folders that protected).
class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({required this.summary, required this.onChanged});

  final SyncWorkspaceSummary summary;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    // A workspace over the caps was not walked to the end, so both figures are
    // lower bounds and both are written as such: "2,000+ files · 212 MB+" is
    // true, "12,345 files" would be a number this device never counted.
    final contents =
        '${summary.truncated ? l10n.lanSyncWorkspaceFilesAtLeast(summary.fileCount) : l10n.lanSyncWorkspaceFiles(summary.fileCount)}'
        ' · '
        '${summary.truncated ? l10n.lanSyncWorkspaceSizeAtLeast(formatBytes(summary.totalBytes)) : formatBytes(summary.totalBytes)}';

    final String status;
    final Color tint;
    if (!summary.enabled) {
      status = l10n.lanSyncWorkspaceStatusOff;
      tint = cs.onSurface.withValues(alpha: 0.5);
    } else if (summary.truncated) {
      status = l10n.lanSyncWorkspaceStatusTooLarge;
      tint = context.appColors.warning;
    } else if (summary.unreadable) {
      // Part of the folder could not be read, so this device is not offering
      // it at all this session — and the row has to say so rather than look
      // synced.
      status = l10n.lanSyncWorkspaceStatusUnreadable;
      tint = context.appColors.warning;
    } else {
      status = l10n.lanSyncWorkspaceStatusSyncing;
      tint = cs.primary;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: AppFontWeights.medium,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  contents,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          _WorkspaceStatusChip(text: status, color: tint),
          const SizedBox(width: 4),
          IosSwitch(
            value: summary.enabled,
            onChanged: onChanged,
            semanticLabel: summary.name,
          ),
        ],
      ),
    );
  }
}

/// The one-word state of a workspace: syncing its files, too large to sync,
/// unreadable, or switched off. A pill rather than a bare word because the
/// states sit in a column, and colour is what makes them scannable.
class _WorkspaceStatusChip extends StatelessWidget {
  const _WorkspaceStatusChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

/// One section title, with the section's rules behind a ⓘ instead of a
/// footnote: the explanations are long, they are needed once, and a screen whose
/// every section carries a paragraph of grey text is a screen nobody reads.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.text, this.tip, this.trailing});

  final String text;

  /// The explanation the ⓘ opens, or null for a header that needs none.
  final String? tip;

  /// A short fact that belongs to the whole section, right-aligned: "2 syncing
  /// files". Never a sentence — the ⓘ is where those live.
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 2),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
          if (tip != null) TipIcon(message: tip!),
          if (trailing != null) ...[
            const Spacer(),
            Text(
              trailing!,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/models/director_session.dart';
import '../../../core/services/chat/group_chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../group_chat_navigation.dart';

/// Debug-only page: inspect the hidden director transcript for one group.
///
/// Director activity stays silent on the main chat timeline; this page is the
/// sole user-facing surface for status / state_json / messagesJson.
class GroupDirectorLogPage extends StatefulWidget {
  const GroupDirectorLogPage({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupDirectorLogPage> createState() => _GroupDirectorLogPageState();
}

class _GroupDirectorLogPageState extends State<GroupDirectorLogPage> {
  bool _loading = true;
  DirectorSession? _session;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final svc = context.read<GroupChatService>();
      await svc.ensureLoaded();
      final session = await svc.reloadDirectorSession(widget.groupId);
      if (!mounted) return;
      setState(() {
        _session = session;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  String _formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _prettyJson(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value?.toString() ?? '';
    }
  }

  String _roleLabel(Map<String, dynamic> msg) {
    final role = (msg['role'] ?? '').toString().trim();
    if (role.isEmpty) return 'unknown';
    return role;
  }

  String _messageBody(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is String && content.trim().isNotEmpty) {
      return content;
    }
    if (content != null && content is! String) {
      return _prettyJson(content);
    }
    // Tool / multi-part leftovers without plain content.
    final extras = <String, dynamic>{};
    for (final key in msg.keys) {
      if (key == 'role' || key == 'content') continue;
      extras[key] = msg[key];
    }
    if (extras.isEmpty) return '(empty)';
    return _prettyJson(extras);
  }

  String _buildCopyText(DirectorSession session) {
    final buf = StringBuffer();
    buf.writeln('=== Director session ===');
    buf.writeln('id: ${session.id}');
    buf.writeln('groupId: ${session.groupId}');
    buf.writeln('status: ${session.status}');
    buf.writeln('updatedAt: ${session.updatedAt.toIso8601String()}');
    buf.writeln('createdAt: ${session.createdAt.toIso8601String()}');
    if (session.triggerUserMessageId != null) {
      buf.writeln('triggerUserMessageId: ${session.triggerUserMessageId}');
    }
    if (session.errorText != null && session.errorText!.trim().isNotEmpty) {
      buf.writeln('errorText: ${session.errorText}');
    }
    buf.writeln();
    buf.writeln('--- state ---');
    buf.writeln(_prettyJson(session.state));
    buf.writeln();
    buf.writeln('--- messages (${session.messages.length}) ---');
    for (var i = 0; i < session.messages.length; i++) {
      final m = session.messages[i];
      buf.writeln('[$i] role=${_roleLabel(m)}');
      buf.writeln(_messageBody(m));
      buf.writeln();
    }
    return buf.toString();
  }

  Future<void> _copyAll() async {
    final l10n = AppLocalizations.of(context)!;
    final session = _session;
    if (session == null) return;
    await Clipboard.setData(ClipboardData(text: _buildCopyText(session)));
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: l10n.groupChatDirectorLogCopied,
      type: NotificationType.success,
    );
  }

  Color _roleColor(ColorScheme cs, String role) {
    switch (role) {
      case 'system':
        return cs.tertiary;
      case 'user':
        return cs.primary;
      case 'assistant':
        return cs.secondary;
      case 'tool':
        return cs.error;
      default:
        return cs.onSurface.withValues(alpha: 0.55);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final session = _session;
    final empty =
        !_loading &&
        _loadError == null &&
        (session == null ||
            (session.messages.isEmpty &&
                session.status == DirectorSession.statusIdle &&
                (session.errorText == null ||
                    session.errorText!.trim().isEmpty) &&
                session.state.isEmpty));

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.groupChatBackTooltip,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            minSize: 44,
            onTap: () => closeGroupPage(context),
            semanticLabel: l10n.groupChatBackTooltip,
          ),
        ),
        title: Text(l10n.groupChatDirectorLogTitle),
        actions: [
          Tooltip(
            message: l10n.groupChatDirectorLogCopyAll,
            child: IosIconButton(
              icon: Lucide.Copy,
              size: 20,
              minSize: 44,
              onTap: session == null ? null : _copyAll,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 160),
                  Center(child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              )
            : empty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 80, 24, 40),
                children: [
                  Icon(
                    Lucide.MessagesSquare,
                    size: 40,
                    color: cs.onSurface.withValues(alpha: 0.28),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.groupChatDirectorLogEmpty,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              )
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  if (_loadError != null) ...[
                    _InfoCard(
                      isDark: isDark,
                      child: Text(
                        _loadError!,
                        style: TextStyle(color: cs.error, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (session != null) ...[
                    _sectionTitle(cs, l10n.groupChatDirectorLogMetaSection),
                    const SizedBox(height: 8),
                    _InfoCard(
                      isDark: isDark,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _metaRow(
                            cs,
                            l10n.groupChatDirectorLogStatus,
                            session.status,
                          ),
                          const SizedBox(height: 6),
                          _metaRow(
                            cs,
                            l10n.groupChatDirectorLogUpdatedAt,
                            _formatDateTime(session.updatedAt.toLocal()),
                          ),
                          if (session.triggerUserMessageId != null) ...[
                            const SizedBox(height: 6),
                            _metaRow(
                              cs,
                              'trigger',
                              session.triggerUserMessageId!,
                            ),
                          ],
                          if (session.errorText != null &&
                              session.errorText!.trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              l10n.groupChatDirectorLogError,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: AppFontWeights.emphasis,
                                color: cs.error,
                              ),
                            ),
                            const SizedBox(height: 4),
                            SelectableText(
                              session.errorText!,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: cs.error.withValues(alpha: 0.9),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _sectionTitle(cs, l10n.groupChatDirectorLogStateSection),
                    const SizedBox(height: 8),
                    _InfoCard(
                      isDark: isDark,
                      child: SelectableText(
                        session.state.isEmpty
                            ? '—'
                            : _prettyJson(session.state),
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          fontFamily: 'monospace',
                          color: cs.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    _sectionTitle(
                      cs,
                      l10n.groupChatDirectorLogMessagesSection(
                        session.messages.length,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (session.messages.isEmpty)
                      _InfoCard(
                        isDark: isDark,
                        child: Text(
                          l10n.groupChatDirectorLogEmpty,
                          style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      )
                    else
                      for (var i = 0; i < session.messages.length; i++) ...[
                        _MessageTile(
                          index: i,
                          role: _roleLabel(session.messages[i]),
                          body: _messageBody(session.messages[i]),
                          roleColor: _roleColor(
                            cs,
                            _roleLabel(session.messages[i]),
                          ),
                          isDark: isDark,
                        ),
                        if (i != session.messages.length - 1)
                          const SizedBox(height: 10),
                      ],
                  ],
                ],
              ),
      ),
    );
  }

  Widget _sectionTitle(ColorScheme cs, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: AppFontWeights.emphasis,
        color: cs.onSurface.withValues(alpha: 0.7),
      ),
    );
  }

  Widget _metaRow(ColorScheme cs, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: AppFontWeights.medium,
              color: cs.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.child, required this.isDark});

  final Widget child;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.14 : 0.1),
          width: 0.6,
        ),
      ),
      child: child,
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.index,
    required this.role,
    required this.body,
    required this.roleColor,
    required this.isDark,
  });

  final int index;
  final String role;
  final String body;
  final Color roleColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: isDark ? 0.14 : 0.1),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: roleColor.withValues(alpha: isDark ? 0.22 : 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  role,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: AppFontWeights.emphasis,
                    color: roleColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '#$index',
                style: TextStyle(
                  fontSize: 11.5,
                  color: cs.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            body,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: cs.onSurface.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

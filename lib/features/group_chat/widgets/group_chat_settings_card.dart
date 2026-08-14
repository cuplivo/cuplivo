import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/group_chat.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../pages/group_chat_settings_page.dart';
import 'group_avatar.dart';

/// Card showing a group chat (avatar, name, latest message preview) that
/// opens the group's settings page on tap. Shared by the desktop and mobile
/// assistant settings pages.
class GroupChatSettingsCard extends StatelessWidget {
  const GroupChatSettingsCard({
    super.key,
    required this.group,
    this.radius = 14,
    this.padding = const EdgeInsets.all(12),
    this.avatarSize = 44,
  });

  final GroupChat group;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final preview = context.watch<GroupChatProvider>().latestMessagePreview(
      group.id,
    );
    final baseBg = isDark
        ? Colors.white10
        : Colors.white.withValues(alpha: 0.96);

    return IosCardPress(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GroupChatSettingsPage(groupChatId: group.id),
          ),
        );
      },
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: cs.outlineVariant.withValues(alpha: isDark ? 0.12 : 0.08),
        width: 1.0,
      ),
      baseColor: baseBg,
      pressedScale: 0.98,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            GroupAvatar(
              avatar: group.avatar,
              name: group.name,
              size: avatarSize,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          group.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: AppFontWeights.emphasis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.groupChatDefaultName,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.42),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    preview ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.7),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

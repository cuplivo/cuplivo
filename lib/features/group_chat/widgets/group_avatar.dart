import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../shared/widgets/emoji_text.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/avatar_cache.dart';
import '../../../utils/sandbox_path_resolver.dart';

/// Renders a group chat avatar from its raw value (http URL, local file path
/// or emoji), falling back to the group's first letter. Mirrors
/// [AssistantAvatar]'s resolution logic.
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.avatar,
    required this.name,
    this.size = 44,
  });

  final String? avatar;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatarValue = avatar?.trim() ?? '';
    final displayName = name.trim();

    Widget inner;
    if (avatarValue.isNotEmpty) {
      if (avatarValue.startsWith('http')) {
        inner = FutureBuilder<String?>(
          future: AvatarCache.getPath(avatarValue),
          builder: (context, snapshot) {
            final path = snapshot.data;
            if (path != null && File(path).existsSync()) {
              return ClipOval(
                child: Image(
                  image: FileImage(File(path)),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              );
            }
            return ClipOval(
              child: Image.network(
                avatarValue,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _GroupFallback(cs: cs, name: displayName, size: size),
              ),
            );
          },
        );
      } else if (!kIsWeb &&
          (avatarValue.startsWith('/') || avatarValue.contains(':'))) {
        final fixedPath = SandboxPathResolver.fix(avatarValue);
        final file = File(fixedPath);
        inner = file.existsSync()
            ? ClipOval(
                child: Image(
                  image: FileImage(file),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              )
            : _GroupFallback(cs: cs, name: displayName, size: size);
      } else {
        inner = _GroupEmoji(cs: cs, emoji: avatarValue, size: size);
      }
    } else {
      inner = _GroupFallback(cs: cs, name: displayName, size: size);
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: isDark ? Colors.white24 : Colors.black12,
          width: 0.5,
        ),
      ),
      child: inner,
    );
  }
}

class _GroupFallback extends StatelessWidget {
  const _GroupFallback({
    required this.cs,
    required this.name,
    required this.size,
  });

  final ColorScheme cs;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = name.isNotEmpty ? name.characters.first : 'G';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: cs.primary,
          fontSize: size * 0.42,
          fontWeight: AppFontWeights.emphasis,
        ),
      ),
    );
  }
}

class _GroupEmoji extends StatelessWidget {
  const _GroupEmoji({
    required this.cs,
    required this.emoji,
    required this.size,
  });

  final ColorScheme cs;
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: EmojiText(
        emoji.characters.take(1).toString(),
        fontSize: size * 0.5,
        optimizeEmojiAlign: true,
      ),
    );
  }
}

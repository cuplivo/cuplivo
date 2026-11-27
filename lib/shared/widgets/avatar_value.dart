import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'avatar_image.dart';
import 'emoji_text.dart';

/// Renders one stored avatar value inside whatever shape the caller draws.
///
/// The same string shape means the same thing everywhere: an emoji, an
/// `http(s)` URL, or a local file path (the third one never applies on web).
/// Assistants and group chats both store their avatar this way, so both
/// resolve it here instead of branching twice.
///
/// [fallback] is shown when there is no value, and also when an image fails to
/// load — that is why callers pass their real default (an initial, or a group's
/// member cluster) rather than a placeholder.
class AvatarValue extends StatelessWidget {
  const AvatarValue({
    super.key,
    required this.value,
    required this.size,
    required this.fallback,
  });

  final String? value;
  final double size;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final avatar = value?.trim() ?? '';
    if (avatar.isEmpty) return fallback;
    final isNetwork = avatar.startsWith('http');
    final isPath = !kIsWeb && (avatar.startsWith('/') || avatar.contains(':'));
    if (isNetwork || isPath) {
      return AvatarImage(
        source: avatar,
        isNetwork: isNetwork,
        size: size,
        fallback: fallback,
      );
    }
    return _EmojiAvatar(
      color: Theme.of(context).colorScheme.primary,
      emoji: avatar,
      size: size,
    );
  }
}

class _EmojiAvatar extends StatelessWidget {
  const _EmojiAvatar({
    required this.color,
    required this.emoji,
    required this.size,
  });

  final Color color;
  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
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

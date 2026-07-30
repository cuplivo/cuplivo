import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../theme/app_font_weights.dart';
import '../../utils/avatar_cache.dart';
import '../../utils/sandbox_path_resolver.dart';
import 'emoji_text.dart';

/// Shared avatar renderer for URL, local-file, emoji, and initial values.
class ResolvedAvatar extends StatelessWidget {
  const ResolvedAvatar({
    super.key,
    required this.name,
    this.avatar,
    this.size = 28,
    this.showBorder = false,
    this.fallbackCharacter = '?',
  });

  final String name;
  final String? avatar;
  final double size;
  final bool showBorder;
  final String fallbackCharacter;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final avatarValue = (avatar ?? '').trim();
    final normalizedName = name.trim();
    final child = _resolveAvatar(colorScheme, avatarValue, normalizedName);
    if (!showBorder) return child;
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      child: child,
    );
  }

  Widget _resolveAvatar(
    ColorScheme colorScheme,
    String avatarValue,
    String normalizedName,
  ) {
    if (avatarValue.isEmpty) {
      return _initial(colorScheme, normalizedName);
    }
    if (avatarValue.startsWith('http')) {
      return FutureBuilder<String?>(
        future: AvatarCache.getPath(avatarValue),
        builder: (context, snapshot) {
          final path = snapshot.data;
          if (path != null && File(path).existsSync()) {
            return _file(path);
          }
          return ClipOval(
            child: Image.network(
              avatarValue,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  _initial(colorScheme, normalizedName),
            ),
          );
        },
      );
    }
    if (!kIsWeb && (avatarValue.startsWith('/') || avatarValue.contains(':'))) {
      final fixedPath = SandboxPathResolver.fix(avatarValue);
      return File(fixedPath).existsSync()
          ? _file(fixedPath)
          : _initial(colorScheme, normalizedName);
    }
    return Container(
      width: size,
      height: size,
      decoration: _background(colorScheme),
      alignment: Alignment.center,
      child: EmojiText(
        avatarValue.characters.take(1).toString(),
        fontSize: size * 0.5,
        optimizeEmojiAlign: true,
      ),
    );
  }

  Widget _file(String path) {
    return ClipOval(
      child: Image(
        image: FileImage(File(path)),
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _initial(ColorScheme colorScheme, String normalizedName) {
    final character = normalizedName.isNotEmpty
        ? normalizedName.characters.first
        : fallbackCharacter;
    return Container(
      width: size,
      height: size,
      decoration: _background(colorScheme),
      alignment: Alignment.center,
      child: Text(
        character,
        style: TextStyle(
          color: colorScheme.primary,
          fontSize: size * 0.42,
          fontWeight: AppFontWeights.emphasis,
        ),
      ),
    );
  }

  BoxDecoration _background(ColorScheme colorScheme) => BoxDecoration(
    color: colorScheme.primary.withValues(alpha: 0.15),
    shape: BoxShape.circle,
  );
}

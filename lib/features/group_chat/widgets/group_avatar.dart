import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../shared/widgets/emoji_text.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/avatar_cache.dart';
import '../../../utils/sandbox_path_resolver.dart';

/// Avatar for a group chat room (emoji / url / file / title initial).
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.title,
    this.avatar,
    this.size = 40,
  });

  final String title;
  final String? avatar;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final av = (avatar ?? '').trim();
    final name = title.trim();

    if (av.isNotEmpty) {
      if (av.startsWith('http')) {
        return FutureBuilder<String?>(
          future: AvatarCache.getPath(av),
          builder: (context, snapshot) {
            final path = snapshot.data;
            if (path != null && File(path).existsSync()) {
              return _clipFile(path);
            }
            return ClipOval(
              child: Image.network(
                av,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _initial(cs, name),
              ),
            );
          },
        );
      }
      if (!kIsWeb && (av.startsWith('/') || av.contains(':'))) {
        final fixed = SandboxPathResolver.fix(av);
        final file = File(fixed);
        if (file.existsSync()) {
          return _clipFile(fixed);
        }
        return _initial(cs, name);
      }
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: EmojiText(
          av.characters.take(1).toString(),
          fontSize: size * 0.5,
        ),
      );
    }
    return _initial(cs, name);
  }

  Widget _clipFile(String path) {
    return ClipOval(
      child: Image(
        image: FileImage(File(path)),
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _initial(ColorScheme cs, String name) {
    final letter = name.isNotEmpty ? name.characters.first : '#';
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
          fontWeight: AppFontWeights.emphasis,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

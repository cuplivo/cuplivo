import 'package:flutter/material.dart';

import '../../../core/models/assistant.dart';
import '../../../shared/widgets/resolved_avatar.dart';

class AssistantAvatar extends StatelessWidget {
  const AssistantAvatar({
    super.key,
    required this.assistant,
    this.fallbackName,
    this.size = 28,
  });

  final Assistant? assistant;
  final String? fallbackName;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ResolvedAvatar(
      name: assistant?.name ?? fallbackName ?? '',
      avatar: assistant?.avatar,
      size: size,
      showBorder: true,
    );
  }
}

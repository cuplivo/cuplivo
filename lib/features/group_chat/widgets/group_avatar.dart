import 'package:flutter/material.dart';

import '../../../shared/widgets/resolved_avatar.dart';

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
    return ResolvedAvatar(
      name: title,
      avatar: avatar,
      size: size,
      fallbackCharacter: '#',
    );
  }
}

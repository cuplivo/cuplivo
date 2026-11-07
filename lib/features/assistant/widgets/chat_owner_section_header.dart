import 'package:flutter/material.dart';

import '../../../theme/app_font_weights.dart';

/// The label above one kind of chat owner, drawn when assistants and group
/// chats are shown as separate sections instead of one mixed list.
///
/// Settings › Assistants and groups, the desktop settings pane and the sidebar
/// all read [title] from the same localisation and draw it here, so the three
/// surfaces cannot drift into different type sizes for the same distinction.
class ChatOwnerSectionHeader extends StatelessWidget {
  const ChatOwnerSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: AppFontWeights.emphasis,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

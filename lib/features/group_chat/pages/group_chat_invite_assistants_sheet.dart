import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/responsive/screen_type_helper.dart';
import 'package:Cuplivo/shared/widgets/ios_checkbox.dart';

/// Invite-assistants picker. On mobile it presents a bottom sheet; on desktop
/// it uses a dialog (bottom sheets are not used on desktop).
Future<List<String>?> showGroupChatInviteAssistantsSheet(
  BuildContext context, {
  required Set<String> alreadyInGroup,
  required int softCap,
  required int hardCap,
}) {
  if (ResponsiveHelper.isDesktop(context)) {
    return showDialog<List<String>>(
      context: context,
      builder: (_) => _InviteSheet(
        alreadyInGroup: alreadyInGroup,
        softCap: softCap,
        hardCap: hardCap,
        inDialog: true,
      ),
    );
  }
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _InviteSheet(
      alreadyInGroup: alreadyInGroup,
      softCap: softCap,
      hardCap: hardCap,
    ),
  );
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet({
    required this.alreadyInGroup,
    required this.softCap,
    required this.hardCap,
    this.inDialog = false,
  });

  final Set<String> alreadyInGroup;
  final int softCap;
  final int hardCap;
  final bool inDialog;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final assistants = context
        .watch<AssistantProvider>()
        .assistants
        .where((a) => !widget.alreadyInGroup.contains(a.id))
        .toList();
    final remaining = widget.hardCap - widget.alreadyInGroup.length;

    Widget list = ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.5,
      ),
      child: assistants.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.groupChatNoAssistantsToInvite),
            )
          : ListView.builder(
              shrinkWrap: true,
              itemCount: assistants.length,
              itemBuilder: (context, index) {
                final a = assistants[index];
                final checked = _selected.contains(a.id);
                final wouldExceed =
                    !checked && (_selected.length + 1) > remaining;
                return ListTile(
                  title: Text(a.name),
                  trailing: IosCheckbox(
                    value: checked,
                    onChanged: wouldExceed
                        ? null
                        : (v) {
                            setState(() {
                              if (v) {
                                _selected.add(a.id);
                              } else {
                                _selected.remove(a.id);
                              }
                            });
                          },
                  ),
                  onTap: wouldExceed
                      ? null
                      : () {
                          setState(() {
                            if (checked) {
                              _selected.remove(a.id);
                            } else {
                              _selected.add(a.id);
                            }
                          });
                        },
                );
              },
            ),
    );

    Widget buttons = Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.groupChatCancel),
          ),
        ),
        Expanded(
          child: FilledButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(context, _selected.toList()),
            child: Text(l10n.groupChatConfirm),
          ),
        ),
      ],
    );

    if (widget.inDialog) {
      return AlertDialog(
        title: Text(l10n.groupChatInvite),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [list, const SizedBox(height: 12), buttons],
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.groupChatInvite,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            list,
            const SizedBox(height: 12),
            buttons,
          ],
        ),
      ),
    );
  }
}

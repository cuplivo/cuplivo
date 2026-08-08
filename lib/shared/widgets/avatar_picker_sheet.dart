import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../core/services/haptics.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import 'emoji_picker_dialog.dart';
import 'ios_tactile.dart';
import 'snackbar.dart';

/// Bottom-sheet avatar picker with the same options as the assistant avatar
/// picker: choose image, emoji, link, import from QQ, or reset.
///
/// [onPick] receives the new avatar value (file path / emoji / URL) and
/// [onReset] is invoked when the user chooses to clear the avatar.
Future<void> showAvatarPickerSheet(
  BuildContext context, {
  required ValueChanged<String> onPick,
  required VoidCallback onReset,
}) async {
  final l10n = AppLocalizations.of(context)!;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      final maxH = MediaQuery.of(ctx).size.height * 0.8;
      Widget row(String text, Future<void> Function() action) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SizedBox(
            height: 48,
            child: IosCardPress(
              borderRadius: BorderRadius.circular(14),
              baseColor: cs.surface,
              duration: const Duration(milliseconds: 260),
              onTap: () async {
                Haptics.light();
                Navigator.of(ctx).pop();
                await Future<void>.delayed(const Duration(milliseconds: 10));
                await action();
              },
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.medium,
                  ),
                ),
              ),
            ),
          ),
        );
      }

      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  row(l10n.assistantEditAvatarChooseImage, () async {
                    await _pickLocalImage(context, onPick);
                  }),
                  row(l10n.assistantEditAvatarChooseEmoji, () async {
                    final emoji = await _pickEmoji(context);
                    if (emoji == null || !context.mounted) return;
                    onPick(emoji);
                  }),
                  row(l10n.assistantEditAvatarEnterLink, () async {
                    await _inputAvatarUrl(context, onPick);
                  }),
                  row(l10n.assistantEditAvatarImportQQ, () async {
                    await _inputQQAvatar(context, onPick);
                  }),
                  row(l10n.assistantEditAvatarReset, () async => onReset()),
                  const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<String?> _pickEmoji(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  return showEmojiPickerDialog(
    context,
    title: l10n.assistantEditEmojiDialogTitle,
    hintText: l10n.assistantEditEmojiDialogHint,
  );
}

Future<void> _pickLocalImage(
  BuildContext context,
  ValueChanged<String> onPick,
) async {
  try {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      imageQuality: 85,
    );
    if (!context.mounted || file == null) return;
    onPick(file.path);
  } catch (_) {}
}

Future<void> _inputAvatarUrl(
  BuildContext context,
  ValueChanged<String> onPick,
) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  final controller = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: cs.surface,
        title: Text(l10n.assistantEditImageUrlDialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.assistantEditImageUrlDialogHint,
            filled: true,
            fillColor: Theme.of(ctx).brightness == Brightness.dark
                ? Colors.white10
                : const Color(0xFFF2F3F5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.transparent),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.transparent),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.assistantEditImageUrlDialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.assistantEditImageUrlDialogSave),
          ),
        ],
      );
    },
  );
  if (ok == true) {
    final url = controller.text.trim();
    if (url.isNotEmpty && context.mounted) onPick(url);
  }
}

Future<void> _inputQQAvatar(
  BuildContext context,
  ValueChanged<String> onPick,
) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      String value = '';
      bool valid(String s) => RegExp(r'^[0-9]{5,12}$').hasMatch(s.trim());
      String randomQQ() {
        final lengths = <int>[5, 6, 7, 8, 9, 10, 11];
        final weights = <int>[1, 20, 80, 100, 500, 5000, 80];
        final total = weights.fold<int>(0, (a, b) => a + b);
        final rnd = math.Random();
        int roll = rnd.nextInt(total) + 1;
        int chosenLen = lengths.last;
        int acc = 0;
        for (int i = 0; i < lengths.length; i++) {
          acc += weights[i];
          if (roll <= acc) {
            chosenLen = lengths[i];
            break;
          }
        }
        final sb = StringBuffer();
        final firstGroups = <List<int>>[
          [1, 2],
          [3, 4],
          [5, 6, 7, 8],
          [9],
        ];
        final firstWeights = <int>[128, 4, 2, 1];
        final firstTotal = firstWeights.fold<int>(0, (a, b) => a + b);
        int r2 = rnd.nextInt(firstTotal) + 1;
        int idx = 0;
        int a2 = 0;
        for (int i = 0; i < firstGroups.length; i++) {
          a2 += firstWeights[i];
          if (r2 <= a2) {
            idx = i;
            break;
          }
        }
        final group = firstGroups[idx];
        sb.write(group[rnd.nextInt(group.length)]);
        for (int i = 1; i < chosenLen; i++) {
          sb.write(rnd.nextInt(10));
        }
        return sb.toString();
      }

      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            backgroundColor: cs.surface,
            title: Text(l10n.assistantEditQQAvatarDialogTitle),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                hintText: l10n.assistantEditQQAvatarDialogHint,
                filled: true,
                fillColor: Theme.of(ctx).brightness == Brightness.dark
                    ? Colors.white10
                    : const Color(0xFFF2F3F5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.transparent),
                ),
                enabledBorder: const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                  borderSide: BorderSide(color: Colors.transparent),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: cs.primary.withValues(alpha: 0.4),
                  ),
                ),
              ),
              onChanged: (v) => setLocal(() => value = v),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  const int maxTries = 20;
                  bool applied = false;
                  for (int i = 0; i < maxTries; i++) {
                    final qq = randomQQ();
                    final url =
                        'https://q2.qlogo.cn/headimg_dl?dst_uin=$qq&spec=100';
                    try {
                      final resp = await http
                          .get(Uri.parse(url))
                          .timeout(const Duration(seconds: 5));
                      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
                        onPick(url);
                        applied = true;
                        break;
                      }
                    } catch (_) {}
                  }
                  if (applied) {
                    if (!ctx.mounted) return;
                    if (Navigator.of(ctx).canPop()) {
                      Navigator.of(ctx).pop(false);
                    }
                  } else {
                    if (!context.mounted) return;
                    showAppSnackBar(
                      context,
                      message: l10n.assistantEditQQAvatarFailedMessage,
                      type: NotificationType.error,
                    );
                  }
                },
                child: Text(l10n.assistantEditQQAvatarRandomButton),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(l10n.assistantEditQQAvatarDialogCancel),
              ),
              TextButton(
                onPressed: valid(value)
                    ? () => Navigator.of(ctx).pop(true)
                    : null,
                child: Text(l10n.assistantEditQQAvatarDialogSave),
              ),
            ],
          );
        },
      );
    },
  );
  if (ok == true) {
    final qq = controller.text.trim();
    if (qq.isNotEmpty && context.mounted) {
      onPick('https://q2.qlogo.cn/headimg_dl?dst_uin=$qq&spec=100');
    }
  }
}

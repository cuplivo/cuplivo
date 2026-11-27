import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_font_weights.dart';
import '../../theme/app_semantic_colors.dart';
import 'action_sheet.dart';
import 'emoji_picker_dialog.dart';
import 'snackbar.dart';

/// The five ways any avatar can be set: a local image, an emoji, a link, a QQ
/// number, or back to the default.
///
/// Assistants and group chats use this same entry point, so the menu, the
/// order of its rows, the dialogs behind them and the validation are one
/// implementation. Only the write-back differs, and that is [onSelected].
///
/// Desktop anchors the menu to [anchorKey] (or the screen centre when it is
/// missing); mobile raises the standard action sheet.
Future<void> showAvatarMenu(
  BuildContext context, {
  required String? value,
  required ValueChanged<String?> onSelected,
  GlobalKey? anchorKey,
}) async {
  final l10n = AppLocalizations.of(context)!;

  void run(Future<_AvatarPick?> Function() pick) {
    unawaited(
      pick().then((picked) {
        if (picked == null) return;
        onSelected(picked.cleared ? null : picked.value);
      }),
    );
  }

  await showAdaptiveActionMenu(
    context,
    anchorKey: anchorKey,
    title: null,
    items: [
      ActionSheetItem(
        icon: Lucide.Image,
        label: l10n.assistantEditAvatarChooseImage,
        onTap: () => run(() => _pickImage(context)),
      ),
      ActionSheetItem(
        icon: Lucide.Smile,
        label: l10n.assistantEditAvatarChooseEmoji,
        onTap: () => run(() => _pickEmoji(context)),
      ),
      ActionSheetItem(
        icon: Lucide.Link,
        label: l10n.assistantEditAvatarEnterLink,
        onTap: () => run(() => _inputUrl(context)),
      ),
      ActionSheetItem(
        svgAsset: 'assets/icons/tencent-qq.svg',
        label: l10n.assistantEditAvatarImportQQ,
        onTap: () => run(() => _inputQq(context)),
      ),
      ActionSheetItem(
        icon: Lucide.RotateCw,
        label: l10n.assistantEditAvatarReset,
        onTap: () => run(() async => const _AvatarPick.cleared()),
      ),
    ],
  );
}

/// One menu outcome: a new value, or "back to the default" (`null` value).
class _AvatarPick {
  const _AvatarPick.value(this.value) : cleared = false;
  const _AvatarPick.cleared() : value = null, cleared = true;

  final String? value;
  final bool cleared;
}

Future<_AvatarPick?> _pickEmoji(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final emoji = await showEmojiPickerDialog(
    context,
    title: l10n.assistantEditEmojiDialogTitle,
    hintText: l10n.assistantEditEmojiDialogHint,
  );
  if (emoji == null || emoji.isEmpty) return null;
  return _AvatarPick.value(emoji);
}

Future<_AvatarPick?> _pickImage(BuildContext context) async {
  if (kIsWeb) return _inputUrl(context);
  if (_isDesktopPlatform()) return _pickImageFile(context);
  return _pickImageGallery(context);
}

Future<_AvatarPick?> _pickImageFile(BuildContext context) async {
  try {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
      type: FileType.custom,
      allowedExtensions: const [
        'png',
        'jpg',
        'jpeg',
        'gif',
        'webp',
        'heic',
        'heif',
      ],
    );
    final path = (res != null && res.files.isNotEmpty)
        ? res.files.first.path
        : null;
    if (path == null || path.isEmpty) return null;
    return _AvatarPick.value(path);
  } catch (_) {
    return null;
  }
}

Future<_AvatarPick?> _pickImageGallery(BuildContext context) async {
  try {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 90,
    );
    if (file == null) return null;
    return _AvatarPick.value(file.path);
  } on PlatformException {
    if (!context.mounted) return null;
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: l10n.assistantEditGalleryErrorMessage,
      type: NotificationType.error,
    );
    return _inputUrl(context);
  } catch (_) {
    if (!context.mounted) return null;
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: l10n.assistantEditGeneralErrorMessage,
      type: NotificationType.error,
    );
    return _inputUrl(context);
  }
}

Future<_AvatarPick?> _inputUrl(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final url = await showDialog<String>(
    context: context,
    builder: (_) => _AvatarInputDialog(
      title: l10n.assistantEditImageUrlDialogTitle,
      hintText: l10n.assistantEditImageUrlDialogHint,
      cancelLabel: l10n.assistantEditImageUrlDialogCancel,
      saveLabel: l10n.assistantEditImageUrlDialogSave,
      isValid: (value) {
        final trimmed = value.trim();
        return trimmed.startsWith('http://') || trimmed.startsWith('https://');
      },
    ),
  );
  if (url == null || url.trim().isEmpty) return null;
  return _AvatarPick.value(url.trim());
}

Future<_AvatarPick?> _inputQq(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final url = await showDialog<String>(
    context: context,
    builder: (dialogContext) => _AvatarInputDialog(
      title: l10n.assistantEditQQAvatarDialogTitle,
      hintText: l10n.assistantEditQQAvatarDialogHint,
      cancelLabel: l10n.assistantEditQQAvatarDialogCancel,
      saveLabel: l10n.assistantEditQQAvatarDialogSave,
      randomLabel: l10n.assistantEditQQAvatarRandomButton,
      keyboardType: TextInputType.number,
      isValid: (value) => RegExp(r'^[0-9]{5,12}$').hasMatch(value.trim()),
      transform: (value) => _qqAvatarUrl(value.trim()),
      onRandom: () async {
        final random = await _randomQqAvatarUrl();
        if (random == null && dialogContext.mounted) {
          showAppSnackBar(
            dialogContext,
            message: l10n.assistantEditQQAvatarFailedMessage,
            type: NotificationType.error,
          );
        }
        return random;
      },
    ),
  );
  if (url == null || url.isEmpty) return null;
  return _AvatarPick.value(url);
}

String _qqAvatarUrl(String qq) =>
    'https://q2.qlogo.cn/headimg_dl?dst_uin=$qq'
    '&spec=100';

/// A QQ avatar that actually resolves: the CDN answers 404 for unassigned
/// numbers, so a random pick has to be probed before it is offered.
Future<String?> _randomQqAvatarUrl() async {
  const maxTries = 20;
  for (var i = 0; i < maxTries; i++) {
    final url = _qqAvatarUrl(_randomQqNumber());
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return url;
      }
    } catch (_) {}
  }
  return null;
}

/// Weighted towards the lengths real QQ numbers have, so a random pick is not
/// a five-digit one every time.
String _randomQqNumber() {
  const lengths = <int>[5, 6, 7, 8, 9, 10, 11];
  const weights = <int>[1, 20, 80, 100, 500, 5000, 80];
  const firstGroups = <List<int>>[
    [1, 2],
    [3, 4],
    [5, 6, 7, 8],
    [9],
  ];
  const firstWeights = <int>[128, 4, 2, 1];
  final random = math.Random();
  final length = _weightedPick(random, lengths, weights);
  final first = _weightedPick(random, [
    for (final group in firstGroups) group.first,
  ], firstWeights);
  final buffer = StringBuffer('$first');
  for (var i = 1; i < length; i++) {
    buffer.write(random.nextInt(10));
  }
  return buffer.toString();
}

T _weightedPick<T>(math.Random random, List<T> values, List<int> weights) {
  final total = weights.fold<int>(0, (sum, weight) => sum + weight);
  var roll = random.nextInt(total) + 1;
  for (var i = 0; i < values.length; i++) {
    roll -= weights[i];
    if (roll <= 0) return values[i];
  }
  return values.last;
}

bool _isDesktopPlatform() {
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// One text field with a validating Save, shared by the link and QQ entries.
class _AvatarInputDialog extends StatefulWidget {
  const _AvatarInputDialog({
    required this.title,
    required this.hintText,
    required this.cancelLabel,
    required this.saveLabel,
    required this.isValid,
    this.keyboardType,
    this.transform,
    this.randomLabel,
    this.onRandom,
  });

  final String title;
  final String hintText;
  final String cancelLabel;
  final String saveLabel;
  final bool Function(String value) isValid;
  final TextInputType? keyboardType;
  final String Function(String value)? transform;
  final String? randomLabel;
  final Future<String?> Function()? onRandom;

  @override
  State<_AvatarInputDialog> createState() => _AvatarInputDialogState();
}

class _AvatarInputDialogState extends State<_AvatarInputDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _value => _controller.text;

  bool get _canSave => widget.isValid(_value);

  void _submit() {
    if (!_canSave) return;
    final transformed = widget.transform?.call(_value) ?? _value.trim();
    Navigator.of(context).pop(transformed);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: Colors.transparent),
    );
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: context.overlaySurface,
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: widget.keyboardType,
        decoration: InputDecoration(
          hintText: widget.hintText,
          filled: true,
          fillColor: context.appColors.surfaceFill,
          border: outline,
          enabledBorder: outline,
          focusedBorder: outline.copyWith(
            borderSide: BorderSide(color: cs.primary.withValues(alpha: 0.4)),
          ),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actionsAlignment: widget.onRandom == null
          ? MainAxisAlignment.end
          : MainAxisAlignment.spaceBetween,
      actions: [
        if (widget.onRandom != null)
          TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              final picked = await widget.onRandom!.call();
              if (!mounted || picked == null) return;
              navigator.pop(picked);
            },
            child: Text(widget.randomLabel ?? ''),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(widget.cancelLabel),
            ),
            TextButton(
              onPressed: _canSave ? _submit : null,
              child: Text(
                widget.saveLabel,
                style: TextStyle(
                  color: _canSave
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.38),
                  fontWeight: AppFontWeights.semibold,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

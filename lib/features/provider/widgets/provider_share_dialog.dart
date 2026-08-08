import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:provider/provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart' as lucide;
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/shared/widgets/snackbar.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/utils/clipboard_images.dart';

import 'share_provider_sheet.dart' show encodeProviderConfig;

/// Desktop-style provider share dialog: QR code preview plus "Copy text" /
/// "Copy QR" actions. Used on desktop platforms where the mobile bottom
/// sheet is not appropriate.
Future<void> showProviderShareDialog(
  BuildContext context, {
  required String providerKey,
  required String displayName,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _ProviderShareDialog(
      providerKey: providerKey,
      displayName: displayName,
    ),
  );
}

class _ProviderShareDialog extends StatefulWidget {
  const _ProviderShareDialog({
    required this.providerKey,
    required this.displayName,
  });
  final String providerKey;
  final String displayName;

  @override
  State<_ProviderShareDialog> createState() => _ProviderShareDialogState();
}

class _ProviderShareDialogState extends State<_ProviderShareDialog> {
  late final String _code;
  final GlobalKey _qrKey = GlobalKey();
  bool _copyingQr = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    final cfg =
        settings.providerConfigs[widget.providerKey] ??
        settings.getProviderConfig(
          widget.providerKey,
          defaultName: widget.displayName,
        );
    _code = encodeProviderConfig(cfg);
  }

  Future<void> _copyText() async {
    await Clipboard.setData(ClipboardData(text: _code));
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: AppLocalizations.of(context)!.shareProviderSheetCopiedMessage,
      type: NotificationType.success,
    );
  }

  Future<Uint8List?> _captureQrBytes() async {
    try {
      final boundary =
          _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 3.0);
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } catch (e) {
      debugPrint('showProviderShareDialog: capture QR image failed: $e');
      return null;
    }
  }

  Future<bool> _writeQrToClipboard(Uint8List bytes) async {
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard != null) {
        final item = DataWriterItem(suggestedName: 'provider-qr.png');
        item.add(Formats.png(bytes));
        await clipboard.write([item]);
        return true;
      }
    } catch (e) {
      debugPrint(
        'showProviderShareDialog: write QR to system clipboard '
        'failed: $e',
      );
    }

    try {
      final file = File(
        p.join(
          Directory.systemTemp.path,
          'kelivo-provider-qr-${DateTime.now().millisecondsSinceEpoch}.png',
        ),
      );
      await file.writeAsBytes(bytes, flush: true);
      return await ClipboardImages.setImagePath(file.path);
    } catch (e) {
      debugPrint('showProviderShareDialog: write QR image file failed: $e');
      return false;
    }
  }

  Future<void> _copyQr() async {
    if (_copyingQr) return;
    setState(() => _copyingQr = true);
    bool ok = false;
    try {
      final bytes = await _captureQrBytes();
      if (bytes != null && bytes.isNotEmpty) {
        ok = await _writeQrToClipboard(bytes);
      }
    } catch (e) {
      debugPrint('showProviderShareDialog: copy QR failed: $e');
      ok = false;
    }
    if (!mounted) return;
    setState(() => _copyingQr = false);
    final l10n = AppLocalizations.of(context)!;
    showAppSnackBar(
      context,
      message: ok
          ? l10n.shareProviderSheetCopiedMessage
          : l10n.messageExportSheetExportFailed('copy-failed'),
      type: ok ? NotificationType.success : NotificationType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    return Dialog(
      backgroundColor: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.shareProviderSheetTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    child: _IconBtn(
                      icon: lucide.Lucide.X,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                l10n.shareProviderSheetDescription,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: RepaintBoundary(
                  key: _qrKey,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: cs.outlineVariant.withValues(alpha: 0.2),
                      ),
                    ),
                    child: SizedBox.square(
                      dimension: 180,
                      child: PrettyQrView.data(
                        data: _code,
                        errorCorrectLevel: QrErrorCorrectLevel.M,
                        decoration: const PrettyQrDecoration(
                          shape: PrettyQrSmoothSymbol(roundFactor: 1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.black.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.25),
                  ),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _code,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.35,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _DialogActionButton(
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: l10n.desktopProviderShareCopyText,
                    filled: false,
                    onTap: _copyText,
                  ),
                  const SizedBox(width: 10),
                  _DialogActionButton(
                    icon: _copyingQr
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CupertinoActivityIndicator(radius: 8),
                          )
                        : const Icon(Icons.qr_code_2, size: 18),
                    label: l10n.desktopProviderShareCopyQr,
                    filled: true,
                    onTap: _copyingQr ? null : _copyQr,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatefulWidget {
  const _IconBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = _hover
        ? (isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05))
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 18, color: cs.onSurface),
        ),
      ),
    );
  }
}

class _DialogActionButton extends StatefulWidget {
  const _DialogActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });
  final Widget icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  @override
  State<_DialogActionButton> createState() => _DialogActionButtonState();
}

class _DialogActionButtonState extends State<_DialogActionButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = widget.onTap != null;
    final baseBg = widget.filled ? cs.primary : Colors.transparent;
    final hoverOverlay = widget.filled
        ? Colors.white.withValues(alpha: isDark ? 0.08 : 0.10)
        : cs.primary.withValues(alpha: isDark ? 0.12 : 0.10);
    final bg = Color.alphaBlend(
      (_hover ? hoverOverlay : Colors.transparent),
      baseBg,
    );
    final borderColor = widget.filled
        ? cs.primary.withValues(alpha: isDark ? 0.30 : 0.25)
        : cs.primary.withValues(alpha: 0.35);
    final fg = widget.filled ? cs.onPrimary : cs.primary;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: enabled ? bg : baseBg.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTheme.merge(
                  data: IconThemeData(color: fg, size: 18),
                  child: widget.icon,
                ),
                const SizedBox(width: 8),
                Text(
                  widget.label,
                  style: TextStyle(
                    color: enabled ? fg : fg.withValues(alpha: 0.5),
                    fontSize: 13.5,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

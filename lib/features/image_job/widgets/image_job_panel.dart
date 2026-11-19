/// The panel behind an illustration's header.
///
/// One body serves both shells: a bottom sheet on a phone, `showDialog` with a
/// scrim on a desktop — the same split the tool detail already uses. The body is
/// read-only on purpose: an illustration is an accessory, so it names the model
/// that drew it, the size, the time it took and the prompt, and offers nothing
/// to press but 复制.
///
/// Everything it shows comes from the [ImagePart] first: the part survives a
/// restart, and the live job only fills in what the part cannot know (elapsed
/// time, whether it is still running).
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/message_part.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/responsive/screen_type_helper.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../models/image_job.dart';
import '../services/image_job_coordinator.dart' show imageJobCoordinatorOf;
import '../services/image_model_resolver.dart';

/// Everything the panel needs, resolved once by the caller that has them.
final class ImageJobPanelData {
  const ImageJobPanelData({required this.part, this.job, this.binding});

  final ImagePart part;

  /// Null after a restart: the part is then the only witness.
  final ImageJob? job;
  final ModelBinding? binding;
}

/// Open the panel for [part]. Phone: a draggable sheet. Desktop: a dialog.
Future<void> showImageJobPanel(BuildContext context, ImageJobPanelData data) {
  if (ResponsiveHelper.isDesktop(context)) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.30),
      builder: (ctx) => Dialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          // A prompt is unbounded text: without a ceiling the column grows past
          // the window and the tail of it is unreachable. The phone branch has
          // always scrolled; this one did not.
          constraints: BoxConstraints(
            maxWidth: 340,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            child: ImageJobPanelBody(data: data),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      // Keyboard-safe: the prompt is editable one level down.
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (ctx, controller) => SafeArea(
          top: false,
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      ctx,
                    ).colorScheme.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              ImageJobPanelBody(data: data),
            ],
          ),
        ),
      ),
    ),
  );
}

class ImageJobPanelBody extends StatefulWidget {
  const ImageJobPanelBody({super.key, required this.data});

  final ImageJobPanelData data;

  @override
  State<ImageJobPanelBody> createState() => _ImageJobPanelBodyState();
}

class _ImageJobPanelBodyState extends State<ImageJobPanelBody> {
  ImageJobPanelData get data => widget.data;

  @override
  Widget build(BuildContext context) {
    // The panel is opened with a snapshot — a resolved `ImageJobPanelData` — and
    // `ImageJob` is immutable, so a picture that finishes while the sheet is open
    // would never update "Time taken" or the real pixel size. Subscribe to the
    // coordinator like the card does and read the *live* job each build.
    final coordinator = imageJobCoordinatorOf(context);
    if (coordinator == null) return Builder(builder: _body);
    return ListenableBuilder(
      listenable: coordinator,
      builder: (context, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final part = data.part;
    final coordinator = imageJobCoordinatorOf(context);
    final assetId = part.assetId;
    final job =
        (assetId == null ? null : coordinator?.jobForAsset(assetId)) ??
        data.job;
    final startedAt = job?.startedAt ?? job?.createdAt;
    final finishedAt = job?.finishedAt;
    final elapsed = startedAt == null || finishedAt == null
        ? null
        : finishedAt.difference(startedAt);
    final muted = cs.onSurface.withValues(alpha: 0.6);
    final body = TextStyle(fontSize: 13, color: cs.onSurface);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Full width, explicitly: the ✕ sat at ~two thirds of the panel because
        // this row was shrinking to its content, and a Flexible title lets that
        // happen. Expanded forces it to the incoming width instead.
        SizedBox(
          width: double.infinity,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.imageJobTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: AppFontWeights.semibold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // A bare IconButton keeps 8-ish px of its own padding, so the glyph
              // never reaches the panel's right edge and reads as misplaced
              // against the content below it.
              Semantics(
                button: true,
                label: MaterialLocalizations.of(context).closeButtonTooltip,
                child: InkResponse(
                  onTap: () => Navigator.of(context).maybePop(),
                  radius: 16,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Lucide.X, size: 18, color: muted),
                  ),
                ),
              ),
            ],
          ),
        ),
        _KvRow(
          label: l10n.imageJobPanelModelLabel,
          value: imageModelDisplayName(
            context.read<SettingsProvider>(),
            data.binding,
            fallbackKey: part.model,
          ),
        ),
        _KvRow(
          label: l10n.imageJobPanelSizeLabel,
          value: null,
          child: _ImageSize(
            uri: part.uri,
            requestedRatio: job?.aspectRatio,
            revision: finishedAt?.microsecondsSinceEpoch,
          ),
        ),
        if (elapsed != null)
          _KvRow(
            label: l10n.imageJobPanelElapsedLabel,
            value: '${(elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
          ),
        // Usage sits here rather than in the header: today it is one picture,
        // and a picture is eventually also a token count — the same row has to
        // be able to say either.
        _KvRow(
          label: l10n.imageJobPanelUsageLabel,
          value: l10n.imageJobPanelOneImage,
        ),
        Divider(height: 22, color: cs.onSurface.withValues(alpha: 0.08)),
        Row(
          children: [
            Text(
              l10n.imageJobPanelPromptLabel,
              style: TextStyle(fontSize: 12, color: muted),
            ),
            const Spacer(),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
                textStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 12),
              ),
              onPressed: () => _copy(context),
              child: Text(l10n.imageJobPanelCopy),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(part.prompt ?? '', style: body.copyWith(height: 1.6)),
        ),
      ],
    );
  }

  Future<void> _copy(BuildContext context) async {
    final prompt = data.part.prompt ?? '';
    if (prompt.isEmpty) return;
    // Same confirmation every other copy in the app gives: the app's own toast
    // at the top of the screen, not a Material snackbar at the bottom.
    await copyTextWithConfirmation(
      context,
      prompt,
      message: AppLocalizations.of(context)!.chatMessageWidgetCopiedToClipboard,
    );
  }
}

class _KvRow extends StatelessWidget {
  const _KvRow({required this.label, this.value, this.child});

  final String label;
  final String? value;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 12),
          // One value column, right-aligned as a whole: a Spacer in front of a
          // loose Flexible sized each value to its own text, so a long model
          // name and a short "自动" ended at different x.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: child != null
                  ? child!
                  : Text(
                      value ?? '—',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The picture's real pixel size, decoded from the file when there is one.
///
/// A promise has no size yet, so it shows the ratio that was asked for — the
/// only honest answer before the bytes exist.
class _ImageSize extends StatefulWidget {
  const _ImageSize({required this.uri, this.requestedRatio, this.revision});

  final String uri;
  final String? requestedRatio;

  /// Changes when the picture may have landed (the job's finish stamp). The
  /// probe runs once per revision, so an open panel picks up the real pixels
  /// instead of keeping the requested ratio forever.
  final int? revision;

  @override
  State<_ImageSize> createState() => _ImageSizeState();
}

class _ImageSizeState extends State<_ImageSize> {
  String? _size;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(covariant _ImageSize oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri || oldWidget.revision != widget.revision) {
      unawaited(_resolve());
    }
  }

  Future<void> _resolve() async {
    final ratio = widget.requestedRatio;
    try {
      // The part's uri is whatever the resolver canonicalised, which for a file
      // under the content root is a `kelivo-file:///…` URI — a bare File() of
      // that never exists, and the row would quietly report the requested ratio
      // for every picture. Every other reader in the app runs fix() first.
      final file = File(SandboxPathResolver.fix(widget.uri));
      if (!await file.exists()) {
        _set(ratio == null || ratio == 'auto' ? _autoLabel() : ratio);
        return;
      }
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final width = frame.image.width;
      final height = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      _set('$width × $height');
    } catch (_) {
      _set(null);
    }
  }

  String? _autoLabel() {
    if (!mounted) return null;
    return AppLocalizations.of(context)?.imageJobPanelAuto;
  }

  void _set(String? value) {
    if (!mounted) return;
    setState(() => _size = value);
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _size ?? '—',
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurface,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// The name a configured image model shows under, falling back to the raw id.
///
/// [binding] is live when the job still exists; [fallbackKey] is the
/// `provider::model` string a part carries, so the row still names something
/// true after a restart.
String imageModelDisplayName(
  SettingsProvider settings,
  ModelBinding? binding, {
  String? fallbackKey,
}) {
  var providerId = binding?.providerId ?? '';
  var modelId = binding?.modelId ?? '';
  if (modelId.isEmpty && fallbackKey != null && fallbackKey.contains('::')) {
    final split = fallbackKey.split('::');
    providerId = split.first;
    modelId = split.sublist(1).join('::');
  }
  if (modelId.isEmpty) return '—';
  try {
    final config = settings.getProviderConfig(providerId);
    final override = config.modelOverrides[modelId] as Map?;
    final name = (override?['name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) return name;
    final apiId = (override?['apiModelId'] ?? override?['api_model_id'])
        ?.toString()
        .trim();
    if (apiId != null && apiId.isNotEmpty) return apiId;
  } catch (_) {}
  return modelId;
}

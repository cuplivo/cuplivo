import 'package:flutter/material.dart';

import '../../../core/models/backup.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

enum BackupChannel { webdav, s3 }

/// Result of a channel test-connection click, rendered inline in the dialog
/// (a SnackBar would hide behind the sheet/dialog barrier).
class ChannelTestResult {
  const ChannelTestResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// Dual-shell (mobile bottom sheet / desktop centered dialog) editor for one
/// backup channel's connection form. The form is a controlled input copied
/// from `settings` on open; [onSave] persists the resulting config.
class BackupChannelConfigDialog extends StatefulWidget {
  const BackupChannelConfigDialog({
    super.key,
    required this.channel,
    this.webdavCfg,
    this.s3Cfg,
    this.onTestWebDav,
    this.onTestS3,
    this.onSaveWebDav,
    this.onSaveS3,
    this.isSheet = false,
  });

  final BackupChannel channel;
  final WebDavConfig? webdavCfg;
  final S3Config? s3Cfg;

  /// Test-connection callbacks receiving the typed DRAFT config. The test
  /// must not persist anything — only 保存 writes; `onSaveWebDav`/`onSaveS3`
  /// own the side-effects (persist + auto-select channel).
  final Future<ChannelTestResult> Function(WebDavConfig cfg)? onTestWebDav;
  final Future<ChannelTestResult> Function(S3Config cfg)? onTestS3;
  final Future<void> Function(WebDavConfig cfg)? onSaveWebDav;
  final Future<void> Function(S3Config cfg)? onSaveS3;
  final bool isSheet;

  /// Desktop: centered dialog.
  static Future<void> show(
    BuildContext context, {
    required BackupChannel channel,
    WebDavConfig? webdavCfg,
    S3Config? s3Cfg,
    Future<ChannelTestResult> Function(WebDavConfig cfg)? onTestWebDav,
    Future<ChannelTestResult> Function(S3Config cfg)? onTestS3,
    Future<void> Function(WebDavConfig cfg)? onSaveWebDav,
    Future<void> Function(S3Config cfg)? onSaveS3,
  }) {
    final cs = Theme.of(context).colorScheme;
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          // Fields would otherwise stretch to nearly full screen on desktop.
          constraints: const BoxConstraints(maxWidth: 480),
          child: BackupChannelConfigDialog(
            channel: channel,
            webdavCfg: webdavCfg,
            s3Cfg: s3Cfg,
            onTestWebDav: onTestWebDav,
            onTestS3: onTestS3,
            onSaveWebDav: onSaveWebDav,
            onSaveS3: onSaveS3,
            isSheet: false,
          ),
        ),
      ),
    );
  }

  /// Mobile: bottom sheet.
  static Future<void> showSheet(
    BuildContext context, {
    required BackupChannel channel,
    WebDavConfig? webdavCfg,
    S3Config? s3Cfg,
    Future<ChannelTestResult> Function(WebDavConfig cfg)? onTestWebDav,
    Future<ChannelTestResult> Function(S3Config cfg)? onTestS3,
    Future<void> Function(WebDavConfig cfg)? onSaveWebDav,
    Future<void> Function(S3Config cfg)? onSaveS3,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        top: false,
        child: BackupChannelConfigDialog(
          channel: channel,
          webdavCfg: webdavCfg,
          s3Cfg: s3Cfg,
          onTestWebDav: onTestWebDav,
          onTestS3: onTestS3,
          onSaveWebDav: onSaveWebDav,
          onSaveS3: onSaveS3,
          isSheet: true,
        ),
      ),
    );
  }

  @override
  State<BackupChannelConfigDialog> createState() =>
      _BackupChannelConfigDialogState();
}

class _BackupChannelConfigDialogState extends State<BackupChannelConfigDialog> {
  static const String _defaultPath = 'kelivo_backups';

  // WebDAV
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _path;
  late final TextEditingController _webDavUserAgent;

  // S3
  late final TextEditingController _endpoint;
  late final TextEditingController _region;
  late final TextEditingController _bucket;
  late final TextEditingController _accessKeyId;
  late final TextEditingController _secretAccessKey;
  late final TextEditingController _sessionToken;
  late final TextEditingController _prefix;
  late final TextEditingController _s3UserAgent;

  bool _showPassword = false;
  bool _showSecret = false;
  bool _showToken = false;
  bool _pathStyle = true;

  bool _testing = false;
  ChannelTestResult? _testResult;

  bool get _isWebDav => widget.channel == BackupChannel.webdav;

  @override
  void initState() {
    super.initState();
    final w = widget.webdavCfg ?? const WebDavConfig();
    final s = widget.s3Cfg ?? const S3Config();
    _url = TextEditingController(text: w.url);
    _username = TextEditingController(text: w.username);
    _password = TextEditingController(text: w.password);
    _path = TextEditingController(text: w.path.isEmpty ? _defaultPath : w.path);
    _webDavUserAgent = TextEditingController(text: w.userAgent);

    _endpoint = TextEditingController(text: s.endpoint);
    _region = TextEditingController(text: s.region);
    _bucket = TextEditingController(text: s.bucket);
    _accessKeyId = TextEditingController(text: s.accessKeyId);
    _secretAccessKey = TextEditingController(text: s.secretAccessKey);
    _sessionToken = TextEditingController(text: s.sessionToken);
    _prefix = TextEditingController(
      text: s.prefix.isEmpty ? _defaultPath : s.prefix,
    );
    _s3UserAgent = TextEditingController(text: s.userAgent);
    _pathStyle = s.pathStyle;
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _path.dispose();
    _webDavUserAgent.dispose();
    _endpoint.dispose();
    _region.dispose();
    _bucket.dispose();
    _accessKeyId.dispose();
    _secretAccessKey.dispose();
    _sessionToken.dispose();
    _prefix.dispose();
    _s3UserAgent.dispose();
    super.dispose();
  }

  Future<void> _runTest() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      // Validate the typed DRAFT — never persist; only 保存 commits.
      final result = _isWebDav
          ? await widget.onTestWebDav!(_draftWebDavConfig())
          : await widget.onTestS3!(_draftS3Config());
      if (mounted) setState(() => _testResult = result);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  WebDavConfig _draftWebDavConfig() =>
      (widget.webdavCfg ?? const WebDavConfig()).copyWith(
        url: _url.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        path: _path.text.trim().isEmpty ? _defaultPath : _path.text.trim(),
        userAgent: _webDavUserAgent.text.trim(),
      );

  S3Config _draftS3Config() => (widget.s3Cfg ?? const S3Config()).copyWith(
    endpoint: _endpoint.text.trim(),
    region: _region.text.trim().isEmpty ? 'us-east-1' : _region.text.trim(),
    bucket: _bucket.text.trim(),
    accessKeyId: _accessKeyId.text.trim(),
    secretAccessKey: _secretAccessKey.text,
    sessionToken: _sessionToken.text,
    prefix: _prefix.text.trim().isEmpty ? _defaultPath : _prefix.text.trim(),
    pathStyle: _pathStyle,
    userAgent: _s3UserAgent.text.trim(),
  );

  Future<void> _persistDraft() async {
    if (_isWebDav) {
      final save = widget.onSaveWebDav;
      if (save == null) return;
      await save(_draftWebDavConfig());
    } else {
      final save = widget.onSaveS3;
      if (save == null) return;
      await save(_draftS3Config());
    }
  }

  Future<void> _save() async {
    await _persistDraft();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.of(context).size.height * 0.88;
    final title = _isWebDav
        ? l10n.backupPageWebDavServerSettings
        : l10n.backupPageS3ServerSettings;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.isSheet)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              widget.isSheet ? 16 : 20,
              widget.isSheet ? 12 : 20,
              12,
              4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                ),
                if (!widget.isSheet)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Lucide.X,
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(
                widget.isSheet ? 16 : 20,
                8,
                widget.isSheet ? 16 : 20,
                8,
              ),
              children: _isWebDav ? _webDavFields(context) : _s3Fields(context),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              widget.isSheet ? 16 : 20,
              0,
              widget.isSheet ? 16 : 20,
              widget.isSheet ? 12 : 18,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_testResult != null) ...[
                  Text(
                    _testResult!.message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: _testResult!.ok ? cs.primary : cs.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      child: _OutlineActionButton(
                        label: _testing
                            ? l10n.backupPageTestingConnection
                            : l10n.backupPageTestConnection,
                        onTap: _testing ? null : _runTest,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _FilledActionButton(
                        label: l10n.backupPageSave,
                        onTap: _save,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _webDavFields(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _FormField(
        label: l10n.backupPageWebDavServerUrl,
        controller: _url,
        hintText: 'https://example.com/dav',
      ),
      const SizedBox(height: 12),
      _FormField(label: l10n.backupPageUsername, controller: _username),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPagePassword,
        controller: _password,
        obscure: !_showPassword,
        suffix: _EyeToggle(
          show: _showPassword,
          onPressed: () => setState(() => _showPassword = !_showPassword),
        ),
      ),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPagePath,
        controller: _path,
        hintText: _defaultPath,
      ),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPageUserAgent,
        controller: _webDavUserAgent,
        hintText: l10n.backupPageUserAgentHint,
      ),
    ];
  }

  List<Widget> _s3Fields(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _FormField(
        label: l10n.backupPageS3Endpoint,
        controller: _endpoint,
        hintText: 'https://s3.amazonaws.com',
      ),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPageS3Region,
        controller: _region,
        hintText: 'us-east-1 / auto',
      ),
      const SizedBox(height: 12),
      _FormField(label: l10n.backupPageS3Bucket, controller: _bucket),
      const SizedBox(height: 12),
      _FormField(label: l10n.backupPageS3AccessKeyId, controller: _accessKeyId),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPageS3SecretAccessKey,
        controller: _secretAccessKey,
        obscure: !_showSecret,
        suffix: _EyeToggle(
          show: _showSecret,
          onPressed: () => setState(() => _showSecret = !_showSecret),
        ),
      ),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPageS3SessionToken,
        controller: _sessionToken,
        obscure: !_showToken,
        suffix: _EyeToggle(
          show: _showToken,
          onPressed: () => setState(() => _showToken = !_showToken),
        ),
      ),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPageS3Prefix,
        controller: _prefix,
        hintText: _defaultPath,
      ),
      const SizedBox(height: 12),
      _FormField(
        label: l10n.backupPageUserAgent,
        controller: _s3UserAgent,
        hintText: l10n.backupPageUserAgentHint,
      ),
      const SizedBox(height: 12),
      Container(
        decoration: BoxDecoration(
          color: context.appColors.surfaceFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.18),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                l10n.backupPageS3PathStyle,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            IosSwitch(
              value: _pathStyle,
              onChanged: (v) => setState(() => _pathStyle = v),
            ),
          ],
        ),
      ),
    ];
  }
}

class _FormField extends StatelessWidget {
  const _FormField({
    required this.label,
    required this.controller,
    this.hintText,
    this.obscure = false,
    this.suffix,
  });

  final String label;
  final TextEditingController controller;
  final String? hintText;
  final bool obscure;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fieldBg = context.appColors.surfaceFill;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.72),
          ),
        ),
        const SizedBox(height: 7),
        TextField(
          controller: controller,
          obscureText: obscure,
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: AppFontWeights.medium,
            color: cs.onSurface.withValues(alpha: 0.92),
          ),
          decoration: InputDecoration(
            hintText: hintText,
            isDense: true,
            filled: true,
            fillColor: fieldBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.primary, width: 1),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 40,
            ),
          ),
        ),
      ],
    );
  }
}

class _EyeToggle extends StatefulWidget {
  const _EyeToggle({required this.show, required this.onPressed});

  final bool show;
  final VoidCallback onPressed;

  @override
  State<_EyeToggle> createState() => _EyeToggleState();
}

class _EyeToggleState extends State<_EyeToggle> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _pressed
        ? cs.onSurface.withValues(alpha: 0.5)
        : cs.onSurface.withValues(alpha: 0.7);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onPressed,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          widget.show ? Lucide.EyeOff : Lucide.Eye,
          size: 20,
          color: color,
        ),
      ),
    );
  }
}

class _OutlineActionButton extends StatefulWidget {
  const _OutlineActionButton({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_OutlineActionButton> createState() => _OutlineActionButtonState();
}

class _OutlineActionButtonState extends State<_OutlineActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled
          ? (_) => Future.delayed(const Duration(milliseconds: 80), () {
              if (mounted) setState(() => _pressed = false);
            })
          : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: enabled
                  ? cs.primary.withValues(alpha: 0.5)
                  : cs.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: enabled ? cs.primary : cs.onSurface.withValues(alpha: 0.4),
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilledActionButton extends StatefulWidget {
  const _FilledActionButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_FilledActionButton> createState() => _FilledActionButtonState();
}

class _FilledActionButtonState extends State<_FilledActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => Future.delayed(const Duration(milliseconds: 80), () {
        if (mounted) setState(() => _pressed = false);
      }),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: cs.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: cs.onPrimary,
              fontWeight: AppFontWeights.semibold,
            ),
          ),
        ),
      ),
    );
  }
}

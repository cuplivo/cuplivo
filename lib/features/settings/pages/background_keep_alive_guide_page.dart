import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/services/background_protection_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_settings_section.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/snackbar.dart';

/// Android keep-alive guide (Issue #676): walks the user through the pieces
/// that keep Cuplivo alive in the background — background chat mode, battery
/// optimization exemption, notification permission, and the OEM whitelist
/// pages that Chinese domestic ROMs require on top of the foreground service.
/// Android-only entry (gated by the settings page); every status read is
/// refreshed when the app resumes, because system settings change elsewhere.
class BackgroundKeepAliveGuidePage extends StatefulWidget {
  const BackgroundKeepAliveGuidePage({super.key});

  @override
  State<BackgroundKeepAliveGuidePage> createState() =>
      _BackgroundKeepAliveGuidePageState();
}

class _BackgroundKeepAliveGuidePageState
    extends State<BackgroundKeepAliveGuidePage>
    with WidgetsBindingObserver {
  Future<bool?>? _batteryFuture;
  Future<bool>? _notificationsFuture;
  Future<KeepAliveVendor>? _vendorFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final service = BackgroundProtectionService.instance;
    _batteryFuture = service.refreshBatteryOptimizationStatus();
    _notificationsFuture = service.areNotificationsGranted();
    _vendorFuture = _loadVendor();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reloadStatuses();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<KeepAliveVendor> _loadVendor() async {
    final manufacturer = await BackgroundProtectionService.instance
        .detectVendor();
    return KeepAliveVendor.fromManufacturer(manufacturer);
  }

  void _reloadStatuses() {
    if (!mounted) return;
    final service = BackgroundProtectionService.instance;
    setState(() {
      _batteryFuture = service.refreshBatteryOptimizationStatus();
      _notificationsFuture = service.areNotificationsGranted();
    });
  }

  void _showMessage(
    String message, {
    NotificationType type = NotificationType.info,
  }) {
    AppSnackBarManager().show(
      context,
      AppNotification(message: message, type: type),
    );
  }

  Future<void> _requestBatteryExemption() async {
    final ok = await BackgroundProtectionService.instance
        .requestIgnoreBatteryOptimization();
    if (!mounted) return;
    if (!ok) {
      _showMessage(
        AppLocalizations.of(context)!.keepAliveGuideOpenFailed,
        type: NotificationType.error,
      );
      return;
    }
    _reloadStatuses();
  }

  Future<void> _requestNotifications() async {
    final ok = await BackgroundProtectionService.instance
        .requestNotificationsPermission();
    if (!mounted) return;
    if (!ok) {
      _showMessage(
        AppLocalizations.of(context)!.keepAliveGuideNotificationsDenied,
        type: NotificationType.warning,
      );
      return;
    }
    _reloadStatuses();
  }

  Future<void> _openVendorSettings(
    KeepAliveSettingsKind kind,
    KeepAliveVendor vendor,
  ) async {
    final result = await BackgroundProtectionService.instance
        .openVendorSettings(vendor: vendor, kind: kind);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    switch (result) {
      case VendorSettingsOpenResult.opened:
        break;
      case VendorSettingsOpenResult.fallback:
        _showMessage(l10n.keepAliveGuideFallbackOpened);
        break;
      case VendorSettingsOpenResult.failed:
        _showMessage(
          l10n.keepAliveGuideOpenFailed,
          type: NotificationType.error,
        );
    }
  }

  String _modeText(AppLocalizations l10n, SettingsProvider sp) {
    switch (sp.androidBackgroundChatMode) {
      case AndroidBackgroundChatMode.onNotify:
        return l10n.androidBackgroundStatusOther;
      case AndroidBackgroundChatMode.on:
        return l10n.androidBackgroundStatusOn;
      case AndroidBackgroundChatMode.off:
        return l10n.androidBackgroundStatusOff;
    }
  }

  String _vendorLabel(AppLocalizations l10n, KeepAliveVendor vendor) {
    switch (vendor) {
      case KeepAliveVendor.xiaomi:
        return 'Xiaomi / HyperOS';
      case KeepAliveVendor.huawei:
        return 'Huawei / HarmonyOS';
      case KeepAliveVendor.honor:
        return 'Honor / MagicOS';
      case KeepAliveVendor.oppo:
        return 'OPPO / ColorOS';
      case KeepAliveVendor.oneplus:
        return 'OnePlus';
      case KeepAliveVendor.vivo:
        return 'vivo / OriginOS';
      case KeepAliveVendor.samsung:
        return 'Samsung / One UI';
      case KeepAliveVendor.meizu:
        return 'Meizu / Flyme';
      case KeepAliveVendor.other:
        return l10n.keepAliveGuideVendorNotDetected;
    }
  }

  String _vendorHint(AppLocalizations l10n, KeepAliveVendor vendor) {
    switch (vendor) {
      case KeepAliveVendor.xiaomi:
        return l10n.keepAliveGuideXiaomiHint;
      case KeepAliveVendor.huawei:
        return l10n.keepAliveGuideHuaweiHint;
      case KeepAliveVendor.honor:
        return l10n.keepAliveGuideHonorHint;
      case KeepAliveVendor.oppo:
        return l10n.keepAliveGuideOppoHint;
      case KeepAliveVendor.oneplus:
        return l10n.keepAliveGuideOneplusHint;
      case KeepAliveVendor.vivo:
        return l10n.keepAliveGuideVivoHint;
      case KeepAliveVendor.samsung:
        return l10n.keepAliveGuideSamsungHint;
      case KeepAliveVendor.meizu:
        return l10n.keepAliveGuideMeizuHint;
      case KeepAliveVendor.other:
        return l10n.keepAliveGuideOtherVendorHint;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            size: 22,
            minSize: 44,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.keepAliveGuidePageTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        children: [
          _footnote(context, l10n.keepAliveGuideIntro),
          const SizedBox(height: 12),
          _statusCard(context),
          const SizedBox(height: 12),
          _batteryCard(context),
          const SizedBox(height: 8),
          _footnote(context, l10n.keepAliveGuideBatteryStep),
          const SizedBox(height: 12),
          _notificationCard(context),
          const SizedBox(height: 8),
          _footnote(context, l10n.keepAliveGuideNotificationStep),
          const SizedBox(height: 12),
          _vendorCard(context),
          const SizedBox(height: 12),
          _lockCard(context),
        ],
      ),
    );
  }

  Widget _footnote(BuildContext context, String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.58),
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sp = context.watch<SettingsProvider>();
    return IosSettingsSection(
      children: [
        IosSettingsNavRow(
          icon: Lucide.Monitor,
          label: l10n.displaySettingsPageAndroidBackgroundChatTitle,
          detailText: _modeText(l10n, sp),
        ),
      ],
    );
  }

  Widget _batteryCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<bool?>(
      future: _batteryFuture,
      builder: (context, snapshot) {
        String statusText;
        if (snapshot.connectionState != ConnectionState.done) {
          statusText = l10n.keepAliveGuideStatusUnknown;
        } else if (snapshot.data == true) {
          statusText = l10n.keepAliveGuideStatusIgnored;
        } else if (snapshot.data == false) {
          statusText = l10n.keepAliveGuideStatusNotIgnored;
        } else {
          statusText = l10n.keepAliveGuideStatusQueryFailed;
        }
        return IosSettingsSection(
          children: [
            IosSettingsNavRow(
              icon: Lucide.Zap,
              label: l10n.keepAliveGuideBatteryTitle,
              detailText: statusText,
              onTap: _requestBatteryExemption,
            ),
          ],
        );
      },
    );
  }

  Widget _notificationCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<bool>(
      future: _notificationsFuture,
      builder: (context, snapshot) {
        final statusText = snapshot.data == true
            ? l10n.keepAliveGuideStatusGranted
            : l10n.keepAliveGuideStatusDenied;
        return IosSettingsSection(
          children: [
            IosSettingsNavRow(
              icon: Lucide.MessageCircle,
              label: l10n.keepAliveGuideNotificationTitle,
              detailText: statusText,
              onTap: _requestNotifications,
            ),
          ],
        );
      },
    );
  }

  Widget _vendorCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<KeepAliveVendor>(
      future: _vendorFuture,
      builder: (context, snapshot) {
        final vendor = snapshot.data ?? KeepAliveVendor.other;
        final isOther = vendor == KeepAliveVendor.other;
        return IosSettingsSection(
          children: [
            IosSettingsNavRow(
              icon: Lucide.Shield,
              label: l10n.keepAliveGuideVendorTitle,
              detailText: _vendorLabel(l10n, vendor),
            ),
            IosSettingsDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _vendorHint(l10n, vendor),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.4,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (!isOther) ...[
                        Expanded(
                          child: IosTileButton(
                            label: l10n.keepAliveGuideAutostartAction,
                            icon: Lucide.Shield,
                            onTap: () => _openVendorSettings(
                              KeepAliveSettingsKind.autostart,
                              vendor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: IosTileButton(
                          label: l10n.keepAliveGuidePowerAction,
                          icon: Lucide.Zap,
                          onTap: () => _openVendorSettings(
                            KeepAliveSettingsKind.battery,
                            vendor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _lockCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IosSettingsSection(
          children: [
            IosSettingsNavRow(
              icon: Lucide.Pin,
              label: l10n.keepAliveGuideLockTitle,
            ),
          ],
        ),
        const SizedBox(height: 8),
        _footnote(context, l10n.keepAliveGuideLockStep),
      ],
    );
  }
}

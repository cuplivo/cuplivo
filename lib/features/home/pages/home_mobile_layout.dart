import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'dart:io';
import 'dart:ui' as ui;

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/interactive_drawer.dart';
import '../widgets/side_drawer.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../shared/animations/widgets.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../chat/widgets/frosted/chat_frosted_backdrop.dart';
import '../widgets/assistant_avatar.dart';
import '../widgets/assistant_entry_actions.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';

/// Mobile layout scaffold for the home page
/// This widget handles only the structural layout - AppBar, drawer, body structure
/// All message list rendering and input bar logic remain in home_page.dart
class HomeMobileScaffold extends StatelessWidget {
  const HomeMobileScaffold({
    super.key,
    required this.scaffoldKey,
    required this.drawerController,
    required this.assistantPickerCloseTick,
    required this.loadingConversationIds,
    required this.title,
    required this.providerName,
    required this.modelDisplay,
    required this.onToggleDrawer,
    required this.onDismissKeyboard,
    required this.onSelectConversation,
    required this.onNewConversation,
    required this.onOpenMiniMap,
    required this.onCreateNewConversation,
    required this.onToggleTemporaryConversation,
    required this.onSelectModel,
    required this.canToggleTemporaryConversation,
    required this.temporaryConversationEnabled,
    required this.globalSearchMode,
    required this.globalSearchQuery,
    required this.onGlobalSearchQueryChanged,
    required this.onEnterGlobalSearch,
    required this.onExitGlobalSearch,
    required this.onOpenGlobalSearchResult,
    this.appBarOverride,
    required this.body,
  });

  final GlobalKey<ScaffoldState> scaffoldKey;
  final InteractiveDrawerController drawerController;
  final ValueNotifier<int> assistantPickerCloseTick;
  final Set<String> loadingConversationIds;
  final String title;
  final String? providerName;
  final String? modelDisplay;
  final VoidCallback onToggleDrawer;
  final VoidCallback onDismissKeyboard;
  final void Function(String id) onSelectConversation;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenMiniMap;
  final Future<void> Function() onCreateNewConversation;
  final Future<void> Function() onToggleTemporaryConversation;
  final VoidCallback onSelectModel;
  final bool canToggleTemporaryConversation;
  final bool temporaryConversationEnabled;
  final bool globalSearchMode;
  final String globalSearchQuery;
  final ValueChanged<String> onGlobalSearchQueryChanged;
  final VoidCallback onEnterGlobalSearch;
  final VoidCallback onExitGlobalSearch;
  final Future<void> Function(String conversationId, String messageId)
  onOpenGlobalSearchResult;
  final PreferredSizeWidget? appBarOverride;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return InteractiveDrawer(
      controller: drawerController,
      side: DrawerSide.left,
      drawerWidth: MediaQuery.sizeOf(context).width * 0.75,
      scrimColor: cs.onSurface,
      maxScrimOpacity: 0.12,
      barrierDismissible: true,
      drawer: SideDrawer(
        userName: context.watch<UserProvider>().name,
        assistantName: _getAssistantName(context),
        closePickerTicker: assistantPickerCloseTick,
        loadingConversationIds: loadingConversationIds,
        globalSearchMode: globalSearchMode,
        globalSearchQuery: globalSearchQuery,
        onGlobalSearchQueryChanged: onGlobalSearchQueryChanged,
        onEnterGlobalSearch: onEnterGlobalSearch,
        onExitGlobalSearch: onExitGlobalSearch,
        onOpenGlobalSearchResult: (conversationId, messageId) async {
          await onOpenGlobalSearchResult(conversationId, messageId);
          drawerController.close();
        },
        onSelectConversation: (id, {closeDrawer = true}) {
          onSelectConversation(id);
          if (closeDrawer) drawerController.close();
        },
        onNewConversation: ({closeDrawer = true}) async {
          await onCreateNewConversation();
          if (closeDrawer) drawerController.close();
        },
      ),
      child: ChatFrostedBackdrop(
        backdrop: const MobileBackgroundLayer(),
        child: Scaffold(
          key: scaffoldKey,
          resizeToAvoidBottomInset: true,
          extendBodyBehindAppBar: true,
          backgroundColor: Colors.transparent,
          appBar: appBarOverride ?? _buildAppBar(context, cs),
          body: body,
        ),
      ),
    );
  }

  String _getAssistantName(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final a = context.watch<AssistantProvider>().currentAssistant;
    final n = a?.name.trim();
    return (n == null || n.isEmpty) ? l10n.homePageDefaultAssistant : n;
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, ColorScheme cs) {
    final isDesktopPlatform =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    final useNewAssistantAvatarUx = context
        .watch<SettingsProvider>()
        .useNewAssistantAvatarUx;

    return AppBar(
      systemOverlayStyle: (Theme.of(context).brightness == Brightness.dark)
          ? const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            )
          : const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.dark,
              statusBarBrightness: Brightness.light,
            ),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: Builder(
        builder: (context) {
          return IosIconButton(
            size: 20,
            padding: const EdgeInsets.all(8),
            minSize: 40,
            builder: (color) => SvgPicture.asset(
              'assets/icons/list.svg',
              width: 14,
              height: 14,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
            onTap: () {
              onDismissKeyboard();
              onToggleDrawer();
            },
          );
        },
      ),
      titleSpacing: 2,
      title: useNewAssistantAvatarUx
          ? Row(
              children: [
                _buildAssistantTitleAvatar(context),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedTextSwap(
                        text: title,
                        style: TextStyle(
                          fontSize: isDesktopPlatform ? 14 : 16,
                          fontWeight: AppFontWeights.medium,
                        ),
                      ),
                      if (providerName != null && modelDisplay != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: onSelectModel,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 0),
                              child: AnimatedTextSwap(
                                text: '$modelDisplay ($providerName)',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurface.withValues(alpha: 0.6),
                                  fontWeight: AppFontWeights.medium,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedTextSwap(
                  text: title,
                  style: TextStyle(
                    fontSize: isDesktopPlatform ? 14 : 16,
                    fontWeight: AppFontWeights.medium,
                  ),
                ),
                if (providerName != null && modelDisplay != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: onSelectModel,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 0),
                        child: AnimatedTextSwap(
                          text: '$modelDisplay ($providerName)',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.6),
                            fontWeight: AppFontWeights.medium,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
      actions: [
        IosIconButton(
          size: 20,
          minSize: 44,
          onTap: onOpenMiniMap,
          semanticLabel: AppLocalizations.of(context)!.miniMapTooltip,
          icon: Lucide.Map,
        ),
        IosIconButton(
          size: 22,
          minSize: 44,
          onTap: () async {
            if (canToggleTemporaryConversation) {
              await onToggleTemporaryConversation();
            } else {
              await onCreateNewConversation();
            }
          },
          semanticLabel: canToggleTemporaryConversation
              ? AppLocalizations.of(context)!.temporaryChatToggleTooltip
              : AppLocalizations.of(context)!.titleForLocale,
          icon: canToggleTemporaryConversation && !temporaryConversationEnabled
              ? Lucide.MessageCircleDashed
              : Lucide.MessageCirclePlus,
          builder:
              canToggleTemporaryConversation && temporaryConversationEnabled
              ? (color) => SvgPicture.asset(
                  'assets/icons/temporary_chat_checked.svg',
                  width: 22,
                  height: 22,
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                )
              : null,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildAssistantTitleAvatar(BuildContext context) {
    final assistantProvider = context.watch<AssistantProvider>();
    final currentAssistant = assistantProvider.currentAssistant;
    final currentAssistantId = assistantProvider.currentAssistantId;

    return IosCardPress(
      borderRadius: BorderRadius.circular(999),
      baseColor: Colors.transparent,
      padding: const EdgeInsets.all(2),
      longPressTimeout: const Duration(milliseconds: 280),
      onTap: () {
        onDismissKeyboard();
        onToggleDrawer();
      },
      onLongPress: currentAssistantId == null
          ? null
          : () {
              Haptics.light();
              AssistantEntryActions.openAssistantSettings(
                context,
                currentAssistantId,
              );
            },
      child: AssistantAvatar(
        assistant: currentAssistant,
        fallbackName: _getAssistantName(context),
        size: 28,
      ),
    );
  }
}

/// Mobile background widget with assistant-specific image and gradient overlay
class MobileBackgroundLayer extends StatelessWidget {
  const MobileBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = context.watch<AssistantProvider>().currentAssistant?.background;
    final maskStrength = context
        .watch<SettingsProvider>()
        .chatBackgroundMaskStrength;

    if (bg == null || bg.trim().isEmpty) return const SizedBox.expand();

    ImageProvider provider;
    if (bg.startsWith('http')) {
      provider = NetworkImage(bg);
    } else {
      final localPath = SandboxPathResolver.fix(bg);
      final file = File(localPath);
      if (!file.existsSync()) return const SizedBox.expand();
      provider = FileImage(file);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            image: DecorationImage(
              image: provider,
              fit: BoxFit.cover,
              colorFilter: ColorFilter.mode(
                cs.shadow.withValues(alpha: 0.04),
                BlendMode.srcATop,
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  cs.surface.withValues(
                    alpha: (0.20 * maskStrength).clamp(0.0, 1.0),
                  ),
                  cs.surface.withValues(
                    alpha: (0.50 * maskStrength).clamp(0.0, 1.0),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Scroll navigation buttons (scroll to bottom + scroll to previous question)
class ScrollNavigationButtons extends StatelessWidget {
  const ScrollNavigationButtons({
    super.key,
    required this.showJumpToBottom,
    required this.inputBarHeight,
    required this.hasMessages,
    required this.onScrollToBottom,
    required this.onScrollToPreviousQuestion,
  });

  final bool showJumpToBottom;
  final double inputBarHeight;
  final bool hasMessages;
  final VoidCallback onScrollToBottom;
  final VoidCallback onScrollToPreviousQuestion;

  @override
  Widget build(BuildContext context) {
    final showSetting = context.watch<SettingsProvider>().showMessageNavButtons;
    if (!showSetting || !hasMessages) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomOffset = inputBarHeight + 12;

    return Stack(
      children: [
        // Scroll to bottom button
        Align(
          alignment: Alignment.bottomRight,
          child: SafeArea(
            top: false,
            bottom: false,
            child: IgnorePointer(
              ignoring: !showJumpToBottom,
              child: AnimatedScale(
                scale: showJumpToBottom ? 1.0 : 0.9,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  opacity: showJumpToBottom ? 1 : 0,
                  child: Padding(
                    padding: EdgeInsets.only(right: 16, bottom: bottomOffset),
                    child: _ScrollButton(
                      isDark: isDark,
                      icon: Lucide.ChevronDown,
                      onTap: onScrollToBottom,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Scroll to previous question button
        Align(
          alignment: Alignment.bottomRight,
          child: SafeArea(
            top: false,
            bottom: false,
            child: IgnorePointer(
              ignoring: !showJumpToBottom,
              child: AnimatedScale(
                scale: showJumpToBottom ? 1.0 : 0.9,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  opacity: showJumpToBottom ? 1 : 0,
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: 16,
                      bottom: bottomOffset + 52,
                    ),
                    child: _ScrollButton(
                      isDark: isDark,
                      icon: Lucide.ChevronUp,
                      onTap: onScrollToPreviousQuestion,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScrollButton extends StatelessWidget {
  const _ScrollButton({
    required this.isDark,
    required this.icon,
    required this.onTap,
  });

  final bool isDark;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.07),
            shape: BoxShape.circle,
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.10)
                  : Theme.of(
                      context,
                    ).colorScheme.outline.withValues(alpha: 0.20),
              width: 1,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(icon, size: 16, color: cs.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

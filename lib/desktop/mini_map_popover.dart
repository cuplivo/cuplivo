import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models/chat_message.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../shared/widgets/mini_map/mini_map_shared.dart';
import '../theme/app_font_weights.dart';

Future<String?> showDesktopMiniMapPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<ChatMessage> messages,
  bool selecting = false,
  Set<String>? selectedMessageIds,
  Listenable? selectionListenable,
  ValueChanged<String>? onToggleSelection,
}) async {
  assert(
    !selecting || (selectedMessageIds != null && onToggleSelection != null),
    'Mini map selection mode requires selectedMessageIds and onToggleSelection.',
  );
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return null;
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return null;

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return null;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy,
    size.width,
    size.height,
  );

  final completer = Completer<String?>();

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _MiniMapPopover(
      anchorRect: anchorRect,
      anchorWidth: size.width,
      messages: messages,
      selecting: selecting,
      selectedMessageIds: selectedMessageIds,
      selectionListenable: selectionListenable,
      onToggleSelection: onToggleSelection,
      onSelect: selecting
          ? null
          : (id) {
              try {
                entry.remove();
              } catch (_) {}
              if (!completer.isCompleted) completer.complete(id);
            },
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
        if (!completer.isCompleted) completer.complete(null);
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _MiniMapPopover extends StatefulWidget {
  const _MiniMapPopover({
    required this.anchorRect,
    required this.anchorWidth,
    required this.messages,
    required this.onSelect,
    required this.selecting,
    required this.selectedMessageIds,
    required this.selectionListenable,
    required this.onToggleSelection,
    required this.onClose,
  });

  final Rect anchorRect;
  final double anchorWidth;
  final List<ChatMessage> messages;
  final ValueChanged<String>? onSelect;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;
  final ValueChanged<String>? onToggleSelection;
  final VoidCallback onClose;

  @override
  State<_MiniMapPopover> createState() => _MiniMapPopoverState();
}

class _MiniMapPopoverState extends State<_MiniMapPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  late final Animation<double> _slideY; // px translateY
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _fadeIn = curve;
    _slideY = Tween<double>(begin: 16.0, end: 0.0).animate(curve);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _controller.forward();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final width = (widget.anchorWidth - 16).clamp(320.0, 800.0);
    final left =
        (widget.anchorRect.left + (widget.anchorRect.width - width) / 2).clamp(
          8.0,
          screen.width - width - 8.0,
        );
    final clipHeight = widget.anchorRect.top.clamp(0.0, screen.height);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: clipHeight,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  width: width,
                  bottom: 0,
                  child: FadeTransition(
                    opacity: _fadeIn,
                    child: AnimatedBuilder(
                      animation: _slideY,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, _slideY.value),
                        child: child,
                      ),
                      child: _GlassPanel(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(14),
                        ),
                        child: _MiniMapList(
                          messages: widget.messages,
                          selecting: widget.selecting,
                          selectedMessageIds: widget.selectedMessageIds,
                          selectionListenable: widget.selectionListenable,
                          onClose: _close,
                          onTapMessage: (id) {
                            if (_closing) return;
                            if (widget.selecting) {
                              widget.onToggleSelection?.call(id);
                            } else {
                              widget.onSelect?.call(id);
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child, this.borderRadius});
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (isDark ? Colors.black : Colors.white).withValues(
              alpha: isDark ? 0.28 : 0.56,
            ),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.18),
                width: 0.7,
              ),
              left: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
              right: BorderSide(
                color: Colors.white.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _MiniMapList extends StatefulWidget {
  const _MiniMapList({
    required this.messages,
    required this.onTapMessage,
    required this.onClose,
    required this.selecting,
    this.selectedMessageIds,
    this.selectionListenable,
  });
  final List<ChatMessage> messages;
  final ValueChanged<String> onTapMessage;
  final VoidCallback onClose;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;

  @override
  State<_MiniMapList> createState() => _MiniMapListState();
}

class _MiniMapListState extends State<_MiniMapList> {
  late List<MiniMapQaPair> _pairs;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _resultsScrollController = ScrollController();

  String _query = '';
  List<String> _tokens = const [];
  List<ChatMessage> _searchResults = const [];
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _pairs = buildMiniMapPairs(widget.messages);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant _MiniMapList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.messages, widget.messages)) {
      _pairs = buildMiniMapPairs(widget.messages);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _searchDebounce?.cancel();
    if (value.trim().isNotEmpty && _tokens.isEmpty) {
      // First keystroke: apply immediately so the search view shows real
      // results right away (no debounce-window collapse). Subsequent
      // keystrokes are debounced and keep the previous result set visible.
      _applySearch();
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 180), _applySearch);
  }

  void _applySearch() {
    final tokens = miniMapSearchTokens(_query);
    final results = tokens.isEmpty
        ? const <ChatMessage>[]
        : filterMiniMapMessages(widget.messages, tokens);
    if (!mounted) return;
    setState(() {
      _tokens = tokens;
      _searchResults = results;
    });
    final sc = _resultsScrollController;
    if (sc.hasClients) {
      sc.jumpTo(0);
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _query = '';
      _tokens = const [];
      _searchResults = const [];
      _searchController.clear();
    });
    _searchFocusNode.requestFocus();
  }

  KeyEventResult _onSearchKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_query.isNotEmpty) {
        _clearSearch();
      } else {
        widget.onClose();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildSearchField(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = cs.outlineVariant.withValues(alpha: isDark ? 0.5 : 0.8);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: SizedBox(
        height: 36,
        child: Focus(
          onKeyEvent: _onSearchKeyEvent,
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              isDense: true,
              hintText: MaterialLocalizations.of(context).searchFieldLabel,
              prefixIcon: Icon(Lucide.Search, size: 18, color: cs.onSurface),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Lucide.X,
                        size: 16,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                      onPressed: _clearSearch,
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonLabel,
                    ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              filled: true,
              fillColor: cs.surfaceContainerHighest.withValues(
                alpha: isDark ? 0.35 : 0.6,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: borderColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: cs.primary),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResultsList(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textBase = isDark ? Colors.white : Colors.black;
    final highlightColor = isDark
        ? const Color(0xFFB8860B).withValues(alpha: 0.55)
        : const Color(0xFFFFD700).withValues(alpha: 0.55);

    if (_tokens.isEmpty) {
      // Debounce window: query entered but no result set computed yet.
      // Keep the previous state's space without flashing a false empty state.
      return const SizedBox.shrink();
    }

    if (_searchResults.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            l10n.miniMapSearchNoResults,
            style: TextStyle(
              fontSize: 13,
              color: textBase.withValues(alpha: 0.45),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Text(
            l10n.miniMapSearchResultCount(_searchResults.length),
            style: TextStyle(
              fontSize: 12,
              color: textBase.withValues(alpha: 0.5),
              fontWeight: AppFontWeights.medium,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _resultsScrollController,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
            primary: false,
            shrinkWrap: true,
            itemCount: _searchResults.length,
            itemBuilder: (context, index) {
              final message = _searchResults[index];
              return _MiniMapSearchRow(
                message: message,
                tokens: _tokens,
                highlightColor: highlightColor,
                selecting: widget.selecting,
                selectedMessageIds: widget.selectedMessageIds,
                onTap: () => widget.onTapMessage(message.id),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPairsList(List<MiniMapQaPair> pairs) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      primary: false,
      shrinkWrap: true,
      itemCount: pairs.length,
      itemBuilder: (context, index) {
        final p = pairs[index];
        final userSelected =
            widget.selecting &&
            widget.selectedMessageIds != null &&
            p.user != null &&
            widget.selectedMessageIds!.contains(p.user!.id);
        final assistantSelected =
            widget.selecting &&
            widget.selectedMessageIds != null &&
            p.assistant != null &&
            widget.selectedMessageIds!.contains(p.assistant!.id);

        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _MiniMapRow(
            user: p.user,
            assistant: p.assistant,
            userSelected: userSelected,
            assistantSelected: assistantSelected,
            onTapMessage: widget.onTapMessage,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Search view is active while a query is present — even during the
    // debounce window, where the previous result set stays visible — or once
    // a result set has been computed.
    final hasActiveSearch = _query.trim().isNotEmpty || _tokens.isNotEmpty;
    Widget buildList() {
      if (hasActiveSearch) {
        return _buildSearchResultsList(context);
      }
      return _buildPairsList(_pairs);
    }

    final Widget list = widget.selecting && widget.selectionListenable != null
        ? AnimatedBuilder(
            animation: widget.selectionListenable!,
            builder: (context, child) => buildList(),
          )
        : buildList();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSearchField(context),
          Flexible(child: list),
        ],
      ),
    );
  }
}

class _MiniMapSearchRow extends StatefulWidget {
  final ChatMessage message;
  final List<String> tokens;
  final Color highlightColor;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final VoidCallback onTap;

  const _MiniMapSearchRow({
    required this.message,
    required this.tokens,
    required this.highlightColor,
    required this.selecting,
    required this.selectedMessageIds,
    required this.onTap,
  });

  @override
  State<_MiniMapSearchRow> createState() => _MiniMapSearchRowState();
}

class _MiniMapSearchRowState extends State<_MiniMapSearchRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isUser = widget.message.role == 'user';
    final snippet = miniMapHitSnippet(widget.message.content, widget.tokens);

    final selected =
        widget.selecting &&
        widget.selectedMessageIds != null &&
        widget.selectedMessageIds!.contains(widget.message.id);
    final bg = isUser
        ? (isDark
              ? cs.primary.withValues(alpha: 0.15)
              : cs.primary.withValues(alpha: 0.08))
        : cs.onSurface.withValues(alpha: isDark ? 0.05 : 0.03);
    final hoverBg = isUser
        ? (isDark
              ? cs.primary.withValues(alpha: 0.22)
              : cs.primary.withValues(alpha: 0.14))
        : cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.06);
    final selectedBg = isUser
        ? (isDark
              ? cs.primary.withValues(alpha: 0.26)
              : cs.primary.withValues(alpha: 0.14))
        : (isDark
              ? cs.primary.withValues(alpha: 0.18)
              : cs.primary.withValues(alpha: 0.10));
    final border = cs.primary.withValues(alpha: isDark ? 0.38 : 0.28);

    final baseStyle = TextStyle(
      fontSize: 15,
      height: 1.4,
      color: cs.onSurface,
      decoration: TextDecoration.none,
    );
    final highlightStyle = baseStyle.copyWith(
      backgroundColor: widget.highlightColor,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.75,
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: selected ? selectedBg : (_hover ? hoverBg : bg),
                  borderRadius: BorderRadius.circular(16),
                  border: selected ? Border.all(color: border, width: 1) : null,
                ),
                child: RichText(
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    children: buildMiniMapHighlightSpans(
                      snippet.isEmpty
                          ? miniMapOneLine(widget.message.content)
                          : snippet,
                      widget.tokens,
                      baseStyle,
                      highlightStyle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniMapRow extends StatefulWidget {
  const _MiniMapRow({
    required this.user,
    required this.assistant,
    required this.onTapMessage,
    required this.userSelected,
    required this.assistantSelected,
  });
  final ChatMessage? user;
  final ChatMessage? assistant;
  final ValueChanged<String> onTapMessage;
  final bool userSelected;
  final bool assistantSelected;

  @override
  State<_MiniMapRow> createState() => _MiniMapRowState();
}

class _MiniMapRowState extends State<_MiniMapRow> {
  bool _hoverUser = false;
  bool _hoverAssistant = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userText = widget.user?.content ?? '';
    final asstText = widget.assistant?.content ?? '';
    final userBorder = cs.primary.withValues(alpha: isDark ? 0.45 : 0.35);

    final assistantSelectedBg = (isDark
        ? cs.primary.withValues(alpha: 0.18)
        : cs.primary.withValues(alpha: 0.10));
    final assistantBorder = cs.primary.withValues(alpha: isDark ? 0.38 : 0.28);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // User bubble
        Align(
          alignment: Alignment.centerRight,
          child: MouseRegion(
            cursor: widget.user != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hoverUser = true),
            onExit: (_) => setState(() => _hoverUser = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.user != null
                  ? () => widget.onTapMessage(widget.user!.id)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(
                    alpha: _hoverUser
                        ? (widget.userSelected
                              ? (isDark ? 0.32 : 0.18)
                              : (isDark ? 0.22 : 0.14))
                        : (widget.userSelected
                              ? (isDark ? 0.26 : 0.14)
                              : (isDark ? 0.15 : 0.08)),
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: widget.userSelected
                      ? Border.all(color: userBorder, width: 1)
                      : null,
                ),
                child: Text(
                  userText.isNotEmpty ? miniMapOneLine(userText) : ' ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: cs.onSurface,
                    decoration: TextDecoration.none,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Assistant line
        Align(
          alignment: Alignment.centerLeft,
          child: MouseRegion(
            cursor: widget.assistant != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hoverAssistant = true),
            onExit: (_) => setState(() => _hoverAssistant = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.assistant != null
                  ? () => widget.onTapMessage(widget.assistant!.id)
                  : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: widget.assistantSelected
                      ? assistantSelectedBg
                      : cs.onSurface.withValues(
                          alpha: _hoverAssistant
                              ? (isDark ? 0.07 : 0.05)
                              : (isDark ? 0.05 : 0.03),
                        ),
                  borderRadius: BorderRadius.circular(16),
                  border: widget.assistantSelected
                      ? Border.all(color: assistantBorder, width: 1)
                      : null,
                ),
                child: Text(
                  asstText.isNotEmpty ? miniMapOneLine(asstText) : ' ',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15.2,
                    height: 1.4,
                    decoration: TextDecoration.none,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import '../../../core/models/chat_message.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/mini_map/mini_map_shared.dart';
import '../../../theme/app_font_weights.dart';

Future<String?> showMiniMapSheet(
  BuildContext context,
  List<ChatMessage> messages, {
  bool selecting = false,
  Set<String>? selectedMessageIds,
  Listenable? selectionListenable,
  ValueChanged<String>? onToggleSelection,
}) async {
  assert(
    !selecting || (selectedMessageIds != null && onToggleSelection != null),
    'Mini map selection mode requires selectedMessageIds and onToggleSelection.',
  );
  return await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _MiniMapSheet(
      messages: messages,
      selecting: selecting,
      selectedMessageIds: selectedMessageIds,
      selectionListenable: selectionListenable,
      onToggleSelection: onToggleSelection,
    ),
  );
}

class _MiniMapSheet extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;
  final ValueChanged<String>? onToggleSelection;

  const _MiniMapSheet({
    required this.messages,
    this.selecting = false,
    this.selectedMessageIds,
    this.selectionListenable,
    this.onToggleSelection,
  });

  @override
  State<_MiniMapSheet> createState() => _MiniMapSheetState();
}

class _MiniMapSheetState extends State<_MiniMapSheet>
    with TickerProviderStateMixin {
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  late List<MiniMapQaPair> _pairs;
  String _query = '';
  bool _isSearching = false;

  List<String> _tokens = const [];
  List<ChatMessage> _searchResults = const [];
  Timer? _searchDebounce;
  ScrollController? _sheetController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _pairs = buildMiniMapPairs(widget.messages);
  }

  @override
  void didUpdateWidget(covariant _MiniMapSheet oldWidget) {
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
    super.dispose();
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _clearOrCloseSearch({bool close = false}) {
    _searchDebounce?.cancel();
    setState(() {
      _query = '';
      _tokens = const [];
      _searchResults = const [];
      _searchController.clear();
      _isSearching = close ? false : _isSearching;
    });
    if (close) {
      _searchFocusNode.unfocus();
    } else {
      _searchFocusNode.requestFocus();
    }
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
    final sc = _sheetController;
    if (sc != null && sc.hasClients) {
      sc.jumpTo(0);
    }
  }

  /// True while the search view should replace the Q/A pair map: a query is
  /// present (even during the debounce window, where the previous result set
  /// stays visible) or a result set has been computed.
  bool get _searchActive =>
      _isSearching && (_query.trim().isNotEmpty || _tokens.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final searchWidth = min(MediaQuery.sizeOf(context).width * 0.6, 260.0);

    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (ctx, controller) {
          _sheetController = controller;
          Widget buildList() {
            if (_searchActive) {
              return _buildSearchResultsList(context, controller);
            }
            return ListView.builder(
              controller: controller,
              itemCount: _pairs.length,
              itemBuilder: (context, index) {
                return _MiniMapRow(
                  pair: _pairs[index],
                  selecting: widget.selecting,
                  selectedMessageIds: widget.selectedMessageIds,
                  onToggleSelection: widget.onToggleSelection,
                );
              },
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Pinned drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Pinned title
                Row(
                  children: [
                    Icon(Lucide.Map, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.miniMapTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (!_searchActive)
                      SizedBox(
                        height: 36,
                        width: 36,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Lucide.ChevronsDown,
                            size: 18,
                            color: cs.onSurface,
                          ),
                          tooltip: AppLocalizations.of(
                            context,
                          )!.miniMapScrollToBottomTooltip,
                          onPressed: () {
                            if (controller.hasClients &&
                                controller.position.maxScrollExtent > 0) {
                              controller.jumpTo(
                                controller.position.maxScrollExtent,
                              );
                            }
                          },
                        ),
                      ),
                    _buildSearchToggle(context, searchWidth),
                  ],
                ),
                const SizedBox(height: 12),
                // Scrollable content
                Expanded(
                  child: widget.selecting && widget.selectionListenable != null
                      ? AnimatedBuilder(
                          animation: widget.selectionListenable!,
                          builder: (context, child) => buildList(),
                        )
                      : buildList(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchResultsList(
    BuildContext context,
    ScrollController controller,
  ) {
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
      return Center(
        child: Text(
          l10n.miniMapSearchNoResults,
          style: TextStyle(
            fontSize: 13,
            color: textBase.withValues(alpha: 0.45),
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
            controller: controller,
            itemCount: _searchResults.length,
            itemBuilder: (context, index) {
              final message = _searchResults[index];
              return _MiniMapSearchRow(
                message: message,
                tokens: _tokens,
                highlightColor: highlightColor,
                selecting: widget.selecting,
                selectedMessageIds: widget.selectedMessageIds,
                onTap: () {
                  if (widget.selecting) {
                    widget.onToggleSelection?.call(message.id);
                  } else {
                    Navigator.of(context).pop(message.id);
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSearchToggle(BuildContext context, double maxWidth) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = cs.outlineVariant.withValues(alpha: isDark ? 0.5 : 0.8);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        switchInCurve: Curves.easeInOut,
        switchOutCurve: Curves.easeInOut,
        transitionBuilder: (child, animation) {
          return SizeTransition(
            sizeFactor: animation,
            axis: Axis.horizontal,
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: _isSearching
            ? ConstrainedBox(
                key: const ValueKey('miniMapSearchField'),
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          onChanged: _onSearchChanged,
                          textInputAction: TextInputAction.search,
                          textAlignVertical: TextAlignVertical.center,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: MaterialLocalizations.of(
                              context,
                            ).searchFieldLabel,
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
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 36,
                      width: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Lucide.X,
                          size: 18,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                        onPressed: () => _clearOrCloseSearch(close: true),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonLabel,
                      ),
                    ),
                  ],
                ),
              )
            : SizedBox(
                key: const ValueKey('miniMapSearchButton'),
                height: 36,
                width: 36,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: Icon(Lucide.Search, size: 20, color: cs.onSurface),
                  onPressed: _startSearch,
                  tooltip: MaterialLocalizations.of(context).searchFieldLabel,
                ),
              ),
      ),
    );
  }
}

class _MiniMapSearchRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isUser = message.role == 'user';
    final snippet = miniMapHitSnippet(message.content, tokens);

    final selected =
        selecting &&
        selectedMessageIds != null &&
        selectedMessageIds!.contains(message.id);
    final bg = isUser
        ? (isDark
              ? cs.primary.withValues(alpha: 0.15)
              : cs.primary.withValues(alpha: 0.08))
        : cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.04);
    final selectedBg = isUser
        ? (isDark
              ? cs.primary.withValues(alpha: 0.26)
              : cs.primary.withValues(alpha: 0.14))
        : (isDark
              ? cs.primary.withValues(alpha: 0.18)
              : cs.primary.withValues(alpha: 0.10));
    final border = isUser
        ? cs.primary.withValues(alpha: isDark ? 0.45 : 0.35)
        : cs.primary.withValues(alpha: isDark ? 0.38 : 0.28);

    final baseStyle = TextStyle(
      fontSize: 15.5,
      height: 1.4,
      color: cs.onSurface,
    );
    final highlightStyle = baseStyle.copyWith(backgroundColor: highlightColor);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth:
                MediaQuery.sizeOf(context).width * 0.75 -
                32, // subtract side paddings approx in sheet
          ),
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: selected ? selectedBg : bg,
                  borderRadius: BorderRadius.circular(16),
                  border: selected ? Border.all(color: border, width: 1) : null,
                ),
                child: RichText(
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    children: buildMiniMapHighlightSpans(
                      snippet.isEmpty
                          ? miniMapOneLine(message.content)
                          : snippet,
                      tokens,
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

class _MiniMapRow extends StatelessWidget {
  final MiniMapQaPair pair;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final ValueChanged<String>? onToggleSelection;

  const _MiniMapRow({
    required this.pair,
    this.selecting = false,
    this.selectedMessageIds,
    this.onToggleSelection,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userText = pair.user?.content ?? '';
    final asstText = pair.assistant?.content ?? '';

    final bool userSelected =
        selectedMessageIds != null &&
        pair.user != null &&
        selectedMessageIds!.contains(pair.user!.id);
    final bool assistantSelected =
        selectedMessageIds != null &&
        pair.assistant != null &&
        selectedMessageIds!.contains(pair.assistant!.id);

    final userBg = (isDark
        ? cs.primary.withValues(alpha: 0.15)
        : cs.primary.withValues(alpha: 0.08));
    final userSelectedBg = (isDark
        ? cs.primary.withValues(alpha: 0.26)
        : cs.primary.withValues(alpha: 0.14));
    final userBorder = cs.primary.withValues(alpha: isDark ? 0.45 : 0.35);

    final assistantBg = cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.04);
    final assistantSelectedBg = (isDark
        ? cs.primary.withValues(alpha: 0.18)
        : cs.primary.withValues(alpha: 0.10));
    final assistantBorder = cs.primary.withValues(alpha: isDark ? 0.38 : 0.28);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // User bubble — match main chat style (right aligned rounded rectangle)
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth:
                    MediaQuery.sizeOf(context).width * 0.75 -
                    32, // subtract side paddings approx in sheet
              ),
              child: Material(
                color: Colors.transparent,
                child: selecting
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: pair.user != null
                            ? () => onToggleSelection?.call(pair.user!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: userSelected ? userSelectedBg : userBg,
                            borderRadius: BorderRadius.circular(16),
                            border: userSelected
                                ? Border.all(color: userBorder, width: 1)
                                : null,
                          ),
                          child: Text(
                            userText.isNotEmpty
                                ? miniMapOneLine(userText)
                                : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15.5,
                              height: 1.4,
                              color: cs.onSurface,
                            ),
                            textAlign: TextAlign.left,
                          ),
                        ),
                      )
                    : InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: pair.user != null
                            ? () => Navigator.of(context).pop(pair.user!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: userBg,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            userText.isNotEmpty
                                ? miniMapOneLine(userText)
                                : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15.5,
                              height: 1.4,
                              color: cs.onSurface,
                            ),
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Assistant message
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(
                  context,
                ).width, //* 0.75 - 32, // subtract side paddings approx in sheet
              ),
              child: Material(
                color: Colors.transparent,
                child: selecting
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: pair.assistant != null
                            ? () => onToggleSelection?.call(pair.assistant!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: assistantSelected
                                ? assistantSelectedBg
                                : assistantBg,
                            borderRadius: BorderRadius.circular(16),
                            border: assistantSelected
                                ? Border.all(color: assistantBorder, width: 1)
                                : null,
                          ),
                          child: Text(
                            asstText.isNotEmpty
                                ? miniMapOneLine(asstText)
                                : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15.7, height: 1.5),
                            textAlign: TextAlign.left,
                          ),
                        ),
                      )
                    : InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: pair.assistant != null
                            ? () =>
                                  Navigator.of(context).pop(pair.assistant!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: assistantBg,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            asstText.isNotEmpty
                                ? miniMapOneLine(asstText)
                                : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15.7, height: 1.5),
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

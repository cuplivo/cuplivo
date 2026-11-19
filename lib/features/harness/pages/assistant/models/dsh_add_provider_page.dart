import 'package:flutter/material.dart';

import 'package:Cuplivo/features/harness/pages/assistant/models/dsh_provider_settings.dart';
import 'package:Cuplivo/features/harness/state/dsh_gateway.dart';
import 'package:Cuplivo/features/harness/widgets/chat/dsh_picker_scaffold.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_models_states.dart';
import 'package:Cuplivo/features/harness/widgets/models/dsh_provider_row.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:Cuplivo/theme/app_font_weights.dart';
import 'package:Cuplivo/theme/app_semantic_colors.dart';

/// The sentinel "provider id" of the 自定义提供商 row.
const String dshCustomProviderPickId = '__dsh_custom_provider__';

/// One selectable provider in [showDshAddProviderPicker].
///
/// Either a settings entry (the full configurable route list, when the
/// settings seam is wired) or a live catalog group (what this build can read
/// without the seam). [entry] and [group] are carried through so the detail
/// page can open with the right context instead of re-matching by name.
@immutable
class DshProviderChoice {
  const DshProviderChoice({
    required this.providerId,
    required this.displayName,
    this.entry,
    this.group,
    this.isCustom = false,
  });

  final String providerId;
  final String displayName;
  final DshProviderEntry? entry;
  final DshProviderGroup? group;
  final bool isCustom;

  DshProviderChoice copyWith({DshProviderEntry? entry}) => DshProviderChoice(
    providerId: providerId,
    displayName: displayName,
    entry: entry ?? this.entry,
    group: group,
    isCustom: isCustom,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DshProviderChoice &&
          other.providerId == providerId &&
          other.displayName == displayName &&
          other.entry == entry &&
          other.group == group &&
          other.isCustom == isCustom;

  @override
  int get hashCode =>
      Object.hash(providerId, displayName, entry, group, isCustom);
}

/// Opens the add-provider picker (R10) and returns the chosen row, or null.
///
/// The 自定义提供商 row is always first and stays visible while searching, so
/// the creation flow is never buried under a filter; the rest of the list is
/// alphabetical by display name, exactly like the reference.
Future<DshProviderChoice?> showDshAddProviderPicker(
  BuildContext context, {
  required List<DshProviderChoice> choices,
  bool customEnabled = true,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showDshPicker<DshProviderChoice>(
    context: context,
    title: l10n.dshModelsAddProvider,
    panelKey: const Key('dsh-add-provider-picker'),
    bodyBuilder: (pickerContext, scrollController) => _DshAddProviderPicker(
      choices: choices,
      customEnabled: customEnabled,
      searchHint: l10n.dshModelsSearchHint,
    ),
  );
}

class _DshAddProviderPicker extends StatefulWidget {
  const _DshAddProviderPicker({
    required this.choices,
    required this.customEnabled,
    required this.searchHint,
  });

  final List<DshProviderChoice> choices;
  final bool customEnabled;
  final String searchHint;

  @override
  State<_DshAddProviderPicker> createState() => _DshAddProviderPickerState();
}

class _DshAddProviderPickerState extends State<_DshAddProviderPicker> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<DshProviderChoice> get _filtered {
    final normalized = _query.trim().toLowerCase();
    final sorted = List<DshProviderChoice>.of(widget.choices)
      ..sort((a, b) {
        final byName = a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        );
        return byName != 0 ? byName : a.providerId.compareTo(b.providerId);
      });
    if (normalized.isEmpty) return sorted;
    return [
      for (final choice in sorted)
        if (choice.displayName.toLowerCase().contains(normalized) ||
            choice.providerId.toLowerCase().contains(normalized))
          choice,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final filtered = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            style: TextStyle(color: cs.onSurface, fontSize: 14),
            decoration: InputDecoration(
              hintText: widget.searchHint,
              hintStyle: TextStyle(
                color: cs.onSurface.withValues(alpha: 0.5),
                fontSize: 13.5,
              ),
              isDense: true,
              filled: true,
              fillColor: context.appColors.surfaceFill,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              prefixIcon: Icon(
                Lucide.Search,
                size: 17,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 40,
                minHeight: 40,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(13),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              if (widget.customEnabled)
                DshProviderPickRow(
                  key: const Key('dsh-provider-pick-custom'),
                  providerId: dshCustomProviderPickId,
                  displayName: l10n.dshModelsCustomProviderTitle,
                  showDivider: _filtered.isNotEmpty || _query.isEmpty,
                  icon: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: context.appColors.surfaceCardFill,
                    ),
                    child: Icon(Lucide.Plus, size: 16, color: cs.primary),
                  ),
                  onTap: () => Navigator.of(context).pop(
                    const DshProviderChoice(
                      providerId: dshCustomProviderPickId,
                      displayName: '',
                      isCustom: true,
                    ),
                  ),
                ),
              if (filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: DshModelsStatePanel(
                    icon: Lucide.SearchX,
                    title: l10n.dshModelsSearchEmpty,
                    compact: true,
                  ),
                )
              else
                for (final choice in filtered)
                  DshProviderPickRow(
                    key: ValueKey<String>(
                      'dsh-provider-pick-${choice.providerId}',
                    ),
                    providerId: choice.providerId,
                    displayName: choice.displayName,
                    showDivider: choice != filtered.last,
                    onTap: () => Navigator.of(context).pop(choice),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The small caption used above provider rows when they come from the live
/// catalog instead of the full configurable-route list.
class DshProviderListCaption extends StatelessWidget {
  const DshProviderListCaption({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
      child: Row(
        children: [
          Icon(
            Lucide.BadgeInfo,
            size: 13,
            color: cs.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: AppFontWeights.regular,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

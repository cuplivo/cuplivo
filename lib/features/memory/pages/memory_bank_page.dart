import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/database/app_database.dart';
import '../../../core/memory/memory_bank_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';
import '../view_models/memory_bank_view_model.dart';

/// Browser for the long-term memory bank (`memory_bank_rows` table).
///
/// Read-only on a per-assistant basis. The user can search by keyword,
/// filter by `type`, and delete individual rows. Writes happen out-of-band
/// (chat pipeline + tool calls), so this page never creates or edits rows.
class MemoryBankPage extends StatefulWidget {
  const MemoryBankPage({super.key, this.assistantId});

  final String? assistantId;

  @override
  State<MemoryBankPage> createState() => _MemoryBankPageState();
}

class _MemoryBankPageState extends State<MemoryBankPage> {
  late MemoryBankViewModel _vm;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final db = context.read<ChatService>().repo.db;
    _vm = MemoryBankViewModel(
      service: MemoryBankService(db),
      assistantId: widget.assistantId,
    );
    _vm.addListener(_onVmChanged);
    _vm.load();
  }

  void _onVmChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _vm.removeListener(_onVmChanged);
    _vm.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return ChangeNotifierProvider<MemoryBankViewModel>.value(
      value: _vm,
      child: Consumer<MemoryBankViewModel>(
        builder: (context, vm, _) {
          return Scaffold(
            appBar: AppBar(
              title: Text(l10n.memoryBankPageTitle),
            ),
            body: Column(
              children: [
                _StatsStrip(stats: vm.stats),
                _SearchBar(
                  controller: _searchCtrl,
                  keyword: vm.keyword,
                  type: vm.type,
                  onKeywordChanged: (v) {
                    vm.setKeyword(v);
                    vm.load();
                  },
                  onTypeChanged: (v) {
                    vm.setType(v);
                    vm.load();
                  },
                ),
                const Divider(height: 0.5, thickness: 0.5),
                Expanded(
                  child: _buildList(vm, cs, l10n),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(
    MemoryBankViewModel vm,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    if (vm.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (vm.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${l10n.memoryBankPageErrorPrefix}${vm.error}',
            style: TextStyle(color: cs.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (vm.rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.memoryBankPageEmpty,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: vm.rows.length,
      separatorBuilder: (_, __) => Divider(
        height: 0.5,
        thickness: 0.5,
        color: cs.outlineVariant.withValues(alpha: 0.3),
      ),
      itemBuilder: (context, index) {
        final r = vm.rows[index];
        return _BankRow(
          row: r,
          onDelete: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(l10n.memoryBankPageDeleteTitle),
                content: Text(l10n.memoryBankPageDeleteConfirm),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(l10n.commonCancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(l10n.commonDelete),
                  ),
                ],
              ),
            );
            if (ok == true) {
              await vm.deleteById(r.id);
            }
          },
        );
      },
    );
  }
}

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats});
  final MemoryStats stats;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: cs.surface,
      child: Row(
        children: [
          _StatCell(label: l10n.memoryBankPageStatTotal, value: stats.total),
          _StatCell(
            label: l10n.memoryBankPageStatMessages,
            value: stats.messageCount,
          ),
          _StatCell(
            label: l10n.memoryBankPageStatSummaries,
            value: stats.summaryCount,
          ),
          _StatCell(
            label: l10n.memoryBankPageStatManual,
            value: stats.manualCount,
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: 18,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.keyword,
    required this.type,
    required this.onKeywordChanged,
    required this.onTypeChanged,
  });
  final TextEditingController controller;
  final String keyword;
  final String type;
  final ValueChanged<String> onKeywordChanged;
  final ValueChanged<String> onTypeChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
          TextField(
            controller: controller,
            onChanged: onKeywordChanged,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Lucide.Search, size: 18),
              hintText: l10n.memoryBankPageSearchHint,
              suffixIcon: keyword.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Lucide.X, size: 16),
                      onPressed: () {
                        controller.clear();
                        onKeywordChanged('');
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _TypeChip(
                  label: l10n.memoryBankPageTypeAll,
                  selected: type.isEmpty,
                  onTap: () => onTypeChanged(''),
                ),
                for (final t in MemoryBankService.typeValues)
                  _TypeChip(
                    label: _typeLabel(t, l10n),
                    selected: type == t,
                    onTap: () => onTypeChanged(t),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(String type, AppLocalizations l10n) {
    switch (type) {
      case 'message':
        return l10n.memoryBankPageTypeMessage;
      case 'phase_summary':
        return l10n.memoryBankPageTypePhase;
      case 'daily_summary':
        return l10n.memoryBankPageTypeDaily;
      case 'manual':
        return l10n.memoryBankPageTypeManual;
      case 'auto_summary':
        return l10n.memoryBankPageTypeAuto;
      default:
        return type;
    }
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: cs.primary.withValues(alpha: 0.18),
        labelStyle: TextStyle(
          fontSize: 12,
          color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _BankRow extends StatelessWidget {
  const _BankRow({required this.row, required this.onDelete});
  final MemoryBankRow row;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        row.type,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '#${row.id}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatDate(row.createdAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  row.content,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).deleteButtonTooltip,
            icon: const Icon(Lucide.Trash2, size: 18),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  String _formatDate(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '${dt.year}-$mm-$dd $hh:$mi';
  }
}

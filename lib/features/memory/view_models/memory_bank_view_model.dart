import 'package:flutter/foundation.dart';

import '../../../core/memory/memory_bank_service.dart';
import '../../../core/database/app_database.dart';

/// View model for the long-term memory bank browser.
///
/// Loads pages of [MemoryBankRow] on demand and exposes simple filter +
/// delete operations. The view is responsible for calling [load] /
/// [refresh] when the user changes the filter; the model never schedules
/// its own reads.
class MemoryBankViewModel extends ChangeNotifier {
  MemoryBankViewModel({required this.service, this.assistantId});

  final MemoryBankService service;
  final String? assistantId;

  String _keyword = '';
  String _type = '';
  List<MemoryBankRow> _rows = const <MemoryBankRow>[];
  MemoryStats _stats = const MemoryStats();
  bool _loading = false;
  String? _error;

  String get keyword => _keyword;
  String get type => _type;
  List<MemoryBankRow> get rows => _rows;
  MemoryStats get stats => _stats;
  bool get loading => _loading;
  String? get error => _error;

  /// Page size for one refresh — small enough that a busy bank stays
  /// snappy, large enough that a few hundred rows fit on screen.
  static const int pageLimit = 200;

  void setKeyword(String value) {
    final next = value.trim();
    if (_keyword == next) return;
    _keyword = next;
    notifyListeners();
  }

  void setType(String value) {
    if (_type == value) return;
    _type = value;
    notifyListeners();
  }

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait(<Future<Object?>>[
        service.searchMemories(
          keyword: _keyword,
          type: _type,
          limit: pageLimit,
          assistantId: assistantId,
        ),
        service.getStats(assistantId),
      ]);
      _rows = (results[0] as List).cast<MemoryBankRow>();
      _stats = results[1] as MemoryStats;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> deleteById(int id) async {
    try {
      await service.deleteMemoryById(id);
      _rows = _rows.where((r) => r.id != id).toList(growable: false);
      _stats = MemoryStats(
        total: mathMax0(_stats.total - 1),
        messageCount: _stats.messageCount,
        summaryCount: _stats.summaryCount,
        manualCount: _stats.manualCount,
        vectorizedCount: _stats.vectorizedCount,
        pendingCount: _stats.pendingCount,
        failedCount: _stats.failedCount,
      );
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  static int mathMax0(int v) => v < 0 ? 0 : v;
}

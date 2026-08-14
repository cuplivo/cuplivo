import 'package:flutter/foundation.dart';

import '../services/workspace/workspace_download_service.dart';

/// Live status of one workspace download job (shaped like the subagent
/// panel's per-slot status). A job is either running, or it has been cancelled
/// by a stop-conversation abort; on normal completion/error it is simply
/// removed from the store.
enum DownloadJobStatus { running, cancelled }

/// A single in-flight workspace `download(url, path)` tool call.
class DownloadJob {
  DownloadJob({
    required this.id,
    required this.conversationId,
    required this.url,
    required this.displayPath,
    required this.abortToken,
  });

  final String id;
  final String conversationId;
  final String url;
  final String displayPath;
  final WorkspaceDownloadAbortToken abortToken;
  final DateTime startedAt = DateTime.now();

  int receivedBytes = 0;
  int? totalBytes;
  DownloadJobStatus status = DownloadJobStatus.running;

  /// Download completion in the inclusive range 0...1, or null when the
  /// server provides no total size.
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0).toDouble();
  }

  /// Whole-number download percentage, or null when unknown (rounds down so
  /// an in-flight download cannot display 100% prematurely).
  int? get percent {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    if (receivedBytes <= 0) return 0;
    if (receivedBytes >= total) return 100;
    return (receivedBytes * 100) ~/ total;
  }
}

/// Root-level store of in-flight workspace downloads, watched by the
/// LivePanel. Jobs are keyed per conversation so the panel renders only the
/// current conversation's downloads. `cancelForConversation` aborts every
/// active download of a stopped conversation (see ADR-0030).
class DownloadProgressStore extends ChangeNotifier {
  final Map<String, DownloadJob> _jobs = <String, DownloadJob>{};
  int _nextId = 0;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _progressNotifyThrottle = Duration(milliseconds: 100);

  /// Registers a new download job and returns its handle.
  DownloadJob begin({
    required String conversationId,
    required String url,
    required String displayPath,
  }) {
    final job = DownloadJob(
      id: 'dl_${_nextId++}',
      conversationId: conversationId,
      url: url,
      displayPath: displayPath,
      abortToken: WorkspaceDownloadAbortToken(),
    );
    _jobs[job.id] = job;
    notifyListeners();
    return job;
  }

  /// Updates a running job's progress. Intermediate updates are throttled to
  /// ~100 ms so a fast transfer does not rebuild the panel per chunk; the
  /// final update is never throttled.
  void updateProgress(DownloadJob job, int receivedBytes, int? totalBytes) {
    if (job.status != DownloadJobStatus.running) return;
    job.receivedBytes = receivedBytes;
    job.totalBytes = totalBytes;
    final now = DateTime.now();
    final elapsed = now.difference(_lastNotify);
    if (elapsed < _progressNotifyThrottle) return;
    _lastNotify = now;
    notifyListeners();
  }

  /// Marks a job finished (success or error) and removes it — the tool-call
  /// card takes over either way.
  void finish(DownloadJob job) {
    _remove(job);
  }

  /// Active (running) jobs for a conversation, in start order.
  List<DownloadJob> runningFor(String conversationId) {
    final out = _jobs.values
        .where(
          (j) =>
              j.conversationId == conversationId &&
              j.status == DownloadJobStatus.running,
        )
        .toList();
    out.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return out;
  }

  /// Aborts every active download of [conversationId] and drops them from the
  /// store (stop-conversation abort — ADR-0030). The in-flight transfer's raw
  /// client is force-closed via each job's abort token.
  void cancelForConversation(String conversationId) {
    final jobs = _jobs.values
        .where(
          (j) =>
              j.conversationId == conversationId &&
              j.status == DownloadJobStatus.running,
        )
        .toList();
    if (jobs.isEmpty) return;
    for (final job in jobs) {
      job.status = DownloadJobStatus.cancelled;
      job.abortToken.abort();
    }
    _jobs.removeWhere(
      (_, j) =>
          j.conversationId == conversationId &&
          j.status != DownloadJobStatus.running,
    );
    notifyListeners();
  }

  void _remove(DownloadJob job) {
    if (_jobs.remove(job.id) != null) notifyListeners();
  }
}

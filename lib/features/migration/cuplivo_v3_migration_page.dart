import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/backup/backup_task_progress.dart';
import '../../core/services/migration/cuplivo_v3/cuplivo_v3_migration.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/restart_app_action.dart';
import '../../utils/platform_utils.dart';

/// One-shot first-run migration screen for a Cuplivo v3 install: reads the
/// old schema-v23 database, restores it into the current one, retires the old
/// file, then asks for an app restart. Runs before any provider exists, so
/// it builds its own minimal scaffold.
class CuplivoV3MigrationPage extends StatefulWidget {
  const CuplivoV3MigrationPage({
    super.key,
    required this.service,
    required this.appDataDirectory,
  });

  final CuplivoV3MigrationService service;
  final Directory appDataDirectory;

  @override
  State<CuplivoV3MigrationPage> createState() => _CuplivoV3MigrationPageState();
}

enum _CuplivoV3MigrationUiState { running, done, failed }

class _CuplivoV3MigrationPageState extends State<CuplivoV3MigrationPage> {
  _CuplivoV3MigrationUiState _uiState = _CuplivoV3MigrationUiState.running;
  CuplivoV3MigrationResult? _result;
  Object? _error;
  BackupPhase? _phase;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _uiState = _CuplivoV3MigrationUiState.running;
      _error = null;
      _result = null;
      _phase = null;
    });
    try {
      final result = await widget.service.run(
        widget.appDataDirectory,
        onPhase: (phase) {
          if (mounted) setState(() => _phase = phase);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _uiState = _CuplivoV3MigrationUiState.done;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _uiState = _CuplivoV3MigrationUiState.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: switch (_uiState) {
                _CuplivoV3MigrationUiState.running => _RunningStep(
                  l10n: l10n,
                  theme: theme,
                  phase: _phase,
                ),
                _CuplivoV3MigrationUiState.done => _DoneStep(
                  l10n: l10n,
                  theme: theme,
                  result: _result!,
                  onRestart: () =>
                      requestAppRestart(context, PlatformUtils.restartApp),
                ),
                _CuplivoV3MigrationUiState.failed => _FailedStep(
                  l10n: l10n,
                  theme: theme,
                  error: _error,
                  onRetry: _run,
                ),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RunningStep extends StatelessWidget {
  const _RunningStep({required this.l10n, required this.theme, this.phase});

  final AppLocalizations l10n;
  final ThemeData theme;
  final BackupPhase? phase;

  @override
  Widget build(BuildContext context) {
    final detail = switch (phase) {
      BackupPhase.extracting => l10n.cuplivoV3MigrationPhaseReading,
      BackupPhase.committing => l10n.cuplivoV3MigrationPhaseWriting,
      _ => l10n.cuplivoV3MigrationPhasePreparing,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 24),
        Text(
          l10n.cuplivoV3MigrationTitle,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _DoneStep extends StatelessWidget {
  const _DoneStep({
    required this.l10n,
    required this.theme,
    required this.result,
    required this.onRestart,
  });

  final AppLocalizations l10n;
  final ThemeData theme;
  final CuplivoV3MigrationResult result;
  final Future<void> Function() onRestart;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Lucide.Check, size: 48, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          l10n.cuplivoV3MigrationSuccessTitle,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.cuplivoV3MigrationSuccessCounts(
            result.conversationCount,
            result.messageCount,
          ),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.cuplivoV3MigrationSuccessHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => onRestart(),
          child: Text(l10n.cuplivoV3MigrationRestartButton),
        ),
      ],
    );
  }
}

class _FailedStep extends StatelessWidget {
  const _FailedStep({
    required this.l10n,
    required this.theme,
    required this.error,
    required this.onRetry,
  });

  final AppLocalizations l10n;
  final ThemeData theme;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Lucide.TriangleAlert, size: 48, color: theme.colorScheme.error),
        const SizedBox(height: 16),
        Text(
          l10n.cuplivoV3MigrationFailedTitle,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.cuplivoV3MigrationFailedHint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            error.toString(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: onRetry,
          child: Text(l10n.cuplivoV3MigrationRetryButton),
        ),
      ],
    );
  }
}

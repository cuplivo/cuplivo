import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/settings/widgets/memory_ui.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';

void main() {
  test('known codes return translated text', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      memoryOutcomeLabel(l10n, 'empty_window'),
      l10n.memoryOutcomeEmptyWindow,
    );
    expect(
      memoryOutcomeLabel(l10n, 'below_threshold'),
      l10n.memoryOutcomeBelowThreshold,
    );
    expect(
      memoryOutcomeLabel(l10n, 'memory_model_unset'),
      l10n.memoryOutcomeMemoryModelUnset,
    );
    expect(memoryOutcomeLabel(l10n, 'empty_window'), isNot('empty_window'));
  });

  test('prefixed codes match by prefix', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      memoryOutcomeLabel(l10n, 'gate_request_failed:SocketException'),
      l10n.memoryOutcomeGateRequestFailed,
    );
    expect(
      memoryOutcomeLabel(l10n, 'extract_request_failed:timeout'),
      l10n.memoryOutcomeExtractRequestFailed,
    );
  });

  test('unknown codes return the raw string', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(memoryOutcomeLabel(l10n, 'not_a_real_code'), 'not_a_real_code');
    expect(
      memoryOutcomeLabel(l10n, 'gate_request_failed_typo'),
      'gate_request_failed_typo',
    );
  });
}

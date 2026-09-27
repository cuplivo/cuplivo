import 'package:Cuplivo/core/database/business_data.dart';
import 'package:Cuplivo/core/database/business_settings_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the sync face's membership. These lists are the single authority for
/// what LAN sync carries (ADR-0002 decision 6), so a change here is a change to
/// the wire face and should be a deliberate edit to this expectation too.
void main() {
  const synced = BusinessKeyRegistry.syncedPreferenceKeys;

  test('the synced set is a subset of the business preferences', () {
    for (final key in synced) {
      expect(
        BusinessKeyRegistry.preferenceKeys,
        contains(key),
        reason: '$key must still be an ordinary business preference',
      );
    }
  });

  test('every synced key classifies as syncedPreference', () {
    for (final key in synced) {
      expect(
        BusinessKeyRegistry.classify(key),
        BusinessKeyDisposition.syncedPreference,
        reason: key,
      );
    }
  });

  test('device-local keys are excluded by the new-device test', () {
    const deviceLocal = <String>[
      // Session position: where this device is looking, not how the app is set
      // up.
      'current_assistant_id_v1',
      'selected_model_v1',
      // Platform and window facts.
      'window_width_v1',
      'display_chat_font_scale_v1',
      'flutter_log_enabled_v1',
      // Local network environment.
      'global_proxy_enabled_v1',
      'global_proxy_host_v1',
      // Platform fallbacks and runtime state.
      'tts_engine_v1',
      'tts_language_v1',
      'app_launch_count_v1',
      'memory_trace_enabled_v1',
      'instruction_injections_active_ids_by_assistant_v1',
      'search_auto_test_on_launch_v1',
    ];
    for (final key in deviceLocal) {
      expect(synced, isNot(contains(key)), reason: key);
      expect(
        BusinessKeyRegistry.classify(key),
        isNot(BusinessKeyDisposition.syncedPreference),
        reason: key,
      );
    }
  });

  test('an unclassified key is fail-closed', () {
    expect(
      BusinessKeyRegistry.classify('some_future_key_v1'),
      BusinessKeyDisposition.unknownPreference,
    );
    expect(synced, isNot(contains('some_future_key_v1')));
  });

  test('skills and workspaces are entities but not part of this slice', () {
    // Both are entities to the router; the sync face adds its own exclusion
    // until skills travel with their directory blob (slice 3) and workspaces
    // stay device-local forever.
    for (final kind in [
      BusinessEntityKind.skill,
      BusinessEntityKind.workspace,
    ]) {
      expect(
        BusinessKeyRegistry.classify(kind.sourceKey),
        BusinessKeyDisposition.entity,
      );
    }
  });

  test('the synced face covers what a new device needs', () {
    // Named anchors from the ADR: assistants and providers are entities, and
    // these are the preference-side essentials.
    expect(synced, containsAll(<String>['user_name', 'avatar_type']));
    expect(synced, containsAll(<String>['theme_mode_v1', 'app_locale_v1']));
    expect(synced, containsAll(<String>['pinned_models_v1']));
    expect(synced, containsAll(<String>['webdav_config_v1', 's3_config_v1']));
    expect(
      BusinessKeyRegistry.classify(BusinessEntityKind.assistant.sourceKey),
      BusinessKeyDisposition.entity,
    );
    expect(
      BusinessKeyRegistry.classify(BusinessEntityKind.provider.sourceKey),
      BusinessKeyDisposition.entity,
    );
  });
}

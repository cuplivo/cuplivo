/// Classification schema for business-preference keys.
///
/// Mirrors upstream Kelivo's `BusinessKeyRegistry` (where every key has a
/// storage destination) with Cuplivo-specific localOnly additions:
/// `codex_oauth_v1` / `grok_oauth_v1` (OAuth secrets) and `chat_draft_v1`
/// (per-device transient UI state) are exempt from migration and backup,
/// exactly like the device-bound keys in `SharedPreferencesAsync._localOnlyKeys`.
///
/// Classification:
/// - `localOnly` — never migrated, never backed up, stays in SharedPreferences.
/// - `discarded` — legacy junk, dropped/ignored on migration.
/// - `entity` — owned by another subsystem (assistants_v1 → typed
///   `assistant_rows`); the business layer must not touch it.
/// - `preference` / `unknownPreference` — business data, migrated into the KV
///   table. Unknown keys default to business (the registry is a guard list,
///   not an allow-list), so new keys migrate without registry edits.
library;

enum BusinessKeyDisposition {
  localOnly,
  discarded,
  entity,
  providerOrder,
  preference,
  unknownPreference,
}

final class BusinessKeyRegistry {
  BusinessKeyRegistry._();

  static const localOnlyKeys = <String>{
    // Upstream Kelivo localOnly set.
    'window_width_v1',
    'window_height_v1',
    'window_pos_x_v1',
    'window_pos_y_v1',
    'window_maximized_v1',
    'desktop_hotkeys_commands_v1',
    'desktop_hotkeys_enabled_v1',
    'display_chat_font_scale_v1',
    'flutter_log_enabled_v1',
    // Upstream #555 (experimental WebView chat viewport): device-local UI
    // toggle, excluded from backup/restore snapshots (upstream keeps it in
    // its raw SharedPreferences localOnly set; our migration must skip it).
    'experimental_webview_rendering_v1',
    // Cuplivo additions: never leave the device, never migrate.
    'codex_oauth_v1',
    'grok_oauth_v1',
    'chat_draft_v1',
    // Last successfully used LAN sync server endpoints (initiator-side
    // convenience prefill); meaningless on another device.
    'lan_sync_recent_endpoints_v1',
    // User-relocatable @workspaces host directory (desktop-only host path);
    // AppDirectories reads it straight from SharedPreferences.
    'workspaces_dir_v1',
  };

  static const discardedKeys = <String>{
    // Upstream discards several keys here (pinned_chat_ids, chat_titles_map,
    // instruction_injections_active_id_v1, instruction_injections_active_ids_v1,
    // migrations_version_v1, provider_configs_backup_v1). In Cuplivo ALL of
    // them are still live (ChatProvider, InstructionInjectionStore, and
    // SettingsProvider's one-shot migrations read/write them), so none may be
    // dropped. A truly-dead key may be listed here in the future after
    // verifying no reader/writer remains — the facade throws on any write.
  };

  static const entityKeys = <String>{'assistants_v1'};

  static const providerOrderKey = 'providers_order_v1';

  static BusinessKeyDisposition classify(String key) {
    if (entityKeys.contains(key)) return BusinessKeyDisposition.entity;
    if (key == providerOrderKey) return BusinessKeyDisposition.providerOrder;
    if (localOnlyKeys.contains(key) || key.startsWith('restore_')) {
      return BusinessKeyDisposition.localOnly;
    }
    if (discardedKeys.contains(key)) {
      return BusinessKeyDisposition.discarded;
    }
    return BusinessKeyDisposition.unknownPreference;
  }
}

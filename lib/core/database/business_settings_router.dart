import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/assistant.dart';
import 'business_data.dart';

/// What a key does: where it lives, and what carries it.
///
/// The four *stored* classes are the four sets this registry used to keep by
/// hand, plus the class the old design hid in a second list
/// (`BackupPortability.devicePreferenceKeys`): a business preference this device
/// keeps to itself.
enum KeyPolicy {
  /// A business preference that rides LAN sync and a travelling backup.
  synced,

  /// A business preference that rides a backup but never a pairing.
  backupOnly,

  /// A business preference stored on this device and carried nowhere: the
  /// portability layer strips it from a backup that travels.
  deviceLocal,

  /// A platform preference. It never enters the business store at all, so it can
  /// ride neither a backup nor a pairing.
  platformOnly,

  /// A legacy key the app only reads in order to drop it.
  discarded,
}

/// Why a key has its policy — a closed list on purpose.
///
/// This registry's defects were all a prose comment that turned out to be wrong,
/// missing, or attached to the wrong key. Prose cannot be checked by CI, and a
/// reason that cannot be checked is how "backed up, never synced" stayed
/// indistinguishable from "deliberately local" for 109 keys.
enum PolicyReason {
  /// Ownership and order for an entity kind whose rows travel: which provider
  /// belongs to which group, which world books an assistant enables.
  syncCompanionOfEntity,

  /// Configuration a new device should arrive with (ADR-0003 decision 6).
  newDeviceConfiguration,

  /// What this device is showing: collapsed sets, open panels, the last tab.
  deviceViewState,

  /// Window and panel geometry.
  windowGeometry,

  /// Where this device is looking in a session.
  sessionPosition,

  /// An OS or hardware feature, or a fallback for one.
  platformCapability,

  /// This device's network path, and its patience with it.
  networkEnvironment,

  /// Runtime state and diagnostics: logs, counters, cached readings, recovery
  /// hints.
  runtimeDiagnostics,

  /// A schedule or a run stamp of this device (snapshots, reminders, tasks).
  deviceScheduleState,

  /// A location on this device's filesystem.
  deviceStoragePath,

  /// Bookkeeping from an older data shape.
  legacyBookkeeping,

  /// No recorded reason.
  ///
  /// A key here is device-local *today* because nobody wrote down why, not
  /// because the new-device test says it stays. That is the state the old
  /// registry could not distinguish from a deliberate exclusion; it is now an
  /// explicit list a test pins, so it can only shrink.
  notYetReviewed,
}

final class KeyRule {
  const KeyRule(this.policy, this.reason, [this.note = '']);

  final KeyPolicy policy;
  final PolicyReason reason;

  /// For the reader only. Never an input to a test or to a decision: the reason
  /// enum is what CI can check.
  final String note;
}

final class BusinessKeyRegistry {
  BusinessKeyRegistry._();

  /// Not a stored key: [BusinessSettingsRouter.exportSnapshot] projects the
  /// provider order from the provider rows' `sort_order`, and the runtime view is
  /// republished from those rows, so the order travels with the rows themselves
  /// (ADR-0003 slice 2; the entity digest covers the position since slice 8). It
  /// has no policy row because it has no row.
  static const providerOrderKey = 'providers_order_v1';

  static bool isProviderOrder(String key) => key == providerOrderKey;

  /// The name shape of a preference key the app itself owns: `…_vN`.
  ///
  /// One definition, two guards — the `setMany` debug assert and the writer scan
  /// in `business_key_registry_sync_test.dart` both read this, so widening the
  /// convention cannot leave one of them blind to what the other enforces.
  static final appKeyPattern = RegExp(r'^[a-z][a-z0-9_]*_v\d+$');

  /// One row per key the app can write. This table is the whole authority: a key
  /// outside it is fail-closed — never synced, never treated as a business
  /// preference — and, in a debug build, a bug: the writer scan in
  /// `business_key_registry_sync_test.dart` fails on it.
  ///
  /// Rows are grouped by policy and then by reason, so "what does sync do with
  /// this family" is one section rather than a search.
  static const rules = <String, KeyRule>{
    // synced — the ownership and order of a synced entity
    'assistant_tag_map_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.syncCompanionOfEntity,
      'assistantId → tagId. The tags and the assistants are rows that travel; the assignment between them is this key.',
    ),
    'chat_owner_order_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.syncCompanionOfEntity,
      'The sidebar\'s mixed assistant/group order. The owners are rows, but their own sort_order no longer carries this order.',
    ),
    'instruction_injections_active_ids_by_assistant_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.syncCompanionOfEntity,
      'assistantId → the injection ids that assistant has enabled. \'__global__\' is the default row.',
    ),
    'mcp_presentation_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.syncCompanionOfEntity,
      'MCP groups, each server\'s group and icon, and the collapsed set. The collapsed set rides because the ownership half is co-stored in this one blob — the single carve-out from "view state stays home".',
    ),
    'provider_group_map_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.syncCompanionOfEntity,
      'providerKey → groupId. The groups and the providers are rows that travel; the assignment between them is this key.',
    ),
    'provider_ungrouped_position_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.syncCompanionOfEntity,
      'Where the synthetic "ungrouped" bucket sits in the group order. A group\'s own order travels in its row\'s sort_order; without this the bucket lands wherever the receiving device defaults.',
    ),
    'world_books_active_ids_by_assistant_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.syncCompanionOfEntity,
      'assistantId → the world book ids that assistant has enabled. \'__global__\' is the default row.',
    ),

    // synced — configuration a new device wants as its own
    'app_locale_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'asr_selected_service_id_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'asr_services_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'avatar_type': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'avatar_value': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'backup_reminder_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'backup_reminder_interval_days_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'backup_reminder_minutes_of_day_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'chat_bubble_style_overrides_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'compress_generation_thinking_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'compress_keep_user_messages_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'compress_limit_mode_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'compress_max_chars_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'compress_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'compress_prompt_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'compression_defaults_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'native_compression_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'custom_theme_selected_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
      'Half of the definition behind theme_palette_v1 = \'custom\'; see custom_themes_v1.',
    ),
    'custom_themes_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
      'A custom palette is *named* by theme_palette_v1 (\'custom\') and *defined* by this and custom_theme_selected_v1. A name without the definition lands a new device on a palette it cannot resolve.',
    ),
    'group_director_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_extract_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_extract_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_gate_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_gate_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_injection_max_items_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_legacy_mode_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_legacy_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_legacy_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_migrate_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_migrate_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_migration_batch_size_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_model_thinking_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_profile_distill_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_profile_distill_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_prompt_lang_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_rules_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_rules_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_smart_add_batch_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_smart_add_batch_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_smart_add_prompt_en_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'memory_smart_add_prompt_zh_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'ocr_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'ocr_generation_thinking_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'ocr_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'ocr_prompt_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'pinned_models_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    's3_config_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'search_common_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'search_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'search_selected_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'suggestion_generation_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'suggestion_generation_thinking_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'suggestion_insert_on_tap_only_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'suggestion_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'suggestion_prompt_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'summary_generation_thinking_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'summary_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'summary_prompt_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'theme_mode_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'theme_palette_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'title_generation_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'title_generation_thinking_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'title_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'title_prompt_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'tool_schema_overrides_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'translate_generation_thinking_enabled_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'translate_model_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'translate_prompt_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'translate_target_lang_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'translate_visible_languages_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'tts_pitch_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'tts_selected_service_id_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'tts_speech_rate_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'use_dynamic_color_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),
    'user_name': KeyRule(KeyPolicy.synced, PolicyReason.newDeviceConfiguration),
    'webdav_config_v1': KeyRule(
      KeyPolicy.synced,
      PolicyReason.newDeviceConfiguration,
    ),

    // deviceLocal — a schedule or run stamp of this device
    'desktop_scheduled_tasks_v1': KeyRule(
      KeyPolicy.deviceLocal,
      PolicyReason.deviceScheduleState,
      'Scheduled tasks run on this device\'s clock; the portability layer strips them from a backup that travels.',
    ),
    'scheduled_task_results_v1': KeyRule(
      KeyPolicy.deviceLocal,
      PolicyReason.deviceScheduleState,
      'Run stamps for the tasks above.',
    ),

    // deviceLocal — a fact about this device's sandbox
    'environment_proot_options_v1': KeyRule(
      KeyPolicy.deviceLocal,
      PolicyReason.platformCapability,
      'How this device runs PRoot.',
    ),
    'environment_state_v1': KeyRule(
      KeyPolicy.deviceLocal,
      PolicyReason.platformCapability,
    ),

    // deviceLocal — runtime state and diagnostics
    'environment_disk_usage_v1': KeyRule(
      KeyPolicy.deviceLocal,
      PolicyReason.runtimeDiagnostics,
    ),

    // deviceLocal — a location on this device's filesystem
    'environment_rootfs_selection_v1': KeyRule(
      KeyPolicy.deviceLocal,
      PolicyReason.deviceStoragePath,
      'A path on this device, and the portability layer strips it from a backup that travels.',
    ),

    // deviceLocal — no recorded reason
    'backup_encryption_enabled_v1': KeyRule(
      KeyPolicy.deviceLocal,
      PolicyReason.notYetReviewed,
      'Stripped from a travelling backup by the portability layer. Whether that is deliberate or an oversight was never recorded — the reason says so instead of inventing one.',
    ),

    // backupOnly — how this device shows things
    'assistant_tag_collapsed_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'desktop_right_sidebar_open_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'desktop_side_panel_last_kind_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'desktop_side_panel_open_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'desktop_side_panel_tabs_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'desktop_sidebar_open_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'desktop_topic_position_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'desktop_workspace_bar_open_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_app_font_family_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_app_font_is_google_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_app_font_local_alias_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_assistant_bubble_fit_content_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_assistant_bubble_split_paragraphs_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_auto_collapse_code_block_lines_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_auto_collapse_code_block_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_auto_collapse_thinking_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_auto_scroll_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_chat_background_mask_strength_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_chat_input_background_opacity_dark_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_chat_input_background_opacity_light_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_chat_message_background_style_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_chat_tools_expanded_groups_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_code_font_family_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_code_font_is_google_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_code_font_local_alias_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_collapse_long_user_message_chars_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_collapse_long_user_messages_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_collapse_thinking_steps_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_desktop_auto_switch_topics_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_desktop_message_nav_buttons_mode_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_desktop_minimize_to_tray_on_close_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_desktop_show_tray_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_enable_assistant_markdown_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_enable_dollar_latex_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_enable_math_rendering_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_enable_reasoning_markdown_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_enable_user_markdown_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_enter_to_send_on_mobile_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_haptics_global_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_haptics_ios_switch_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_haptics_on_card_tap_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_haptics_on_drawer_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_haptics_on_generate_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_haptics_on_list_item_tap_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_hide_tool_result_images_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_keep_assistant_list_expanded_on_sidebar_close_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_keep_screen_on_during_generation_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_keep_sidebar_open_on_assistant_tap_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_keep_sidebar_open_on_topic_tap_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_long_paste_as_file_threshold_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_long_paste_as_file_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_mobile_code_block_wrap_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_mobile_message_nav_buttons_mode_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_new_chat_after_delete_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_new_chat_on_assistant_switch_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_new_chat_on_launch_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_regenerate_delete_trailing_messages_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_app_updates_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_browser_page_cards_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_chat_list_date_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_genui_header_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_message_nav_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_model_icon_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_model_name_timestamp_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_model_name_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_model_timestamp_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_produced_files_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_provider_in_chat_message_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_provider_in_model_capsule_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_reasoning_level_badge_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_regenerate_confirm_dialog_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_thinking_cards_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_token_stats_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_tool_cards_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_tool_result_summary_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_total_tokens_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_user_avatar_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_user_message_actions_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_user_name_timestamp_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_user_name_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_show_user_timestamp_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_use_layered_sheet_tiles_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_use_layered_surfaces_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_use_legacy_inline_code_style_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_use_new_assistant_avatar_ux_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'display_use_pure_background_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'instruction_injection_group_collapsed_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'mobile_assistant_detail_outline_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'mobile_assistant_edit_tab_hidden_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'mobile_assistant_edit_tab_order_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'provider_group_collapsed_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    'world_books_collapsed_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceViewState,
    ),
    // backupOnly — this device's panel geometry
    'desktop_right_sidebar_width_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.windowGeometry,
    ),
    'desktop_side_panel_width_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.windowGeometry,
    ),
    'desktop_sidebar_width_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.windowGeometry,
    ),

    // backupOnly — where this device is looking in a session
    'current_assistant_id_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.sessionPosition,
    ),
    'selected_model_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.sessionPosition,
    ),

    // backupOnly — a platform feature or fallback
    'android_background_chat_mode_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'desktop_send_shortcut_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'environment_privacy_mode_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'environment_variables_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'ios_background_generation_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'ios_background_notifications_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'ios_background_task_refresh_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'ios_live_activity_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'mobile_background_settings_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'tts_engine_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'tts_language_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),
    'tts_selected_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.platformCapability,
    ),

    // backupOnly — this device's network path and its patience
    'environment_mirrors_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'global_proxy_bypass_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'global_proxy_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'global_proxy_host_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'global_proxy_password_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'global_proxy_port_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'global_proxy_type_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'global_proxy_username_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),
    'mcp_request_timeout_ms_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
      'Describes this device\'s patience with its own network, not the MCP setup — which is why MCP\'s presentation syncs and this does not.',
    ),
    'search_auto_test_on_launch_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.networkEnvironment,
    ),

    // backupOnly — runtime state and diagnostics
    'app_launch_count_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'context_log_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'log_auto_delete_days_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'log_elide_large_payloads_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'log_max_size_mb_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'log_save_output_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'memory_trace_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'orphaned_conversations_assistant_id_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),
    'request_log_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.runtimeDiagnostics,
    ),

    // backupOnly — a schedule or run stamp of this device
    'backup_reminder_enabled_at_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'backup_reminder_last_backup_at_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_announce_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_failure_streak_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_fingerprint_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_first_observed_at_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_interval_days_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_keep_monthly_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_keep_recent_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_keep_weekly_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_last_failure_at_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_last_failure_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_last_skip_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_last_success_at_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),
    'local_snapshot_max_total_bytes_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceScheduleState,
    ),

    // backupOnly — a location on this device's filesystem
    'display_app_font_local_path_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceStoragePath,
    ),
    'display_code_font_local_path_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.deviceStoragePath,
    ),

    // backupOnly — bookkeeping from an older data shape
    'desktop_side_panel_migrated_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.legacyBookkeeping,
    ),

    // backupOnly — no recorded reason
    // Found by making the writer scan exhaustive (review of #1068): it used to
    // read only `_vN`-shaped names, so this key passed both guards unseen. It is
    // backed up today, which is what `backupOnly` says, and whether a paired
    // device should get it has never been decided — which is what
    // `notYetReviewed` says instead of inventing a reason.
    'auto_retry_options': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
      'API retry attempts and backoff, set on the provider settings page. The '
      'new-device test would probably accept it; nobody has decided.',
    ),
    'chat_bubble_style_overrides_user_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'chat_edit_assistant_keep_thinking_tool_cards_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'chat_fork_keep_message_versions_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'image_compress_custom_quality_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'image_compress_transparent_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'image_compression_mode_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'image_cropper_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'image_upload_quality_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'learning_mode_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'learning_mode_prompt_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'manual_compress_format_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'manual_compress_max_long_edge_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'manual_compress_quality_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'memory_full_injection_types_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'per_chat_model_enabled_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'proactive_care_decision_model_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'reasoning_choice_by_model_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'search_web_fetch_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'send_markdown_image_links_as_images_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'tts_auto_play_assistant_replies_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'tts_cache_network_audio_for_replay_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),
    'tts_text_selection_mode_v1': KeyRule(
      KeyPolicy.backupOnly,
      PolicyReason.notYetReviewed,
    ),

    // platformOnly — this device's window geometry
    'window_height_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.windowGeometry,
    ),
    'window_maximized_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.windowGeometry,
    ),
    'window_physical_pos_x_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.windowGeometry,
    ),
    'window_physical_pos_y_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.windowGeometry,
    ),
    'window_pos_x_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.windowGeometry,
    ),
    'window_pos_y_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.windowGeometry,
    ),
    'window_width_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.windowGeometry,
    ),

    // platformOnly — how this device shows things
    'display_chat_font_scale_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.deviceViewState,
    ),

    // platformOnly — a platform feature or fallback
    'desktop_hotkeys_commands_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.platformCapability,
    ),
    'desktop_hotkeys_enabled_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.platformCapability,
    ),
    'ios_native_selection_menu_enabled_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.platformCapability,
    ),
    'linux_hide_title_bar_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.platformCapability,
    ),

    // platformOnly — runtime state and diagnostics
    'flutter_log_enabled_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.runtimeDiagnostics,
    ),

    // platformOnly — this device's network path
    'model_catalog_auto_update_v1': KeyRule(
      KeyPolicy.platformOnly,
      PolicyReason.networkEnvironment,
    ),

    // discarded — read only to drop it
    'chat_titles_map': KeyRule(
      KeyPolicy.discarded,
      PolicyReason.legacyBookkeeping,
    ),
    'instruction_injections_active_id_v1': KeyRule(
      KeyPolicy.discarded,
      PolicyReason.legacyBookkeeping,
    ),
    'instruction_injections_active_ids_v1': KeyRule(
      KeyPolicy.discarded,
      PolicyReason.legacyBookkeeping,
    ),
    'migrations_version_v1': KeyRule(
      KeyPolicy.discarded,
      PolicyReason.legacyBookkeeping,
    ),
    'pinned_chat_ids': KeyRule(
      KeyPolicy.discarded,
      PolicyReason.legacyBookkeeping,
    ),
    'provider_configs_backup_v1': KeyRule(
      KeyPolicy.discarded,
      PolicyReason.legacyBookkeeping,
    ),
  };

  /// Which preference keys organize which entity kind.
  ///
  /// A kind whose rows travel must not reach a new device as an unorganized
  /// pile: groups, tags and per-assistant selections are only meaningful beside
  /// the rows they name. The test walks [BusinessEntityKind.values], so a new
  /// kind must add a row — empty when it needs no companion — and every
  /// companion listed here must be `synced`.
  static const companionKeys = <BusinessEntityKind, Set<String>>{
    BusinessEntityKind.assistant: {
      'assistant_tag_map_v1',
      'chat_owner_order_v1',
      'instruction_injections_active_ids_by_assistant_v1',
      'world_books_active_ids_by_assistant_v1',
    },
    BusinessEntityKind.provider: {'provider_group_map_v1'},
    BusinessEntityKind.providerGroup: {
      'provider_group_map_v1',
      'provider_ungrouped_position_v1',
    },
    BusinessEntityKind.mcpServer: {'mcp_presentation_v1'},
    BusinessEntityKind.worldBook: {'world_books_active_ids_by_assistant_v1'},
    BusinessEntityKind.assistantMemory: {},
    BusinessEntityKind.quickPhrase: {},
    BusinessEntityKind.searchService: {},
    BusinessEntityKind.ttsService: {},
    BusinessEntityKind.instructionInjection: {
      'instruction_injections_active_ids_by_assistant_v1',
    },
    BusinessEntityKind.assistantTag: {'assistant_tag_map_v1'},
    BusinessEntityKind.memoryEntry: {},
    BusinessEntityKind.workspace: {},
    BusinessEntityKind.skill: {},
    BusinessEntityKind.groupChat: {'chat_owner_order_v1'},
    BusinessEntityKind.userProfileField: {},
  };

  static KeyRule? ruleFor(String key) => rules[key];

  static KeyPolicy? policyOf(String key) => rules[key]?.policy;

  /// Whether LAN sync carries this key (ADR-0003 decision 6).
  static bool isSynced(String key) => policyOf(key) == KeyPolicy.synced;

  static bool isDeviceLocal(String key) =>
      policyOf(key) == KeyPolicy.deviceLocal;

  /// Whether the table registers this key as one that lives in the business
  /// store (`preference_rows`): a platform preference does not, and a discarded
  /// key is only read to be dropped.
  ///
  /// **False means unregistered, not unstorable.** The router still stores a key
  /// the table does not know — it is routed into preferences and only kept out
  /// of sync (see `normalizeAndRoute`) — so a restore/import guard asking "may
  /// this key be in `preference_rows`" must not use this predicate, or it drops
  /// every key a newer build introduced.
  static bool isRegisteredInBusinessStore(String key) =>
      _storedPolicies.contains(policyOf(key));

  /// The policies whose keys are rows in the business store.
  static const _storedPolicies = {
    KeyPolicy.synced,
    KeyPolicy.backupOnly,
    KeyPolicy.deviceLocal,
  };

  /// A platform preference, or one of the restore progress markers — those are
  /// minted per run, so they are a prefix family rather than table rows.
  static bool isPlatformOnly(String key) =>
      policyOf(key) == KeyPolicy.platformOnly || key.startsWith(_restorePrefix);

  static bool isDiscarded(String key) => policyOf(key) == KeyPolicy.discarded;

  /// The entity kind whose rows this source key names, or null when the key is
  /// not an entity at all.
  static BusinessEntityKind? entityKindFor(String key) {
    for (final kind in BusinessEntityKind.values) {
      if (kind.sourceKey == key) return kind;
    }
    return null;
  }

  static const _restorePrefix = 'restore_';
}

final class BusinessSettingsRouter {
  BusinessSettingsRouter._();

  static const _providerOrderKey = BusinessKeyRegistry.providerOrderKey;
  // Storage-only row for an ordered key that has no persisted config. The
  // invalid `enabled` type prevents collision with a routed Provider payload.
  static const _providerOrderOnlyPayload =
      '{"enabled":"__kelivo_provider_order_only__"}';
  static const _legacyPinnedModelsKey = 'pinned_models_v1';
  static const _instructionInjectionsKey = 'instruction_injections_v1';
  static const _legacyActiveIdKey = 'instruction_injections_active_id_v1';
  static const _legacyActiveIdsKey = 'instruction_injections_active_ids_v1';
  static const _activeIdsByAssistantKey =
      'instruction_injections_active_ids_by_assistant_v1';
  static const _searchEnabledKey = 'search_enabled_v1';
  static const _globalAssistantKey = '__global__';
  static const _embeddingTypes = <String>{'embedding', 'embeddings'};
  static const _embeddingChatOnlyFields = <String>{
    'abilities',
    'output',
    'builtInTools',
    'built_in_tools',
    'tools',
  };

  /// Preserve an empty instruction list only at legacy input boundaries.
  /// Canonical SQLite exports always contain every entity key, so their `[]`
  /// cannot by itself distinguish an uninitialized table from a user clear.
  static BusinessSnapshot normalizeAndRoute(
    Map<String, Object?> source, {
    bool preserveExplicitEmptyInstructionList = false,
    Map<String, Object?>? entityRowIds,
    bool assumePreV3EmbeddingMigrationWhenVersionMissing = false,
  }) {
    final normalized = Map<String, Object?>.from(source);
    final rowIdsByKind = _rowIdsByKind(entityRowIds, source);
    final rawMigrationVersion = normalized['migrations_version_v1'];
    final shouldNormalizeLegacyEmbeddingOverrides = rawMigrationVersion is int
        ? rawMigrationVersion < 3
        : rawMigrationVersion == null &&
              assumePreV3EmbeddingMigrationWhenVersionMissing;
    _normalizeStringList(normalized, _providerOrderKey);
    _normalizeStringList(normalized, _legacyPinnedModelsKey);
    _normalizeInstructionActivation(
      normalized,
      preserveExplicitEmptyList: preserveExplicitEmptyInstructionList,
    );

    final entities = <BusinessEntityKind, List<BusinessEntityValue>>{};
    for (final kind in BusinessEntityKind.values) {
      entities[kind] = kind == BusinessEntityKind.provider
          ? _routeProviders(
              normalized,
              normalizeLegacyEmbeddingOverrides:
                  shouldNormalizeLegacyEmbeddingOverrides,
            )
          : _routeList(kind, normalized, rowIdsByKind[kind]);
    }

    final preferences = <String, Object>{};
    for (final entry in normalized.entries) {
      // Entities, the provider-order projection and the keys that live outside
      // business data never become preferences here; a key the table does not
      // know is still routed, exactly as it was before the table existed, but it
      // never syncs.
      if (BusinessKeyRegistry.entityKindFor(entry.key) != null ||
          BusinessKeyRegistry.isProviderOrder(entry.key) ||
          BusinessKeyRegistry.isPlatformOnly(entry.key) ||
          BusinessKeyRegistry.isDiscarded(entry.key)) {
        continue;
      }
      final value = entry.value;
      if (value == null) continue;
      preferences[entry.key] = _validatePreferenceValue(entry.key, value);
    }
    return BusinessSnapshot(entities: entities, preferences: preferences);
  }

  static Map<String, Object> exportSnapshot(BusinessSnapshot snapshot) {
    final result = <String, Object>{};
    for (final kind in BusinessEntityKind.values) {
      final rows = List<BusinessEntityValue>.of(snapshot.entities[kind]!)
        ..sort(_compareRows);
      if (kind == BusinessEntityKind.provider) {
        final providers = <String, Object?>{};
        for (final row in rows) {
          if (!isProviderOrderOnlyRow(row)) {
            providers[row.id] = _decodePayload(row.payload, kind.sourceKey);
          }
        }
        result[kind.sourceKey] = jsonEncode(providers);
        result[_providerOrderKey] = rows.map((row) => row.id).toList();
      } else {
        result[kind.sourceKey] = jsonEncode(
          rows
              .map((row) => _decodePayload(row.payload, kind.sourceKey))
              .toList(growable: false),
        );
      }
    }
    result.addAll(snapshot.preferences);
    return result;
  }

  static BusinessSettingsExport exportSnapshotWithRowIds(
    BusinessSnapshot snapshot,
  ) {
    final entityRowIds = <String, List<String>>{};
    for (final kind in BusinessEntityKind.values) {
      if (kind == BusinessEntityKind.provider) continue;
      final rows = List<BusinessEntityValue>.of(snapshot.entities[kind]!)
        ..sort(_compareRows);
      entityRowIds[kind.sourceKey] = rows.map((row) => row.id).toList();
    }
    return (settings: exportSnapshot(snapshot), entityRowIds: entityRowIds);
  }

  /// Builds the legacy key-value-compatible view consumed by runtime
  /// providers. Stable row ids are projected into list payloads that came
  /// from legacy data without an id; assistant memories use deterministic
  /// negative ids so they stay outside the persisted positive-id space.
  /// [exportSnapshot] deliberately preserves the published payload byte shape
  /// used by backup validation.
  static Map<String, Object> exportRuntimeSnapshot(BusinessSnapshot snapshot) {
    final result = exportSnapshot(snapshot);
    for (final kind in BusinessEntityKind.values) {
      if (kind == BusinessEntityKind.provider) continue;
      final rows = List<BusinessEntityValue>.of(snapshot.entities[kind]!)
        ..sort(_compareRows);
      final projectedMemoryIds = kind == BusinessEntityKind.assistantMemory
          ? _projectMemoryIds(rows)
          : const <String, int>{};
      result[kind.sourceKey] = jsonEncode([
        for (final row in rows)
          () {
            final payload = Map<String, Object?>.from(
              (_decodePayload(row.payload, kind.sourceKey) as Map).map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            );
            final rawId = payload['id'];
            if (rawId == null || rawId.toString().trim().isEmpty) {
              payload['id'] = kind == BusinessEntityKind.assistantMemory
                  ? projectedMemoryIds[row.id]!
                  : row.id;
            }
            if (kind == BusinessEntityKind.assistant) {
              _validateRuntimeAssistant(payload);
            }
            return payload;
          }(),
      ]);
    }
    return result;
  }

  static List<BusinessEntityValue> _routeProviders(
    Map<String, Object?> source, {
    required bool normalizeLegacyEmbeddingOverrides,
  }) {
    final key = BusinessEntityKind.provider.sourceKey;
    final rawOrder = source[_providerOrderKey];
    final order = rawOrder == null
        ? const <String>[]
        : _stringList(rawOrder, _providerOrderKey);
    final raw = source[key];
    final providers = <String, Map<String, dynamic>>{};
    if (raw != null) {
      final decoded = _decodeJson(raw, key);
      if (decoded is! Map) throw FormatException(key);
      for (final entry in decoded.entries) {
        if (entry.value is! Map) throw FormatException(key);
        final payload = (entry.value as Map).map(
          (field, value) => MapEntry(field.toString(), value),
        );
        if (normalizeLegacyEmbeddingOverrides) {
          _normalizeLegacyEmbeddingOverrides(payload);
        }
        _validateEntityPayload(BusinessEntityKind.provider, payload);
        providers[entry.key.toString()] = payload;
      }
    }
    final orderedKeys = <String>[];
    final seen = <String>{};
    for (final providerKey in order) {
      if (providerKey.isNotEmpty && seen.add(providerKey)) {
        orderedKeys.add(providerKey);
      }
    }
    for (final providerKey in providers.keys) {
      if (seen.add(providerKey)) orderedKeys.add(providerKey);
    }
    return [
      for (var index = 0; index < orderedKeys.length; index++)
        BusinessEntityValue(
          id: orderedKeys[index],
          sortOrder: index,
          payload: providers.containsKey(orderedKeys[index])
              ? jsonEncode(providers[orderedKeys[index]])
              : _providerOrderOnlyPayload,
        ),
    ];
  }

  static bool isProviderOrderOnlyRow(BusinessEntityValue row) =>
      row.payload == _providerOrderOnlyPayload;

  static List<BusinessEntityValue> _routeList(
    BusinessEntityKind kind,
    Map<String, Object?> source,
    List<String>? entityRowIds,
  ) {
    final raw = source[kind.sourceKey];
    if (raw == null) {
      if (entityRowIds != null && entityRowIds.isNotEmpty) {
        throw FormatException(kind.sourceKey);
      }
      return const <BusinessEntityValue>[];
    }
    final decoded = _decodeJson(raw, kind.sourceKey);
    if (decoded is! List) throw FormatException(kind.sourceKey);
    if (entityRowIds != null && entityRowIds.length != decoded.length) {
      throw FormatException(kind.sourceKey);
    }
    final legacySearchEnabled = source[_searchEnabledKey];
    if (legacySearchEnabled != null && legacySearchEnabled is! bool) {
      throw const FormatException(_searchEnabledKey);
    }
    return [
      for (var index = 0; index < decoded.length; index++)
        _routeListItem(
          kind,
          decoded[index],
          index,
          legacySearchEnabled: legacySearchEnabled as bool?,
          rowId: entityRowIds?[index],
        ),
    ];
  }

  static BusinessEntityValue _routeListItem(
    BusinessEntityKind kind,
    Object? raw,
    int index, {
    required bool? legacySearchEnabled,
    String? rowId,
  }) {
    if (raw is! Map) throw FormatException(kind.sourceKey);
    final payload = raw.map((key, value) => MapEntry(key.toString(), value));
    if (kind == BusinessEntityKind.assistant &&
        legacySearchEnabled != null &&
        !payload.containsKey('searchEnabled')) {
      payload['searchEnabled'] = legacySearchEnabled;
    }
    _validateEntityPayload(kind, payload);
    final rawId = payload['id'];
    final hasPayloadId = rawId != null && rawId.toString().trim().isNotEmpty;
    if (hasPayloadId && rowId != null && rowId != rawId.toString()) {
      throw FormatException(kind.sourceKey);
    }
    final id = hasPayloadId
        ? rawId.toString()
        : rowId ?? _stableGeneratedId(kind.sourceKey, index, payload);
    if (kind == BusinessEntityKind.assistant) {
      _validateRuntimeAssistant({...payload, 'id': id});
    }
    String? assistantId;
    if (kind == BusinessEntityKind.assistantMemory) {
      final rawAssistantId = payload['assistantId'];
      if (rawAssistantId is! String || rawAssistantId.trim().isEmpty) {
        throw FormatException(kind.sourceKey);
      }
      assistantId = rawAssistantId;
    }
    return BusinessEntityValue(
      id: id,
      sortOrder: index,
      payload: jsonEncode(payload),
      assistantId: assistantId,
    );
  }

  // Validate with the same decoder used by AssistantProvider, before migration
  // cleanup or exposing a startup snapshot. Keep the original payload intact,
  // including unknown fields and IDs projected only for runtime use.
  static void _validateRuntimeAssistant(Map<String, Object?> payload) {
    try {
      Assistant.fromJson(payload);
    } catch (error) {
      throw FormatException(
        BusinessEntityKind.assistant.sourceKey,
        'assistant=${payload['id']}; $error',
      );
    }
  }

  // Mirror runtime decoder cast boundaries without canonicalizing payloads.
  // Fields whose published decoders intentionally coerce values stay lenient.
  static void _validateEntityPayload(
    BusinessEntityKind kind,
    Map<String, Object?> payload,
  ) {
    switch (kind) {
      case BusinessEntityKind.assistant:
        _validateKnownFields(
          kind,
          payload,
          strings: const {
            'id',
            'name',
            'avatar',
            'chatModelProvider',
            'chatModelId',
            'systemPrompt',
            'messageTemplate',
            'background',
            'memorySmartAddMode',
            'memoryWriteScope',
          },
          booleans: const {
            'useAssistantAvatar',
            'useAssistantName',
            'limitContextMessages',
            'streamOutput',
            'searchEnabled',
            'enableMemory',
            // Read as a fallback for allowPastConversationRecall in old backups.
            'enableRecentChatsReference',
            'autoOrganizeMemory',
            'allowPastConversationRecall',
            'generateConversationSummary',
            'appendCurrentTimeToUserMessage',
            'useIso8601TimeFormat',
            'allowConversationSystemPrompt',
            'allowConversationPromptInjection',
            'allowConversationMcp',
          },
          numbers: const {
            'temperature',
            'topP',
            'contextMessageSize',
            'maxTokens',
            'recentChatsSummaryMessageCount',
            'memoryOrganizeEveryNTurns',
          },
          maps: const {'reasoning'},
          lists: const {
            'customHeaders',
            'customBody',
            'presetMessages',
            'regexRules',
          },
          stringLists: const {
            'mcpServerIds',
            'localToolIds',
            'healthDataTypeIds',
          },
        );
        _validateAssistantChildren(kind, payload);
        return;
      case BusinessEntityKind.provider:
        _validateKnownFields(
          kind,
          payload,
          strings: const {
            'id',
            'name',
            'apiKey',
            'oauthProvider',
            'oauthModelsSyncedAt',
            'oauthModelsClientVersion',
            'baseUrl',
            'chatPath',
            'location',
            'projectId',
            'serviceAccountJson',
            'proxyType',
            'proxyHost',
            'proxyPort',
            'proxyUsername',
            'proxyPassword',
            'avatarType',
            'avatarValue',
            'balanceApiPath',
            'balanceResultPath',
            'balanceMethod',
            'balanceBody',
            'claudePromptCachingTtl',
          },
          booleans: const {
            'enabled',
            'useResponseApi',
            'promptCacheKeyEnabled',
            'vertexAI',
            'proxyEnabled',
            'multiKeyEnabled',
            'aihubmixAppCodeEnabled',
            'balanceEnabled',
            'claudePromptCachingEnabled',
          },
          lists: const {'models', 'apiKeys', 'customHeaders', 'customBody'},
          objectLists: const {'balanceHeaders'},
          maps: const {
            'modelOverrides',
            'keyManagement',
            'oauthCredentials',
            'requestBudget',
          },
        );
        _validateProviderChildren(kind, payload);
        return;
      case BusinessEntityKind.providerGroup:
        return;
      case BusinessEntityKind.mcpServer:
        _validateKnownFields(
          kind,
          payload,
          strings: const {'id', 'name', 'transport'},
          booleans: const {'enabled'},
          maps: const {'oauth', 'oauthClient'},
          objectLists: const {'tools'},
        );
        _validateMcpChildren(kind, payload);
        final transport = payload['transport'];
        if (transport == 'stdio') {
          _validateKnownFields(
            kind,
            payload,
            strings: const {'command', 'workingDirectory'},
            lists: const {'args'},
            maps: const {'env'},
          );
        } else if (transport != 'inmemory') {
          _validateKnownFields(
            kind,
            payload,
            strings: const {'url'},
            maps: const {'headers'},
          );
        }
        return;
      case BusinessEntityKind.worldBook:
        _validateKnownFields(
          kind,
          payload,
          strings: const {'id', 'name', 'description'},
          booleans: const {'enabled'},
          lists: const {'entries'},
        );
        _validateWorldBookChildren(kind, payload);
        return;
      case BusinessEntityKind.assistantMemory:
        _validateKnownFields(kind, payload, numbers: const {'id'});
        return;
      case BusinessEntityKind.quickPhrase:
        _validateKnownFields(
          kind,
          payload,
          strings: const {'id', 'title', 'content', 'assistantId'},
          booleans: const {'isGlobal'},
        );
        return;
      case BusinessEntityKind.searchService:
        _validateSearchService(kind, payload);
        return;
      case BusinessEntityKind.ttsService:
        return;
      case BusinessEntityKind.instructionInjection:
        _validateKnownFields(
          kind,
          payload,
          strings: const {'id', 'title', 'prompt', 'group'},
        );
        return;
      case BusinessEntityKind.assistantTag:
        return;
      case BusinessEntityKind.memoryEntry:
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'id', 'scope', 'type', 'content'},
          strings: const {'status', 'source', 'assistantId'},
          numbers: const {'createdAt', 'updatedAt'},
          stringLists: const {'relatedIds', 'migrationIds'},
        );
        final scope = payload['scope'] as String;
        if (scope != 'global' && scope != 'assistant') {
          throw FormatException(kind.sourceKey);
        }
        final type = payload['type'] as String;
        if (type != 'identity' &&
            type != 'workflow' &&
            type != 'voice' &&
            type != 'instruction') {
          throw FormatException(kind.sourceKey);
        }
        final status = payload['status'];
        if (status != null && status != 'active' && status != 'archived') {
          throw FormatException(kind.sourceKey);
        }
        final source = payload['source'];
        if (source != null &&
            source != 'manual' &&
            source != 'tool' &&
            source != 'extracted' &&
            source != 'distilled') {
          throw FormatException(kind.sourceKey);
        }
        final assistantId = payload['assistantId'];
        if (scope == 'global') {
          if (assistantId != null) {
            throw FormatException(kind.sourceKey);
          }
        } else if (assistantId is! String || assistantId.trim().isEmpty) {
          throw FormatException(kind.sourceKey);
        }
        if (payload['createdAt'] is! num || payload['updatedAt'] is! num) {
          throw FormatException(kind.sourceKey);
        }
        final content = payload['content'] as String;
        if (content.trim().isEmpty) {
          throw FormatException(kind.sourceKey);
        }
        return;
      case BusinessEntityKind.workspace:
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'id', 'name'},
        );
        return;
      case BusinessEntityKind.skill:
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'id', 'source', 'installedAt', 'updatedAt'},
          booleans: const {'enabled'},
          numbers: const {'useCount'},
        );
        return;
      case BusinessEntityKind.groupChat:
        // Same shape as a workspace or a skill: an opaque payload that this
        // router must not interpret, only type-check, so a malformed row is
        // refused at the import boundary instead of at first use.
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'id', 'name', 'createdAt', 'updatedAt'},
          strings: const {'avatar'},
          numbers: const {'v', 'maxSpeakerTurns'},
          stringLists: const {'memberIds'},
        );
        return;
      case BusinessEntityKind.userProfileField:
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'id', 'value'},
          numbers: const {'updatedAt'},
        );
        final id = payload['id'] as String;
        if (!_userProfileFieldIdPattern.hasMatch(id)) {
          throw FormatException(kind.sourceKey);
        }
        final value = payload['value'] as String;
        if (value.trim().isEmpty) {
          throw FormatException(kind.sourceKey);
        }
        if (payload['updatedAt'] is! num) {
          throw FormatException(kind.sourceKey);
        }
        return;
    }
  }

  static final _userProfileFieldIdPattern = RegExp(
    r'^(preferred_name|gender|pronouns|preferred_language|timezone|'
    r'occupation|location|custom\.[A-Za-z0-9_\-]{1,32})$',
  );

  static void _validateKnownFields(
    BusinessEntityKind kind,
    Map<String, Object?> payload, {
    Set<String> requiredStrings = const {},
    Set<String> strings = const {},
    Set<String> booleans = const {},
    Set<String> numbers = const {},
    Set<String> integers = const {},
    Set<String> lists = const {},
    Set<String> stringLists = const {},
    Set<String> maps = const {},
    Set<String> objectLists = const {},
  }) {
    for (final field in requiredStrings) {
      if (payload[field] is! String) throw FormatException(kind.sourceKey);
    }
    _validateFields(kind, payload, strings, (value) => value is String);
    _validateFields(kind, payload, booleans, (value) => value is bool);
    _validateFields(kind, payload, numbers, (value) => value is num);
    _validateFields(kind, payload, integers, (value) => value is int);
    _validateFields(kind, payload, lists, (value) => value is List);
    _validateFields(
      kind,
      payload,
      stringLists,
      (value) => value is List && value.every((item) => item is String),
    );
    _validateFields(kind, payload, maps, (value) => value is Map);
    _validateFields(
      kind,
      payload,
      objectLists,
      (value) => value is List && value.every((item) => item is Map),
    );
  }

  static void _validateFields(
    BusinessEntityKind kind,
    Map<String, Object?> payload,
    Set<String> fields,
    bool Function(Object value) accepts,
  ) {
    for (final field in fields) {
      final value = payload[field];
      if (value != null && !accepts(value)) {
        throw FormatException(kind.sourceKey);
      }
    }
  }

  static void _validateAssistantChildren(
    BusinessEntityKind kind,
    Map<String, Object?> payload,
  ) {
    for (final child in _mappedObjects(payload['presetMessages'])) {
      _validateKnownFields(
        kind,
        child,
        strings: const {'id', 'role', 'content'},
      );
    }
    for (final child in _mappedObjects(payload['regexRules'])) {
      _validateKnownFields(
        kind,
        child,
        strings: const {'id', 'name', 'pattern', 'replacement'},
        booleans: const {'visualOnly', 'replaceOnly', 'enabled'},
      );
    }
  }

  static void _validateProviderChildren(
    BusinessEntityKind kind,
    Map<String, Object?> payload,
  ) {
    final balanceMethod = payload['balanceMethod'];
    if (balanceMethod != null &&
        balanceMethod != 'GET' &&
        balanceMethod != 'POST') {
      throw const FormatException('Invalid balance HTTP method');
    }
    for (final header in (payload['balanceHeaders'] as List?) ?? const []) {
      final row = header as Map;
      if (row.keys.any((key) => key is! String) ||
          row.values.any((value) => value is! String)) {
        throw const FormatException('Invalid balance request headers');
      }
    }
    final oauthProvider = payload['oauthProvider'];
    if (oauthProvider != null &&
        !{'chatgpt', 'grok', 'kimi', 'claude'}.contains(oauthProvider)) {
      throw const FormatException('Invalid OAuth provider');
    }
    final credentials = payload['oauthCredentials'];
    if (credentials is Map) {
      _validateKnownFields(
        kind,
        _stringKeyedMap(credentials),
        requiredStrings: const {
          'accessToken',
          'refreshToken',
          'expiresAt',
          'sessionId',
        },
        strings: const {
          'email',
          'accountId',
          'plan',
          'deviceId',
          'organizationId',
          'organizationName',
        },
        booleans: const {'requiresLogin'},
      );
      if (oauthProvider == null ||
          DateTime.tryParse(credentials['expiresAt'] as String) == null) {
        throw const FormatException('Invalid OAuth credentials');
      }
    }
    for (final child in _mappedObjects(payload['apiKeys'])) {
      _validateKnownFields(
        kind,
        child,
        strings: const {'id', 'key', 'name', 'status', 'lastError'},
        booleans: const {'isEnabled'},
        integers: const {
          'priority',
          'maxRequestsPerMinute',
          'createdAt',
          'updatedAt',
        },
        maps: const {'usage'},
      );
      final usage = child['usage'];
      if (usage is Map) {
        _validateKnownFields(
          kind,
          _stringKeyedMap(usage),
          integers: const {
            'totalRequests',
            'successfulRequests',
            'failedRequests',
            'consecutiveFailures',
            'lastUsed',
          },
        );
      }
    }
    final keyManagement = payload['keyManagement'];
    if (keyManagement is Map) {
      _validateKnownFields(
        kind,
        _stringKeyedMap(keyManagement),
        strings: const {'strategy'},
        booleans: const {'enableAutoRecovery'},
        integers: const {
          'maxFailuresBeforeDisable',
          'failureRecoveryTimeMinutes',
          'roundRobinIndex',
        },
      );
    }
  }

  static void _validateMcpChildren(
    BusinessEntityKind kind,
    Map<String, Object?> payload,
  ) {
    for (final tool in _objectList(payload['tools'])) {
      _validateKnownFields(
        kind,
        tool,
        strings: const {'name', 'description'},
        booleans: const {'enabled', 'needsApproval'},
        objectLists: const {'params'},
      );
      for (final parameter in _objectList(tool['params'])) {
        _validateKnownFields(
          kind,
          parameter,
          strings: const {'name', 'type'},
          booleans: const {'required'},
        );
      }
    }
    final oauth = payload['oauth'];
    if (oauth is Map) {
      _validateKnownFields(
        kind,
        oauth.map((key, value) => MapEntry(key.toString(), value)),
        strings: const {
          'clientId',
          'clientSecret',
          'authorizationServer',
          'authorizationEndpoint',
          'tokenEndpoint',
          'registrationEndpoint',
          'serverUrl',
          'resource',
          'scope',
          'tokenEndpointAuthMethod',
          'registrationSource',
          'accessToken',
          'tokenType',
          'refreshToken',
        },
        integers: const {'expiresAt'},
      );
    }
    final oauthClient = payload['oauthClient'];
    if (oauthClient is Map) {
      _validateKnownFields(
        kind,
        oauthClient.map((key, value) => MapEntry(key.toString(), value)),
        strings: const {
          'clientId',
          'clientSecret',
          'tokenEndpointAuthMethod',
          'authorizationServer',
          'registrationSource',
        },
      );
    }
  }

  static void _validateWorldBookChildren(
    BusinessEntityKind kind,
    Map<String, Object?> payload,
  ) {
    for (final entry in _mappedObjects(payload['entries'])) {
      _validateKnownFields(
        kind,
        entry,
        strings: const {'id', 'name', 'content'},
        booleans: const {
          'enabled',
          'useRegex',
          'caseSensitive',
          'constantActive',
        },
        integers: const {
          'priority',
          'injectDepth',
          'scanDepth',
          'sticky',
          'cooldown',
          'delay',
        },
        lists: const {'keywords'},
      );
    }
  }

  static void _validateSearchService(
    BusinessEntityKind kind,
    Map<String, Object?> payload,
  ) {
    _validateKnownFields(
      kind,
      payload,
      requiredStrings: const {'type'},
      strings: const {'id'},
    );
    switch (payload['type']) {
      case 'bing_local':
      case 'kelivo':
        break;
      case 'tavily':
      case 'exa':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          strings: const {'url'},
          stringLists: const {'apiKeys'},
        );
      case 'exa_mcp':
        _validateKnownFields(
          kind,
          payload,
          strings: const {'apiKey', 'url'},
          stringLists: const {'apiKeys'},
        );
      case 'zhipu':
      case 'linkup':
      case 'metaso':
      case 'ollama':
      case 'deepseek':
      case 'jina':
      case 'doubao':
      case 'kagi':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          stringLists: const {'apiKeys'},
        );
      case 'brave':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          strings: const {'mode'},
          integers: const {'maximumNumberOfTokens'},
          stringLists: const {'apiKeys'},
        );
      case 'searxng':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'url'},
          strings: const {'engines', 'language', 'username', 'password'},
        );
      case 'duckduckgo':
        _validateKnownFields(kind, payload, strings: const {'region'});
      case 'perplexity':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          strings: const {'country'},
          integers: const {'maxTokensPerPage'},
          lists: const {'searchDomainFilter'},
          stringLists: const {'apiKeys'},
        );
      case 'bocha':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          strings: const {'freshness', 'include', 'exclude'},
          booleans: const {'summary'},
          stringLists: const {'apiKeys'},
        );
      case 'serper':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          strings: const {'gl', 'hl', 'tbs'},
          integers: const {'page'},
          stringLists: const {'apiKeys'},
        );
      case 'grok':
        _validateKnownFields(
          kind,
          payload,
          strings: const {'apiKey', 'model', 'customUrl', 'systemPrompt'},
          stringLists: const {'apiKeys'},
        );
      case 'querit':
        _validateKnownFields(
          kind,
          payload,
          strings: const {
            'apiKey',
            'sitesInclude',
            'sitesExclude',
            'timeRange',
            'countries',
            'languages',
          },
          stringLists: const {'apiKeys'},
        );
      case 'anysearch':
        _validateKnownFields(
          kind,
          payload,
          strings: const {'apiKey', 'url'},
          stringLists: const {'apiKeys'},
        );
      case 'parallel':
      case 'kimi':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          strings: const {'mode'},
          stringLists: const {'apiKeys'},
        );
      case 'you':
        _validateKnownFields(
          kind,
          payload,
          requiredStrings: const {'apiKey'},
          strings: const {'contentMode'},
          stringLists: const {'apiKeys'},
        );
    }
  }

  static List<Map<String, Object?>> _objectList(Object? raw) {
    if (raw is! List) return const [];
    return [for (final value in raw) _stringKeyedMap(value as Map)];
  }

  static List<Map<String, Object?>> _mappedObjects(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final value in raw)
        if (value is Map) _stringKeyedMap(value),
    ];
  }

  static Map<String, Object?> _stringKeyedMap(Map<dynamic, dynamic> raw) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  static void _normalizeStringList(Map<String, Object?> values, String key) {
    final raw = values[key];
    if (raw == null) return;
    if (raw is String) {
      values[key] = _stringList(_decodeJson(raw, key), key);
      return;
    }
    values[key] = _stringList(raw, key);
  }

  static void _normalizeInstructionActivation(
    Map<String, Object?> values, {
    required bool preserveExplicitEmptyList,
  }) {
    final rawItems = preserveExplicitEmptyList
        ? values[_instructionInjectionsKey]
        : null;
    var explicitlyEmptyItems = false;
    if (rawItems != null) {
      final decodedItems = _decodeJson(rawItems, _instructionInjectionsKey);
      explicitlyEmptyItems = decodedItems is List && decodedItems.isEmpty;
    }
    final finalRaw = values[_activeIdsByAssistantKey];
    Map<String, List<String>>? normalized;
    if (finalRaw != null) {
      final decoded = _decodeJson(finalRaw, _activeIdsByAssistantKey);
      if (decoded is! Map) {
        throw const FormatException(_activeIdsByAssistantKey);
      }
      normalized = <String, List<String>>{};
      for (final entry in decoded.entries) {
        normalized[entry.key.toString()] = _deduplicateStrings(
          _stringList(entry.value, _activeIdsByAssistantKey),
        );
      }
    } else {
      List<String> legacy = const <String>[];
      final legacyIdsRaw = values[_legacyActiveIdsKey];
      if (legacyIdsRaw != null) {
        legacy = _deduplicateStrings(
          _stringList(
            _decodeJson(legacyIdsRaw, _legacyActiveIdsKey),
            _legacyActiveIdsKey,
          ),
        );
      } else {
        final legacyId = values[_legacyActiveIdKey];
        if (legacyId != null) {
          if (legacyId is! String) {
            throw const FormatException(_legacyActiveIdKey);
          }
          if (legacyId.trim().isNotEmpty) legacy = <String>[legacyId.trim()];
        }
      }
      if (legacy.isNotEmpty) {
        normalized = <String, List<String>>{_globalAssistantKey: legacy};
      }
    }
    if (explicitlyEmptyItems) {
      (normalized ??= <String, List<String>>{})[_globalAssistantKey] =
          const <String>[];
    }
    if (normalized != null) {
      values[_activeIdsByAssistantKey] = jsonEncode(normalized);
    }
    values.remove(_legacyActiveIdKey);
    values.remove(_legacyActiveIdsKey);
  }

  static Object _validatePreferenceValue(String key, Object value) {
    if (value is bool || value is int || value is double || value is String) {
      return value;
    }
    if (value is List && value.every((item) => item is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    throw FormatException(key);
  }

  static Object? _decodePayload(String payload, String key) {
    final decoded = _decodeJson(payload, key);
    if (decoded is! Map) throw FormatException(key);
    return decoded;
  }

  static Object? _decodeJson(Object raw, String key) {
    if (raw is! String) throw FormatException(key);
    try {
      return jsonDecode(raw);
    } on FormatException {
      throw FormatException(key);
    }
  }

  static List<String> _stringList(Object? raw, String key) {
    if (raw is! List || raw.any((item) => item is! String)) {
      throw FormatException(key);
    }
    return raw.cast<String>();
  }

  static List<String> _deduplicateStrings(List<String> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (value.trim().isNotEmpty && seen.add(value.trim())) value.trim(),
    ];
  }

  static Map<BusinessEntityKind, List<String>> _rowIdsByKind(
    Map<String, Object?>? raw,
    Map<String, Object?> source,
  ) {
    if (raw == null) return const {};
    final kindByKey = <String, BusinessEntityKind>{
      for (final kind in BusinessEntityKind.values)
        if (kind != BusinessEntityKind.provider) kind.sourceKey: kind,
    };
    final result = <BusinessEntityKind, List<String>>{};
    for (final entry in raw.entries) {
      final kind = kindByKey[entry.key];
      if (kind == null) throw FormatException(entry.key);
      final value = entry.value;
      if (value is! List || value.any((id) => id is! String)) {
        throw FormatException(entry.key);
      }
      final ids = List<String>.unmodifiable(value.cast<String>());
      if (ids.any((id) => id.trim().isEmpty)) {
        throw FormatException(entry.key);
      }
      if (ids.toSet().length != ids.length) {
        throw FormatException(entry.key);
      }
      result[kind] = ids;
    }
    for (final entry in kindByKey.entries) {
      if (source.containsKey(entry.key) && !result.containsKey(entry.value)) {
        throw const FormatException('businessEntityRowIds');
      }
    }
    return result;
  }

  static String _stableGeneratedId(
    String sourceKey,
    int index,
    Map<String, Object?> payload,
  ) {
    final digest = sha256.convert(
      utf8.encode('$sourceKey\u0000$index\u0000${jsonEncode(payload)}'),
    );
    return 'generated_${digest.toString().substring(0, 32)}';
  }

  static void _normalizeLegacyEmbeddingOverrides(
    Map<String, Object?> provider,
  ) {
    final rawOverrides = provider['modelOverrides'];
    if (rawOverrides is! Map) return;
    final normalized = <String, Object?>{};
    for (final entry in rawOverrides.entries) {
      final rawOverride = entry.value;
      if (rawOverride is! Map) {
        normalized[entry.key.toString()] = rawOverride;
        continue;
      }
      final override = rawOverride.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final type = (override['type'] ?? override['t'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (_embeddingTypes.contains(type)) {
        for (final field in _embeddingChatOnlyFields) {
          override.remove(field);
        }
      }
      normalized[entry.key.toString()] = override;
    }
    provider['modelOverrides'] = normalized;
  }

  static Map<String, int> _projectMemoryIds(List<BusinessEntityValue> rows) {
    final used = <int>{};
    final missing = <BusinessEntityValue>[];
    for (final row in rows) {
      final payload =
          _decodePayload(
                row.payload,
                BusinessEntityKind.assistantMemory.sourceKey,
              )!
              as Map;
      final rawId = payload['id'];
      if (rawId is num) {
        used.add(rawId.toInt());
      } else {
        missing.add(row);
      }
    }
    missing.sort((left, right) => left.id.compareTo(right.id));
    final projected = <String, int>{};
    for (final row in missing) {
      final digest = sha256.convert(utf8.encode(row.id)).toString();
      // Keep runtime-only identities outside MemoryStore's positive ID space.
      var candidate =
          -((int.parse(digest.substring(0, 8), radix: 16) & 0x3fffffff) + 1);
      while (!used.add(candidate)) {
        candidate = candidate == -0x40000000 ? -1 : candidate - 1;
      }
      projected[row.id] = candidate;
    }
    return projected;
  }

  static int _compareRows(BusinessEntityValue left, BusinessEntityValue right) {
    final byOrder = left.sortOrder.compareTo(right.sortOrder);
    return byOrder != 0 ? byOrder : left.id.compareTo(right.id);
  }
}

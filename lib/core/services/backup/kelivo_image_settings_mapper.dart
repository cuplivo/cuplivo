import 'package:flutter/foundation.dart';

/// Bridges Kelivo's upstream image-compression settings (a86e11a
/// "feat: add image compression for uploads") and Cuplivo's native
/// `one_click_compress_*` keys across backup import/export (issue #124).
///
/// The two apps use structurally different settings models:
/// - Kelivo: `image_upload_quality_v1` (enum string) + `image_compress_custom_quality_v1`
///   + `image_compress_transparent_enabled_v1`.
/// - Cuplivo: four orthogonal `one_click_compress_*` params.
///
/// Translation is BIDIRECTIONAL but lossy in one dimension only: upstream's
/// `custom` preset fixes maxLongEdge at 1568 px (upstream persists NO long-edge
/// field at all — 1568/2048/1024 are hardcoded per preset). A Cuplivo custom
/// long edge therefore collapses to 1568 in Kelivo and stays there if the
/// backup returns. `enabled`, `quality` (Cuplivo 50-95 ⊂ upstream clamp
/// 10-100) and the transparent toggle round-trip losslessly.
///
/// On import the mapper is only invoked for genuinely Kelivo-originated files
/// (upstream keys present AND no Cuplivo keys); on export the upstream keys
/// are derived fresh from the current `one_click_compress_*` values, so no
/// mirror-writes or dual truth exist in prefs.
class KelivoImageSettingsMapper {
  KelivoImageSettingsMapper._();

  static const String upstreamQualityKey = 'image_upload_quality_v1';
  static const String upstreamCustomQualityKey =
      'image_compress_custom_quality_v1';
  static const String upstreamTransparentKey =
      'image_compress_transparent_enabled_v1';

  /// All upstream keys consumed and stripped by this mapper.
  static const Set<String> upstreamKeys = {
    upstreamQualityKey,
    upstreamCustomQualityKey,
    upstreamTransparentKey,
  };

  // Cuplivo's native keys. Mirror SettingsProvider._oneClickCompress*Key
  // (settings_provider.dart) — a rename there must be applied here too, or
  // the translation silently stops working.
  static const String _enabledKey = 'one_click_compress_enabled_v1';
  static const String _maxLongEdgeKey = 'one_click_compress_max_long_edge_v1';
  static const String _qualityKey = 'one_click_compress_quality_v1';
  static const String _alwaysJpgKey = 'one_click_compress_always_jpg_v1';

  static const Set<String> _cuplivoKeys = {
    _enabledKey,
    _maxLongEdgeKey,
    _qualityKey,
    _alwaysJpgKey,
  };

  // Cuplivo quality bounds (mirror SettingsProvider.setOneClickCompressQuality,
  // settings_provider.dart). Upstream clamps to 10-100 on load, so an
  // incoming value may lie outside Cuplivo's range.
  static const int _minQuality = 50;
  static const int _maxQuality = 95;

  // Cuplivo defaults (mirror SettingsProvider).
  static const int _defaultMaxLongEdge = 1536;
  static const int _defaultQuality = 75;
  // Upstream defaults (mirror Kelivo settings_provider test).
  static const int _customMaxLongEdge = 1568;
  static const int _defaultCustomQuality = 85;

  /// Returns the four translated `one_click_compress_*` entries, or `null`
  /// when [settings] did not originate from Kelivo.
  ///
  /// Two conditions both yield `null`: no String `image_upload_quality_v1`
  /// key, OR any Cuplivo-native `one_click_compress_*` key already present.
  /// The second guard is what makes a Cuplivo export (which carries BOTH key
  /// sets) restore its own values verbatim instead of being re-translated —
  /// re-translation would overwrite the file's own maxLongEdge with 1568.
  ///
  /// Pure: never mutates [settings]. The caller is responsible for stripping
  /// [upstreamKeys] after translation.
  static Map<String, dynamic>? translateFromUpstream(
    Map<String, dynamic> settings,
  ) {
    final rawQuality = settings[upstreamQualityKey];
    if (rawQuality is! String) return null;
    if (_cuplivoKeys.any(settings.containsKey)) return null;

    final transparent = settings[upstreamTransparentKey];
    final alwaysJpg = transparent is bool && transparent;

    switch (rawQuality) {
      case 'original':
        return {
          _enabledKey: false,
          _maxLongEdgeKey: _defaultMaxLongEdge,
          _qualityKey: _defaultQuality,
          _alwaysJpgKey: alwaysJpg,
        };
      case 'high':
        return _compressed(2048, 90, alwaysJpg);
      case 'balanced':
        return _compressed(1568, 85, alwaysJpg);
      case 'saver':
        return _compressed(1024, 70, alwaysJpg);
      case 'custom':
        final rawCustom = settings[upstreamCustomQualityKey];
        if (rawCustom is! int) {
          return _compressed(
            _customMaxLongEdge,
            _defaultCustomQuality,
            alwaysJpg,
          );
        }
        final clamped = rawCustom.clamp(_minQuality, _maxQuality);
        if (clamped != rawCustom) {
          debugPrint(
            '[KelivoImageSettingsMapper] Clamped custom quality $rawCustom '
            'to Cuplivo range $_minQuality..$_maxQuality',
          );
        }
        return _compressed(_customMaxLongEdge, clamped, alwaysJpg);
      default:
        // Unknown/future upstream enum value: fall back to balanced rather
        // than dropping the user's compression intent silently.
        debugPrint(
          '[KelivoImageSettingsMapper] Unknown image_upload_quality_v1 value '
          '"$rawQuality", falling back to balanced',
        );
        return _compressed(1568, 85, alwaysJpg);
    }
  }

  /// Derives the upstream (Kelivo) image-compression keys from Cuplivo's
  /// `one_click_compress_*` values, for export into `settings.json`.
  ///
  /// Returns an empty map when [prefs] has no `one_click_compress_enabled_v1`
  /// key (untouched install): neither app persists explicit defaults, so both
  /// sides fall back to their own defaults on restore.
  ///
  /// The upstream keys are DERIVED at export time from the Cuplivo values —
  /// they are never mirror-written into prefs, so there is no dual truth and
  /// no staleness when the user later changes Cuplivo settings.
  static Map<String, dynamic> translateToUpstream(Map<String, dynamic> prefs) {
    final enabled = prefs[_enabledKey];
    if (enabled is! bool) return const {};
    final quality = prefs[_qualityKey];
    final alwaysJpgRaw = prefs[_alwaysJpgKey];
    return {
      upstreamQualityKey: enabled ? 'custom' : 'original',
      upstreamCustomQualityKey: quality is int ? quality : _defaultQuality,
      upstreamTransparentKey: alwaysJpgRaw is bool && alwaysJpgRaw,
    };
  }

  static Map<String, dynamic> _compressed(
    int maxLongEdge,
    int quality,
    bool alwaysJpg,
  ) {
    return {
      _enabledKey: true,
      _maxLongEdgeKey: maxLongEdge,
      _qualityKey: quality,
      _alwaysJpgKey: alwaysJpg,
    };
  }
}

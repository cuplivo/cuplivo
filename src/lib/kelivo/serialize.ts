/**
 * settings.json 序列化：Kelivo 的 prefs 快照在 Dart 端按类型读取
 * （getDouble/getInt/getString...）。JSON 里 int 与 double 同为 number，
 * 但 `1.0` 与 `1` 经 jsonDecode 后一个是 double 一个是 int——整数值的 double
 * 键若写成 int，导入后 prefs.getDouble 强转崩溃（type 'int' is not a
 * subtype of type 'double'），导致 TTS 等初始化失败。
 */
/** Kelivo 以 SharedPreferences getDouble 读取的键，整数值必须带小数点 */
const DOUBLE_KEYS = new Set([
  'tts_speech_rate_v1',
  'tts_pitch_v1',
  'desktop_sidebar_width_v1',
  'desktop_right_sidebar_width_v1',
  'display_chat_background_mask_strength_v1',
  'display_chat_input_background_opacity_dark_v1',
  'display_chat_input_background_opacity_light_v1',
]);

export function stringifySettingsJson(settings: Record<string, unknown>): string {
  let text = JSON.stringify(settings, null, 2);
  for (const key of DOUBLE_KEYS) {
    const v = settings[key];
    if (typeof v === 'number' && Number.isInteger(v)) {
      // JSON.stringify(1.0) === '1'，JS 无法区分 1 与 1.0，只能在文本层补小数点。
      // 键名带引号且值为裸数字，替换串唯一（JSON 字符串值中的引号会被转义）。
      text = text.replace(`"${key}": ${v}`, `"${key}": ${v}.0`);
    }
  }
  return text;
}

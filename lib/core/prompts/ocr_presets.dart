import 'constants/ocr_prompts.dart';
import 'prompt_preset.dart';

class OcrPresets {
  static final List<PromptPreset> all = [
    const PromptPreset(id: 'standard', prompt: defaultOcrPrompt),
    const PromptPreset(id: 'coordinate', prompt: coordinateOcrPrompt),
  ];

  static String? detect(String text) {
    final norm = text.trim();
    for (final p in all) {
      if (norm == p.prompt.trim()) return p.id;
    }
    return null;
  }

  static PromptPreset? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}

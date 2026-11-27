/// One line out of text a user wrote in a box.
///
/// A description is typed over several lines because a sentence is easier to
/// read that way, but every place that shows it — a settings row, a menu entry,
/// a roster a model reads — renders one line. Newlines inside those places
/// break the shape they hold, so the fold happens once, here.
library;

import 'utf16_safe_cut.dart';

/// [text] with every run of whitespace (newlines included) collapsed to one
/// space, trimmed, and cut to [max] code units with an ellipsis.
String oneLineText(String text, {int max = 120}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= max) return flat;
  return '${truncateHeadUtf16Safe(flat, max)}…';
}

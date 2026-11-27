/// The characters no file name may contain on the platforms this app ships to:
/// the separators every filesystem reads as a path, plus Windows' reserved set.
final RegExp _invalidFileNameCharacters = RegExp(r'[\\/:*?"<>|]');

final RegExp _whitespaceRuns = RegExp(r'\s+');

final RegExp _trailingDotsOrSpaces = RegExp(r'[. ]+$');

/// Windows refuses these as a *stem* whatever the extension is: `CON.pdf` is as
/// unusable as `CON`, and the failure is an I/O error rather than a bad name.
final RegExp _windowsDeviceName = RegExp(
  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
  caseSensitive: false,
);

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

/// [name] as a file name the save dialog can offer, or [fallback] when nothing
/// usable is left.
///
/// A conversation's title is not a path segment: it may carry a slash, a colon,
/// or nothing at all. Truncation is a name's length, not a document's — the page
/// keeps every word either way. Trailing dots and spaces are dropped because
/// Windows silently strips them, so `notes.` and `notes` would otherwise become
/// the same file, and a name Windows reserves as a device is prefixed rather
/// than passed through, because writing it fails outright.
String safeFileName(
  String name, {
  required String fallback,
  int maxLength = 80,
}) {
  var cleaned = name
      .replaceAll(_invalidFileNameCharacters, '_')
      .replaceAll(_whitespaceRuns, ' ')
      .trim()
      .replaceFirst(_trailingDotsOrSpaces, '');
  if (cleaned.isEmpty) return fallback;
  // Before the cut, so the prefix that makes the name legal cannot be the part
  // that is truncated away.
  if (_windowsDeviceName.hasMatch(cleaned.split('.').first)) {
    cleaned = '_$cleaned';
  }
  if (cleaned.length <= maxLength) return cleaned;
  final cut = cleaned.substring(0, maxLength);
  // A code-unit cut can land between a surrogate pair, and half a pair is a
  // replacement character in the name the user is asked to accept.
  return _isHighSurrogate(cut.codeUnitAt(cut.length - 1))
      ? cut.substring(0, cut.length - 1)
      : cut;
}

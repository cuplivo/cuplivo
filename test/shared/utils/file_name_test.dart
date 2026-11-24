import 'package:Cuplivo/shared/utils/file_name.dart';
import 'package:flutter_test/flutter_test.dart';

/// A conversation's title becomes a file name in exactly one place, so what it
/// refuses is worth pinning: the platform strips or rejects each of these, and a
/// name that reaches the save picker already broken is a name the user has to
/// repair by hand.
void main() {
  test('a title that is a name already is left alone', () {
    expect(safeFileName('Project notes', fallback: 'x'), 'Project notes');
  });

  test('every character no filesystem accepts becomes an underscore', () {
    expect(
      safeFileName(r'a\b/c:d*e?f"g<h>i|j', fallback: 'x'),
      'a_b_c_d_e_f_g_h_i_j',
    );
  });

  test('runs of whitespace collapse, and the ends are trimmed', () {
    expect(safeFileName('  two   words  ', fallback: 'x'), 'two words');
  });

  test('an empty title falls back, a replaced one does not', () {
    // Separators are not removed but replaced, so a title made of them is still a
    // name; only an empty result — or one that was only dots — takes the default.
    expect(safeFileName('///', fallback: 'fallback'), '___');
    expect(safeFileName('   ', fallback: 'fallback'), 'fallback');
    expect(safeFileName('', fallback: 'fallback'), 'fallback');
  });

  test('trailing dots and spaces are dropped', () {
    // Windows strips them silently, so `notes.` would otherwise be a second name
    // for `notes`.
    expect(safeFileName('notes.', fallback: 'x'), 'notes');
    expect(safeFileName('notes . .', fallback: 'x'), 'notes');
    expect(safeFileName('.', fallback: 'x'), 'x');
  });

  test('a long title is cut, not refused', () {
    final long = 'a' * 200;
    expect(safeFileName(long, fallback: 'x').length, 80);
    expect(safeFileName(long, fallback: 'x', maxLength: 10).length, 10);
  });

  test('a name Windows reserves as a device is prefixed', () {
    // `CON.pdf` fails with a permission error rather than a bad name, so the
    // export that wrote one produced no document at all.
    for (final device in ['CON', 'con', 'PRN', 'aux', 'NUL', 'COM1', 'lpt9']) {
      expect(safeFileName(device, fallback: 'x'), '_$device');
    }
    // The rule is about the stem, whatever follows it.
    expect(safeFileName('CON.notes', fallback: 'x'), '_CON.notes');
    // Two letters longer than a device name is an ordinary name.
    expect(safeFileName('CONSOLE', fallback: 'x'), 'CONSOLE');
    expect(safeFileName('COM10', fallback: 'x'), 'COM10');
  });

  test('a cut never leaves half a surrogate pair', () {
    // U+1F600 is two code units; cutting at one of them would put a replacement
    // character in the name the user is asked to accept.
    final emoji = String.fromCharCode(0x1F600);
    final name = '${'a' * 9}$emoji';
    expect(safeFileName(name, fallback: 'x', maxLength: 10), 'a' * 9);
    // A cut that lands on a boundary keeps the whole pair.
    expect(safeFileName(name, fallback: 'x', maxLength: 11), name);
  });

  test('CJK survives intact', () {
    expect(safeFileName('项目笔记', fallback: 'x'), '项目笔记');
    expect(safeFileName('项目笔记', fallback: 'x', maxLength: 2), '项目');
  });
}

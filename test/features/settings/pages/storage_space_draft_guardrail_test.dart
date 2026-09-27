import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:Cuplivo/features/settings/pages/storage_space_page.dart';

void main() {
  // The guardrail compares the storage selection against the files the unsent
  // draft references. A restored draft carries paths that went through
  // `SandboxPathResolver.fix`, which normalizes separators on Windows, while
  // the storage listing keeps the OS-native form — so the comparison must be
  // path-aware, not a raw string equality.
  test(
    'a separator-normalized draft path still matches the storage listing',
    () {
      final native = p.join('root', 'upload', 'photo.png');
      final normalized = native.replaceAll(p.separator, '/');

      expect(
        countDraftReferencedPaths([native], {normalized}),
        1,
        reason: 'the restored draft path is the normalized form',
      );
      expect(
        countDraftReferencedPaths([normalized], {native}),
        1,
        reason:
            'the comparison must not depend on which side carries which form',
      );
    },
  );

  test('counts only the selected paths the draft references', () {
    final referenced = p.join('root', 'upload', 'a.png');
    final other = p.join('root', 'upload', 'b.png');

    expect(countDraftReferencedPaths([referenced, other], {referenced}), 1);
    expect(countDraftReferencedPaths([other], {referenced}), 0);
    expect(countDraftReferencedPaths([referenced], const <String>{}), 0);
    expect(
      countDraftReferencedPaths(const <String>[], {referenced}),
      0,
      reason: 'nothing selected, nothing to warn about',
    );
  });
}

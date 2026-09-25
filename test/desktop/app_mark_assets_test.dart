import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The desktop header/tray and the About pages draw the app mark straight from
  // the bundle, so referencing a file that `pubspec.yaml` does not declare
  // crashes at runtime with "Unable to load asset".
  test('app mark assets referenced by the UI are declared in pubspec', () async {
    for (final asset in const [
      'assets/app_icon_about.png',
      'assets/app_icon.ico',
    ]) {
      final data = await rootBundle.load(asset);
      expect(data.lengthInBytes, greaterThan(0), reason: asset);
    }
  });
}

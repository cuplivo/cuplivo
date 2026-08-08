import 'package:Cuplivo/features/linux_sandbox/services/android_rootfs_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AndroidRootfsUrls', () {
    test('maps supported ABIs to Ubuntu base URLs', () {
      expect(AndroidRootfsUrls.urlForAbi('arm64-v8a'), AndroidRootfsUrls.arm64);
      expect(AndroidRootfsUrls.urlForAbi('x86_64'), AndroidRootfsUrls.amd64);
      expect(AndroidRootfsUrls.arm64.contains('arm64'), isTrue);
      expect(AndroidRootfsUrls.amd64.contains('amd64'), isTrue);
    });

    test('returns null for unsupported ABI', () {
      expect(AndroidRootfsUrls.urlForAbi('armeabi-v7a'), isNull);
      expect(AndroidRootfsUrls.urlForAbi('unsupported'), isNull);
      expect(AndroidRootfsUrls.urlForAbi(''), isNull);
    });
  });
}

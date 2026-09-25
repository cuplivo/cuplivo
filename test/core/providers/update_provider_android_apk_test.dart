import 'package:Cuplivo/core/providers/update_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors v2.6.2 GitHub release asset order (arm64 → v7a → x86_64 last).
Map<String, dynamic> _releaseWithSplitApks() {
  return {
    'tag_name': 'v2.6.2',
    'published_at': '2026-08-01T00:00:00Z',
    'body': 'notes',
    'assets': [
      {
        'name': 'Cuplivo_android_2.6.2+28_arm64-v8a.apk',
        'browser_download_url':
            'https://example.com/Cuplivo_android_2.6.2+28_arm64-v8a.apk',
      },
      {
        'name': 'Cuplivo_android_2.6.2+28_armeabi-v7a.apk',
        'browser_download_url':
            'https://example.com/Cuplivo_android_2.6.2+28_armeabi-v7a.apk',
      },
      {
        'name': 'Cuplivo_android_2.6.2+28_x86_64.apk',
        'browser_download_url':
            'https://example.com/Cuplivo_android_2.6.2+28_x86_64.apk',
      },
      {
        'name': 'Cuplivo_windows_2.6.2+28.exe',
        'browser_download_url': 'https://example.com/windows.exe',
      },
    ],
  };
}

void main() {
  group('parseAndroidApkArch', () {
    test('extracts known ABI tags from asset names', () {
      expect(
        parseAndroidApkArch('Cuplivo_android_2.6.2+28_arm64-v8a.apk'),
        'arm64-v8a',
      );
      expect(
        parseAndroidApkArch('Cuplivo_android_2.6.2+28_armeabi-v7a.apk'),
        'armeabi-v7a',
      );
      expect(
        parseAndroidApkArch('Cuplivo_android_2.6.2+28_x86_64.apk'),
        'x86_64',
      );
      expect(parseAndroidApkArch('app-x86-release.apk'), 'x86');
    });

    test('returns null when no arch tag is present', () {
      expect(parseAndroidApkArch('Cuplivo_android_2.6.2.apk'), isNull);
    });
  });

  group('selectAndroidDownloadUrl', () {
    const byArch = {
      'arm64-v8a': 'https://example.com/arm64.apk',
      'armeabi-v7a': 'https://example.com/v7a.apk',
      'x86_64': 'https://example.com/x86_64.apk',
    };

    test('prefers device supportedAbis order', () {
      expect(
        selectAndroidDownloadUrl(
          apkByArch: byArch,
          supportedAbis: const ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
        ),
        'https://example.com/arm64.apk',
      );
      expect(
        selectAndroidDownloadUrl(
          apkByArch: byArch,
          supportedAbis: const ['armeabi-v7a'],
        ),
        'https://example.com/v7a.apk',
      );
      expect(
        selectAndroidDownloadUrl(
          apkByArch: byArch,
          supportedAbis: const ['x86_64'],
        ),
        'https://example.com/x86_64.apk',
      );
    });

    test('falls back to arm64 when abis empty (not last-wins x86_64)', () {
      expect(
        selectAndroidDownloadUrl(apkByArch: byArch),
        'https://example.com/arm64.apk',
      );
    });

    test('uses unarch url when no arch-tagged apks match', () {
      expect(
        selectAndroidDownloadUrl(
          apkByArch: const {},
          unarchUrl: 'https://example.com/universal.apk',
        ),
        'https://example.com/universal.apk',
      );
    });
  });

  group('UpdateInfo.fromGithubRelease android apk selection', () {
    test('default abis picks arm64 even when x86_64 is last asset', () {
      final info = UpdateInfo.fromGithubRelease(_releaseWithSplitApks());
      expect(
        info.downloads['android'],
        'https://example.com/Cuplivo_android_2.6.2+28_arm64-v8a.apk',
      );
      expect(info.downloads['windows'], 'https://example.com/windows.exe');
      expect(info.version, '2.6.2');
    });

    test('matches arm64 device abis', () {
      final info = UpdateInfo.fromGithubRelease(
        _releaseWithSplitApks(),
        androidAbis: const ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
      );
      expect(info.downloads['android'], contains('arm64-v8a'));
    });

    test('matches armeabi-v7a-only device', () {
      final info = UpdateInfo.fromGithubRelease(
        _releaseWithSplitApks(),
        androidAbis: const ['armeabi-v7a'],
      );
      expect(info.downloads['android'], contains('armeabi-v7a'));
    });

    test('matches x86_64 emulator', () {
      final info = UpdateInfo.fromGithubRelease(
        _releaseWithSplitApks(),
        androidAbis: const ['x86_64'],
      );
      expect(info.downloads['android'], contains('x86_64'));
    });

    test('unarch apk is selected when no arch tags present', () {
      final info = UpdateInfo.fromGithubRelease({
        'tag_name': 'v1.0.0',
        'assets': [
          {
            'name': 'Cuplivo_android_1.0.0.apk',
            'browser_download_url': 'https://example.com/universal.apk',
          },
        ],
      });
      expect(info.downloads['android'], 'https://example.com/universal.apk');
    });

    test('empty assets leaves android download unset', () {
      final info = UpdateInfo.fromGithubRelease({
        'tag_name': 'v1.0.0',
        'assets': <Map<String, dynamic>>[],
      });
      expect(info.downloads.containsKey('android'), isFalse);
    });
  });
}

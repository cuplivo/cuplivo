import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Opens [directoryPath] in the system file manager.
///
/// `Uri.file` + `url_launcher` is deliberately NOT used here: on Windows the
/// `file:` scheme is routed through `ShellExecuteW` as a URL, and opening a
/// directory that way is unreliable (issue #789: clicks appeared to do
/// nothing). Platform commands treat the path as a plain path instead.
///
/// On Windows the path is normalized to backslashes first: `explorer.exe`
/// does not resolve forward-slash paths and opens the wrong folder (its
/// command line treats `/`-prefixed tokens as switches, e.g. `/select,`).
///
/// Throws [UnsupportedError] on web (where `defaultTargetPlatform` still
/// reports the browser's host OS) and on non-desktop platforms,
/// [FileSystemException] when the directory does not exist (a detached
/// Windows launch would otherwise fail with no signal), and
/// [ProcessException] when the platform command exits with a non-zero status.
Future<void> openDirectoryInFileManager(String directoryPath) async {
  if (kIsWeb) {
    throw UnsupportedError(
      'Opening a directory is only supported on desktop platforms',
    );
  }
  final platform = defaultTargetPlatform;
  final command = directoryOpenCommandFor(platform, directoryPath);
  if (command == null) {
    throw UnsupportedError(
      'Opening a directory is only supported on desktop platforms',
    );
  }
  if (!await Directory(directoryPath).exists()) {
    throw FileSystemException('Directory does not exist', directoryPath);
  }
  final (executable, arguments) = command;
  if (platform == TargetPlatform.windows) {
    // explorer.exe can report a non-zero exit code (or keep running) even
    // when the folder opens, so launch it detached and ignore the result.
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
    return;
  }
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      result.stderr?.toString() ?? '',
      result.exitCode,
    );
  }
}

/// Executable and arguments that open [path] in the system file manager for
/// [platform], or null when [platform] has no known implementation.
///
/// Deliberately not `@visibleForTesting`: [openDirectoryInFileManager] calls
/// it in production. It is public so tests can assert the mapping without
/// spawning a process.
(String, List<String>)? directoryOpenCommandFor(
  TargetPlatform platform,
  String path,
) {
  return switch (platform) {
    // explorer.exe only resolves backslash paths; forward slashes can make it
    // open the default folder or the parent instead (issue #789 follow-up).
    TargetPlatform.windows => (
      'explorer',
      <String>[path.replaceAll('/', r'\')],
    ),
    TargetPlatform.macOS => ('open', <String>[path]),
    TargetPlatform.linux => ('xdg-open', <String>[path]),
    _ => null,
  };
}

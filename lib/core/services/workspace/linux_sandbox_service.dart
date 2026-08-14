import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/workspace.dart';
import '../../../utils/app_directories.dart';

enum SandboxStatus {
  /// Not a supported mobile platform (or plugin missing entirely).
  unsupported,

  /// No rootfs extracted yet.
  disabled,

  /// Rootfs present but the native runtime is missing from this build.
  runtimeMissing,

  installing,
  ready,
  broken,
}

/// Pure readiness matrix (testable without platform channels).
class SandboxReadiness {
  const SandboxReadiness._();

  static SandboxStatus compute({
    required bool supported,
    required bool hasRootfs,
    required bool hasRuntime,
    bool rootfsCheckFailed = false,
  }) {
    if (!supported) return SandboxStatus.unsupported;
    if (rootfsCheckFailed) return SandboxStatus.broken;
    if (!hasRootfs) return SandboxStatus.disabled;
    if (!hasRuntime) return SandboxStatus.runtimeMissing;
    return SandboxStatus.ready;
  }
}

class SandboxPtyLaunchSpec {
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String workingDirectory;

  const SandboxPtyLaunchSpec({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.workingDirectory,
  });

  factory SandboxPtyLaunchSpec.fromChannelMap(
    Map<dynamic, dynamic> map, {
    required String fallbackWorkingDirectory,
  }) {
    final executable = (map['executable'] ?? '').toString();
    if (executable.isEmpty) {
      throw StateError('ptyLaunchSpec missing executable');
    }
    final rawArgs = map['arguments'];
    if (rawArgs is! List) {
      throw StateError('ptyLaunchSpec missing arguments');
    }
    final rawEnv = map['environment'];
    if (rawEnv is! Map) {
      throw StateError('ptyLaunchSpec missing environment');
    }
    final workingDirectory =
        (map['workingDirectory'] ?? fallbackWorkingDirectory).toString();
    if (workingDirectory.isEmpty) {
      throw StateError('ptyLaunchSpec missing workingDirectory');
    }
    final environment = <String, String>{};
    rawEnv.forEach((key, value) {
      if (key != null && value != null) {
        environment[key.toString()] = value.toString();
      }
    });
    return SandboxPtyLaunchSpec(
      executable: executable,
      arguments: rawArgs.map((e) => e.toString()).toList(),
      environment: environment,
      workingDirectory: workingDirectory,
    );
  }

  static bool parseVolumeCtrlEvent(Object? event) {
    if (event is! bool) {
      throw StateError(
        'volumeCtrl event must be bool, got ${event.runtimeType}',
      );
    }
    return event;
  }
}

class SandboxExecResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  const SandboxExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });
}

class SandboxInstallProgress {
  final String stage; // downloading | extracting | installing | done
  final double? progress; // 0-1 if known
  final String? message;

  const SandboxInstallProgress({
    required this.stage,
    this.progress,
    this.message,
  });
}

/// One staged package-manager operation inside the sandbox rootfs.
class PackageInstallStep {
  /// 'recover' (self-heal package state), 'update' or 'install'.
  final String stage;
  final String command;
  final int timeoutSeconds;

  const PackageInstallStep({
    required this.stage,
    required this.command,
    required this.timeoutSeconds,
  });
}

/// Mobile Linux sandbox.
///
/// - Android: proot + per-workspace Ubuntu rootfs (downloaded), apt.
/// - iOS: embedded iSH-ARM64 userland emulator + ONE shared Alpine rootfs
///   (bundled zip, fakefs format); each workspace host directory is
///   bind-mounted onto `/workspace` at exec time because the iSH kernel can
///   boot only once per app process. apk instead of apt.
///
/// Other platforms report [unsupported]. Architecture mirrors common proot
/// userland sandboxes on Android; the iOS integration follows the embedded
/// fakefs approach. All glue code is original.
class LinuxSandboxService {
  LinuxSandboxService._();
  static final LinuxSandboxService instance = LinuxSandboxService._();

  static const MethodChannel _channel = MethodChannel('cuplivo/linux_sandbox');
  static const EventChannel _volumeCtrlChannel = EventChannel(
    'cuplivo/linux_sandbox/volume_ctrl',
  );

  static const int maxOutputChars = 128 * 1024;

  static const String _ua =
      'Cuplivo/1.0 (Linux sandbox installer; +https://github.com/cuplivo/cuplivo)';

  /// Alpine version of the bundled iOS rootfs (must match
  /// tools/ios_rootfs/prepare_alpine_fakefs.py output).
  static const String alpineVersion = '3.21';

  /// Default rootfs URLs by ABI (Ubuntu base 24.04, Android only).
  static const Map<String, String> defaultRootfsUrls = {
    'arm64-v8a':
        'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
    'x86_64':
        'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
  };

  static const Map<String, Map<String, String>> rootfsSourceUrls = {
    'arm64-v8a': {
      'official':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
      'tuna':
          'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
      'aliyun':
          'https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
    },
    'x86_64': {
      'official':
          'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
      'tuna':
          'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
      'aliyun':
          'https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
    },
  };

  /// Resolve download URL list for [pref] + [abi]. Exposed for tests.
  static List<String> resolveRootfsUrls({
    required String abi,
    required DependencyInstallPref pref,
  }) {
    final bySource = rootfsSourceUrls[abi] ?? rootfsSourceUrls['arm64-v8a']!;
    final source = pref.sourceId.trim().isEmpty ? 'auto' : pref.sourceId.trim();
    if (source == 'custom') {
      final custom = pref.customUrl?.trim() ?? '';
      if (custom.isEmpty) {
        throw StateError('Custom source requires a URL');
      }
      return [custom];
    }
    if (source == 'auto') {
      return [bySource['official']!, bySource['tuna']!, bySource['aliyun']!];
    }
    final single = bySource[source];
    if (single != null) return [single];
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return [source];
    }
    // Unknown named source → official only (do not dump all mirrors).
    return [bySource['official'] ?? defaultRootfsUrls[abi]!];
  }

  /// True when the sandbox platform channel is available on this device.
  static bool get isSandboxPlatform => Platform.isAndroid || Platform.isIOS;

  /// True when the native runtime is packaged and loadable (proot on
  /// Android; the statically linked iSH libraries on iOS).
  Future<bool> get isSupported async => hasRuntime();

  Future<bool> hasRuntime() async {
    if (!isSandboxPlatform) return false;
    try {
      final v = await _channel.invokeMethod<bool>('isSupported');
      return v == true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('LinuxSandboxService.hasRuntime: $e');
      return false;
    }
  }

  Future<String> detectAbi() async {
    if (Platform.isIOS) return 'arm64-v8a';
    if (!Platform.isAndroid) return 'unknown';
    try {
      final v = await _channel.invokeMethod<String>('getAbi');
      return v ?? 'arm64-v8a';
    } catch (e) {
      debugPrint('LinuxSandboxService.detectAbi: $e');
      return 'arm64-v8a';
    }
  }

  String linuxDir(String workspaceHostPath) =>
      p.join(workspaceHostPath, '.sandbox', 'linux');

  String tmpDir(String workspaceHostPath) =>
      p.join(workspaceHostPath, '.sandbox', 'tmp');

  /// iOS only: whether the iSH kernel has already booted this process.
  /// Deleting the rootfs while booted would corrupt the live mount, so
  /// callers (e.g. clear-all-data) must check first.
  Future<bool> isIosKernelBooted() async {
    if (!Platform.isIOS) return false;
    try {
      final v = await _channel.invokeMethod<bool>('isBooted');
      return v == true;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('LinuxSandboxService.isIosKernelBooted: $e');
      return false;
    }
  }

  /// Shared iOS rootfs location (iSH boots once per process, so all
  /// workspaces share one fakefs tree; host dirs are bind-mounted instead).
  Future<String> iosRootfsPath() async {
    final runtime = await AppDirectories.getLinuxSandboxRuntimeDirectory();
    return p.join(runtime.path, 'alpine-rootfs');
  }

  /// Rootfs present? Android: guest shell binary under `.sandbox/linux` of
  /// the workspace. iOS: shared fakefs tree (meta.db + busybox + arch tag).
  Future<bool> hasRootfs(String workspaceHostPath) async {
    try {
      if (Platform.isIOS) {
        final rootfs = await iosRootfsPath();
        final meta = File(p.join(rootfs, 'meta.db'));
        if (!await meta.exists()) return false;
        final busybox = File(p.join(rootfs, 'data', 'bin', 'busybox'));
        if (!await busybox.exists()) return false;
        final arch = File(p.join(rootfs, '.arch'));
        if (!await arch.exists()) return false;
        final tag = (await arch.readAsString()).trim();
        return tag == 'aarch64';
      }
      final sh = File(p.join(linuxDir(workspaceHostPath), 'bin', 'sh'));
      if (await sh.exists()) return true;
      final bash = File(p.join(linuxDir(workspaceHostPath), 'bin', 'bash'));
      return await bash.exists();
    } catch (e) {
      debugPrint('LinuxSandboxService.hasRootfs: $e');
      return false;
    }
  }

  Future<SandboxStatus> statusFor(String workspaceHostPath) async {
    if (!isSandboxPlatform) return SandboxStatus.unsupported;
    bool rootfs;
    var checkFailed = false;
    try {
      rootfs = await hasRootfs(workspaceHostPath);
    } catch (e) {
      debugPrint('LinuxSandboxService.statusFor rootfs: $e');
      rootfs = false;
      checkFailed = true;
    }
    final runtime = await hasRuntime();
    return SandboxReadiness.compute(
      supported: true,
      hasRootfs: rootfs,
      hasRuntime: runtime,
      rootfsCheckFailed: checkFailed,
    );
  }

  Future<bool> isDependencyInstalled(
    String workspaceHostPath,
    String depId,
  ) async {
    // Base = rootfs on disk only (does not require the runtime).
    if (depId == WorkspaceDependencyIds.base) {
      return hasRootfs(workspaceHostPath);
    }
    final status = await statusFor(workspaceHostPath);
    if (status != SandboxStatus.ready) return false;
    final probe = switch (depId) {
      WorkspaceDependencyIds.python => 'command -v python3 >/dev/null 2>&1',
      WorkspaceDependencyIds.nodejs => 'command -v node >/dev/null 2>&1',
      WorkspaceDependencyIds.git => 'command -v git >/dev/null 2>&1',
      // The office step installs a whole toolchain; LibreOffice alone is not
      // enough, so require every component the document skills rely on.
      WorkspaceDependencyIds.office =>
        'command -v soffice >/dev/null 2>&1 && '
            'command -v pandoc >/dev/null 2>&1 && '
            'command -v pdftoppm >/dev/null 2>&1',
      WorkspaceDependencyIds.buildEssential => 'command -v gcc >/dev/null 2>&1',
      _ => null,
    };
    if (probe == null) return false;
    final r = await exec(
      workspaceHostPath: workspaceHostPath,
      command: probe,
      timeoutSeconds: 15,
    );
    return r.exitCode == 0;
  }

  static String statusUserMessage(SandboxStatus status) {
    switch (status) {
      case SandboxStatus.disabled:
        return 'Install the base (Linux rootfs) dependency first.';
      case SandboxStatus.runtimeMissing:
        return 'Sandbox runtime missing from this build; reinstall the app with sandbox native libs.';
      case SandboxStatus.unsupported:
        return 'Linux sandbox is only available on Android or iOS.';
      case SandboxStatus.broken:
        return 'Sandbox rootfs is broken; reinstall the base dependency.';
      case SandboxStatus.installing:
        return 'Sandbox is still installing.';
      case SandboxStatus.ready:
        return 'Sandbox is ready.';
    }
  }

  Future<void> installBase({
    required String workspaceHostPath,
    required DependencyInstallPref pref,
    void Function(SandboxInstallProgress)? onProgress,
  }) async {
    if (Platform.isIOS) {
      await _installBaseIos(onProgress: onProgress);
      return;
    }
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Linux sandbox is only available on Android or iOS',
      );
    }
    final abi = await detectAbi();
    final urls = resolveRootfsUrls(abi: abi, pref: pref);
    final sandboxDir = Directory(p.join(workspaceHostPath, '.sandbox'));
    await sandboxDir.create(recursive: true);
    final archivePath = p.join(sandboxDir.path, 'download.tar.gz');

    Object? lastError;
    for (final url in urls) {
      try {
        onProgress?.call(
          SandboxInstallProgress(
            stage: 'downloading',
            progress: 0,
            message: url,
          ),
        );
        await _downloadFile(
          url: url,
          savePath: archivePath,
          onProgress: (ratio) {
            onProgress?.call(
              SandboxInstallProgress(
                stage: 'downloading',
                progress: ratio,
                message: url,
              ),
            );
          },
        );
        onProgress?.call(
          const SandboxInstallProgress(stage: 'extracting', progress: null),
        );
        await _channel.invokeMethod<void>('extractRootfs', {
          'workspacePath': workspaceHostPath,
          'archivePath': archivePath,
        });
        try {
          final f = File(archivePath);
          if (await f.exists()) await f.delete();
        } catch (e) {
          debugPrint('LinuxSandboxService: cleanup archive failed: $e');
        }
        onProgress?.call(
          const SandboxInstallProgress(stage: 'done', progress: 1),
        );
        return;
      } catch (e) {
        lastError = e;
        debugPrint('installBase failed for $url: $e');
        try {
          final f = File(archivePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    throw StateError('Failed to install rootfs: $lastError');
  }

  /// iOS: the rootfs ships inside the app bundle (fakefs zip); the plugin
  /// extracts it to the shared sandbox directory. No download involved.
  Future<void> _installBaseIos({
    void Function(SandboxInstallProgress)? onProgress,
  }) async {
    final rootfsPath = await iosRootfsPath();
    await Directory(p.dirname(rootfsPath)).create(recursive: true);
    onProgress?.call(
      const SandboxInstallProgress(stage: 'extracting', progress: null),
    );
    try {
      await _channel.invokeMethod<void>('installBase', {
        'rootfsPath': rootfsPath,
      });
    } on MissingPluginException {
      throw StateError('Linux sandbox plugin not available');
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
    onProgress?.call(const SandboxInstallProgress(stage: 'done', progress: 1));
  }

  Future<void> _downloadFile({
    required String url,
    required String savePath,
    void Function(double ratio)? onProgress,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 45),
        receiveTimeout: const Duration(minutes: 30),
        sendTimeout: const Duration(minutes: 5),
        followRedirects: true,
        maxRedirects: 8,
        headers: <String, dynamic>{'User-Agent': _ua, 'Accept': '*/*'},
        // Let us handle non-2xx with a clear message.
        validateStatus: (code) => code != null && code >= 200 && code < 400,
      ),
    );
    try {
      final response = await dio.download(
        url,
        savePath,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          } else {
            onProgress?.call(0);
          }
        },
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (code) => code != null && code >= 200 && code < 300,
        ),
      );
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) {
        throw StateError('HTTP $code downloading $url');
      }
      final file = File(savePath);
      if (!await file.exists() || await file.length() == 0) {
        throw StateError('Downloaded file empty for $url');
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final reason = e.message ?? e.type.name;
      if (code != null) {
        throw StateError('HTTP $code downloading $url: $reason');
      }
      throw StateError('Download failed for $url: $reason');
    } finally {
      dio.close(force: true);
    }
  }

  /// Build the staged apt commands used by [installPackage] (Android).
  ///
  /// The `recover` step repairs an interrupted dpkg state left behind by a
  /// killed transaction (install timeout, app process death), so later
  /// installs do not fail with "dpkg was interrupted". Lock files are NOT
  /// deleted here: fcntl locks are released automatically when the holder
  /// exits, and unlinking the inode under a live holder would let a second
  /// dpkg mutate the database concurrently. Every apt invocation carries
  /// `Acquire::Lock::Timeout` so a transiently held dpkg lock (e.g. an
  /// install triggered through the LLM shell tool) waits instead of failing.
  /// [installTimeoutSeconds] allows oversized packages (LibreOffice ~550MB)
  /// to finish without the exec timeout killing dpkg mid-transaction.
  /// Exposed for tests.
  static List<PackageInstallStep> buildAptInstallSteps({
    required String packages,
    String mirrorSetup = '',
    int installTimeoutSeconds = 1800,
  }) {
    const lockTimeout = '-o Acquire::Lock::Timeout=600';
    return [
      PackageInstallStep(
        stage: 'recover',
        // Long enough to cover the 600s lock wait plus dpkg repair work.
        timeoutSeconds: 900,
        command:
            'export DEBIAN_FRONTEND=noninteractive; '
            'dpkg --configure -a; '
            'apt-get $lockTimeout -f install -y',
      ),
      PackageInstallStep(
        stage: 'update',
        timeoutSeconds: 600,
        command:
            '${mirrorSetup.isEmpty ? '' : mirrorSetup}'
            'apt-get $lockTimeout update -y',
      ),
      PackageInstallStep(
        stage: 'install',
        timeoutSeconds: installTimeoutSeconds,
        command:
            'export DEBIAN_FRONTEND=noninteractive; '
            'apt-get $lockTimeout install -y --no-install-recommends $packages '
            '&& apt-get $lockTimeout clean',
      ),
    ];
  }

  /// Build the staged apk commands used by [installPackage] (iOS Alpine).
  ///
  /// `recover` clears a stale apk lock left by a killed install; apk has no
  /// dpkg-equivalent interrupted state. [installTimeoutSeconds] mirrors
  /// [buildAptInstallSteps] for oversized package sets. Exposed for tests.
  static List<PackageInstallStep> buildApkInstallSteps({
    required String packages,
    String mirrorSetup = '',
    int installTimeoutSeconds = 1800,
  }) {
    return [
      PackageInstallStep(
        stage: 'recover',
        timeoutSeconds: 120,
        command: 'rm -f /lib/apk/db/lock',
      ),
      PackageInstallStep(
        stage: 'update',
        timeoutSeconds: 600,
        command: '${mirrorSetup.isEmpty ? '' : mirrorSetup}apk update',
      ),
      PackageInstallStep(
        stage: 'install',
        timeoutSeconds: installTimeoutSeconds,
        command: 'apk add $packages',
      ),
    ];
  }

  /// Alpine repository base URLs for named sources (iOS apk mirrors).
  /// 'auto'/'official' keep the repositories shipped in the rootfs.
  static const Map<String, String> apkMirrorBaseUrls = {
    'tuna': 'https://mirrors.tuna.tsinghua.edu.cn/alpine',
    'aliyun': 'https://mirrors.aliyun.com/alpine',
  };

  /// apk mirror setup: rewrite /etc/apk/repositories for the bundled
  /// Alpine version. [mirrorUrl] must be the repository base (e.g.
  /// `https://mirrors.aliyun.com/alpine`).
  static String apkMirrorSetup(String mirrorUrl) {
    return "printf '%s\\n' '$mirrorUrl/v$alpineVersion/main' "
        "'$mirrorUrl/v$alpineVersion/community' > /etc/apk/repositories && ";
  }

  Future<void> installPackage({
    required String workspaceHostPath,
    required String depId,
    required DependencyInstallPref pref,
    void Function(SandboxInstallProgress)? onProgress,
  }) async {
    if (depId == WorkspaceDependencyIds.base) {
      await installBase(
        workspaceHostPath: workspaceHostPath,
        pref: pref,
        onProgress: onProgress,
      );
      return;
    }
    if (!isSandboxPlatform) {
      throw UnsupportedError(
        'Linux sandbox is only available on Android or iOS',
      );
    }
    if (!await hasRootfs(workspaceHostPath)) {
      throw StateError(statusUserMessage(SandboxStatus.disabled));
    }
    if (!await hasRuntime()) {
      throw StateError(statusUserMessage(SandboxStatus.runtimeMissing));
    }
    onProgress?.call(const SandboxInstallProgress(stage: 'installing'));
    final ios = Platform.isIOS;
    final packages = switch (depId) {
      WorkspaceDependencyIds.python =>
        ios ? 'python3 py3-pip' : 'python3 python3-pip',
      WorkspaceDependencyIds.nodejs => 'nodejs npm',
      WorkspaceDependencyIds.git => 'git',
      WorkspaceDependencyIds.office =>
        ios
            ? 'libreoffice pandoc poppler-utils py3-lxml py3-pillow '
                  'py3-reportlab py3-openpyxl py3-pandas py3-defusedxml'
            : 'libreoffice pandoc poppler-utils python3-lxml python3-pil '
                  'python3-reportlab python3-openpyxl python3-pandas '
                  'python3-defusedxml',
      WorkspaceDependencyIds.buildEssential =>
        ios ? 'build-base' : 'build-essential',
      _ => throw StateError('Unknown dependency: $depId'),
    };
    var mirrorSetup = '';
    if (pref.sourceId == 'custom' &&
        pref.customUrl != null &&
        pref.customUrl!.trim().isNotEmpty) {
      final url = _sanitizeMirrorUrl(pref.customUrl!.trim());
      if (url == null) {
        throw StateError('Invalid custom mirror URL');
      }
      mirrorSetup = ios
          ? apkMirrorSetup(url)
          : "printf '%s\\n' 'deb $url noble main universe' > /etc/apt/sources.list && ";
    } else if (ios) {
      final named = apkMirrorBaseUrls[pref.sourceId.trim()];
      if (named != null) {
        mirrorSetup = apkMirrorSetup(named);
      }
    }
    final steps = ios
        ? buildApkInstallSteps(
            packages: packages,
            mirrorSetup: mirrorSetup,
            installTimeoutSeconds: depId == WorkspaceDependencyIds.office
                ? 2700
                : 1800,
          )
        : buildAptInstallSteps(
            packages: packages,
            mirrorSetup: mirrorSetup,
            installTimeoutSeconds: depId == WorkspaceDependencyIds.office
                ? 2700
                : 1800,
          );
    for (final step in steps) {
      onProgress?.call(
        SandboxInstallProgress(stage: step.stage, progress: null),
      );
      final r = await exec(
        workspaceHostPath: workspaceHostPath,
        command: step.command,
        timeoutSeconds: step.timeoutSeconds,
      );
      if (r.exitCode != 0) {
        if (step.stage == 'recover') {
          debugPrint(
            'LinuxSandboxService: package self-heal failed (${r.exitCode}): '
            '${r.stderr}',
          );
          continue;
        }
        final label = step.stage == 'update'
            ? (ios ? 'apk update' : 'apt update')
            : (ios ? 'apk add' : 'apt install');
        throw StateError('$label failed (${r.exitCode}): ${r.stderr}');
      }
    }
    onProgress?.call(const SandboxInstallProgress(stage: 'done', progress: 1));
  }

  Future<SandboxExecResult> exec({
    required String workspaceHostPath,
    required String command,
    String? cwd,
    int timeoutSeconds = 30,
  }) async {
    if (!isSandboxPlatform) {
      throw UnsupportedError('shell is only available on Android or iOS');
    }
    try {
      final map = await _channel.invokeMethod<Map>('exec', {
        'workspacePath': workspaceHostPath,
        'command': command,
        if (cwd != null) 'cwd': cwd,
        'timeoutMs': timeoutSeconds * 1000,
        if (Platform.isIOS) 'rootfsPath': await iosRootfsPath(),
      });
      if (map == null) {
        return const SandboxExecResult(
          exitCode: -1,
          stdout: '',
          stderr: 'null result',
        );
      }
      var stdout = (map['stdout'] ?? '').toString();
      var stderr = (map['stderr'] ?? '').toString();
      if (stdout.length > maxOutputChars) {
        stdout = '${stdout.substring(0, maxOutputChars)}\n...[truncated]';
      }
      if (stderr.length > maxOutputChars) {
        stderr = '${stderr.substring(0, maxOutputChars)}\n...[truncated]';
      }
      return SandboxExecResult(
        exitCode: (map['exitCode'] as num?)?.toInt() ?? -1,
        stdout: stdout,
        stderr: stderr,
        timedOut: map['timedOut'] == true,
      );
    } on MissingPluginException {
      return const SandboxExecResult(
        exitCode: -1,
        stdout: '',
        stderr: 'Linux sandbox plugin not available',
      );
    } on PlatformException catch (e) {
      return SandboxExecResult(
        exitCode: -1,
        stdout: '',
        stderr: e.message ?? e.code,
      );
    }
  }

  Future<SandboxPtyLaunchSpec> ptyLaunchSpec(String workspaceHostPath) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('Workspace Terminal is only available on Android');
    }
    final map = await _channel.invokeMethod<Map>('ptyLaunchSpec', {
      'workspacePath': workspaceHostPath,
    });
    if (map == null) {
      throw StateError('ptyLaunchSpec returned null');
    }
    return SandboxPtyLaunchSpec.fromChannelMap(
      map,
      fallbackWorkingDirectory: workspaceHostPath,
    );
  }

  Future<void> setKeepScreenOn(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {
        'enabled': enabled,
      });
    } catch (e) {
      debugPrint('LinuxSandboxService.setKeepScreenOn: $e');
      if (enabled) rethrow;
    }
  }

  Future<void> setVolumeCtrlIntercept(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setVolumeCtrlIntercept', {
        'enabled': enabled,
      });
    } catch (e) {
      debugPrint('LinuxSandboxService.setVolumeCtrlIntercept: $e');
      if (enabled) rethrow;
    }
  }

  Stream<bool> volumeCtrlEvents() {
    if (!Platform.isAndroid) return const Stream<bool>.empty();
    return _volumeCtrlChannel.receiveBroadcastStream().map(
      SandboxPtyLaunchSpec.parseVolumeCtrlEvent,
    );
  }

  /// Allow only plain http(s) mirror base URLs without shell metacharacters.
  static String? _sanitizeMirrorUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (RegExp(r'''[\s'"\\;&|`$<>]''').hasMatch(raw)) return null;
    return raw;
  }
}

import 'dart:io';

import 'package:Cuplivo/features/linux_sandbox/models/linux_sandbox.dart';
import 'package:Cuplivo/features/linux_sandbox/services/android_linux_sandbox_channel.dart';
import 'package:Cuplivo/features/linux_sandbox/services/android_proot_sandbox_runtime.dart';
import 'package:Cuplivo/features/linux_sandbox/services/android_rootfs_installer.dart';
import 'package:Cuplivo/features/linux_sandbox/services/sandbox_disk_layout.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');

  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'tmp');
}

class _FakeChannel extends AndroidLinuxSandboxChannel {
  _FakeChannel({this.abi = 'arm64-v8a'})
    : super(channel: const MethodChannel('test.linux_sandbox.unused'));

  final String abi;
  final List<String> shellCommands = <String>[];
  AndroidProotShellResult shellResult = const AndroidProotShellResult(
    exitCode: 0,
    stdout: 'ok\n',
    stderr: '',
    timedOut: false,
    truncated: false,
  );

  @override
  Future<String> getSupportedAbi() async => abi;

  @override
  Future<String> getNativeLibraryDir() async => '/native';

  @override
  Future<bool> hasRootfs(String sandboxRoot) async {
    return File(p.join(sandboxRoot, 'linux', 'bin', 'sh')).existsSync();
  }

  @override
  Future<AndroidProotShellResult> execShell({
    required String sandboxRoot,
    required String command,
    required int timeoutMs,
  }) async {
    shellCommands.add(command);
    return shellResult;
  }

  @override
  Future<void> destroy(String sandboxRoot) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late PathProviderPlatform previous;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('android_proot_rt_');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    AndroidLinuxSandboxChannel.clearAbiCache();
  });

  tearDown(() async {
    PathProviderPlatform.instance = previous;
    AndroidLinuxSandboxChannel.clearAbiCache();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('ensureReady is layout only', () async {
    final runtime = AndroidProotSandboxRuntime(
      's1',
      channel: _FakeChannel(),
      installer: AndroidRootfsInstaller(
        rawClient: MockClient((_) async => http.Response('no', 500)),
      ),
    );
    await runtime.ensureReady();
    final root = await SandboxDiskLayout.sandboxRoot('s1');
    expect(await Directory(p.join(root.path, 'files')).exists(), isTrue);
    expect(await Directory(p.join(root.path, 'linux')).exists(), isTrue);
    expect(await SandboxDiskLayout.hasBaseEnvMarker('s1'), isFalse);
  });

  test('installBaseEnv fails on unsupported ABI', () async {
    final runtime = AndroidProotSandboxRuntime(
      's2',
      channel: _FakeChannel(abi: 'unsupported'),
      installer: AndroidRootfsInstaller(
        rawClient: MockClient((_) async => http.Response('no', 500)),
      ),
    );
    final result = await runtime.installBaseEnv();
    expect(result.ok, isFalse);
    expect(result.mode, LinuxSandboxRuntimeMode.proot);
    expect(result.errorMessage, contains('Unsupported Android ABI'));
  });

  test('probeStatus ready when rootfs and marker present', () async {
    final runtime = AndroidProotSandboxRuntime('s3', channel: _FakeChannel());
    await runtime.ensureReady();
    final linux = await SandboxDiskLayout.linuxDir('s3');
    await File(p.join(linux.path, 'bin', 'sh')).create(recursive: true);
    await SandboxDiskLayout.writeBaseEnvMarker('s3');
    expect(await runtime.probeStatus(), LinuxSandboxStatus.ready);
  });

  test('shell calls channel when ready', () async {
    final channel = _FakeChannel();
    final runtime = AndroidProotSandboxRuntime('s4', channel: channel);
    await runtime.ensureReady();
    final linux = await SandboxDiskLayout.linuxDir('s4');
    await File(p.join(linux.path, 'bin', 'sh')).create(recursive: true);
    await SandboxDiskLayout.writeBaseEnvMarker('s4');

    final result = await runtime.shell('echo hi');
    expect(result.ok, isTrue);
    expect(result.content, contains('ok'));
    expect(channel.shellCommands, ['echo hi']);
  });

  test('shell fails when not ready', () async {
    final runtime = AndroidProotSandboxRuntime('s5', channel: _FakeChannel());
    await runtime.ensureReady();
    final result = await runtime.shell('echo hi');
    expect(result.ok, isFalse);
    expect(result.errorCode, 'not_ready');
  });

  test('file ops use LocalJailFs under files/', () async {
    final runtime = AndroidProotSandboxRuntime('s6', channel: _FakeChannel());
    await runtime.ensureReady();
    final write = await runtime.write('hello.txt', 'world');
    expect(write.ok, isTrue);
    final read = await runtime.read('hello.txt');
    expect(read.ok, isTrue);
    expect(read.content, 'world');
    final files = await SandboxDiskLayout.filesDir('s6');
    expect(await File(p.join(files.path, 'hello.txt')).exists(), isTrue);
  });
}

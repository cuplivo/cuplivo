import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/assistant.dart';
import '../../models/workspace.dart';
import '../../providers/workspace_provider.dart';
import '../../services/chat/chat_service.dart';
import '../mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'linux_sandbox_service.dart';
import 'workspace_download_service.dart';
import 'workspace_path_presentation.dart';

/// Builds and dispatches workspace local tools (filesystem + shell).
class WorkspaceToolsService {
  const WorkspaceToolsService._();

  static List<Map<String, dynamic>> buildToolDefinitions({
    required Assistant? assistant,
    required WorkspaceProvider workspaces,
    required bool supportsTools,
    LinuxSandboxService? sandbox,
  }) {
    if (!supportsTools || assistant == null || !assistant.workspaceEnabled) {
      return const <Map<String, dynamic>>[];
    }
    final ws = _boundWorkspace(assistant, workspaces);
    if (ws == null) return const <Map<String, dynamic>>[];

    final enabled = <String>{
      for (final t in WorkspaceToolNames.filesystemTools)
        if (ws.isToolEnabled(t)) t,
    };
    if (ws.shellEnabled &&
        ws.isToolEnabled(WorkspaceToolNames.shell) &&
        _shellAvailable(sandbox)) {
      enabled.add(WorkspaceToolNames.shell);
    }

    final engine = KelivoFilesystemMcpServerEngine(
      mountsProvider: () => workspaces.mountsFor(ws),
    );
    final defs = engine.toolDefinitionsFor(enabled);
    final out = <Map<String, dynamic>>[];
    for (final t in defs) {
      // Model-facing copy only: canonical wire format stays unchanged.
      final presented = presentDefMap(t);
      out.add({
        'type': 'function',
        'function': {
          'name': presented['name'],
          'description': presented['description'],
          'parameters': presented['inputSchema'] ?? {'type': 'object'},
        },
      });
    }
    if (enabled.contains(WorkspaceToolNames.shell)) {
      out.add(_shellToolDef());
    }
    return out;
  }

  static Map<String, dynamic> _shellToolDef() => {
    'type': 'function',
    'function': {
      'name': WorkspaceToolNames.shell,
      'description':
          'Run a shell command inside the Linux sandbox for the bound '
          'workspace. Working directory defaults to /workspace (the '
          'workspace root). Output is truncated. Requires base dependency '
          'installed.',
      'parameters': {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'Shell command to execute',
          },
          'cwd': {
            'type': 'string',
            'description':
                'Optional guest cwd under /workspace (relative path or '
                '/workspace/...)',
          },
          'timeout': {
            'type': 'integer',
            'description': 'Timeout seconds (1-600, default 30)',
            'minimum': 1,
            'maximum': 600,
          },
        },
        'required': ['command'],
      },
    },
  };

  /// Whether shell should be exposed to the model.
  ///
  /// Previously this returned true on any mobile platform even when the
  /// native runtime was missing, causing the model to invoke shell and
  /// trigger a native crash. Now we cache a synchronous flag that is set
  /// after the first successful [LinuxSandboxService.hasRuntime] probe.
  static bool _shellAvailable(LinuxSandboxService? sandbox) {
    if (sandbox == null) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    // Only expose shell when we have confirmed the runtime exists.
    // The flag is set by [probeShellAvailability] at app startup.
    return _shellRuntimeConfirmed;
  }

  /// Cached result of the async runtime check. Defaults to false (safe)
  /// until explicitly confirmed.
  static bool _shellRuntimeConfirmed = false;

  /// Call once at app startup (e.g. in main or provider init) to probe
  /// whether the native sandbox runtime is available. Until this completes,
  /// shell tools will not be exposed to models — preventing native crashes
  /// on builds that lack the proot/iSH binary.
  static Future<void> probeShellAvailability([
    LinuxSandboxService? sandbox,
  ]) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final svc = sandbox ?? LinuxSandboxService.instance;
    try {
      _shellRuntimeConfirmed = await svc.hasRuntime();
    } catch (_) {
      _shellRuntimeConfirmed = false;
    }
  }

  static Workspace? _boundWorkspace(
    Assistant assistant,
    WorkspaceProvider workspaces,
  ) {
    final id = assistant.workspaceId;
    if (id == null || id.isEmpty) return null;
    return workspaces.getById(id);
  }

  static Set<String> enabledToolNames(
    Assistant? assistant,
    WorkspaceProvider workspaces, {
    LinuxSandboxService? sandbox,
  }) {
    if (assistant == null || !assistant.workspaceEnabled) {
      return const <String>{};
    }
    final ws = _boundWorkspace(assistant, workspaces);
    if (ws == null) return const <String>{};
    final names = <String>{
      for (final t in WorkspaceToolNames.filesystemTools)
        if (ws.isToolEnabled(t)) t,
    };
    if (ws.shellEnabled &&
        ws.isToolEnabled(WorkspaceToolNames.shell) &&
        _shellAvailable(sandbox)) {
      names.add(WorkspaceToolNames.shell);
    }
    return names;
  }

  static Future<String?> tryHandleToolCall({
    required String name,
    required Map<String, dynamic> args,
    required Assistant? assistant,
    required WorkspaceProvider workspaces,
    ChatService? chatService,
    LinuxSandboxService? sandbox,
    void Function(int receivedBytes, int? totalBytes)? onDownloadProgress,
    WorkspaceDownloadAbortToken? downloadAbortToken,
  }) async {
    if (assistant == null || !assistant.workspaceEnabled) return null;
    if (!WorkspaceToolNames.isWorkspaceTool(name)) return null;

    final ws = _boundWorkspace(assistant, workspaces);
    if (ws == null) {
      return jsonEncode({
        'error': 'workspace_unbound',
        'message': 'No workspace bound to this assistant.',
      });
    }
    if (name == WorkspaceToolNames.shell) {
      if (!ws.shellEnabled ||
          !ws.isToolEnabled(WorkspaceToolNames.shell) ||
          !_shellAvailable(sandbox)) {
        return null;
      }
    } else if (!ws.isToolEnabled(name)) {
      return null;
    }

    if (name == WorkspaceToolNames.shell) {
      return _handleShell(
        args: args,
        ws: ws,
        workspaces: workspaces,
        sandbox: sandbox,
      );
    }

    final engine = KelivoFilesystemMcpServerEngine(
      mountsProvider: () => workspaces.mountsFor(ws),
      pathPresenter: (wire) => presentWirePath(wire, ws.alias),
      onWorkspaceFileDeleted: (wirePath) {
        final store = chatService?.deletedRecordsStore;
        if (store == null) return Future<void>.value();
        return store.recordFileDeletion(
          id: wirePath,
          deletedAt: DateTime.now(),
        );
      },
    );
    final Map<String, dynamic> translatedArgs;
    try {
      translatedArgs = _translateModelArgs(args, ws.alias);
    } on ModelPathException catch (e) {
      return jsonEncode({'error': 'invalid_path', 'message': e.message});
    }
    final result = await engine.callTool(
      name,
      translatedArgs,
      onDownloadProgress: onDownloadProgress,
      downloadAbortToken: downloadAbortToken,
    );
    return _mcpResultToText(result);
  }

  /// Strict model-facing path translation: the model must use
  /// `/workspace/...`; canonical `@alias/...` is rejected (see
  /// `workspace_path_presentation.dart`).
  static Map<String, dynamic> _translateModelArgs(
    Map<String, dynamic> args,
    String alias,
  ) {
    final out = Map<String, dynamic>.from(args);
    for (final key in const ['path', 'source', 'destination']) {
      final v = out[key];
      if (v == null || v is! String) continue;
      out[key] = parseModelPath(v, alias);
    }
    return out;
  }

  static String _mcpResultToText(Map<String, dynamic> result) {
    final isError = result['isError'] == true;
    final content = result['content'];
    final buf = StringBuffer();
    if (content is List) {
      for (final c in content) {
        if (c is Map && c['type'] == 'text') {
          buf.writeln(c['text'] ?? '');
        }
      }
    }
    final text = buf.toString().trim();
    if (isError) {
      return text.isEmpty ? 'Tool error' : text;
    }
    return text;
  }

  static Future<String> _handleShell({
    required Map<String, dynamic> args,
    required Workspace ws,
    required WorkspaceProvider workspaces,
    LinuxSandboxService? sandbox,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return jsonEncode({
        'error': 'shell_unsupported',
        'message': 'Linux sandbox shell is only available on Android or iOS.',
      });
    }
    final svc = sandbox ?? LinuxSandboxService.instance;
    final host = workspaces.hostPathFor(ws);
    if (host == null) {
      return jsonEncode({
        'error': 'workspace_path_missing',
        'message': 'Workspace host path is not ready.',
      });
    }
    final status = await svc.statusFor(host);
    if (status != SandboxStatus.ready) {
      return jsonEncode({
        'error': 'sandbox_not_ready',
        'status': status.name,
        'message': LinuxSandboxService.statusUserMessage(status),
      });
    }
    final command = (args['command'] ?? '').toString();
    if (command.trim().isEmpty) {
      return jsonEncode({
        'error': 'invalid_args',
        'message': 'command is required',
      });
    }
    final cwd = args['cwd']?.toString();
    final timeout = (args['timeout'] as num?)?.toInt() ?? 30;
    try {
      final result = await svc.exec(
        workspaceHostPath: host,
        command: command,
        cwd: cwd,
        timeoutSeconds: timeout.clamp(1, 600),
      );
      return jsonEncode({
        'exitCode': result.exitCode,
        'timedOut': result.timedOut,
        'stdout': result.stdout,
        'stderr': result.stderr,
      });
    } catch (e, st) {
      debugPrint('shell tool failed: $e\n$st');
      return jsonEncode({'error': 'shell_failed', 'message': e.toString()});
    }
  }

  /// Short system-prompt reminder when workspace tools are active.
  static String? buildPromptReminder({
    required Assistant? assistant,
    required WorkspaceProvider workspaces,
    LinuxSandboxService? sandbox,
  }) {
    if (assistant == null || !assistant.workspaceEnabled) return null;
    final ws = _boundWorkspace(assistant, workspaces);
    if (ws == null) return null;
    final tools = enabledToolNames(
      assistant,
      workspaces,
      sandbox: sandbox,
    ).join(', ');
    if (tools.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln('<workspace>')
      ..writeln('Bound workspace: /workspace (${ws.displayName})')
      ..writeln('Paths use the /workspace/rel/path form')
      ..writeln('Enabled tools: $tools');
    if (enabledToolNames(
      assistant,
      workspaces,
      sandbox: sandbox,
    ).contains(WorkspaceToolNames.shell)) {
      buf.writeln('Shell guest cwd default: /workspace');
    }
    buf.writeln('</workspace>');
    return buf.toString();
  }
}

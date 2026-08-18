import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/assistant.dart';
import '../../models/conversation.dart';
import '../../models/workspace.dart';
import '../../providers/workspace_provider.dart';
import '../../services/chat/chat_service.dart';
import '../mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import 'linux_sandbox_service.dart';
import 'workspace_download_service.dart';
import 'workspace_execution_context.dart';
import 'workspace_path_presentation.dart';

/// Builds and dispatches workspace local tools (filesystem + shell).
class WorkspaceToolsService {
  const WorkspaceToolsService._();

  static List<Map<String, dynamic>> buildToolDefinitions({
    required Assistant? assistant,
    required WorkspaceProvider workspaces,
    required bool supportsTools,
    LinuxSandboxService? sandbox,
    Conversation? conversation,
    WorkspaceExecutionContext? executionContext,
  }) {
    if (!supportsTools) {
      return const <Map<String, dynamic>>[];
    }
    final context =
        executionContext ??
        _resolveContext(assistant, conversation, workspaces);
    if (context == null) return const <Map<String, dynamic>>[];
    final ws = context.workspace;

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
      final description =
          '${presented['description'] ?? ''}\n'
          'Relative paths resolve from ${context.workingDirectory}; '
          'absolute /workspace/... paths resolve from the workspace root.';
      out.add({
        'type': 'function',
        'function': {
          'name': presented['name'],
          'description': description,
          'parameters': presented['inputSchema'] ?? {'type': 'object'},
        },
      });
    }
    if (enabled.contains(WorkspaceToolNames.shell)) {
      out.add(_shellToolDef(context.workingDirectory));
    }
    return out;
  }

  static Map<String, dynamic> _shellToolDef(String workingDirectory) => {
    'type': 'function',
    'function': {
      'name': WorkspaceToolNames.shell,
      'description':
          'Run a shell command inside the Linux sandbox for the bound '
          'workspace. Working directory defaults to $workingDirectory. '
          'Relative cwd values resolve from that directory; absolute '
          '/workspace/... values resolve from the workspace root. Output is '
          'truncated. Requires base dependency installed.',
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

  static bool _shellAvailable(LinuxSandboxService? sandbox) {
    if (sandbox == null) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return true;
  }

  static WorkspaceExecutionContext? _resolveContext(
    Assistant? assistant,
    Conversation? conversation,
    WorkspaceProvider workspaces,
  ) {
    try {
      return WorkspaceExecutionContext.resolve(
        assistant: assistant,
        conversation: conversation,
        workspaces: workspaces,
      );
    } on WorkspacePathException catch (e) {
      debugPrint('workspace context invalid: ${e.message}');
      return null;
    }
  }

  static Set<String> enabledToolNames(
    Assistant? assistant,
    WorkspaceProvider workspaces, {
    LinuxSandboxService? sandbox,
    Conversation? conversation,
    WorkspaceExecutionContext? executionContext,
  }) {
    final context =
        executionContext ??
        _resolveContext(assistant, conversation, workspaces);
    if (context == null) return const <String>{};
    final ws = context.workspace;
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
    String? toolCallId,
    String? conversationId,
    Conversation? conversation,
    WorkspaceExecutionContext? executionContext,
  }) async {
    if (!WorkspaceToolNames.isWorkspaceTool(name)) return null;
    if (executionContext == null &&
        (assistant == null || !assistant.workspaceEnabled)) {
      return null;
    }
    final context =
        executionContext ??
        _resolveContext(assistant, conversation, workspaces);
    if (context == null) {
      return jsonEncode({
        'error': 'workspace_unbound',
        'message': 'No workspace bound to this assistant.',
      });
    }
    final ws = context.workspace;
    if (name == WorkspaceToolNames.shell) {
      if (!ws.shellEnabled ||
          !ws.isToolEnabled(WorkspaceToolNames.shell) ||
          !_shellAvailable(sandbox)) {
        return null;
      }
    } else if (!ws.isToolEnabled(name)) {
      return null;
    }
    try {
      await ensureWorkspaceWorkingDirectory(
        context: context,
        workspaces: workspaces,
      );
    } catch (e, st) {
      debugPrint('workspace working directory unavailable: $e\n$st');
      return jsonEncode({
        'error': 'working_directory_unavailable',
        'message': e.toString(),
      });
    }

    if (name == WorkspaceToolNames.shell) {
      return _handleShell(
        args: args,
        ws: ws,
        workspaces: workspaces,
        sandbox: sandbox,
        requestId: toolCallId,
        conversationId: conversationId,
        workingDirectory: context.workingDirectory,
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
      translatedArgs = _translateModelArgs(
        args,
        ws.alias,
        context.workingDirectory,
      );
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

  /// Resolves relative model-facing paths from the captured working directory
  /// and translates them to the canonical `@alias/...` wire format.
  static Map<String, dynamic> _translateModelArgs(
    Map<String, dynamic> args,
    String alias,
    String workingDirectory,
  ) {
    final out = Map<String, dynamic>.from(args);
    for (final key in const ['path', 'source', 'destination']) {
      final v = out[key];
      if (v == null || v is! String) continue;
      out[key] = parseModelPath(v, alias, workingDirectory: workingDirectory);
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
    String? requestId,
    String? conversationId,
    required String workingDirectory,
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
    final command = (args['command'] ?? '').toString();
    if (command.trim().isEmpty) {
      return jsonEncode({
        'error': 'invalid_args',
        'message': 'command is required',
      });
    }
    final String cwd;
    try {
      cwd = resolveWorkspaceGuestPath(
        args['cwd']?.toString() ?? workingDirectory,
        baseDirectory: workingDirectory,
        allowMountListingRoot: false,
      );
    } on WorkspacePathException catch (e) {
      return jsonEncode({'error': 'invalid_path', 'message': e.message});
    }
    final timeout = (args['timeout'] as num?)?.toInt() ?? 30;
    try {
      final result = await svc.exec(
        workspaceHostPath: host,
        command: command,
        cwd: cwd,
        timeoutSeconds: timeout
            .clamp(1, LinuxSandboxService.maxShellTimeoutSeconds)
            .toInt(),
        requestId: requestId,
        conversationId: conversationId,
        requireReady: true,
      );
      return jsonEncode({
        'exitCode': result.exitCode,
        'timedOut': result.timedOut,
        'cancelled': result.cancelled,
        'stdoutTruncated': result.stdoutTruncated,
        'stderrTruncated': result.stderrTruncated,
        'stdout': result.stdout,
        'stderr': result.stderr,
      });
    } on SandboxBusyException {
      return jsonEncode({
        'error': 'sandbox_busy',
        'message':
            'Another sandbox operation is already queued for this workspace.',
      });
    } on SandboxCancelledException {
      return jsonEncode({
        'error': 'sandbox_cancelled',
        'message': 'The sandbox operation was cancelled.',
      });
    } on SandboxNotReadyException catch (e) {
      return jsonEncode({
        'error': 'sandbox_not_ready',
        'status': e.status.name,
        'message': LinuxSandboxService.statusUserMessage(e.status),
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
    Conversation? conversation,
    WorkspaceExecutionContext? executionContext,
  }) {
    final context =
        executionContext ??
        _resolveContext(assistant, conversation, workspaces);
    if (context == null) return null;
    final ws = context.workspace;
    final tools = enabledToolNames(
      assistant,
      workspaces,
      sandbox: sandbox,
      conversation: conversation,
      executionContext: context,
    ).join(', ');
    if (tools.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln('<workspace>')
      ..writeln('Bound workspace: /workspace (${ws.displayName})')
      ..writeln('Current working directory: ${context.workingDirectory}')
      ..writeln(
        'Relative paths resolve from the current working directory; '
        'absolute /workspace/... paths resolve from the workspace root.',
      )
      ..writeln('Enabled tools: $tools');
    if (enabledToolNames(
      assistant,
      workspaces,
      sandbox: sandbox,
      conversation: conversation,
      executionContext: context,
    ).contains(WorkspaceToolNames.shell)) {
      buf.writeln('Shell guest cwd default: ${context.workingDirectory}');
    }
    buf.writeln('</workspace>');
    return buf.toString();
  }
}

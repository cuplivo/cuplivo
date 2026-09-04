import 'package:command_shield/command_shield.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/quick_instruction.dart';

enum QuickInstructionToolKind { local, mcpServer, filesystem, shell }

class QuickInstructionPolicyRejection {
  const QuickInstructionPolicyRejection({
    required this.reason,
    required this.instructionTitles,
  });

  final String reason;
  final List<String> instructionTitles;
}

/// Request-scoped negative permissions contributed by active quick
/// instructions. This never mutates the assistant or workspace tool settings.
class QuickInstructionExecutionPolicy {
  QuickInstructionExecutionPolicy._(this._entries);

  factory QuickInstructionExecutionPolicy.fromSources({
    required Iterable<QuickInstruction> systemInstructions,
    required Iterable<QuickInstructionInvocationSnapshot> anchorInvocations,
  }) {
    final entries = <_NamedPolicy>[
      for (final instruction in systemInstructions)
        if (instruction.toolPolicy.enabled)
          _NamedPolicy(instruction.title, instruction.toolPolicy),
      for (final snapshot in anchorInvocations)
        if (snapshot.toolPolicy.enabled)
          _NamedPolicy(snapshot.title, snapshot.toolPolicy),
    ];
    return QuickInstructionExecutionPolicy._(
      List<_NamedPolicy>.unmodifiable(entries),
    );
  }

  final List<_NamedPolicy> _entries;

  bool get isEmpty => _entries.isEmpty;

  QuickInstructionPolicyRejection? checkTool({
    required QuickInstructionToolKind kind,
    required String id,
  }) {
    final deniedBy = <String>[];
    for (final entry in _entries) {
      final denied = switch (kind) {
        QuickInstructionToolKind.local =>
          entry.policy.disabledLocalToolIds.contains(id),
        QuickInstructionToolKind.mcpServer =>
          entry.policy.disabledMcpServerIds.contains(id),
        QuickInstructionToolKind.filesystem =>
          entry.policy.disabledFilesystemToolNames.contains(id),
        QuickInstructionToolKind.shell => entry.policy.shellDisabled,
      };
      if (denied) deniedBy.add(entry.title);
    }
    if (deniedBy.isEmpty) return null;
    return QuickInstructionPolicyRejection(
      reason: switch (kind) {
        QuickInstructionToolKind.local => 'local_tool_disabled',
        QuickInstructionToolKind.mcpServer => 'mcp_server_disabled',
        QuickInstructionToolKind.filesystem => 'filesystem_tool_disabled',
        QuickInstructionToolKind.shell => 'shell_disabled',
      },
      instructionTitles: _cleanTitles(deniedBy),
    );
  }

  QuickInstructionPolicyRejection? checkShellCommand(String command) {
    final commandEntries = _entries
        .where((entry) => entry.policy.shellBlockPatterns.isNotEmpty)
        .toList(growable: false);
    if (commandEntries.isEmpty) return null;
    final policy = _QuickInstructionCommandPolicy(commandEntries);
    final result = CommandShield(
      defaultSyntax: CommandSyntax.bash,
      policy: policy,
    ).validate(command);
    if (result.decision == CommandDecision.allow) return null;
    return QuickInstructionPolicyRejection(
      reason: policy.lastReason ?? 'shell_command_rejected',
      instructionTitles: _cleanTitles(policy.lastTitles),
    );
  }

  static List<String> _cleanTitles(Iterable<String> titles) {
    return titles
        .map((title) => title.trim())
        .where((title) => title.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }
}

class _NamedPolicy {
  const _NamedPolicy(this.title, this.policy);

  final String title;
  final QuickInstructionToolPolicy policy;
}

/// `command_shield` is used only for complete Bash AST traversal. Its default
/// risk policy is intentionally not composed here: approval and sandboxing
/// remain independent, while quick instructions enforce only their explicit
/// command block rules.
class _QuickInstructionCommandPolicy extends CommandPolicy {
  _QuickInstructionCommandPolicy(this.entries);

  final List<_NamedPolicy> entries;
  String? lastReason;
  List<String> lastTitles = const <String>[];

  @override
  String get name => 'quick-instruction-command-policy';

  @override
  CommandResult evaluate(CommandAnalysis analysis) {
    final hasIncompleteParse =
        analysis.ast == null ||
        analysis.invocations.isEmpty ||
        analysis.diagnostics.any(
          (diagnostic) => diagnostic.severity != DiagnosticSeverity.info,
        );
    if (hasIncompleteParse) {
      lastReason = 'shell_command_incomplete_analysis';
      lastTitles = entries.map((entry) => entry.title).toList(growable: false);
      return result(
        CommandDecision.deny,
        SecurityLevel.highRisk,
        'The shell command could not be analysed completely.',
      );
    }

    for (final invocation in analysis.invocations) {
      final normalized = _canonicalInvocation(invocation);
      final blockedBy = <String>[];
      for (final entry in entries) {
        if (entry.policy.shellBlockPatterns.any(
          (pattern) => _matchesGlob(normalized, pattern),
        )) {
          blockedBy.add(entry.title);
        }
      }
      if (blockedBy.isNotEmpty) {
        lastReason = 'shell_command_blocked';
        lastTitles = blockedBy;
        return result(
          CommandDecision.deny,
          SecurityLevel.highRisk,
          'A quick instruction blocked "$normalized".',
        );
      }
    }

    return allowResult;
  }
}

String _canonicalInvocation(CommandInvocation invocation) {
  final tokens = <String>[
    _quoteToken(invocation.executable),
    ...invocation.arguments.map(_quoteToken),
    for (final redirect in invocation.redirections)
      redirect.type == RedirectionType.mergeStreams
          ? redirect.target.replaceAll('\\', '/')
          : '${_redirectionOperator(redirect.type)}${_quoteToken(redirect.target)}',
  ];
  return tokens.join(' ');
}

String _quoteToken(String token) {
  final normalized = token.replaceAll('\\', '/');
  if (RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(normalized)) {
    return normalized;
  }
  return "'${normalized.replaceAll("'", "'\\''")}'";
}

String _redirectionOperator(RedirectionType type) => switch (type) {
  RedirectionType.output => '>',
  RedirectionType.appendOutput => '>>',
  RedirectionType.input => '<',
  RedirectionType.hereDocument => '<<',
  RedirectionType.errorOutput => '2>',
  RedirectionType.appendErrorOutput => '2>>',
  RedirectionType.mergeStreams => '',
  RedirectionType.combinedOutput => '&>',
  RedirectionType.combinedAppendOutput => '&>>',
};

bool _matchesGlob(String command, String rawPattern) {
  final pattern = rawPattern.trim().replaceAll('\\', '/');
  if (pattern.isEmpty) return false;
  final optionalArguments = pattern.endsWith(' *');
  final body = optionalArguments
      ? pattern.substring(0, pattern.length - 2)
      : pattern;
  final escaped = RegExp.escape(
    body,
  ).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
  final expression = optionalArguments ? '^$escaped(?: .*)?\$' : '^$escaped\$';
  final windowsShell =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  return RegExp(
    expression,
    caseSensitive: !windowsShell,
  ).hasMatch(command.replaceAll('\\', '/'));
}

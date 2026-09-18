import 'dart:io';

import 'package:flutter/foundation.dart';

/// Windows Defender Firewall integration for the LAN sync server.
///
/// The rule is PORT-scoped (`localport=`) rather than program-scoped:
/// program-scoped rules break whenever the executable path changes (app
/// update / reinstall), while a port rule keeps working. The server is
/// single-use, so the port is only open during a sync session.
///
/// Rule names deliberately avoid spaces and parentheses: `netsh` argument
/// quoting for `name=<value>` with special characters is unreliable across
/// locales, and these names must round-trip through both a plain
/// [Process.run] and a `Start-Process -ArgumentList` UAC re-invocation.
class WindowsFirewall {
  static String ruleName(int port) => 'Cuplivo-LanSync-TCP-$port';

  static List<String> addRuleArgs(int port) => [
    'advfirewall',
    'firewall',
    'add',
    'rule',
    'name=${ruleName(port)}',
    'dir=in',
    'action=allow',
    'protocol=TCP',
    'localport=$port',
  ];

  static List<String> showRuleArgs(int port) => [
    'advfirewall',
    'firewall',
    'show',
    'rule',
    'name=${ruleName(port)}',
  ];

  static List<String> deleteRuleArgs(int port) => [
    'advfirewall',
    'firewall',
    'delete',
    'rule',
    'name=${ruleName(port)}',
  ];

  /// PowerShell one-liner that re-runs the same `netsh` add as an elevated
  /// process (triggers the UAC prompt).
  static String elevateAddRuleCommand(int port) {
    final quoted = addRuleArgs(port).map((a) => "'$a'").join(', ');
    return 'Start-Process -Verb RunAs -Wait -WindowStyle Hidden '
        'netsh -ArgumentList $quoted';
  }

  /// Whether a rule with our name already exists. Works without admin.
  static Future<bool> ruleExists(int port) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run('netsh', showRuleArgs(port));
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('WindowsFirewall ruleExists failed: $e');
      return false;
    }
  }

  /// Attempts to add the rule without elevation. Returns false when the
  /// attempt failed (typically: no administrator rights, or netsh missing).
  static Future<bool> tryAddRule(int port) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run('netsh', addRuleArgs(port));
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('WindowsFirewall tryAddRule failed: $e');
      return false;
    }
  }

  /// Elevated one-click add via UAC (`Start-Process -Verb RunAs`).
  /// Re-checks the rule after the elevated process exits; the exit code of
  /// the elevated process is not propagated by `Start-Process`.
  static Future<bool> addRuleElevated(int port) async {
    if (!Platform.isWindows) return false;
    try {
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        elevateAddRuleCommand(port),
      ]);
    } catch (e) {
      debugPrint('WindowsFirewall addRuleElevated failed: $e');
    }
    return ruleExists(port);
  }

  /// Best-effort removal without elevation. Returns false when the deletion
  /// failed (typically: no administrator rights).
  ///
  /// Only called for non-preferred (random fallback) ports on server stop —
  /// the main-port rule is kept across sessions so the common path never
  /// re-prompts for UAC.
  static Future<bool> tryDeleteRule(int port) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run('netsh', deleteRuleArgs(port));
      return result.exitCode == 0;
    } catch (e) {
      debugPrint('WindowsFirewall tryDeleteRule failed: $e');
      return false;
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:math_expressions/math_expressions.dart';

import '../../../core/models/assistant.dart';
import '../../../features/skills/github_importer.dart';
import '../../../features/skills/skill_importer.dart';
import '../../../features/skills/skill_manager.dart';
import '../../../features/skills/skill_paths.dart';

typedef TextToSpeechStarter = Future<void> Function(String text);
typedef SkillsImportedCallback = Future<void> Function(List<String> names);

class LocalToolNames {
  const LocalToolNames._();

  static const String timeInfo = 'get_time_info';
  static const String clipboard = 'clipboard_tool';
  static const String textToSpeech = 'text_to_speech';
  static const String askUser = 'ask_user_input_v0';
  static const String calculate = 'calculate';
  static const String loadSkill = 'load_skill';
  static const String readSkillFile = 'read_skill_file';
  static const String handoff = 'kelivo_handoff';
  static const String handoffSync = 'kelivo_handoff_sync';
  static const String downloadSkill = 'download_skill';
  static const String createSkill = 'create_skill';
  static const String screenTime = 'get_screen_time';
  static const String calendarQuery = 'calendar_query';
  static const String calendarCreate = 'calendar_create';
}

/// Outcome of the platform permission flow when a device-backed local tool
/// toggle is turned on. Both toggle surfaces (assistant edit tab, Tools Hub)
/// translate it into persist + snackbar behavior.
enum DeviceToolToggleOutcome {
  /// Permission already granted, or granted via the flow → enable the tool.
  canEnable,

  /// Usage Access missing: the system Usage Access settings page was opened.
  /// The tool is still enabled (upstream parity) and the caller shows the
  /// permission-required snackbar.
  canEnableUsageAccessMissing,

  /// Calendar permission was denied → do not enable the tool.
  blocked,

  /// The current platform does not support the tool → do not enable it.
  notSupported,
}

/// Platform capability check + permission facade for the device-backed local
/// tools (get_screen_time / calendar_query / calendar_create), implemented
/// over a MethodChannel in the Android/iOS host apps.
class DeviceLocalTools {
  const DeviceLocalTools._();

  static const MethodChannel channel = MethodChannel('app.device_tools');

  static bool get screenTimeSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get calendarSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether Android Usage Access (PACKAGE_USAGE_STATS) is granted.
  static Future<bool> hasUsageStatsPermission() async {
    if (!screenTimeSupported) return false;
    try {
      final result = await channel.invokeMethod<bool>(
        'hasUsageStatsPermission',
      );
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Opens the system Usage Access settings page (Android).
  static Future<void> openUsageAccessSettings() async {
    if (!screenTimeSupported) return;
    try {
      await channel.invokeMethod<void>('openUsageAccessSettings');
    } on MissingPluginException {
      // Unsupported host.
    } on PlatformException {
      // Settings unavailable.
    }
  }

  /// Returns true when calendar full access is already granted. Uses the
  /// native EventKit / Android calendar permission path (not
  /// permission_handler), so it works without iOS PERMISSION_EVENTS macros.
  static Future<bool> hasCalendarPermission() async {
    if (!calendarSupported) return false;
    try {
      final result = await channel.invokeMethod<bool>('hasCalendarPermission');
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Upper bound for `requestCalendarPermission` (see the review note on
  /// activity recreation losing the permission result). Test overrides this
  /// to a short duration.
  @visibleForTesting
  static Duration calendarPermissionTimeout = const Duration(minutes: 2);

  /// Requests calendar full access via the native channel. Returns true only
  /// when granted. On iOS, permanently denied / restricted states open the app
  /// Settings page.
  static Future<bool> requestCalendarPermission() async {
    if (!calendarSupported) return false;
    try {
      final result = await channel
          .invokeMethod<bool>('requestCalendarPermission')
          .timeout(calendarPermissionTimeout);
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      // Activity recreation mid-dialog (rotation / memory-pressured OEM
      // restart) can lose the permission result: the native callback is bound
      // to the old activity and never fires, leaving this future pending
      // forever. Re-check the actual grant state instead of reporting false
      // — the user may have granted before the recreation, and a retry tap
      // must not be stuck behind the stale "request in progress" guard.
      return hasCalendarPermission();
    }
  }

  /// True when [toolId] is a device-tool name and the current platform
  /// supports it (rows are hidden elsewhere via `screenTimeSupported` /
  /// `calendarSupported`).
  static bool isSupportedDeviceTool(String toolId) {
    if (toolId == LocalToolNames.screenTime) {
      return screenTimeSupported;
    }
    if (toolId == LocalToolNames.calendarQuery ||
        toolId == LocalToolNames.calendarCreate) {
      return calendarSupported;
    }
    return false;
  }

  /// Runs the asymmetric permission flow used by both toggle surfaces (assistant
  /// edit tab + Tools Hub) before a device tool is enabled:
  /// - screenTime: Usage Access is a system-settings special permission. When
  ///   missing, the settings page is opened and the tool is still enabled (the
  ///   tool def itself reports NO_PERMISSION and lets the model guide the user).
  /// - calendar: standard runtime request. When denied, the tool stays off.
  static Future<DeviceToolToggleOutcome> requestToggleEnable(
    String toolId,
  ) async {
    if (!isSupportedDeviceTool(toolId)) {
      return DeviceToolToggleOutcome.notSupported;
    }
    if (toolId == LocalToolNames.screenTime) {
      final granted = await hasUsageStatsPermission();
      if (!granted) {
        await openUsageAccessSettings();
        return DeviceToolToggleOutcome.canEnableUsageAccessMissing;
      }
      return DeviceToolToggleOutcome.canEnable;
    }
    if (toolId == LocalToolNames.calendarQuery ||
        toolId == LocalToolNames.calendarCreate) {
      if (!await hasCalendarPermission()) {
        final granted = await requestCalendarPermission();
        if (!granted) {
          return DeviceToolToggleOutcome.blocked;
        }
      }
      return DeviceToolToggleOutcome.canEnable;
    }
    return DeviceToolToggleOutcome.notSupported;
  }
}

class LocalToolsService {
  const LocalToolsService._();

  static List<Map<String, dynamic>> buildToolDefinitions({
    required Assistant? assistant,
    required bool supportsTools,
    List<Assistant>? discoverableAssistants,
  }) {
    if (!supportsTools || assistant == null) {
      return const <Map<String, dynamic>>[];
    }

    final tools = <Map<String, dynamic>>[];
    if (assistant.localToolIds.contains(LocalToolNames.timeInfo)) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.timeInfo,
          'description':
              'Get the current local date and time from the user\'s device. Use this only when time info is necessary for your response. NOT for time differences, durations, or scheduling logic.',
          'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
        },
      });
    }
    if (assistant.localToolIds.contains(LocalToolNames.clipboard)) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.clipboard,
          'description':
              'Read or write plain text from/to the device clipboard. Use only when the user explicitly asks to read, copy, or paste clipboard content. CRITICAL: Do NOT write to the clipboard unless the user has explicitly requested it. Never read the clipboard speculatively as clipboard content is private.',
          'parameters': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['read', 'write'],
                'description': 'Operation to perform: read or write',
              },
              'text': {
                'type': 'string',
                'description':
                    'Text to write to the clipboard. Required for write.',
              },
            },
            'required': ['action'],
          },
        },
      });
    }
    if (assistant.localToolIds.contains(LocalToolNames.textToSpeech)) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.textToSpeech,
          'description':
              'Speak text aloud to the user using the configured text-to-speech playback. Use this when the user asks you to read something aloud, or when audio output is appropriate. The tool returns after playback has been requested; audio may continue in the background. Provide natural, readable text without markdown formatting.',
          'parameters': {
            'type': 'object',
            'properties': {
              'text': {
                'type': 'string',
                'description': 'The text to speak aloud.',
              },
            },
            'required': ['text'],
          },
        },
      });
    }
    if (assistant.localToolIds.contains(LocalToolNames.askUser)) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.askUser,
          'description':
              'Ask the user one or more short choice questions when you need clarification, additional information, or a decision before you can continue. Use when the request is ambiguous, the user must pick between options, or you need specific information they have not provided. IMPORTANT: The UI automatically provides "Other" and "Skip" options, so do NOT include those as explicit options. DO NOT use this when you can infer the answer from conversation context. Limit to at most 4 questions at a time.',
          'parameters': {
            'type': 'object',
            'properties': {
              'questions': {
                'type': 'array',
                'description': 'One to four questions to ask the user.',
                'items': {
                  'type': 'object',
                  'properties': {
                    'id': {
                      'type': 'string',
                      'description':
                          'Unique stable identifier for this question.',
                    },
                    'question': {
                      'type': 'string',
                      'description':
                          'The full question text shown to the user.',
                    },
                    'type': {
                      'type': 'string',
                      'enum': ['single', 'multi'],
                      'description':
                          'Answer type: single choice or multi choice.',
                    },
                    'options': {
                      'type': 'array',
                      'description':
                          'Suggested options for the user to choose from.',
                      'items': {'type': 'string'},
                    },
                  },
                  'required': ['id', 'question'],
                },
              },
            },
            'required': ['questions'],
          },
        },
      });
    }
    if (assistant.localToolIds.contains(LocalToolNames.calculate)) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.calculate,
          'description':
              'Evaluate a mathematical expression. Supports: + - * / ^ % !, sin() cos() tan() sqrt() ln() abs() floor() ceil() sgn(), log(base, value), constants pi e. Example: "5!", "sin(pi/4)", "log(2, 8)", "floor(3.7)"',
          'parameters': {
            'type': 'object',
            'properties': {
              'expression': {
                'type': 'string',
                'description':
                    'A mathematical expression in standard notation, e.g. "(15 + 3) * 2", "2^10", "sqrt(144)"',
              },
            },
            'required': ['expression'],
          },
        },
      });
    }
    if (DeviceLocalTools.screenTimeSupported &&
        assistant.localToolIds.contains(LocalToolNames.screenTime)) {
      tools.add({
        'type': 'function',
        'function': {
          'name': LocalToolNames.screenTime,
          'description':
              "Get the user's app screen usage (screen time) over a time range. "
              "Specify a custom interval with 'begin'/'end', or use the 'range' preset (today/week). "
              'Returns the total foreground time and a per-app breakdown sorted by usage time (descending). '
              '${_deviceTimezoneHint()} '
              "Requires the 'Usage access' special permission; if it is not granted, the device's usage "
              'access settings page is opened automatically and an error is returned.',
          'parameters': {
            'type': 'object',
            'properties': {
              'begin': {
                'type': 'string',
                'description':
                    "Start time (inclusive). Accepts an ISO-8601 date 'yyyy-MM-dd', a local "
                    "date-time 'yyyy-MM-ddTHH:mm:ss', an offset date-time, or epoch milliseconds. "
                    "When provided, 'range' is ignored.",
              },
              'end': {
                'type': 'string',
                'description':
                    "End time (exclusive), same formats as 'begin'. Defaults to now.",
              },
              'range': {
                'type': 'string',
                'enum': ['today', 'week'],
                'description':
                    "Convenience preset, used only when 'begin' is omitted: today or week. Default today.",
              },
              'top': {
                'type': 'integer',
                'description':
                    'Maximum number of top apps to return, sorted by usage time. Default 10.',
              },
            },
          },
        },
      });
    }
    if (DeviceLocalTools.calendarSupported &&
        assistant.localToolIds.contains(LocalToolNames.calendarQuery)) {
      tools.add({
        'type': 'function',
        'function': {
          'name': LocalToolNames.calendarQuery,
          'description':
              "Query calendar events on the user's device within a time range. "
              "Specify a custom interval with 'begin'/'end', or use the 'range' preset (today/week/month). "
              'Returns a list of events with title, description, location, start/end times, and calendar info. '
              '${_deviceTimezoneHint()} '
              "Requires the 'Calendar' permission; if it is not granted, an error is returned.",
          'parameters': {
            'type': 'object',
            'properties': {
              'begin': {
                'type': 'string',
                'description':
                    "Start time (inclusive). Accepts an ISO-8601 date 'yyyy-MM-dd', a local "
                    "date-time 'yyyy-MM-ddTHH:mm:ss', an offset date-time, or epoch milliseconds. "
                    "When provided, 'range' is ignored.",
              },
              'end': {
                'type': 'string',
                'description': "End time (exclusive), same formats as 'begin'.",
              },
              'range': {
                'type': 'string',
                'enum': ['today', 'week', 'month'],
                'description':
                    "Convenience preset, used only when 'begin' is omitted: today, week, or month. Default today.",
              },
              'query': {
                'type': 'string',
                'description':
                    'Optional keyword to filter events by title (case-insensitive substring match).',
              },
              'limit': {
                'type': 'integer',
                'description':
                    'Maximum number of events to return. Default 20.',
              },
            },
          },
        },
      });
    }
    if (DeviceLocalTools.calendarSupported &&
        assistant.localToolIds.contains(LocalToolNames.calendarCreate)) {
      tools.add({
        'type': 'function',
        'function': {
          'name': LocalToolNames.calendarCreate,
          'description':
              "Create a new calendar event on the user's device. "
              'Requires title and start time at minimum. End time defaults to 1 hour after start. '
              'A reminder alarm is set when reminder_minutes is provided (minutes before start, at least 1). '
              'The user will be asked to confirm before the event is created. '
              '${_deviceTimezoneHint()} '
              "Requires the 'Calendar' permission; if it is not granted, an error is returned.",
          'parameters': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': 'Event title.'},
              'description': {
                'type': 'string',
                'description': 'Event description or notes.',
              },
              'location': {'type': 'string', 'description': 'Event location.'},
              'start': {
                'type': 'string',
                'description':
                    "Start time. Accepts an ISO-8601 date 'yyyy-MM-dd', a local "
                    "date-time 'yyyy-MM-ddTHH:mm:ss', an offset date-time, or epoch milliseconds.",
              },
              'end': {
                'type': 'string',
                'description':
                    "End time, same formats as 'start'. Defaults to 1 hour after start.",
              },
              'all_day': {
                'type': 'boolean',
                'description':
                    'Whether this is an all-day event. Default false.',
              },
              'reminder_minutes': {
                'type': 'integer',
                'description':
                    'Reminder alarm, minutes before start (at least 1). Optional; no reminder when omitted.',
              },
            },
            'required': ['title', 'start'],
          },
        },
      });
    }
    if (assistant.skillIds.isNotEmpty) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.loadSkill,
          'description':
              'Load the full instructions of a named skill. Use this when the task matches the description of an available skill and you need the detailed instructions. Call this early before attempting the task.',
          'parameters': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description': 'The name of the skill to load',
              },
            },
            'required': ['name'],
          },
        },
      });
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.readSkillFile,
          'description':
              'Read an auxiliary file from a skill directory. Use this after load_skill shows available files and you need to read a specific one.',
          'parameters': {
            'type': 'object',
            'properties': {
              'name': {
                'type': 'string',
                'description': 'The name of the skill',
              },
              'path': {
                'type': 'string',
                'description':
                    'Relative path to the file within the skill directory (forward slashes only)',
              },
            },
            'required': ['name', 'path'],
          },
        },
      });
    }
    if (assistant.localToolIds.contains(LocalToolNames.handoff)) {
      // Single wait-mode sub-agent delegation tool (ADR-0045): the retired
      // `kelivo_handoff_sync` sibling is fused into `kelivo_handoff`, whose
      // ids are normalized at Assistant construction.
      tools.add({
        'type': 'function',
        'function': {
          'name': LocalToolNames.handoff,
          'description': _handoffDescription(
            discoverableAssistants: discoverableAssistants,
            excludeId: assistant.id,
          ),
          'parameters': _handoffParameters(),
        },
      });
    }
    if (assistant.localToolIds.contains(LocalToolNames.downloadSkill)) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.downloadSkill,
          'description':
              'Download and install one or more skills from a GitHub repository. Use this when the user asks you to install a skill from a GitHub URL or provides a repository link, or when the task needs a capability that an installable skill provides. Use the /tree/<branch>/<path> URL form to target a specific subdirectory when the repository contains many skills.',
          'parameters': {
            'type': 'object',
            'properties': {
              'url': {
                'type': 'string',
                'description':
                    'GitHub repository URL, e.g. https://github.com/owner/repo or https://github.com/owner/repo/tree/main/skills/foo',
              },
            },
            'required': ['url'],
          },
        },
      });
    }
    if (assistant.localToolIds.contains(LocalToolNames.createSkill)) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LocalToolNames.createSkill,
          'description':
              'Create a new skill from its full SKILL.md content, including the YAML frontmatter with a name field. Use this when the user asks you to create or save a skill, or provides SKILL.md content to store as a skill.',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {
                'type': 'string',
                'description':
                    'The complete SKILL.md content, including YAML frontmatter (name, description, optional category) and the instruction body.',
              },
            },
            'required': ['content'],
          },
        },
      });
    }
    return tools;
  }

  static List<Assistant> _handoffTargets(
    List<Assistant>? discoverable, {
    String? excludeId,
  }) {
    return (discoverable ?? const <Assistant>[])
        .where(
          (a) =>
              a.discoverable &&
              a.handoffId != null &&
              a.handoffId!.isNotEmpty &&
              // Self-delegation would enable unbounded recursion — the
              // delegating assistant is never a valid target.
              a.id != excludeId,
        )
        .toList();
  }

  /// Available sub-agent delegation targets for the given assistant — the
  /// single source behind the settings status row, the Tools Hub badge and
  /// the target list sheet.
  static List<Assistant> handoffTargets(
    List<Assistant> all, {
    String? excludeId,
  }) {
    return _handoffTargets(all, excludeId: excludeId);
  }

  static String _handoffDescription({
    required List<Assistant>? discoverableAssistants,
    String? excludeId,
  }) {
    final buffer = StringBuffer();
    buffer.write(
      'Delegate a task to another specialized assistant AS A SUB-AGENT and '
      'WAIT for it to finish. '
      'The sub-agent\'s complete output is returned as the tool result, '
      'so you can synthesize from it. '
      'The result may be long and this call may take minutes. '
      'The user can watch progress in the sub-agent panel and visit the '
      'sub-conversation.\n',
    );
    final targets = _handoffTargets(
      discoverableAssistants,
      excludeId: excludeId,
    );
    if (targets.isEmpty) {
      buffer.write(
        'No assistants are currently available. '
        'Ask the user to enable "discoverable" on the target assistant.',
      );
    } else {
      buffer.write('Available targets:\n');
      for (final t in targets) {
        buffer.write('- ${t.handoffId}: ${t.handoffDescription ?? t.name}\n');
      }
    }
    return buffer.toString();
  }

  static Map<String, dynamic> _handoffParameters() {
    return {
      'type': 'object',
      'properties': {
        'assistant': {
          'type': 'string',
          'description': 'The handoff ID of the target assistant',
        },
        'task': {
          'type': 'string',
          'description':
              'The complete task prompt for the target assistant. '
              'Include all necessary context — the target has no access '
              'to this conversation\'s history.',
        },
      },
      'required': ['assistant', 'task'],
    };
  }

  static Future<String?> tryHandleToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant, {
    TextToSpeechStarter? onSpeakText,
    SkillsImportedCallback? onSkillsImported,
  }) async {
    if (assistant == null) return null;

    // load_skill is gated by skillIds, not localToolIds
    if (name == LocalToolNames.loadSkill) {
      return _handleLoadSkill(args, assistant);
    }
    if (name == LocalToolNames.readSkillFile) {
      return _handleReadSkillFile(args, assistant);
    }

    if (!assistant.localToolIds.contains(name)) {
      return null;
    }
    if (name == LocalToolNames.timeInfo) {
      return jsonEncode(_buildTimeInfoPayload(DateTime.now()));
    }
    if (name == LocalToolNames.clipboard) {
      return _handleClipboardTool(args);
    }
    if (name == LocalToolNames.textToSpeech) {
      return _handleTextToSpeechTool(args, onSpeakText);
    }
    if (name == LocalToolNames.calculate) {
      return _handleCalculateTool(args);
    }
    if (name == LocalToolNames.screenTime &&
        DeviceLocalTools.screenTimeSupported) {
      return _invokeDeviceTool('getScreenTime', args);
    }
    if (name == LocalToolNames.calendarQuery &&
        DeviceLocalTools.calendarSupported) {
      return _invokeDeviceTool('queryCalendar', args);
    }
    if (name == LocalToolNames.calendarCreate &&
        DeviceLocalTools.calendarSupported) {
      return _invokeDeviceTool('createCalendarEvent', args);
    }
    if (name == LocalToolNames.downloadSkill) {
      return _handleDownloadSkill(args, onSkillsImported);
    }
    if (name == LocalToolNames.createSkill) {
      return _handleCreateSkill(args, onSkillsImported);
    }
    return null;
  }

  static Future<String> _handleClipboardTool(Map<String, dynamic> args) async {
    final action = (args['action'] ?? '').toString();
    switch (action) {
      case 'read':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return jsonEncode({'text': data?.text ?? ''});
      case 'write':
        final text = args['text']?.toString();
        if (text == null) {
          throw ArgumentError('text is required for clipboard write');
        }
        await Clipboard.setData(ClipboardData(text: text));
        return jsonEncode({'success': true, 'text': text});
      default:
        throw ArgumentError('unknown clipboard action: $action');
    }
  }

  static Future<String> _handleTextToSpeechTool(
    Map<String, dynamic> args,
    TextToSpeechStarter? onSpeakText,
  ) async {
    final text = args['text']?.toString().trim();
    if (text == null || text.isEmpty) {
      throw ArgumentError('text is required for text_to_speech');
    }
    if (onSpeakText == null) {
      throw StateError('text-to-speech executor is unavailable');
    }
    await onSpeakText(text);
    return jsonEncode({'success': true});
  }

  static Map<String, dynamic> _buildTimeInfoPayload(DateTime now) {
    final offset = now.timeZoneOffset;
    final offsetSign = offset.isNegative ? '-' : '+';
    final offsetAbs = offset.abs();
    final offsetHours = offsetAbs.inHours.toString().padLeft(2, '0');
    final offsetMinutes = (offsetAbs.inMinutes % 60).toString().padLeft(2, '0');

    final year = now.year.toString().padLeft(4, '0');
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    final weekdayEn = _englishWeekdayName(now.weekday);

    return <String, dynamic>{
      'year': now.year,
      'month': now.month,
      'day': now.day,
      'weekday': weekdayEn,
      'weekday_en': weekdayEn,
      'weekday_index': now.weekday,
      'date': '$year-$month-$day',
      'time': '$hour:$minute:$second',
      'datetime': now.toIso8601String(),
      'timezone': now.timeZoneName,
      'utc_offset': '$offsetSign$offsetHours:$offsetMinutes',
      'timestamp_ms': now.millisecondsSinceEpoch,
    };
  }

  static String _englishWeekdayName(int weekday) {
    return switch (weekday) {
      DateTime.monday => 'Monday',
      DateTime.tuesday => 'Tuesday',
      DateTime.wednesday => 'Wednesday',
      DateTime.thursday => 'Thursday',
      DateTime.friday => 'Friday',
      DateTime.saturday => 'Saturday',
      DateTime.sunday => 'Sunday',
      _ => 'Unknown',
    };
  }

  static String _handleCalculateTool(Map<String, dynamic> args) {
    final expression = (args['expression'] ?? '').toString().trim();
    if (expression.isEmpty) {
      return jsonEncode({
        'error': 'empty_expression',
        'message':
            'Expression is empty. Please provide a mathematical expression in standard notation, e.g. "(15 + 3) * 2".',
      });
    }

    try {
      final parsed = GrammarParser().parse(expression);
      final result = parsed.evaluate(EvaluationType.REAL, ContextModel());
      if (!result.isFinite) {
        return jsonEncode({
          'error': 'math_error',
          'message':
              'The result is not a finite number. Please check your expression (e.g. division by zero).',
        });
      }
      return jsonEncode({
        'expression': expression,
        'result': result.toString(),
      });
    } catch (e) {
      return jsonEncode({
        'error': 'parse_error',
        'message':
            'Could not parse the expression. Use standard notation, e.g. "(15 + 3) * 2".',
        'detail': e.toString(),
      });
    }
  }

  static String _deviceTimezoneHint() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return "The device timezone is '${now.timeZoneName}' (UTC offset $sign$hh:$mm); "
        'times without an explicit offset are interpreted in this timezone.';
  }

  /// Invokes a native device tool over the MethodChannel. The native side
  /// returns a JSON string payload (including structured error payloads that
  /// the model can act on, e.g. missing permissions).
  static Future<String> _invokeDeviceTool(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await DeviceLocalTools.channel.invokeMethod<String>(
        method,
        jsonEncode(args),
      );
      if (result == null || result.isEmpty) {
        return jsonEncode({
          'error': 'no_result',
          'message': 'The device tool returned no result.',
        });
      }
      return result;
    } on MissingPluginException {
      return jsonEncode({
        'error': 'unsupported_platform',
        'message': 'This tool is not available on the current platform.',
      });
    } on PlatformException catch (e) {
      return jsonEncode({
        'error': e.code,
        'message': e.message ?? 'The device tool failed.',
      });
    }
  }

  static Future<String?> _handleLoadSkill(
    Map<String, dynamic> args,
    Assistant assistant,
  ) async {
    final name = (args['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return jsonEncode({
        'error': 'missing_name',
        'message':
            'Please provide a "name" parameter with the skill name to load.',
      });
    }
    if (!assistant.skillIds.contains(name)) {
      return jsonEncode({
        'error': 'skill_not_found',
        'message': 'Skill "$name" is not enabled for this assistant.',
      });
    }
    final body = await SkillManager.readSkillBody(name);
    if (body == null) {
      return jsonEncode({
        'error': 'skill_not_found',
        'message':
            'Skill "$name" was not found on disk. It may have been deleted.',
      });
    }

    final sb = StringBuffer();
    sb.writeln('<skill name="$name">');
    sb.writeln('  <instructions>');
    sb.writeln(body);
    sb.writeln('  </instructions>');

    final files = await SkillManager.listSkillFiles(name);
    if (files.isNotEmpty) {
      sb.writeln('  <files>');
      for (final f in files) {
        sb.writeln('    <file path="${f.path}" size="${f.size}"/>');
      }
      sb.writeln('  </files>');
    }

    sb.write('</skill>');
    return sb.toString();
  }

  static Future<String?> _handleReadSkillFile(
    Map<String, dynamic> args,
    Assistant assistant,
  ) async {
    final name = (args['name'] ?? '').toString().trim();
    final path = (args['path'] ?? '').toString().trim();
    if (name.isEmpty || path.isEmpty) {
      return jsonEncode({
        'error': 'missing_params',
        'message': 'Both "name" and "path" parameters are required.',
      });
    }
    if (!assistant.skillIds.contains(name)) {
      return jsonEncode({
        'error': 'skill_not_found',
        'message': 'Skill "$name" is not enabled for this assistant.',
      });
    }

    final result = await SkillManager.readSkillFile(name, path);
    if (result == null) {
      return jsonEncode({
        'error': 'file_not_found',
        'message':
            'File "$path" not found in skill "$name", or path is invalid.',
      });
    }
    if (result.isBinary) {
      return jsonEncode({
        'error': 'binary_file',
        'message': 'File "$path" is binary and cannot be displayed.',
      });
    }
    return result.content;
  }

  static Future<String> _handleCreateSkill(
    Map<String, dynamic> args,
    SkillsImportedCallback? onSkillsImported,
  ) async {
    final content = (args['content'] ?? '').toString().trim();
    if (content.isEmpty) {
      return jsonEncode({
        'error': 'missing_content',
        'message':
            'Please provide the complete SKILL.md content, including the YAML frontmatter.',
      });
    }

    final parsed = SkillManager.parseFrontmatter(content);
    if (parsed == null) {
      return jsonEncode({
        'error': 'invalid_frontmatter',
        'message':
            'SKILL.md content must start with YAML frontmatter containing a name field.',
      });
    }
    final name = (parsed.fields['name'] ?? '').trim();
    if (name.isEmpty) {
      return jsonEncode({
        'error': 'name_missing',
        'message': 'The YAML frontmatter must contain a "name" field.',
      });
    }

    // Validate the name before the existence check: on a case-insensitive
    // filesystem (Windows) an invalid name like "ALPHA" would otherwise
    // collide with an existing "alpha" directory and be misreported as
    // already_exists. Keep the payload identical to the saveSkill error path.
    final nameError = SkillPaths.validateName(name);
    if (nameError != null) {
      return jsonEncode({
        'error': 'save_failed',
        'message': 'Failed to save skill: $nameError',
      });
    }

    if (await SkillManager.skillExists(name)) {
      return jsonEncode({
        'error': 'already_exists',
        'name': name,
        'message':
            'A skill named "$name" already exists and would be overwritten. '
            'Do not call create_skill with this name again; use load_skill '
            'to read the existing skill or ask the user for a new name.',
      });
    }

    final error = await SkillManager.saveSkill(name: name, content: content);
    if (error != null) {
      return jsonEncode({
        'error': 'save_failed',
        'message':
            'Failed to save skill: ${error.params['detail'] ?? error.code}',
      });
    }

    final enabled = onSkillsImported != null;
    if (onSkillsImported != null) {
      await onSkillsImported([name]);
    }
    return jsonEncode({
      'success': true,
      'name': name,
      'message':
          'Skill "$name" has been created'
          '${enabled ? ' and enabled for this assistant' : ''}. '
          'Call load_skill with this name to read its instructions before use.',
    });
  }

  static Future<String> _handleDownloadSkill(
    Map<String, dynamic> args,
    SkillsImportedCallback? onSkillsImported,
  ) async {
    final url = (args['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      return jsonEncode({
        'error': 'missing_url',
        'message': 'Please provide a GitHub repository URL.',
      });
    }

    final info = parseGitHubUrl(url);
    if (info == null) {
      return jsonEncode({
        'error': 'invalid_url',
        'message':
            'Invalid GitHub URL. Expected https://github.com/owner/repo or '
            'https://github.com/owner/repo/tree/<branch>/<path>.',
      });
    }

    final zipFile = await downloadGitHubArchive(info);
    if (zipFile == null) {
      return jsonEncode({
        'error': 'download_failed',
        'message':
            'Failed to download the repository. It may not exist, is private, '
            'or the network request failed.',
      });
    }

    try {
      final outcome = await SkillImporter.importFromZip(
        zipFile,
        subPath: info.subPath,
        stripPrefix: info.stripPrefix,
      );
      if (outcome.error == SkillZipError.scanFailed) {
        return jsonEncode({
          'error': 'scan_failed',
          'message':
              'Failed to scan the downloaded archive. It may be corrupted, '
              'too large, or contain too many files.',
        });
      }
      if (outcome.error == SkillZipError.noSkillsFound) {
        return jsonEncode({
          'error': 'no_skills_found',
          'message':
              'No skills (SKILL.md files with a name field) were found in the repository.',
        });
      }
      if (outcome.error == SkillZipError.tooManySkills) {
        return jsonEncode({
          'error': 'too_many_skills',
          'count': outcome.discoveredCount,
          'message':
              'The repository contains ${outcome.discoveredCount} skills. '
              'Provide a more specific URL using /tree/<branch>/<path> to '
              'narrow down to fewer than 5 skills.',
        });
      }

      final result = outcome.result!;
      if (result.imported == 0) {
        return jsonEncode({
          'error': 'import_failed',
          'failed': result.failed,
          'message':
              'None of the discovered skills could be imported '
              '(${result.failed} failed).',
        });
      }

      final enabled = onSkillsImported != null;
      if (onSkillsImported != null) {
        await onSkillsImported(result.importedNames);
      }
      return jsonEncode({
        'success': true,
        'imported': result.imported,
        'failed': result.failed,
        'names': result.importedNames,
        'message':
            'Imported ${result.imported} skill(s): '
            '${result.importedNames.join(', ')}'
            '${result.failed > 0 ? ' (${result.failed} failed)' : ''}.'
            '${enabled ? ' All imported skills are enabled for this assistant.' : ''} '
            'Call load_skill with a skill name to read its instructions '
            'before use.',
      });
    } finally {
      try {
        await zipFile.delete();
      } catch (_) {}
    }
  }
}

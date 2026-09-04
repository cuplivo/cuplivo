import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../core/services/workspace/workspace_terminal_native_bridge.dart';

class AndroidWorkspaceTerminalViewController {
  AndroidWorkspaceTerminalViewController({
    required int viewId,
    required this.workspaceId,
    required this.onStateChanged,
    required this.onCopyModeChanged,
    required this.onModifierConsumed,
    required this.onError,
  }) : _channel = MethodChannel('cuplivo/workspace_terminal_view/$viewId') {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final String workspaceId;
  final ValueChanged<WorkspaceTerminalSessionState> onStateChanged;
  final ValueChanged<bool> onCopyModeChanged;
  final VoidCallback onModifierConsumed;
  final ValueChanged<Object> onError;
  final MethodChannel _channel;

  Future<Object?> _handleNativeCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'sessionStateChanged':
          final raw = call.arguments;
          if (raw is! Map) {
            throw StateError('Terminal state callback must contain a map');
          }
          onStateChanged(
            WorkspaceTerminalSessionState.fromMap(
              workspaceId,
              raw.cast<Object?, Object?>(),
            ),
          );
          return null;
        case 'copyModeChanged':
          if (call.arguments is! bool) {
            throw StateError('copyModeChanged must contain a bool');
          }
          onCopyModeChanged(call.arguments as bool);
          return null;
        case 'modifierConsumed':
          onModifierConsumed();
          return null;
        case 'fontSizeChanged':
          return null;
        case 'attachFailed':
          throw StateError(
            call.arguments?.toString() ?? 'Terminal attach failed',
          );
        default:
          throw MissingPluginException('Unknown terminal view callback');
      }
    } catch (error) {
      onError(error);
      return null;
    }
  }

  Future<void> attach() => _channel.invokeMethod<void>('attach');

  Future<void> detach() => _channel.invokeMethod<void>('detach');

  Future<void> sendText(String text, {required bool ctrl, required bool alt}) =>
      _channel.invokeMethod<void>('sendText', <String, Object?>{
        'text': text,
        'ctrl': ctrl,
        'alt': alt,
      });

  Future<void> sendKey(String key, {required bool ctrl, required bool alt}) =>
      _channel.invokeMethod<void>('sendKey', <String, Object?>{
        'key': key,
        'ctrl': ctrl,
        'alt': alt,
      });

  Future<void> setModifiers({required bool ctrl, required bool alt}) =>
      _channel.invokeMethod<void>('setModifiers', <String, Object?>{
        'ctrl': ctrl,
        'alt': alt,
      });

  Future<int?> setTextSize(int size) =>
      _channel.invokeMethod<int>('setTextSize', size);

  Future<String?> copySelection() =>
      _channel.invokeMethod<String>('copySelection');

  Future<void> clearSelection() =>
      _channel.invokeMethod<void>('clearSelection');

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}

class AndroidWorkspaceTerminalView extends StatelessWidget {
  const AndroidWorkspaceTerminalView({
    super.key,
    required this.workspaceId,
    required this.fontSize,
    required this.onControllerCreated,
    required this.onStateChanged,
    required this.onCopyModeChanged,
    required this.onModifierConsumed,
    required this.onError,
  });

  final String workspaceId;
  final int fontSize;
  final ValueChanged<AndroidWorkspaceTerminalViewController>
  onControllerCreated;
  final ValueChanged<WorkspaceTerminalSessionState> onStateChanged;
  final ValueChanged<bool> onCopyModeChanged;
  final VoidCallback onModifierConsumed;
  final ValueChanged<Object> onError;

  @override
  Widget build(BuildContext context) {
    return AndroidView(
      viewType: 'cuplivo/workspace_terminal_view',
      creationParams: <String, Object?>{
        'workspaceId': workspaceId,
        'fontSize': fontSize,
      },
      creationParamsCodec: const StandardMessageCodec(),
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onPlatformViewCreated: (viewId) {
        final controller = AndroidWorkspaceTerminalViewController(
          viewId: viewId,
          workspaceId: workspaceId,
          onStateChanged: onStateChanged,
          onCopyModeChanged: onCopyModeChanged,
          onModifierConsumed: onModifierConsumed,
          onError: onError,
        );
        onControllerCreated(controller);
      },
    );
  }
}

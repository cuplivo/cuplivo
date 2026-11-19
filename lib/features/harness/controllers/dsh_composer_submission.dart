import 'package:flutter/foundation.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';

/// The outcome of one composer submission, with the Host's rejection text when
/// there is one.
@immutable
class DshComposerSubmissionResult {
  const DshComposerSubmissionResult(this.result, {this.message});

  final ChatInputSubmissionResult result;

  /// Host-supplied rejection text, already user-readable.
  final String? message;

  bool get rejected => result == ChatInputSubmissionResult.rejected;
}

/// Bridges `ChatInputBar.onSend` to a remote session.
///
/// `ChatInputBar` clears the composer before calling `onSend` and restores the
/// draft when the result is `rejected`, so the contract here is strict:
///
/// - `sent` only after the Host accepted the prompt (`session/prompt` answered
///   `{accepted:true}`);
/// - `rejected` for a refused prompt, a transport error, a stale link, or an
///   empty submission — the user's text is never lost.
///
/// Cuplivo's own `.queued` state is not used: DSH queueing is the server's
/// (`session/prompt` with `mode:'queue'`), and a queued remote prompt is still
/// accepted by the Host, so it reports `sent` here.
class DshComposerSubmission {
  const DshComposerSubmission(this.session);

  final DshChatSession session;

  /// `ChatInputBar.onSend` entry point.
  Future<ChatInputSubmissionResult> submit(ChatInputData input) async {
    final result = await submitWithReason(input);
    return result.result;
  }

  /// Same as [submit] but keeps the rejection text for a snackbar.
  Future<DshComposerSubmissionResult> submitWithReason(
    ChatInputData input,
  ) async {
    final text = input.text.trim();
    if (text.isEmpty) {
      return const DshComposerSubmissionResult(
        ChatInputSubmissionResult.rejected,
      );
    }
    if (!session.canSend) {
      return const DshComposerSubmissionResult(
        ChatInputSubmissionResult.rejected,
      );
    }
    try {
      final result = await session.sendPrompt(text);
      if (result.isAccepted) {
        return const DshComposerSubmissionResult(
          ChatInputSubmissionResult.sent,
        );
      }
      return DshComposerSubmissionResult(
        ChatInputSubmissionResult.rejected,
        message: result.message,
      );
    } catch (error) {
      // A transport failure must keep the draft: the composer restores it when
      // the result is `rejected`. The throw text is deliberately not surfaced
      // verbatim; the controller already maps it to a user sentence.
      return DshComposerSubmissionResult(
        ChatInputSubmissionResult.rejected,
        message: null,
      );
    }
  }
}

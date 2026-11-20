import 'package:flutter/foundation.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/services/dsh_attachment_upload_service.dart';

/// Builds the prompt attachments for one composer submission (images inline,
/// files uploaded). Throws [DshAttachmentFailure] when an item is refused.
typedef DshAttachmentPreparer =
    Future<List<DshPromptAttachment>> Function(ChatInputData input);

/// The outcome of one composer submission, with the Host's rejection text when
/// there is one.
@immutable
class DshComposerSubmissionResult {
  const DshComposerSubmissionResult(
    this.result, {
    this.message,
    this.attachmentFailure,
  });

  final ChatInputSubmissionResult result;

  /// Host-supplied rejection text, already user-readable.
  final String? message;

  /// Set when the composer's own attachment preparation refused the send; the
  /// chat surface localizes the kind and keeps the draft.
  final DshAttachmentFailure? attachmentFailure;

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
  const DshComposerSubmission(this.session, {this.attachmentPreparer});

  final DshChatSession session;

  /// Optional attachment preparation (the remote composer supplies an upload
  /// service; a plain text-only test passes null).
  final DshAttachmentPreparer? attachmentPreparer;

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
    if (!session.canSend) {
      return const DshComposerSubmissionResult(
        ChatInputSubmissionResult.rejected,
      );
    }
    var attachments = const <DshPromptAttachment>[];
    final preparer = attachmentPreparer;
    // The preparer is authoritative about what the draft carries (it also
    // upgrades raw picker paths), so it runs even when the text is empty: an
    // attachment-only message is a legitimate submission.
    if (preparer != null) {
      try {
        attachments = await preparer(input);
      } on DshAttachmentFailure catch (failure) {
        return DshComposerSubmissionResult(
          ChatInputSubmissionResult.rejected,
          attachmentFailure: failure,
        );
      } catch (_) {
        return const DshComposerSubmissionResult(
          ChatInputSubmissionResult.rejected,
        );
      }
    }
    if (text.isEmpty && attachments.isEmpty) {
      return const DshComposerSubmissionResult(
        ChatInputSubmissionResult.rejected,
      );
    }
    try {
      final result = await session.sendPrompt(text, attachments: attachments);
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

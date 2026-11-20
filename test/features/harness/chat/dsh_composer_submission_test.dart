import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_chat_session.dart';
import 'package:Cuplivo/features/harness/controllers/dsh_composer_submission.dart';
import 'package:Cuplivo/features/harness/services/dsh_attachment_upload_service.dart';

/// A session double: no network, no Flutter bindings.
class _FakeSession extends DshChatSession {
  _FakeSession({
    this.sendResult = const DshPromptSendResult.accepted(),
    this.canSend = true,
    this.throwOnSend = false,
  });

  DshPromptSendResult sendResult;

  @override
  bool canSend;
  bool throwOnSend;
  final List<String> prompts = <String>[];
  final List<List<DshPromptAttachment>> promptsAttachments =
      <List<DshPromptAttachment>>[];

  @override
  DshChatViewState get state => const DshChatViewState();

  @override
  Future<DshPromptSendResult> sendPrompt(
    String text, {
    List<DshPromptAttachment> attachments = const <DshPromptAttachment>[],
  }) async {
    prompts.add(text);
    promptsAttachments.add(attachments);
    if (throwOnSend) throw StateError('transport closed');
    return sendResult;
  }

  @override
  Future<String> uploadAttachment(List<int> bytes, {String? name}) async =>
      'receipt:${name ?? ''}';

  @override
  Future<DshCommandResult> runCommand(String line) async =>
      const DshCommandResult(success: true);

  @override
  Future<void> cancelTurn() async {}

  @override
  Future<DshModelSelection?> selectModel(DshModelSelection selection) async =>
      selection;

  @override
  Future<void> refreshModelCatalog() async {}

  @override
  Future<void> setPermission(String value) async {}

  @override
  Future<void> selectAgentPreset(String presetId) async {}

  @override
  Future<void> answerApproval(String requestId, {required bool allow}) async {}

  @override
  Future<void> answerQuestions(
    String requestId,
    List<DshQuestionAnswer> answers,
  ) async {}

  @override
  Future<void> rejectQuestions(String requestId) async {}

  @override
  Future<void> reload() async {}
}

void main() {
  ChatInputData input(String text) => ChatInputData(text: text);

  test('an accepted prompt reports sent', () async {
    final session = _FakeSession();
    final submission = DshComposerSubmission(session);

    final result = await submission.submitWithReason(input('  hello  '));

    expect(result.result, ChatInputSubmissionResult.sent);
    expect(result.rejected, isFalse);
    expect(result.message, isNull);
    expect(session.prompts, <String>['hello']);
  });

  test('a rejected prompt keeps the host message and the draft', () async {
    final session = _FakeSession(
      sendResult: const DshPromptSendResult.rejected('model is unavailable'),
    );
    final submission = DshComposerSubmission(session);

    final result = await submission.submitWithReason(input('hello'));

    expect(result.result, ChatInputSubmissionResult.rejected);
    expect(result.rejected, isTrue);
    expect(result.message, 'model is unavailable');
    expect(session.prompts, hasLength(1));
  });

  test('prepared attachments travel with the prompt', () async {
    final session = _FakeSession();
    final submission = DshComposerSubmission(
      session,
      attachmentPreparer: (input) async => const <DshPromptAttachment>[
        DshPromptAttachment.file(receiptId: 'receipt-1', name: 'a.txt'),
      ],
    );

    final result = await submission.submitWithReason(input('hello'));

    expect(result.result, ChatInputSubmissionResult.sent);
    expect(session.promptsAttachments.single, hasLength(1));
    expect(session.promptsAttachments.single.single.receiptId, 'receipt-1');
  });

  test('an attachment refusal keeps the draft and reports the kind', () async {
    final session = _FakeSession();
    final submission = DshComposerSubmission(
      session,
      attachmentPreparer: (input) async => throw const DshAttachmentFailure(
        DshAttachmentFailureKind.imageTooLarge,
        fileName: 'a.png',
      ),
    );

    final result = await submission.submitWithReason(input('hello'));

    expect(result.result, ChatInputSubmissionResult.rejected);
    expect(
      result.attachmentFailure?.kind,
      DshAttachmentFailureKind.imageTooLarge,
    );
    expect(session.prompts, isEmpty);
  });

  test(
    'an attachment-only send is allowed when preparation yields parts',
    () async {
      final session = _FakeSession();
      final submission = DshComposerSubmission(
        session,
        attachmentPreparer: (input) async => const <DshPromptAttachment>[
          DshPromptAttachment.file(receiptId: 'receipt-1'),
        ],
      );

      final result = await submission.submitWithReason(
        const ChatInputData(text: ''),
      );

      expect(result.result, ChatInputSubmissionResult.sent);
      expect(session.prompts.single, isEmpty);
    },
  );

  test('a session that cannot send is rejected before any prompt', () async {
    final session = _FakeSession(canSend: false);
    final submission = DshComposerSubmission(session);

    final result = await submission.submit(input('hello'));

    expect(result, ChatInputSubmissionResult.rejected);
    expect(session.prompts, isEmpty);
  });

  test('an empty draft is rejected before any prompt', () async {
    final session = _FakeSession();
    final submission = DshComposerSubmission(session);

    final result = await submission.submit(input('   \n  '));

    expect(result, ChatInputSubmissionResult.rejected);
    expect(session.prompts, isEmpty);
  });

  test('a transport failure is rejected and never loses the draft', () async {
    final session = _FakeSession(throwOnSend: true);
    final submission = DshComposerSubmission(session);

    final result = await submission.submitWithReason(input('hello'));

    expect(result.result, ChatInputSubmissionResult.rejected);
    expect(result.message, isNull);
    expect(session.prompts, <String>['hello']);
  });
}

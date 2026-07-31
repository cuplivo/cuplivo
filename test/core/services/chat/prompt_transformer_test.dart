import 'package:Cuplivo/core/models/assistant.dart';
import 'package:Cuplivo/core/services/chat/prompt_transformer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uses an override without a Localizations ancestor', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (buildContext) {
            context = buildContext;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final placeholders = PromptTransformer.buildPlaceholders(
      context: context,
      assistant: Assistant(id: 'a1', name: 'Alice'),
      modelId: 'deepseek-chat',
      modelName: 'deepseek-chat',
      userNickname: 'User',
      localeOverride: 'zh-CN',
    );

    expect(placeholders['{locale}'], 'zh-CN');
    expect(placeholders['{assistant_name}'], 'Alice');
  });

  testWidgets('falls back to the platform locale without Localizations', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (buildContext) {
            context = buildContext;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final placeholders = PromptTransformer.buildPlaceholders(
      context: context,
      assistant: Assistant(id: 'a1', name: 'Alice'),
      modelId: 'deepseek-chat',
      modelName: 'deepseek-chat',
      userNickname: 'User',
    );

    expect(placeholders['{locale}'], isNotEmpty);
  });
}

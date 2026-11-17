import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/image_job/services/image_model_resolver.dart';

void main() {
  test('the assistant wins when it names both halves', () {
    final resolved = resolveModelBinding(
      assistantProviderId: 'openai',
      assistantModelId: 'gpt-image-1',
      globalProviderId: 'openrouter',
      globalModelId: 'flux',
    );

    expect(resolved.source, ModelSource.assistant);
    expect(
      resolved.binding,
      const ModelBinding(providerId: 'openai', modelId: 'gpt-image-1'),
    );
  });

  test('an unset assistant falls through to the global default', () {
    final resolved = resolveModelBinding(
      globalProviderId: 'openai',
      globalModelId: 'gpt-image-1',
    );

    expect(resolved.source, ModelSource.global);
    expect(resolved.binding?.modelId, 'gpt-image-1');
  });

  test('a half-configured assistant does not win over a complete global', () {
    final resolved = resolveModelBinding(
      assistantProviderId: 'openai',
      assistantModelId: '   ',
      globalProviderId: 'openrouter',
      globalModelId: 'flux',
    );

    expect(resolved.source, ModelSource.global);
    expect(resolved.binding?.providerId, 'openrouter');
  });

  test('nothing configured resolves to none, not to a guess', () {
    final resolved = resolveModelBinding(
      assistantProviderId: '',
      globalModelId: '   ',
    );

    expect(resolved.source, ModelSource.none);
    expect(resolved.binding, isNull);
    expect(resolved.isConfigured, false);
  });

  test('ids are trimmed so a stray space cannot look configured', () {
    final resolved = resolveModelBinding(
      globalProviderId: '  openai ',
      globalModelId: ' gpt-image-1 ',
    );

    expect(
      resolved.binding,
      const ModelBinding(providerId: 'openai', modelId: 'gpt-image-1'),
    );
  });
}

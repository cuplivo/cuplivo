import 'package:Cuplivo/core/models/chat_input_data.dart';
import 'package:Cuplivo/core/providers/assistant_provider.dart';
import 'package:Cuplivo/core/providers/input_status_provider.dart';
import 'package:Cuplivo/core/providers/settings_provider.dart';
import 'package:Cuplivo/features/home/services/input_draft_persistence.dart';
import 'package:Cuplivo/features/home/widgets/chat_input_bar.dart';
import 'package:Cuplivo/features/home/widgets/image_generation_options.dart';
import 'package:Cuplivo/icons/lucide_adapter.dart';
import 'package:Cuplivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ImageGenerationOptionsController', () {
    test('toExtraBody omits unchanged quality and format defaults', () {
      final controller = ImageGenerationOptionsController()
        ..sizeTier = '4K'
        ..aspectRatio = '16:9'
        ..count = 2;

      expect(controller.toExtraBody(), {'size': '3840x2160', 'n': 2});
    });

    test('toExtraBody includes quality and format when customized', () {
      final controller = ImageGenerationOptionsController()
        ..quality = 'medium'
        ..outputFormat = 'webp'
        ..outputCompression = 80;

      expect(controller.toExtraBody(), {
        'quality': 'medium',
        'output_format': 'webp',
        'output_compression': 80,
      });
    });

    test(
      'restoreFromBody resets stale values before applying partial body',
      () {
        final controller = ImageGenerationOptionsController()
          ..quality = 'medium'
          ..sizeTier = '4K'
          ..aspectRatio = '16:9'
          ..outputFormat = 'webp'
          ..outputCompression = 80
          ..count = 4;

        controller.restoreFromBody({'n': 2});

        expect(controller.quality, 'high');
        expect(controller.resolvedSize, 'auto');
        expect(controller.outputFormat, 'png');
        expect(controller.outputCompression, isNull);
        expect(controller.count, 2);
      },
    );

    test('restoreFromBody falls back to dynamic defaults', () {
      final controller = ImageGenerationOptionsController()
        ..applyDefaultsFromBody(const {
          'quality': 'medium',
          'output_format': 'webp',
        })
        ..quality = 'low'
        ..sizeTier = '4K'
        ..aspectRatio = '16:9'
        ..outputCompression = 90
        ..count = 4;

      controller.restoreFromBody({'n': 2});

      expect(controller.quality, 'medium');
      expect(controller.resolvedSize, 'auto');
      expect(controller.outputFormat, 'webp');
      expect(controller.outputCompression, isNull);
      expect(controller.count, 2);
    });

    test('restoreFromBody with empty body restores defaults', () {
      final controller = ImageGenerationOptionsController()
        ..quality = 'low'
        ..sizeTier = '2K'
        ..aspectRatio = '1:1'
        ..outputFormat = 'jpeg'
        ..outputCompression = 60
        ..count = 3;

      controller.restoreFromBody(const <String, dynamic>{});

      expect(controller.customized, isFalse);
      expect(controller.toExtraBody(), isEmpty);
    });

    test(
      'applyDefaultsFromBody updates baseline without forcing overrides',
      () {
        final controller = ImageGenerationOptionsController();

        controller.applyDefaultsFromBody(const {
          'quality': 'medium',
          'output_format': 'webp',
        });

        expect(controller.quality, 'medium');
        expect(controller.outputFormat, 'webp');
        expect(controller.customized, isFalse);
        expect(controller.toExtraBody(), isEmpty);
      },
    );

    test('applyDefaultsFromBody keeps user customizations intact', () {
      final controller = ImageGenerationOptionsController()
        ..quality = 'low'
        ..count = 3;

      controller.applyDefaultsFromBody(const {
        'quality': 'medium',
        'output_format': 'webp',
      });

      expect(controller.quality, 'low');
      expect(controller.count, 3);
      expect(controller.toExtraBody(), {'quality': 'low', 'n': 3});
    });

    test('toExtraBody can clear provider size defaults back to auto', () {
      final controller = ImageGenerationOptionsController()
        ..applyDefaultsFromBody(const {'size': '3840x2160'});

      controller.sizeTier = 'auto';
      controller.aspectRatio = 'auto';

      expect(controller.toExtraBody(), {'size': null});
    });

    test(
      'toExtraBody clears inherited compression when switching back to png',
      () {
        final controller = ImageGenerationOptionsController()
          ..applyDefaultsFromBody(const {
            'output_format': 'webp',
            'output_compression': 80,
          });

        controller.outputFormat = 'png';
        controller.outputCompression = null;

        expect(controller.toExtraBody(), {
          'output_format': 'png',
          'output_compression': null,
        });
      },
    );
  });

  group('ImageGenerationOptionsSheet', () {
    Widget buildHarness({
      required TextEditingController controller,
      required FocusNode focusNode,
      required Future<ChatInputSubmissionResult> Function(ChatInputData input)
      onSend,
      required SettingsProvider settings,
    }) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: AssistantProvider()),
          ChangeNotifierProvider.value(value: InputStatusProvider()),
          Provider<InputDraftPersistence>.value(
            value: InputDraftPersistence(null),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatInputBar(
              controller: controller,
              focusNode: focusNode,
              onSend: onSend,
            ),
          ),
        ),
      );
    }

    testWidgets('panel updates its own UI live when options change', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'draw a cat');
      final focusNode = FocusNode();
      final settings = SettingsProvider();
      await settings.setProviderConfig(
        'OpenAITest',
        ProviderConfig(
          id: 'OpenAITest',
          enabled: true,
          name: 'OpenAITest',
          apiKey: 'test-key',
          baseUrl: 'https://example.com/v1',
          providerType: ProviderKind.openai,
        ),
      );
      await settings.setCurrentModel('OpenAITest', 'gpt-image-2');

      await tester.pumpWidget(
        buildHarness(
          controller: controller,
          focusNode: focusNode,
          settings: settings,
          onSend: (_) async => ChatInputSubmissionResult.rejected,
        ),
      );

      // Image mode is active (the model supports image routing), so the
      // palette button is available.
      expect(find.byIcon(Lucide.Palette), findsOneWidget);

      await tester.tap(find.byIcon(Lucide.Palette));
      await tester.pumpAndSettle();

      // Initial state: defaults inherited for gpt-image-* models.
      expect(find.text('Actual size: auto'), findsOneWidget);

      // Tapping a chip must rebuild the panel in place (it is a separate
      // Navigator route; the input bar's setState alone would not update it).
      await tester.tap(find.text('4K'));
      await tester.pump();
      expect(find.text('Actual size: 3840x2160'), findsOneWidget);

      final webpChip = find.text('WEBP');
      await tester.ensureVisible(webpChip);
      await tester.tap(webpChip);
      await tester.pump();
      expect(find.text('Compression'), findsOneWidget);

      await tester.ensureVisible(find.text('Reset'));
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(find.text('Actual size: auto'), findsOneWidget);
      expect(find.text('Compression'), findsNothing);

      controller.dispose();
      focusNode.dispose();
    });
  });
}

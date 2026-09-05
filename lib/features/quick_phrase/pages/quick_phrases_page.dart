import 'package:flutter/material.dart';

import '../../instruction_injection/pages/instruction_injection_page.dart';

/// Compatibility route for callers that still target the former page.
@Deprecated('Use InstructionInjectionPage instead.')
class QuickPhrasesPage extends StatelessWidget {
  const QuickPhrasesPage({super.key, this.assistantId});

  /// Kept only for source compatibility. Quick Instructions are global.
  final String? assistantId;

  @override
  Widget build(BuildContext context) => const InstructionInjectionPage();
}

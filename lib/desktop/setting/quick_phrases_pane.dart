import 'package:flutter/material.dart';

import '../../features/instruction_injection/pages/instruction_injection_page.dart';

/// Compatibility pane for integrations that still select the former target.
@Deprecated('Use DesktopInstructionInjectionPane instead.')
class DesktopQuickPhrasesPane extends StatelessWidget {
  const DesktopQuickPhrasesPane({super.key});

  @override
  Widget build(BuildContext context) {
    return const InstructionInjectionPage(embedded: true);
  }
}

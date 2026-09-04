import 'package:flutter/material.dart';

import '../../features/instruction_injection/pages/instruction_injection_page.dart';

/// Desktop host for the unified quick-instruction management surface.
class DesktopInstructionInjectionPane extends StatelessWidget {
  const DesktopInstructionInjectionPane({super.key});

  @override
  Widget build(BuildContext context) {
    return const InstructionInjectionPage(embedded: true);
  }
}

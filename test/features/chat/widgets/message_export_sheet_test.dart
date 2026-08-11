import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/features/chat/widgets/message_export_sheet.dart';

void main() {
  test('desktop export image config keeps enough source pixels for text', () {
    final config = exportImageRenderConfigForTesting(isDesktop: true);

    expect(config.width * config.pixelRatio, greaterThanOrEqualTo(2160));
    expect(config.pixelRatio, greaterThanOrEqualTo(3.0));
  });
}

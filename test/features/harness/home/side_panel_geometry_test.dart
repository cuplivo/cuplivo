import 'package:Cuplivo/features/side_panel/widgets/side_panel_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SidePanelGeometry constants', () {
    test('docking threshold is derived from the chat and panel minimums', () {
      expect(
        SidePanelGeometry.dockThreshold,
        SidePanelGeometry.minWidth + SidePanelGeometry.chatReserve,
      );
      expect(SidePanelGeometry.defaultWidth, 520);
      expect(SidePanelGeometry.minWidth, 360);
      expect(SidePanelGeometry.maxWidth, 900);
    });

    test('persisted preference keys live under the panel prefix', () {
      const keys = [
        SidePanelGeometry.keyOpen,
        SidePanelGeometry.keyWidth,
        SidePanelGeometry.keyLastTab,
        SidePanelGeometry.keyTabs,
        SidePanelGeometry.keyMigrated,
      ];
      for (final key in keys) {
        expect(key, startsWith(SidePanelGeometry.prefsPrefix));
        expect(key, endsWith('_v1'));
      }
      expect(keys.toSet(), hasLength(keys.length));
    });
  });

  group('presentationFor', () {
    test('a closed panel is hidden at every width and never expands', () {
      for (final width in [0.0, 400.0, 849.0, 1440.0]) {
        expect(
          SidePanelGeometry.presentationFor(
            open: false,
            expanded: false,
            availableWidth: width,
          ),
          SidePanelPresentation.hidden,
        );
        expect(
          SidePanelGeometry.presentationFor(
            open: false,
            expanded: true,
            availableWidth: width,
          ),
          SidePanelPresentation.hidden,
        );
      }
    });

    test('an expanded panel stays expanded at every width', () {
      for (final width in [0.0, 400.0, 1440.0]) {
        expect(
          SidePanelGeometry.presentationFor(
            open: true,
            expanded: true,
            availableWidth: width,
          ),
          SidePanelPresentation.expanded,
        );
      }
    });

    test('the dock threshold decides overlay vs docked exactly at 849', () {
      SidePanelPresentation at(double width) =>
          SidePanelGeometry.presentationFor(
            open: true,
            expanded: false,
            availableWidth: width,
          );

      expect(
        at(SidePanelGeometry.dockThreshold - 0.001),
        SidePanelPresentation.overlay,
      );
      expect(at(SidePanelGeometry.dockThreshold), SidePanelPresentation.docked);
      expect(
        at(SidePanelGeometry.dockThreshold + 1),
        SidePanelPresentation.docked,
      );
      expect(at(400), SidePanelPresentation.overlay);
      expect(at(1440), SidePanelPresentation.docked);
    });
  });

  group('maxWidthFor', () {
    test('caps at maxWidth, floors at minWidth, reserves the chat column', () {
      // 1126 - 489 = 637, the existing desktop panel's cap at a 1440 window.
      expect(SidePanelGeometry.maxWidthFor(1126), 637);
      // A wide surface stops at the panel's own maximum.
      expect(SidePanelGeometry.maxWidthFor(1440), SidePanelGeometry.maxWidth);
      expect(SidePanelGeometry.maxWidthFor(2000), SidePanelGeometry.maxWidth);
      // A surface exactly at the dock threshold leaves the panel its minimum.
      expect(
        SidePanelGeometry.maxWidthFor(SidePanelGeometry.dockThreshold),
        SidePanelGeometry.minWidth,
      );
      // A surface too narrow to dock never yields a nonsensical negative cap.
      expect(SidePanelGeometry.maxWidthFor(500), SidePanelGeometry.minWidth);
      expect(SidePanelGeometry.maxWidthFor(0), SidePanelGeometry.minWidth);
    });
  });

  group('widthFor', () {
    double width({
      required SidePanelPresentation presentation,
      required double preferredWidth,
      double availableWidth = 1126,
    }) => SidePanelGeometry.widthFor(
      presentation: presentation,
      preferredWidth: preferredWidth,
      availableWidth: availableWidth,
    );

    test('expanded owns the whole available width', () {
      expect(
        width(
          presentation: SidePanelPresentation.expanded,
          preferredWidth: 520,
          availableWidth: 1440,
        ),
        1440,
      );
    });

    test('overlay is bounded by the preferred width and the surface', () {
      expect(
        width(
          presentation: SidePanelPresentation.overlay,
          preferredWidth: 520,
          availableWidth: 726,
        ),
        520,
      );
      expect(
        width(
          presentation: SidePanelPresentation.overlay,
          preferredWidth: 900,
          availableWidth: 726,
        ),
        726,
      );
    });

    test('docked and hidden clamp the preferred width to the surface cap', () {
      expect(
        width(presentation: SidePanelPresentation.docked, preferredWidth: 520),
        520,
      );
      // 1126 - 489 = 637 caps a 900px preference.
      expect(
        width(presentation: SidePanelPresentation.docked, preferredWidth: 900),
        637,
      );
      // Below the minimum the panel grows back to minWidth.
      expect(
        width(presentation: SidePanelPresentation.docked, preferredWidth: 20),
        360,
      );
      // Hidden resolves like docked so layout math never needs a branch.
      expect(
        width(presentation: SidePanelPresentation.hidden, preferredWidth: 900),
        637,
      );
    });
  });
}

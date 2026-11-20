import 'package:Cuplivo/core/models/chat_input_data.dart';

/// A deterministic way for integration tests to stage composer attachments.
///
/// The real path goes through the native image/document pickers, which an
/// `integration_test` cannot drive. The mounted remote-chat composer registers
/// itself here, so a test can place files in the composer tray exactly as the
/// picker would — chips, upload, prompt parts and the transcript card all stay
/// on the product path. In a normal app the stager is null and [stage] is a
/// no-op.
abstract final class DshComposerE2e {
  static DshComposerE2eStager? _stager;

  /// Whether a remote-chat composer is currently mounted.
  static bool get isAvailable => _stager != null;

  static void attach(DshComposerE2eStager stager) {
    _stager = stager;
  }

  static void detach() {
    _stager = null;
  }

  /// Stages [images] (absolute paths, compressed like a picker result) and
  /// [documents] (already copied documents, as the picker would hand them over).
  static void stage({
    required List<String> images,
    required List<DocumentAttachment> documents,
  }) {
    _stager?.call(images, documents);
  }
}

/// Consumes staged attachments: images enter the composer's photo pipeline,
/// documents enter the document tray.
typedef DshComposerE2eStager =
    void Function(List<String> images, List<DocumentAttachment> documents);

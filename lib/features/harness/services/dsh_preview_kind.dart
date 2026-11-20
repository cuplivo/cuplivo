import 'package:path/path.dart' as p;

import 'package:Cuplivo/features/workspace/widgets/preview/preview_file_type.dart';

/// How the harness preview page intends to render one remote file.
///
/// Public and pure so the mapping from `path`/`mediaType` to a renderer can be
/// unit-tested without a widget, a gateway or a Host. `unknown` behaves like
/// `text` in the page (it attempts the text read and falls back to the metadata
/// card when the Host refuses or the body is not text).
enum DshRemotePreviewKind { text, image, pdf, office, unknown }

const Set<String> _officeExtensions = {
  '.doc',
  '.docx',
  '.rtf',
  '.odt',
  '.pages',
  '.xls',
  '.xlsx',
  '.ods',
  '.ppt',
  '.pptx',
  '.odp',
  '.key',
};

/// Classifies a workspace file for the remote preview page.
///
/// The Host's `mediaType` wins when it is specific; otherwise the extension
/// decides (the workspace listing carries no reliable MIME type). An
/// unclassifiable path goes to `text` because the Host's `workspaceFiles/read`
/// is the cheapest discriminator: a refused read means binary.
DshRemotePreviewKind classifyDshRemotePreview(
  String path, {
  String? mediaType,
}) {
  final ext = p.extension(path).toLowerCase();
  final media = mediaType?.toLowerCase();
  if (media == 'application/pdf' || ext == '.pdf') {
    return DshRemotePreviewKind.pdf;
  }
  if (_officeExtensions.contains(ext) ||
      (media != null &&
          (media.contains('officedocument') ||
              media.contains('msword') ||
              media.contains('ms-excel') ||
              media.contains('ms-powerpoint')))) {
    return DshRemotePreviewKind.office;
  }
  if ((media?.startsWith('image/') ?? false) ||
      kPreviewImageExtensions.contains(ext)) {
    return DshRemotePreviewKind.image;
  }
  return DshRemotePreviewKind.text;
}

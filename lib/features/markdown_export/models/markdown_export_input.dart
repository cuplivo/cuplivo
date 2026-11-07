/// The files this tool can turn into a picture: readable text, nothing else.
const Set<String> markdownExportExtensions = {'.md', '.markdown', '.txt'};

/// Whether [path] names a file this tool can read. The extension decides, so a
/// document that happens to be named `.pdf` never reaches the parser.
bool isMarkdownExportFile(String path) {
  final lower = path.toLowerCase();
  return markdownExportExtensions.any(lower.endsWith);
}

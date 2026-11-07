/// How large the picture's type is.
///
/// The sheet keeps its width, so a larger size means fewer characters per line
/// and a taller picture rather than a wider file.
enum MarkdownExportTextSize {
  small(0.85),
  standard(1),
  large(1.2);

  const MarkdownExportTextSize(this.scale);

  final double scale;
}

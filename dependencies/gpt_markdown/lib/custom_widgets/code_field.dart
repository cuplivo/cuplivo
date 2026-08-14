import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A widget that displays code with syntax highlighting and a copy button.
///
/// The [CodeField] widget takes a [name] parameter which is displayed as a label
/// above the code block, and a [codes] parameter containing the actual code text
/// to display.
///
/// Features:
/// - Displays code in a Material container with rounded corners
/// - Shows the code language/name as a label
/// - Provides a copy button to copy code to clipboard
/// - Visual feedback when code is copied
/// - Themed colors that adapt to light/dark mode
/// - Shows live line/character count while streaming (when [closed] is false)
class CodeField extends StatefulWidget {
  const CodeField({
    super.key,
    required this.name,
    required this.codes,
    this.closed = true,
  });
  final String name;
  final String codes;

  /// Whether the code block has been closed with a trailing ```.
  /// When false, the block is still being streamed and a live progress
  /// indicator (line count and character count) is shown instead of just
  /// the language label.
  final bool closed;

  @override
  State<CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<CodeField> {
  bool _copied = false;

  int get _lineCount {
    if (widget.codes.isEmpty) return 0;
    return '\n'.allMatches(widget.codes).length + 1;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.onInverseSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8,
                ),
                child: !widget.closed
                    ? Text(
                        widget.name.isNotEmpty
                            ? '正在生成 ${widget.name} · $_lineCount 行 · ${widget.codes.length} 字符'
                            : '正在生成 · $_lineCount 行 · ${widget.codes.length} 字符',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    : Text(widget.name),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.onSurface,
                  textStyle: const TextStyle(fontWeight: FontWeight.normal),
                ),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.codes),
                  ).then((value) {
                    setState(() {
                      _copied = true;
                    });
                  });
                  await Future.delayed(const Duration(seconds: 2));
                  setState(() {
                    _copied = false;
                  });
                },
                icon: Icon(
                  (_copied) ? Icons.done : Icons.content_paste,
                  size: 15,
                ),
                label: Text((_copied) ? "Copied!" : "Copy code"),
              ),
            ],
          ),
          const Divider(height: 1),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(16),
            child: Text(
              widget.codes,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                package: "gpt_markdown",
              ),
            ),
          ),
        ],
      ),
    );
  }
}

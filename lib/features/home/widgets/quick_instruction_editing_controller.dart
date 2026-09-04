import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/quick_instruction.dart';
import '../../../theme/app_font_weights.dart';

/// Text controller whose leading object-replacement characters render frozen
/// quick-instruction invocations as atomic inline labels.
///
/// The raw [value] is intentionally reserved for Flutter's editable-text
/// machinery. App code should use [bodyText], [bodySelection], and [bodyValue]
/// so hidden object markers never enter drafts, messages, or clipboard text.
class QuickInstructionEditingController extends TextEditingController {
  QuickInstructionEditingController({String text = ''}) : super(text: text);

  static const String objectReplacementCharacter = '\uFFFC';

  List<QuickInstructionInvocationSnapshot> _instructions =
      const <QuickInstructionInvocationSnapshot>[];

  ValueChanged<List<QuickInstructionInvocationSnapshot>>?
  onInstructionsChangedByEditing;

  List<QuickInstructionInvocationSnapshot> get instructions =>
      List<QuickInstructionInvocationSnapshot>.unmodifiable(_instructions);

  int get _prefixLength => _instructions.length;
  String get _prefix =>
      List<String>.filled(_prefixLength, objectReplacementCharacter).join();

  String get bodyText {
    final raw = value.text;
    if (raw.startsWith(_prefix)) return raw.substring(_prefixLength);
    return raw.replaceAll(objectReplacementCharacter, '');
  }

  TextSelection get bodySelection => _selectionToBody(value.selection);

  TextEditingValue get bodyValue => TextEditingValue(
    text: bodyText,
    selection: bodySelection,
    composing: _rangeToBody(value.composing),
  );

  void setBodyText(String text) {
    setBodyValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
  }

  void setBodyValue(TextEditingValue body) {
    value = _rawValueFromBody(body);
  }

  void setBodySelection(TextSelection selection) {
    value = value.copyWith(selection: _selectionToRaw(selection));
  }

  void clearBody() {
    setBodyValue(const TextEditingValue());
  }

  void setInstructions(
    Iterable<QuickInstructionInvocationSnapshot> instructions,
  ) {
    final body = bodyValue;
    _instructions = List<QuickInstructionInvocationSnapshot>.unmodifiable(
      instructions,
    );
    value = _rawValueFromBody(body);
  }

  void clampSelectionToBody() {
    final selection = value.selection;
    if (!selection.isValid ||
        (selection.baseOffset >= _prefixLength &&
            selection.extentOffset >= _prefixLength)) {
      return;
    }
    final extent = math.max(selection.extentOffset, _prefixLength);
    value = value.copyWith(
      selection: TextSelection.collapsed(offset: extent),
      composing: TextRange.empty,
    );
  }

  TextEditingValue normalizeEdit(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final expectedCount = _prefixLength;
    final markerCount = objectReplacementCharacter
        .allMatches(newValue.text)
        .length;
    final hasStablePrefix =
        newValue.text.startsWith(_prefix) && markerCount == expectedCount;
    if (hasStablePrefix) {
      return newValue.copyWith(
        selection: _clampRawSelection(newValue.selection),
        composing: _clampRawRange(newValue.composing),
      );
    }

    final removedMarkers = math.max(0, expectedCount - markerCount);
    final insertedIntoPrefix = newValue.text.length > oldValue.text.length;
    if (removedMarkers > 0 && !insertedIntoPrefix) {
      final keepCount = math.max(0, expectedCount - removedMarkers);
      _instructions = List<QuickInstructionInvocationSnapshot>.unmodifiable(
        _instructions.take(keepCount),
      );
      onInstructionsChangedByEditing?.call(instructions);
    }

    final body = newValue.text.replaceAll(objectReplacementCharacter, '');
    final bodySelection = TextSelection(
      baseOffset: _bodyOffsetBefore(
        newValue.text,
        newValue.selection.baseOffset,
      ),
      extentOffset: _bodyOffsetBefore(
        newValue.text,
        newValue.selection.extentOffset,
      ),
      affinity: newValue.selection.affinity,
      isDirectional: newValue.selection.isDirectional,
    );
    final bodyComposing = newValue.composing.isValid
        ? TextRange(
            start: _bodyOffsetBefore(newValue.text, newValue.composing.start),
            end: _bodyOffsetBefore(newValue.text, newValue.composing.end),
          )
        : TextRange.empty;
    return _rawValueFromBody(
      TextEditingValue(
        text: body,
        selection: bodySelection,
        composing: bodyComposing,
      ),
    );
  }

  int _bodyOffsetBefore(String raw, int rawOffset) {
    if (rawOffset < 0) return 0;
    final end = math.min(math.max(rawOffset, 0), raw.length);
    return raw
        .substring(0, end)
        .replaceAll(objectReplacementCharacter, '')
        .length;
  }

  TextEditingValue _rawValueFromBody(TextEditingValue body) {
    final text = '$_prefix${body.text}';
    return TextEditingValue(
      text: text,
      selection: _selectionToRaw(body.selection),
      composing: _rangeToRaw(body.composing),
    );
  }

  TextSelection _selectionToBody(TextSelection selection) {
    if (!selection.isValid) return const TextSelection.collapsed(offset: 0);
    return TextSelection(
      baseOffset: math.max(0, selection.baseOffset - _prefixLength),
      extentOffset: math.max(0, selection.extentOffset - _prefixLength),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  TextSelection _selectionToRaw(TextSelection selection) {
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: _prefixLength);
    }
    return TextSelection(
      baseOffset: _prefixLength + selection.baseOffset,
      extentOffset: _prefixLength + selection.extentOffset,
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  TextRange _rangeToBody(TextRange range) {
    if (!range.isValid) return TextRange.empty;
    return TextRange(
      start: math.max(0, range.start - _prefixLength),
      end: math.max(0, range.end - _prefixLength),
    );
  }

  TextRange _rangeToRaw(TextRange range) {
    if (!range.isValid || range.isCollapsed) return TextRange.empty;
    return TextRange(
      start: _prefixLength + range.start,
      end: _prefixLength + range.end,
    );
  }

  TextSelection _clampRawSelection(TextSelection selection) {
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: _prefixLength);
    }
    return TextSelection(
      baseOffset: math.max(_prefixLength, selection.baseOffset),
      extentOffset: math.max(_prefixLength, selection.extentOffset),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  TextRange _clampRawRange(TextRange range) {
    if (!range.isValid || range.isCollapsed) return TextRange.empty;
    return TextRange(
      start: math.max(_prefixLength, range.start),
      end: math.max(_prefixLength, range.end),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[
      for (final instruction in _instructions)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: Semantics(
              label: instruction.title,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.22),
                  ),
                ),
                child: Text(
                  instruction.title,
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontSize: 12,
                    fontWeight: AppFontWeights.medium,
                  ),
                ),
              ),
            ),
          ),
        ),
    ];

    final body = bodyText;
    final composing = _rangeToBody(value.composing);
    if (withComposing && composing.isValid && !composing.isCollapsed) {
      spans.addAll(<InlineSpan>[
        TextSpan(text: body.substring(0, composing.start), style: style),
        TextSpan(
          text: body.substring(composing.start, composing.end),
          style: style?.merge(
            const TextStyle(decoration: TextDecoration.underline),
          ),
        ),
        TextSpan(text: body.substring(composing.end), style: style),
      ]);
    } else {
      spans.add(TextSpan(text: body, style: style));
    }
    return TextSpan(style: style, children: spans);
  }
}

class QuickInstructionEditingFormatter extends TextInputFormatter {
  const QuickInstructionEditingFormatter(this.controller);

  final QuickInstructionEditingController controller;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return controller.normalizeEdit(oldValue, newValue);
  }
}

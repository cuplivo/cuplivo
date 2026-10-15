import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'markdown_line_lexer.dart';

/// A source block in an append-only streaming Markdown document.
final class MarkdownStreamBlock {
  const MarkdownStreamBlock({
    required this.start,
    required this.text,
    required this.stable,
    this.swallowsSeparator = false,
  });

  final int start;

  /// The block's source, without the blank run that separates it from the
  /// next block. The splitter skips that run on its own; the widget inserts
  /// one separator in its place, unless [swallowsSeparator] says the block's
  /// own last element already consumed the run.
  final String text;

  /// Whether the walk has committed this block. The unfinished tail is not
  /// stable, and neither is a committed block an indented line has reopened.
  /// Only the tail may receive streaming stabilization (tables, unfinished
  /// math).
  final bool stable;

  /// Whether a whole-document render folds the blank run after this block into
  /// the block's own last element, leaving no gap for a separator to
  /// reproduce.
  ///
  /// A rule (`---`) and a display formula close their pattern with `\s*$`, so
  /// the match runs past the newline that ends the block and `NewLines` never
  /// lays the run out. Every other block leaves the run behind, which is what
  /// the widget's separator stands in for.
  final bool swallowsSeparator;
}

/// One top-level element of the walked region, at the position the walk
/// reported rather than the range the node carries.
///
/// A node's own range may address the element's text instead of the document —
/// `DetailsHtmlMd` builds its range over the `<details>` source — while the
/// walk callback always reports where the element sits in the text it walked.
final class _MdElement {
  const _MdElement(this.start, this.end, this.kind);

  final int start;
  final int end;
  final MdNodeKind kind;
}

/// A run of two or more newlines: the separator between two candidate blocks.
final class _BlankRun {
  const _BlankRun(this.start, this.end);

  final int start;
  final int end;
}

/// Splits streaming Markdown into blocks whose boundaries the IR walk decides.
///
/// The grammar stays in the components. A fence, a table, a closed `<details>`
/// and a display formula each claim their whole element as one node, so the
/// blank runs inside them are not gaps and need no protection pass of their
/// own; every run the walk leaves bare is a candidate boundary, and three
/// questions decide what becomes of it:
///
///  * Is an unfinished construct holding it? A display formula or a `<details>`
///    without its closer is ordinary text to the walk, so the retained
///    [MarkdownDisplayMathScanner] and [MarkdownLineLexer] answer this one.
///  * Does the content after it continue the same block? An indented line
///    belongs to the block above it, and so does the next item of the same
///    list.
///  * Does an element reach past the run? Then the run is inside a claimed
///    block. Does the block's own last element reach *into* the run? Then the
///    whole-document render lays out no gap there, and the widget must not
///    insert a separator either — while the blocks still split, which is what
///    keeps a finished element's identity.
///
/// The region is walked only while it holds a run or opens on whitespace, so a
/// stream that is still growing one paragraph pays nothing for the splitter.
final class MarkdownStreamingSplit {
  MarkdownStreamingSplit({
    required List<MarkdownComponent> global,
    required List<MarkdownComponent> inline,
  }) : _config = GptMarkdownConfig(
         components: global,
         inlineComponents: inline,
         streaming: true,
       );

  final GptMarkdownConfig _config;

  /// The one line-level rule the walk cannot answer for.
  ///
  /// `UnOrderedList` and `OrderedList` claim `*`/`-` and `N.` only, so `+`,
  /// `1)` and a task checkbox stay prose; the renderer draws them as text
  /// either way, but a block that starts with one still has to stay with the
  /// line after it. This is the same expression the old scanner used, and it
  /// is a superset of what the list components claim.
  static final _listMarker = RegExp(
    r'^(?:[*+-](?:\s+\[[ xX]\])?|\d{1,9}[.)])(?:\s|$)',
  );

  String _rawSource = '';
  String _source = '';
  bool _rawEndsWithCR = false;
  List<MarkdownStreamBlock> _blocks = const [];
  final List<MarkdownStreamBlock> _stableBlocks = [];
  final MarkdownLineLexer _lexer = MarkdownLineLexer();
  final MarkdownDisplayMathScanner _mathScanner = MarkdownDisplayMathScanner();
  int _rescannedCodeUnits = 0;
  int _walkedRegions = 0;
  bool _lastUpdateAppended = true;

  /// The start of the line the lexer has consumed up to. The lexer is
  /// forward-only, so candidate runs are decided in the order their lines
  /// arrive.
  int _lineStart = 0;

  /// The first blank run not yet decided.
  int _runCursor = 0;

  /// The start of the unfrozen region: everything before it is either a
  /// committed block together with the run that closed it, or such a run.
  int _blockStart = 0;

  List<MarkdownStreamBlock> get blocks => _blocks;

  int get rescannedCodeUnits => _rescannedCodeUnits;

  /// Whether the region is walked for every append, whatever the appended
  /// suffix holds. The guard may only skip work, never a boundary, and a test
  /// that runs this splitter beside one without the guard is what keeps that
  /// claim honest: the two must agree on every source.
  bool debugAlwaysWalk = false;

  /// How many times the region has actually been walked. A decision the text
  /// answers on its own — a loose list waiting for its next item, a fence whose
  /// runs are all decided — must not raise it.
  int get debugWalkedRegions => _walkedRegions;

  /// The last source retained its previous prefix. Blocks at the same start
  /// offset therefore retain their prefix too.
  bool get lastUpdateAppended => _lastUpdateAppended;

  /// Whether [_source] is still the caller's raw string. False after a CR
  /// forced a normalized copy.
  bool get debugReusesCallerSource => identical(_source, _rawSource);

  /// [appendOnly] may be supplied when the owner already compared this exact
  /// source with the preceding update. Omit it for independently rewritten
  /// text.
  List<MarkdownStreamBlock> update(String source, {bool? appendOnly}) {
    if (source == _rawSource) {
      _lastUpdateAppended = true;
      return _blocks;
    }
    _lastUpdateAppended = appendOnly ?? source.startsWith(_rawSource);
    final String appended;
    if (!_lastUpdateAppended) {
      _stableBlocks.clear();
      _lineStart = 0;
      _runCursor = 0;
      _blockStart = 0;
      _lexer.reset();
      _mathScanner.reset();
      appended = source;
      final normalized = _normalizeNewlines(source);
      _rescannedCodeUnits += normalized.length;
      _source = normalized;
    } else {
      appended = source.substring(_rawSource.length);
      if (_canReuseCallerSource(appended)) {
        _rescannedCodeUnits += appended.length;
        _source = source;
      } else {
        final suffix = _normalizeAppendedSuffix(appended);
        _rescannedCodeUnits += suffix.length;
        _source += suffix;
      }
    }
    _rawSource = source;
    _rawEndsWithCR =
        source.isNotEmpty && source.codeUnitAt(source.length - 1) == 0x0D;
    if (!_lastUpdateAppended || debugAlwaysWalk || _regionHasCandidate()) {
      _decideBoundaries();
    }
    _blocks = List<MarkdownStreamBlock>.unmodifiable(_visibleBlocks());
    return _blocks;
  }

  /// Whether the region holds anything this update could decide.
  ///
  /// A boundary is only ever a blank run, and the walk exists to answer the
  /// questions a run raises, so a region without one has nothing to decide: an
  /// append can then only grow its last element, which the block text already
  /// covers. A region that opens on whitespace is the exception — the block
  /// before it may still swallow that line, and only the walk's first element
  /// can tell an indented continuation apart from an indented fence or
  /// `<details>`.
  ///
  /// The run is looked for from the region's start rather than the run cursor,
  /// because a run that was left in place — the next item of a list may still
  /// belong to the block — has to be re-read when the line after it changes.
  bool _regionHasCandidate() =>
      _source.indexOf('\n\n', _blockStart) >= 0 || _regionStartsIndented();

  /// The common path never contained a CR, so [source] is already the
  /// accumulated document. Reuse it instead of copying `_source + suffix`.
  bool _canReuseCallerSource(String rawSuffix) {
    return identical(_source, _rawSource) &&
        !_rawEndsWithCR &&
        !rawSuffix.contains('\r');
  }

  /// CRLF and bare CR become LF, the same way `GptMarkdown` rewrites them
  /// before it parses. U+2028 / U+2029 stay as content: `NewLines` only
  /// matches `\n\n+`, so they can never open a run.
  static String _normalizeNewlines(String source) {
    if (!source.contains('\r')) return source;
    return source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  /// Only the newly appended raw suffix is rewritten. A CR that closed the
  /// previous chunk plus an LF that opens this one is one newline, not two.
  String _normalizeAppendedSuffix(String suffix) {
    if (suffix.isEmpty) return '';
    var rest = suffix;
    if (_rawEndsWithCR && rest.codeUnitAt(0) == 0x0A) {
      rest = rest.substring(1);
    }
    return _normalizeNewlines(rest);
  }

  /// Answers the boundary questions for every run the region has not decided
  /// yet, in order.
  ///
  /// Only two of those questions need the walk — whether the run is inside a
  /// claimed element, and whether that claim matched into it, which only an
  /// element's own match can say. The rest are answered from the text, and they
  /// are asked first, so a region whose runs stay undecided — a loose list,
  /// whose next item may still belong to it — never pays for a walk. The walk
  /// happens the first time an answer actually needs it.
  void _decideBoundaries() {
    final mathScan = _mathScanner.synchronize(_source, appendOnly: true);
    List<_MdElement>? walked;
    List<_MdElement> elements() => walked ??= _walkRegion();
    // A block that ended before an indented line is the same block: a
    // block-by-block render trims the leading whitespace off every fragment,
    // and the indentation is part of the syntax the renderer matches, so the
    // line has to reach the renderer inside the block above it.
    if (_regionStartsIndented() && _reopenIndentedTail(elements())) {
      walked = _walkRegion();
    }
    var elementIndex = 0;
    while (true) {
      final run = _nextRun(_runCursor);
      if (run == null) break;
      _runCursor = run.end;
      if (run.start < _blockStart) continue;
      _feedLexerTo(run.start);
      if (run.start == _blockStart) {
        // The run follows an earlier one with nothing between them, so it is
        // part of the gap the block before already skipped.
        _blockStart = run.end;
        continue;
      }
      // An unfinished display formula or `<details>` is prose to the walk, and
      // the blank lines inside it belong to the construct the closer will
      // complete.
      if (_lexer.detailsDepth > 0 || mathScan.covers(run.start + 1)) continue;
      final contentAfter = _hasContentAfter(run.end);
      if (!contentAfter) {
        // Nothing but whitespace follows the run yet. A list waits for the line
        // after it — the next item may still belong to it — while every other
        // block commits here, which is what lets a finished paragraph survive
        // the blank lines the stream appends behind it.
        if (_blockIsList()) continue;
      } else if (_blockIsList() && _listContinues(run)) {
        continue;
      }
      final list = elements();
      while (elementIndex < list.length &&
          list[elementIndex].end <= run.start) {
        elementIndex++;
      }
      var covering =
          elementIndex < list.length && list[elementIndex].start <= run.start
          ? list[elementIndex]
          : null;
      // The gap itself is an element too (`NewLines` claims the run). It marks
      // the boundary rather than absorbing it, so it never suppresses the
      // separator the boundary needs.
      if (covering != null &&
          covering.start == run.start &&
          covering.end == run.end) {
        covering = null;
      }
      final after = _firstElementFrom(list, elementIndex, run.end);
      // A run a claimed element reaches past is inside that element: it is one
      // block, and the renderer lays its own text out across the run.
      if (covering != null && covering.end > run.end) continue;
      // A claim that reaches the end of the source exactly as the run does is
      // an element still growing around the run — an unclosed fence body is
      // every line that has arrived, trailing blank lines included. Only
      // content after the run can turn the claim's end into a boundary the
      // renderer would lay a gap out for.
      if (covering != null && covering.end == run.end && after == null) {
        continue;
      }
      if (contentAfter &&
          run.end < _source.length &&
          _isWhitespace(_source.codeUnitAt(run.end)) &&
          !_indentExempt(after)) {
        continue;
      }
      _commit(run, absorbed: covering != null);
    }
  }

  /// The region's top-level elements, in document order.
  List<_MdElement> _walkRegion() {
    _walkedRegions++;
    final reported = <MdNode, (int, int)>{};
    final nodes = MarkdownComponent.walkNodes(
      _source.substring(_blockStart),
      config: _config,
      source: _source,
      offset: _blockStart,
      onNode: (node, start, end, component, block) =>
          reported[node] = (start, end),
    );
    final elements = <_MdElement>[];
    for (final node in nodes) {
      final span = reported[node];
      final start = span?.$1 ?? node.range?.start;
      final end = span?.$2 ?? node.range?.end;
      if (start == null || end == null) continue;
      elements.add(_MdElement(start, end, node.kind));
    }
    return elements;
  }

  /// Reopens the last committed block when an indented line has joined it.
  ///
  /// Returns whether the region has to be walked again from the reopened
  /// block's start.
  bool _reopenIndentedTail(List<_MdElement> elements) {
    if (_stableBlocks.isEmpty || _blockStart >= _source.length) return false;
    final unit = _source.codeUnitAt(_blockStart);
    if (unit == 0x0A || unit == 0x0D || !_isWhitespace(unit)) return false;
    if (elements.isEmpty || _indentExempt(elements.first)) return false;
    // A tail of whitespace alone lays out nothing: it stays outside the block,
    // which is what keeps a completed block identical while the indentation of
    // the next line is still arriving.
    if (_source.substring(_blockStart).trim().isEmpty) return false;
    _blockStart = _stableBlocks.removeLast().start;
    return true;
  }

  /// The first blank run at or after [from], or null when the region has none
  /// left.
  ///
  /// The run's start is walked back to the first of its newlines. A run the
  /// walk left in place — a list waiting for the line after it — can gain
  /// newlines from a later append, and the search then finds it part-way in;
  /// committing from there would end the block with the newlines it is
  /// supposed to skip.
  _BlankRun? _nextRun(int from) {
    final found = _source.indexOf('\n\n', from);
    if (found < 0) return null;
    var start = found;
    while (start > _blockStart && _source.codeUnitAt(start - 1) == 0x0A) {
      start--;
    }
    var end = found + 2;
    while (end < _source.length && _source.codeUnitAt(end) == 0x0A) {
      end++;
    }
    return _BlankRun(start, end);
  }

  /// The first element that begins at or after [position].
  static _MdElement? _firstElementFrom(
    List<_MdElement> elements,
    int from,
    int position,
  ) {
    for (var i = from; i < elements.length; i++) {
      if (elements[i].start >= position) return elements[i];
    }
    return null;
  }

  /// Whether anything but whitespace follows [position].
  ///
  /// This is the text-level form of "is there an element after the run": the
  /// walk reports no element for whitespace alone, and an element that holds
  /// content is exactly a non-whitespace code unit.
  bool _hasContentAfter(int position) {
    for (var i = position; i < _source.length; i++) {
      if (!_isWhitespace(_source.codeUnitAt(i))) return true;
    }
    return false;
  }

  /// Whether the region opens on whitespace, which is the one case the text
  /// cannot decide: the block before it may swallow that line, and telling an
  /// indented continuation apart from an indented fence or `<details>` needs
  /// the walk's first element.
  bool _regionStartsIndented() {
    if (_blockStart >= _source.length) return false;
    final unit = _source.codeUnitAt(_blockStart);
    return unit != 0x0A && unit != 0x0D && _isWhitespace(unit);
  }

  /// Whether the block the run would close is a list. Such a block commits
  /// only once a line that cannot continue it arrives.
  bool _blockIsList() {
    final lineEnd = _source.indexOf('\n', _blockStart);
    final line = _source
        .substring(_blockStart, lineEnd < 0 ? _source.length : lineEnd)
        .trimLeft();
    return _listMarker.hasMatch(line);
  }

  /// Whether the line after the run continues the list the block belongs to:
  /// an indented line belongs to the item above it, and a list marker opens
  /// the next item.
  bool _listContinues(_BlankRun run) {
    if (run.end >= _source.length) return false;
    if (_isWhitespace(_source.codeUnitAt(run.end))) return true;
    final lineEnd = _source.indexOf('\n', run.end);
    final end = lineEnd < 0 ? _source.length : lineEnd;
    return _listMarker.hasMatch(_source.substring(run.end, end));
  }

  /// A fenced code block and a `<details>` are claimed together with their
  /// indentation and keep it — the old scanner counted the line that opened
  /// them as protected, so they never merged into the block above. Every other
  /// indented line does merge.
  static bool _indentExempt(_MdElement? after) =>
      after != null &&
      (after.kind == MdNodeKind.codeBlock || after.kind == MdNodeKind.details);

  /// Consumes every complete line that ends at or before [limit], so the
  /// lexer's details depth is the one the line before the run would have set.
  void _feedLexerTo(int limit) {
    while (true) {
      final newline = _source.indexOf('\n', _lineStart);
      if (newline < 0 || newline > limit) return;
      _lexer.consumePhysicalLine(_source.substring(_lineStart, newline));
      _lineStart = newline + 1;
    }
  }

  /// Commits the block the run closes and skips the run.
  ///
  /// [absorbed] records that the block's own last element matched into the run
  /// — a rule or a display formula closing with `\s*$` consumed the newline
  /// that ends the block — so a whole-document render lays out no gap there and
  /// the widget inserts no separator.
  void _commit(_BlankRun run, {required bool absorbed}) {
    _stableBlocks.add(
      MarkdownStreamBlock(
        start: _blockStart,
        text: _source.substring(_blockStart, run.start),
        stable: true,
        swallowsSeparator: absorbed,
      ),
    );
    _blockStart = run.end;
  }

  /// Committed blocks plus the unfinished tail. A tail of only whitespace is
  /// dropped: `GptMarkdown` trims it, so keeping it would only rebuild a block
  /// that lays out the same.
  List<MarkdownStreamBlock> _visibleBlocks() {
    final tailText = _source.substring(_blockStart);
    if (tailText.trim().isEmpty) return List.of(_stableBlocks);
    return [
      ..._stableBlocks,
      MarkdownStreamBlock(start: _blockStart, text: tailText, stable: false),
    ];
  }

  /// Whitespace as `\s` in a Dart pattern reads it, so an indent is judged the
  /// way the patterns that would consume it are.
  static bool _isWhitespace(int unit) =>
      unit == 0x20 ||
      (unit >= 0x09 && unit <= 0x0D) ||
      (unit >= 0x80 && _isWideWhitespace(unit));

  static bool _isWideWhitespace(int unit) =>
      unit == 0x85 ||
      unit == 0xA0 ||
      unit == 0x1680 ||
      (unit >= 0x2000 && unit <= 0x200A) ||
      unit == 0x2028 ||
      unit == 0x2029 ||
      unit == 0x202F ||
      unit == 0x205F ||
      unit == 0x3000 ||
      unit == 0xFEFF;
}

import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'markdown_line_lexer.dart';

/// A source block in an append-only streaming Markdown document.
final class MarkdownStreamBlock {
  const MarkdownStreamBlock({
    required this.start,
    required this.text,
    required this.stable,
    this.swallowedBy,
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

  /// The kind of element that matched into the blank run after this block, or
  /// null when the run is a gap the renderer lays out.
  ///
  /// A rule (`---`) and a display formula close their pattern with `\s*$`, so
  /// the match runs past the newline that ends the block and `NewLines` never
  /// lays the run out — the boundary is still real, but the widget must not
  /// stand a separator in for it.
  ///
  /// The kind rather than a flag, because whether the element is there at all
  /// can depend on a setting: with math rendering off a display formula's
  /// dollars are prose, the gap is laid out, and the separator is right.
  final MdNodeKind? swallowedBy;
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

/// A refused blank run whose proviso is text that has not arrived yet.
///
/// The line-level state is carried along because the lexer only moves forward:
/// deciding a run again is legitimate, but reading a later line's fence or
/// details depth for it is not, so the state as of the run has to travel with
/// the run.
final class _DeferredRun {
  const _DeferredRun(
    this.start, {
    required this.detailsDepth,
    required this.fenced,
  });

  final int start;
  final int detailsDepth;
  final bool fenced;
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

  /// The first blank run whose decision is settled. A run refused because the
  /// text that decides it has not arrived yet is behind this cursor on purpose
  /// and re-decided from [_deferredRun] instead.
  int _runCursor = 0;

  /// A run whose refusal is provisional: the text that decides it has not
  /// arrived yet, so the next update has to decide it again.
  _DeferredRun? _deferredRun;

  /// Whether an indented tail the walk cannot classify yet is folded into the
  /// block above it for the returned list only.
  bool _tailFold = false;

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
      _deferredRun = null;
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
    _tailFold = false;
    if (!_lastUpdateAppended ||
        debugAlwaysWalk ||
        _deferredRun != null ||
        _regionHasCandidate()) {
      _decideBoundaries();
    }
    _skipGrownRun();
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
    if (_regionStartsIndented()) {
      if (_reopenIndentedTail(elements())) {
        walked = _walkRegion();
      } else {
        // The line is still arriving, or it opens a construct of its own. The
        // fold is for the returned list only: the committed blocks stay as they
        // are, so the tail can still turn out to be a fence or a `<details>`
        // and keep a block of its own.
        _tailFold =
            _source.substring(_blockStart).trim().isNotEmpty &&
            !_indentedTailIsOwnBlock(elements());
      }
    }
    // A gap the committed block behind it skipped can gain a whitespace-bearing
    // blank line from a later append. Such a line is content to the renderers
    // around it, so the boundary the block was committed on has to be taken
    // again with the whole gap in view.
    if (_reopenWhitespaceGap()) {
      walked = _walkRegion();
    }
    var elementIndex = 0;
    final deferred = _deferredRun;
    _deferredRun = null;
    var cursor = deferred?.start ?? _runCursor;
    _DeferredRun? pending;
    while (true) {
      final run = _nextRun(cursor);
      if (run == null) {
        break;
      }
      cursor = run.end;
      if (run.start < _blockStart) {
        continue;
      }
      _feedLexerTo(run.start);
      if (run.start == _blockStart) {
        // The run follows an earlier one with nothing between them, so it is
        // part of the gap the block before already skipped.
        _blockStart = run.end;
        continue;
      }
      final state = deferred != null && deferred.start == run.start
          ? deferred
          : _DeferredRun(
              run.start,
              detailsDepth: _lexer.detailsDepth,
              fenced: _lexer.fenced,
            );
      // An unfinished display formula or `<details>` is prose to the walk, and
      // the blank lines inside it belong to the construct the closer will
      // complete. Closing it keeps the run interior, so this refusal is final.
      if (state.detailsDepth > 0 || mathScan.covers(run.start + 1)) {
        continue;
      }
      // A blank line that carries whitespace is content to the renderers around
      // it: a rule, a heading and a display-math block each swallow it into
      // their own match, and plain text lays it out as a line of its own. Rather
      // than model all of that, the whole gap stays inside one block, which
      // renders the way the document reads.
      if (_gapCarriesWhitespace(run)) {
        // The whitespace-bearing line the refusal rests on may still grow
        // content (`  ` becomes `  ``` `), which takes the whitespace out of
        // the gap again. Only the source's unfinished last line can change that
        // way, so the refusal waits while it is the one being read.
        if (_gapRefusalIsProvisional()) {
          pending = state;
          break;
        }
        continue;
      }
      final contentAfter = _hasContentAfter(run.end);
      if (!contentAfter && _blockIsList()) {
        // Nothing but whitespace follows the run yet, and the next item of a
        // list may still belong to this block. The line that decides it has not
        // arrived, so the run stays undecided rather than refused.
        pending = state;
        break;
      }
      if (contentAfter) {
        // The line after the run is what decides a list continuation and an
        // indentation, and it can still grow into a list marker (`2` becomes
        // `2)`) or into a fence or `<details>` opener. A decision waits for its
        // newline; only a complete line can be classified.
        final lineEnd = _source.indexOf('\n', run.end);
        final lineIncomplete = lineEnd < 0;
        if (_blockIsList() && lineIncomplete) {
          // The line can still turn into a marker (`2` becomes `2)`), so the
          // run stays undecided until it is complete.
          pending = state;
          break;
        }
        if (_blockIsList() && _listContinues(run)) {
          // A complete line that continues the list: the run is no boundary,
          // and the block ends at whatever run arrives after the item.
          continue;
        }
        if (lineIncomplete && _isWhitespace(_source.codeUnitAt(run.end))) {
          pending = state;
          break;
        }
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
      if (covering != null && covering.end > run.end) {
        continue;
      }
      // A claim that reaches the end of the source exactly as the run does is
      // an element still growing around the run — an unclosed fence body is
      // every line that has arrived, trailing blank lines included. Only a
      // fence that is still open can grow that way: a rule and a display
      // formula close their pattern with `\s*$` and are finished, so the run
      // after them is a boundary whose separator the widget suppresses.
      if (covering != null &&
          covering.end == run.end &&
          after == null &&
          state.fenced) {
        continue;
      }
      if (contentAfter &&
          run.end < _source.length &&
          _isWhitespace(_source.codeUnitAt(run.end)) &&
          !_indentExempt(after)) {
        // An indented line belongs to the block above it unless it opens a
        // construct of its own. The walk still reports an unclosed `<details>`
        // as prose, so the line-level rule decides that case here — otherwise
        // the boundary would be refused for a construct that turns out to claim
        // its own block once its closer arrives.
        final lineEnd = _source.indexOf('\n', run.end);
        if (!(lineEnd >= 0 && _lineOpensFenceOrDetails(run.end, lineEnd))) {
          continue;
        }
      }
      _commit(run, absorbed: covering?.kind);
    }
    if (pending != null) {
      _deferredRun = pending;
      _runCursor = pending.start;
    } else {
      _runCursor = cursor;
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
    // Only a complete line can be classified. While the indentation's line is
    // still arriving it may yet open a fence or a `<details>`, and reopening
    // the block above is permanent, so the decision waits for the newline and
    // the tail is folded for the view in the meantime.
    final lineEnd = _source.indexOf('\n', _blockStart);
    if (lineEnd < 0) return false;
    if (elements.isEmpty || _indentedTailIsOwnBlock(elements)) {
      return false;
    }
    // A tail of whitespace alone lays out nothing: it stays outside the block,
    // which is what keeps a completed block identical while the indentation of
    // the next line is still arriving.
    if (_source.substring(_blockStart).trim().isEmpty) return false;
    _blockStart = _stableBlocks.removeLast().start;
    return true;
  }

  /// Whether the line from [lineStart] to [lineEnd] opens a construct that
  /// claims its own indentation instead of joining the block above it.
  ///
  /// The walk answers this for a fence and for a closed `<details>`; an
  /// unclosed `<details>` is still prose to it, so the line-level lexer — the
  /// rule the renderer shares — answers here.
  bool _lineOpensFenceOrDetails(int lineStart, int lineEnd) {
    if (lineEnd <= lineStart) return false;
    final lexer = MarkdownLineLexer()
      ..consumePhysicalLine(_source.substring(lineStart, lineEnd));
    return lexer.fenced || lexer.detailsDepth > 0;
  }

  /// Whether an indented tail keeps a block of its own instead of joining the
  /// block above it.
  bool _indentedTailIsOwnBlock(List<_MdElement> elements) {
    if (_indentExempt(elements.isEmpty ? null : elements.first)) return true;
    final lineEnd = _source.indexOf('\n', _blockStart);
    return lineEnd >= 0 && _lineOpensFenceOrDetails(_blockStart, lineEnd);
  }

  /// Reopens the last committed block when the gap behind it gained a
  /// whitespace-bearing blank line.
  ///
  /// Such a line is content to the renderers around it, so the whole gap has to
  /// stay inside one block: the boundary the block was committed on was taken
  /// before that line existed, and leaving it would make the block list depend
  /// on how the reply was chunked.
  bool _reopenWhitespaceGap() {
    if (_stableBlocks.isEmpty || _blockStart >= _source.length) return false;
    final last = _stableBlocks.last;
    final runStart = last.start + last.text.length;
    if (runStart >= _source.length || _source.codeUnitAt(runStart) != 0x0A) {
      return false;
    }
    if (!_gapCarriesWhitespace(_BlankRun(runStart, runStart))) return false;
    _stableBlocks.removeLast();
    _blockStart = last.start;
    _runCursor = runStart;
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

  /// Whether a line in the gap this run opens is blank but not empty — the
  /// rule the old scanner kept with its `_blankRunCarriesWhitespace` flag.
  ///
  /// Such a line is content to the renderers around it: a rule, a heading and a
  /// display-math block each swallow it into their own match, and plain text
  /// lays it out as a line of its own. Rather than model all of that, the whole
  /// gap between two content lines stays inside one block, which renders the
  /// way the document reads.
  ///
  /// The walk starts on the line the run closes, so a whitespace-bearing blank
  /// line before the run counts too, and ends at the next line with content.
  /// Whitespace *on* a line with content — trailing spaces, indentation — is
  /// not blank-line whitespace and does not refuse the boundary: an indented
  /// continuation has to reach the next test as its own block.
  bool _gapCarriesWhitespace(_BlankRun run) {
    var i = run.start;
    while (i > _blockStart && _source.codeUnitAt(i - 1) != 0x0A) {
      i--;
    }
    var passedContent = false;
    while (i < _source.length) {
      var end = _source.indexOf('\n', i);
      if (end < 0) end = _source.length;
      final line = _source.substring(i, end);
      if (line.trim().isNotEmpty) {
        if (passedContent) return false;
        passedContent = true;
      } else if (line.isNotEmpty) {
        return true;
      }
      i = end + 1;
    }
    return false;
  }

  /// Whether the whitespace-bearing blank line a gap refusal rests on is still
  /// arriving.
  ///
  /// Only the source's unfinished last line can grow content and take the
  /// whitespace out of the gap again; every earlier line is complete, so a
  /// refusal that rests on one of those is final.
  bool _gapRefusalIsProvisional() {
    if (_source.isEmpty || _source.codeUnitAt(_source.length - 1) == 0x0A) {
      return false;
    }
    final line = _source.substring(_source.lastIndexOf('\n') + 1);
    return line.isNotEmpty && line.trim().isEmpty;
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
  /// [absorbed] is the kind of element that matched into the run — a rule or a
  /// display formula closing with `\s*$` consumed the newline that ends the
  /// block — or null when the run stays a gap.
  void _commit(_BlankRun run, {required MdNodeKind? absorbed}) {
    _stableBlocks.add(
      MarkdownStreamBlock(
        start: _blockStart,
        text: _source.substring(_blockStart, run.start),
        stable: true,
        swallowedBy: absorbed,
      ),
    );
    _blockStart = run.end;
  }

  /// Committed blocks plus the unfinished tail. A tail of only whitespace is
  /// dropped: `GptMarkdown` trims it, so keeping it would only rebuild a block
  /// that lays out the same.
  ///
  /// An indented tail the walk cannot classify yet is folded into the last
  /// committed block for this list only — the scanner itself is left alone, so
  /// the tail can still turn out to be an indented fence or `<details>` and keep
  /// a block of its own.
  List<MarkdownStreamBlock> _visibleBlocks() {
    final tailText = _source.substring(_blockStart);
    if (tailText.trim().isEmpty) return List.of(_stableBlocks);
    if (_tailFold && _stableBlocks.isNotEmpty) {
      final last = _stableBlocks.last;
      return [
        ..._stableBlocks.sublist(0, _stableBlocks.length - 1),
        MarkdownStreamBlock(
          start: last.start,
          text: _source.substring(last.start),
          stable: false,
        ),
      ];
    }
    return [
      ..._stableBlocks,
      MarkdownStreamBlock(start: _blockStart, text: tailText, stable: false),
    ];
  }

  /// A run the splitter already skipped can gain newlines from a later append.
  ///
  /// They belong to the gap the block before already skipped, so the tail must
  /// not start with them: the same text has to produce the same tail whether
  /// the newlines arrived with the run or after it.
  void _skipGrownRun() {
    while (_blockStart < _source.length &&
        _source.codeUnitAt(_blockStart) == 0x0A) {
      _blockStart++;
    }
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

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../../../utils/kelivo_file_uri.dart';
import '../../../utils/sandbox_path_resolver.dart';
import 'sync_models.dart';

/// Blob plane for LAN sync (ADR-0003 slice 3): the "blobs follow URIs" rule.
///
/// A blob is a content-addressed transfer unit. The sender scans the rows it
/// is *actually sending* (message parts, entity payloads, preference values)
/// for `kelivo-file` URIs and publishes one entry per referenced file —
/// canonical URI, sha256, byte size. The receiver keeps what it already has
/// (hash match), fetches the rest by hash, and lands each blob at the path
/// its URI names. URIs inside rows are never rewritten: a rewritten URI would
/// diverge the conversation digests and re-send forever.
///
/// Skill bodies are the second blob kind (`skill-dir`): the entry key is the
/// skill id and the bytes are a zip of the directory; see
/// `SkillDirectorySync`.
const String kKelivoFileScheme = 'kelivo-file://';

/// One character a canonical URI's path may contain: RFC 3986 `pchar` plus the
/// separators a path is built from. Parentheses are in it on purpose — they are
/// legal sub-delims, which is exactly why a Markdown link around a URI is
/// ambiguous. `'` is out: the writer escapes a real one as `%27`, so a raw `'`
/// after a reference is prose (`kelivo-file:///upload/a.png's`), not a name.
final RegExp _uriChar = RegExp(r"[A-Za-z0-9\-._~%!$&()*+,;=:@/]");

/// Characters that end a sentence far more often than they end a filename.
///
/// `)` is not among them: a bracket is decided by counting, not by class — a
/// reference wrapped in a Markdown link ends with one, and so does a name like
/// `notes(1)`. An opening `(` is here, because one that ends a run closes
/// nothing (`…/a.png( see`). `?`, `"` and `'` cannot be here: none of the three
/// is in [_uriChar], so a run never ends with one.
final RegExp _trailingProse = RegExp(r'''[.,;:!(]''');

/// Roots a received file blob may land in — the managed roots the sandbox
/// resolver knows, minus `skills` (directory blobs own that root) and
/// workspace/session roots (device-local by decision).
const Set<String> kSyncBlobAllowedRoots = {
  'upload',
  'images',
  'avatars',
  'fonts',
};

/// Maps a canonical URI to the file it names on *this* device. Production uses
/// the sandbox resolver; the seam exists because one test process hosts both
/// peers, each with its own managed root.
typedef BlobPathResolver = String? Function(String uri);

String? defaultBlobPathResolver(String uri) =>
    SandboxPathResolver.resolveForIo(uri);

/// Every canonical `kelivo-file` URI referenced by these rows. Payload columns
/// are JSON strings, so one lexical pass per value covers parts, entity payloads
/// and preference values alike.
///
/// The URI is **parsed out of the text**, not pattern-matched. A character class
/// is what made an inline image unreachable: `)` is a legal path character, so
/// `![…](kelivo-file:///a.png)` matched the closing bracket too, the strict
/// parser then rejected the whole candidate, and the file was silently never
/// advertised. Here the run is maximal and its tail is trimmed by the framing it
/// sits in — see [kelivoFileUriAt] — and what is left is shortened until the
/// strict parser accepts it.
///
/// [columns] is the family's declared blob columns ([SyncFamily.blobColumns]) —
/// which columns may reference a file is a property of the family, not a guess
/// per call site. Null scans every value, for a caller holding rows whose family
/// it cannot name.
Set<String> kelivoFileUrisInRows(
  Iterable<Map<String, dynamic>> rows, {
  List<String>? columns,
}) {
  final uris = <String>{};
  for (final row in rows) {
    final values = columns == null
        ? row.values
        : [for (final column in columns) row[column]];
    for (final value in values) {
      if (value is! String) continue;
      var from = value.indexOf(kKelivoFileScheme);
      while (from >= 0) {
        final uri = kelivoFileUriAt(value, from);
        if (uri == null) {
          from = value.indexOf(
            kKelivoFileScheme,
            from + kKelivoFileScheme.length,
          );
          continue;
        }
        uris.add(uri);
        from = value.indexOf(kKelivoFileScheme, from + uri.length);
      }
    }
  }
  return uris;
}

/// The longest canonical URI that starts at [start] and parses, or null when
/// nothing there is one.
///
/// A canonical path may contain every character a path is built from,
/// parentheses included, and the app's writer leaves them raw — so the scan is a
/// *maximal run* rather than a bracket-aware walk: it stops at the first
/// character no path can contain, or where the next `kelivo-file://` starts (a
/// second reference is not part of this one). Prose is then trimmed off its tail
/// by the rules in [_trimProseTail], and what is left is shortened until
/// [KelivoFileUri.decodeToSegments] accepts it.
///
/// Four shapes, and no guessing which `)` is which:
///
///     ![shot](kelivo-file:///upload/a.png)      → …/upload/a.png
///     ![shot](kelivo-file:///upload/a)b.png)    → …/upload/a)b.png
///     {"u":"kelivo-file:///upload/notes(1)"}    → …/upload/notes(1)
///     {"u":"kelivo-file:///upload/report,"}     → …/upload/report,
///
/// The first two are prose: a trailing `)` there is the link's bracket, and the
/// second keeps its own `)` only because the bracket that ends the run is the one
/// after it. The last two are whole JSON values, where the `"` says the run is
/// the value — so the tail is the name, and a balanced bracket pair survives.
///
/// The one shape this reads together is a reference glued to another
/// parenthetical with no separator (`…/a.png)(more`) — the app's writer puts a
/// space there, and the alternative, stopping at the first `)`, is what made a
/// file whose name carries one unreachable.
String? kelivoFileUriAt(String text, int start) {
  if (!text.startsWith(kKelivoFileScheme, start)) return null;
  final floor = start + kKelivoFileScheme.length;
  final limit = start + _kMaxUriLength;
  var end = floor;
  while (end < text.length && end < limit) {
    if (!_uriChar.hasMatch(text[end])) break;
    if (end > floor && text.startsWith(kKelivoFileScheme, end)) break;
    end++;
  }
  // A run that reached the cap is longer than any real reference. Refuse it
  // rather than return the truncated prefix — that prefix can parse, and a URI
  // that parses is treated as a file to advertise.
  if (end >= limit) return null;
  // A path may legally contain `.` or `,`, so "it parses" alone would keep the
  // full stop of a sentence — but a run that ends where a JSON string ends is
  // the whole value, and there the punctuation is the name. Reading a real
  // sentence that way costs one `missing` line; reading a real name the other
  // way costs the file.
  final endsValue = end < text.length && text[end] == '"';
  var stop = _trimTail(text, floor, end, wholeValue: endsValue);
  for (; stop > floor; stop--) {
    final candidate = text.substring(start, stop);
    if (KelivoFileUri.decodeToSegments(candidate) != null) return candidate;
  }
  return null;
}

/// Where a run of [text] from [floor] to [end] ends once prose is trimmed off.
///
/// In prose a trailing `)` is the bracket that closes the Markdown link around
/// the reference, so it goes with everything in [_trailingProse] — `…/a.png)`,
/// `…/a(b.png)` and `…/a.png, and` all lose their tail.
///
/// A run that ends where a JSON string ends ([wholeValue]) is the whole value, so
/// there the punctuation is the name and only an *excess* bracket is trimmed: a
/// balanced pair belongs to the name (`notes(1)`), while `notes(1))` keeps the
/// pair and loses the link's bracket. Counting is what makes those two separable
/// at all; a name that both ends in `)` and carries an unmatched `(` is the one
/// shape the count reads as prose.
int _trimTail(String text, int floor, int end, {required bool wholeValue}) {
  if (!wholeValue) {
    while (end > floor) {
      final last = text[end - 1];
      if (last != ')' && !_trailingProse.hasMatch(last)) break;
      end--;
    }
    return end;
  }
  var opens = 0;
  var closes = 0;
  for (var i = floor; i < end; i++) {
    if (text[i] == '(') opens++;
    if (text[i] == ')') closes++;
  }
  while (end > floor && text[end - 1] == ')' && closes > opens) {
    end--;
    closes--;
  }
  return end;
}

/// The longest reference [kelivoFileUriAt] will accept. Real references are a
/// few hundred bytes; the cap is what keeps a pathological run — the scheme
/// followed by a pasted base64 blob — from making the shortening loop quadratic
/// in the input rather than in the cap.
const int _kMaxUriLength = 1024;

/// Whether a file blob for [uri] may be written here (root allowlist).
bool isAllowedFileBlobUri(String uri) {
  final segments = KelivoFileUri.decodeToSegments(uri);
  if (segments == null || segments.isEmpty) return false;
  return kSyncBlobAllowedRoots.contains(segments.first);
}

/// sha256 of file contents, memoised by (path, length, mtime) so repeated
/// manifest builds do not re-read unchanged files. Missing files hash to
/// null — the sender skips them (reported), the receiver needs them.
class BlobFileHasher {
  final Map<String, ({int length, int mtimeMs, String hash})> _memo = {};

  Future<String?> hashOf(File file) async {
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final memo = _memo[file.path];
    if (memo != null &&
        memo.length == stat.size &&
        memo.mtimeMs == stat.modified.millisecondsSinceEpoch) {
      return memo.hash;
    }
    final stream = file.openRead();
    final builder = await crypto.sha256.bind(stream).first;
    final hash = builder.toString();
    _memo[file.path] = (
      length: stat.size,
      mtimeMs: stat.modified.millisecondsSinceEpoch,
      hash: hash,
    );
    return hash;
  }
}

/// What a sender can and cannot serve: one entry per referenced URI it has, and
/// the URIs it does not.
///
/// [missing] is a report, not a filter: a referenced file this device cannot
/// serve is the exact shape of "the reference arrived, the bytes did not", and
/// skipping it without saying so is how an inline image becomes invisible to
/// everyone including the sender. It holds every unservable reason in one
/// bucket — a root the blob plane may not write, a URI the sandbox cannot
/// resolve, a file that is not there — because the sender's next move is the
/// same in all three: nothing.
typedef BlobManifestBuild = ({
  List<SyncBlobEntry> entries,
  List<String> missing,
});

/// The sender side of the manifest: one entry per referenced URI this device
/// can actually serve (the file exists and the target root is allowed).
Future<BlobManifestBuild> buildFileBlobEntries(
  Set<String> uris,
  BlobFileHasher hasher, {
  BlobPathResolver resolve = defaultBlobPathResolver,
}) async {
  final entries = <SyncBlobEntry>[];
  final missing = <String>[];
  for (final uri in uris) {
    if (!isAllowedFileBlobUri(uri)) {
      missing.add(uri);
      continue;
    }
    final resolved = resolve(uri);
    if (resolved == null) {
      missing.add(uri);
      continue;
    }
    final file = File(resolved);
    final hash = await hasher.hashOf(file);
    if (hash == null) {
      missing.add(uri);
      continue;
    }
    entries.add(
      SyncBlobEntry(
        kind: SyncBlobEntry.kindFile,
        key: uri,
        contentHash: hash,
        byteSize: await file.length(),
      ),
    );
  }
  return (entries: entries, missing: missing);
}

/// The receiver side: which entries must be fetched. A file that exists with
/// a different hash also needs the fetch (the travelling rows are
/// authoritative for that path; the replacement is reported, not silent).
Future<List<SyncBlobEntry>> neededFileBlobEntries(
  List<SyncBlobEntry> entries,
  BlobFileHasher hasher, {
  BlobPathResolver resolve = defaultBlobPathResolver,
}) async {
  final needed = <SyncBlobEntry>[];
  for (final entry in entries) {
    if (!isAllowedFileBlobUri(entry.key)) continue;
    final resolved = resolve(entry.key);
    if (resolved == null) continue;
    final hash = await hasher.hashOf(File(resolved));
    if (hash == null || hash != entry.contentHash) needed.add(entry);
  }
  return needed;
}

/// Lands a fetched file blob at the path its URI names. [downloaded] carries
/// the verified bytes (the client hashes while streaming); placement is a
/// directory-create + atomic rename, overwriting any different content that
/// sat at the path. Returns the byte size landed, or null when the URI is not
/// a legal target.
Future<int?> placeFileBlob(
  SyncBlobEntry entry,
  File downloaded, {
  BlobPathResolver resolve = defaultBlobPathResolver,
}) async {
  if (entry.kind != SyncBlobEntry.kindFile) return null;
  if (!isAllowedFileBlobUri(entry.key)) return null;
  final resolved = resolve(entry.key);
  if (resolved == null) return null;
  final dest = File(resolved);
  await dest.parent.create(recursive: true);
  if (await dest.exists()) {
    await dest.delete();
  }
  final landed = await downloaded.rename(resolved);
  return await landed.length();
}

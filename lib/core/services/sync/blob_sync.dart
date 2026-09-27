import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../../../utils/kelivo_file_uri.dart';
import '../../../utils/sandbox_path_resolver.dart';
import 'sync_models.dart';

/// Blob plane for LAN sync (ADR-0002 slice 3): the "blobs follow URIs" rule.
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
final RegExp _kelivoFileUriPattern = RegExp(
  r'kelivo-file://[A-Za-z0-9\-._~%!$&()*+,;=:@/]*',
);

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

/// Every canonical `kelivo-file` URI referenced by the string values of these
/// rows. Payload columns are JSON strings, so one lexical pass per value
/// covers parts, entity payloads and preference values alike; each candidate
/// is validated by the strict URI parser, so junk matches are dropped.
Set<String> kelivoFileUrisInRows(Iterable<Map<String, dynamic>> rows) {
  final uris = <String>{};
  for (final row in rows) {
    for (final value in row.values) {
      if (value is! String) continue;
      for (final match in _kelivoFileUriPattern.allMatches(value)) {
        final candidate = match.group(0)!;
        if (KelivoFileUri.decodeToSegments(candidate) != null) {
          uris.add(candidate);
        }
      }
    }
  }
  return uris;
}

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

/// The sender side of the manifest: one entry per referenced URI this device
/// can actually serve (the file exists and the target root is allowed).
/// Missing local files are skipped — the sender's own UI is missing them too.
Future<List<SyncBlobEntry>> buildFileBlobEntries(
  Set<String> uris,
  BlobFileHasher hasher, {
  BlobPathResolver resolve = defaultBlobPathResolver,
}) async {
  final entries = <SyncBlobEntry>[];
  for (final uri in uris) {
    if (!isAllowedFileBlobUri(uri)) continue;
    final resolved = resolve(uri);
    if (resolved == null) continue;
    final file = File(resolved);
    final hash = await hasher.hashOf(file);
    if (hash == null) continue;
    entries.add(
      SyncBlobEntry(
        kind: SyncBlobEntry.kindFile,
        key: uri,
        contentHash: hash,
        byteSize: await file.length(),
      ),
    );
  }
  return entries;
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

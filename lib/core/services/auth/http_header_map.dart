// Helpers for mutating `http` request header maps without tripping a deleted
// slot in the map's round-trip hashing.
//
// `http.BaseRequest.headers` is a case-insensitive hash map
// (`http/src/base_request.dart`: `LinkedHashMap(equals: (key1, key2) => ...)`).
// Deleting a key in place leaves that slot marked as deleted, and inserting a
// name that hashes to that slot hands the deleted marker — a `List<dynamic>` —
// to the map's `equals` closure, whose parameters are typed `String`:
//
//     type 'List<dynamic>' is not a subtype of type 'String' of 'key1'
//
// Minimal reproduction (a bare `LinkedHashMap` with the same closures, on
// Flutter 3.47.0 / Dart 3.13.0): deleting a name that is *not* present and then
// inserting is fine, deleting a *different* name and inserting is fine, but
// deleting a present name and re-inserting that same name throws. Rebuilding
// the map through a plain map and re-inserting does not.
//
// Both helpers below rebuild instead of deleting in place: the resulting
// headers are identical and no deleted slot is left behind.

/// Case-insensitively removes [name] from [headers].
void removeHeaderCaseInsensitive(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  if (!headers.keys.any((key) => key.toLowerCase() == lower)) return;
  final kept = <String, String>{
    for (final entry in headers.entries)
      if (entry.key.toLowerCase() != lower) entry.key: entry.value,
  };
  headers
    ..clear()
    ..addAll(kept);
}

/// Case-insensitively assigns `name: value` so the header appears exactly once,
/// spelled as [name].
void setHeaderCaseInsensitive(
  Map<String, String> headers,
  String name,
  String value,
) {
  final lower = name.toLowerCase();
  String? existing;
  for (final key in headers.keys) {
    if (key.toLowerCase() == lower) {
      existing = key;
      break;
    }
  }
  if (existing == null || existing == name) {
    headers[name] = value;
    return;
  }
  final kept = <String, String>{
    for (final entry in headers.entries)
      if (entry.key.toLowerCase() != lower) entry.key: entry.value,
  };
  headers
    ..clear()
    ..addAll(kept);
  headers[name] = value;
}

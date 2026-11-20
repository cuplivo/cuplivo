/// The preview URL seam implemented by the DSH gateway adapter.
///
/// The page must not build `/api/file` URLs itself: the wire shape (absolute
/// path + version token) belongs to the protocol client, and the feature layer
/// deliberately imports no `lib/core/dsh/` type. The adapter is the only place
/// that knows both the endpoint and the cookie.
abstract interface class DshFilePreviewHost {
  /// `GET /api/file?path=<absolutePath>[&v=<version>]` for an already-statted
  /// workspace file. Null when this host cannot serve file bytes.
  Uri? fileUri(String absolutePath, {String? version});
}

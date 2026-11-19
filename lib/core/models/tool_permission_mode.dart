enum ToolPermissionMode {
  requestApproval,
  fullAccess;

  static const extrasKey = 'tools.permission_mode';

  /// The pre-rename key an older build honoured for the same grant.
  ///
  /// Nothing in this build reads it, and that is exactly why it is stripped
  /// wherever the grant is: a peer or an archive that still honours it would
  /// otherwise auto-approve a call this device never approved.
  static const allowAllExtrasKey = 'workspace.allowAll';

  /// Every key a grant is written to, so "remove the grant" has one spelling.
  static const Set<String> grantExtrasKeys = {extrasKey, allowAllExtrasKey};

  static ToolPermissionMode fromExtras(Map<String, dynamic> extras) =>
      extras[extrasKey] == fullAccess.name ? fullAccess : requestApproval;

  Map<String, dynamic> applyTo(Map<String, dynamic> extras) => {
    ...withoutGrant(extras),
    extrasKey: name,
  };

  static Map<String, dynamic> withoutGrant(Map<String, dynamic> extras) =>
      Map<String, dynamic>.from(extras)
        ..removeWhere((key, _) => grantExtrasKeys.contains(key));
}

class ToolPermissionState {
  const ToolPermissionState({
    this.mode = ToolPermissionMode.requestApproval,
    this.workspaceId,
    this.assistantId,
  });
  final ToolPermissionMode mode;
  final String? workspaceId;
  final String? assistantId;
}

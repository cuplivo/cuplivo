import 'package:flutter/material.dart';

import '../../../core/models/workspace.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/mcp/kelivo_filesystem/kelivo_filesystem_server.dart';
import '../../../shared/responsive/breakpoints.dart';
import '../../../utils/platform_utils.dart';
import '../../settings/pages/mount_files_page.dart';

Future<String?> showWorkspaceDirectoryPicker(
  BuildContext context, {
  required Workspace workspace,
  required WorkspaceProvider workspaces,
  required String initialDirectory,
}) async {
  final hostPath = workspaces.hostPathFor(workspace);
  if (hostPath == null) return null;
  final page = MountFilesPage(
    mount: FilesystemMount(
      alias: workspace.alias,
      path: hostPath,
      readOnly: workspace.readOnly,
    ),
    selectDirectory: true,
    initialDirectory: initialDirectory,
  );
  final useConstrainedDialog =
      PlatformUtils.isDesktopTarget ||
      MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
  if (!useConstrainedDialog) {
    return Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => page));
  }
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: page,
      ),
    ),
  );
}

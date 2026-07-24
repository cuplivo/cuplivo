import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class GitHubRepoInfo {
  final String owner;
  final String repo;
  final String branch;
  final String? subPath;

  const GitHubRepoInfo({
    required this.owner,
    required this.repo,
    required this.branch,
    this.subPath,
  });

  String get archiveUrl =>
      'https://github.com/$owner/$repo/archive/refs/heads/$branch.zip';

  String get stripPrefix => '$repo-$branch/';
}

GitHubRepoInfo? parseGitHubUrl(String url) {
  final trimmed = url.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;

  final host = uri.host.toLowerCase();
  if (host != 'github.com' && host != 'www.github.com') return null;

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 2) return null;

  final owner = segments[0];
  final repo = segments[1];

  if (owner.isEmpty || repo.isEmpty) return null;

  String branch = 'main';
  String? subPath;

  if (segments.length >= 4 && segments[2] == 'tree') {
    branch = segments[3];
    if (segments.length > 4) {
      subPath = segments.sublist(4).join('/');
    }
  }

  return GitHubRepoInfo(
    owner: owner,
    repo: repo,
    branch: branch,
    subPath: subPath,
  );
}

Future<File?> downloadGitHubArchive(
  GitHubRepoInfo info, {
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final response = await c
        .get(Uri.parse(info.archiveUrl))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) return null;

    final tmpDir = Directory.systemTemp;
    final tmpFile = File(
      p.join(
        tmpDir.path,
        'cuplivo_skill_${DateTime.now().millisecondsSinceEpoch}.zip',
      ),
    );
    await tmpFile.writeAsBytes(response.bodyBytes, flush: true);
    return tmpFile;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

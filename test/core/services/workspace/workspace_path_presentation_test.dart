import 'package:flutter_test/flutter_test.dart';

import 'package:Cuplivo/core/services/workspace/workspace_path_presentation.dart';

void main() {
  group('parseModelPath (standard cwd semantics)', () {
    test('passes "/" through (mount listing special case)', () {
      expect(parseModelPath('/', 'default'), '/');
    });

    test('translates /workspace root and nested paths', () {
      expect(parseModelPath('/workspace', 'default'), '@default');
      expect(parseModelPath('/workspace/a.md', 'default'), '@default/a.md');
      expect(
        parseModelPath('/workspace/a/b/c.txt', 'default'),
        '@default/a/b/c.txt',
      );
      expect(parseModelPath('/workspace', 'workspace_2'), '@workspace_2');
      expect(parseModelPath('/workspace/x', 'workspace_2'), '@workspace_2/x');
    });

    test('resolves relative paths from the configured working directory', () {
      expect(
        parseModelPath(
          'notes.md',
          'default',
          workingDirectory: '/workspace/project',
        ),
        '@default/project/notes.md',
      );
      expect(
        parseModelPath(
          '../shared/file.txt',
          'default',
          workingDirectory: '/workspace/project/src',
        ),
        '@default/project/shared/file.txt',
      );
      expect(
        parseModelPath(
          '/workspace/root.txt',
          'default',
          workingDirectory: '/workspace/project',
        ),
        '@default/root.txt',
      );
    });

    test('rejects relative paths that escape the workspace root', () {
      expect(
        () => parseModelPath(
          '../../outside.txt',
          'default',
          workingDirectory: '/workspace/project',
        ),
        throwsA(isA<ModelPathException>()),
      );
    });

    test('preserves trailing slash for engine validation parity', () {
      expect(parseModelPath('/workspace/', 'default'), '@default/');
      expect(parseModelPath('/workspace/dir/', 'default'), '@default/dir/');
    });

    test('rejects canonical @alias form (strict)', () {
      expect(
        () => parseModelPath('@default/a.md', 'default'),
        throwsA(isA<ModelPathException>()),
      );
      expect(
        () => parseModelPath('@default', 'default'),
        throwsA(isA<ModelPathException>()),
      );
      expect(
        () => parseModelPath('@workspace_2/a', 'workspace_2'),
        throwsA(isA<ModelPathException>()),
      );
    });

    test('rejects absolute paths outside /workspace', () {
      for (final bad in [
        '/etc/passwd',
        '/tmp/x',
        '/workspace2/x', // prefix lookalike, not under /workspace/
        'C:/x',
      ]) {
        expect(
          () => parseModelPath(bad, 'default'),
          throwsA(isA<ModelPathException>()),
          reason: 'should reject: $bad',
        );
      }
    });

    test('rejects whitespace and empty paths', () {
      expect(
        () => parseModelPath('', 'default'),
        throwsA(isA<ModelPathException>()),
      );
      expect(
        () => parseModelPath(' /workspace/x', 'default'),
        throwsA(isA<ModelPathException>()),
      );
      expect(
        () => parseModelPath('/workspace/x ', 'default'),
        throwsA(isA<ModelPathException>()),
      );
    });
  });

  group('presentWirePath', () {
    test('presents the bound alias root and descendants as /workspace', () {
      expect(presentWirePath('@default', 'default'), '/workspace');
      expect(presentWirePath('@default/a.md', 'default'), '/workspace/a.md');
      expect(presentWirePath('@workspace_2/x', 'workspace_2'), '/workspace/x');
    });

    test('leaves unknown mounts unchanged', () {
      expect(presentWirePath('@docs/a.md', 'default'), '@docs/a.md');
    });
  });

  group('presentDefText', () {
    test('rewrites model-visible tool copy to /workspace', () {
      expect(
        presentDefText('e.g. @default/notes.md'),
        'e.g. /workspace/notes.md',
      );
      expect(
        presentDefText('moved into @default get mtime=now'),
        'moved into /workspace get mtime=now',
      );
      expect(
        presentDefText('Mount-relative path (@alias/rel/path)'),
        'Workspace-relative path (/workspace/rel/path)',
      );
      expect(
        presentDefText('file path (mount-relative)'),
        'file path (workspace-relative)',
      );
    });
  });

  group('presentDefMap', () {
    test('rewrites nested schema strings only', () {
      final def = presentDefMap({
        'name': 'read',
        'description': 'Read @default/notes.md.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Mount-relative path (@alias/rel/path)',
            },
          },
          'required': ['path'],
        },
      });
      expect(def['description'], 'Read /workspace/notes.md.');
      final properties = ((def['inputSchema'] as Map)['properties'] as Map);
      expect(
        ((properties['path'] as Map)['description']),
        'Workspace-relative path (/workspace/rel/path)',
      );
      expect(((properties['path'] as Map)['type']), 'string');
      expect((def['inputSchema'] as Map)['required'], ['path']);
    });
  });
}

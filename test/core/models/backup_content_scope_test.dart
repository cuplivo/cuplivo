import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/models/backup.dart';

void main() {
  group('BackupContentScope model', () {
    test('defaults to everything included', () {
      const scope = BackupContentScope();
      expect(scope.chatsAndAssistants, isTrue);
      expect(scope.settings, isTrue);
      expect(scope.attachments, isTrue);
      expect(scope.workspaces, isTrue);
      expect(scope.skills, isTrue);
      expect(scope.fontsAndAvatars, isTrue);
      expect(scope.anySettings, isTrue);
      expect(scope.anyFiles, isTrue);
    });

    test('toJson round-trips through fromJson', () {
      final scope = const BackupContentScope(
        chatsAndAssistants: false,
        fontsAndAvatars: false,
      );
      final decoded = BackupContentScope.fromJson(scope.toJson());
      expect(decoded, scope);
    });

    test('legacy includeChats/includeFiles map to equivalent bits', () {
      final decoded = BackupContentScope.fromJson(
        const {},
        legacyIncludeChats: false,
        legacyIncludeFiles: false,
      );
      expect(decoded.chatsAndAssistants, isFalse);
      // Old semantics: settings.json and skills were always exported.
      expect(decoded.settings, isTrue);
      expect(decoded.skills, isTrue);
      expect(decoded.attachments, isFalse);
      expect(decoded.workspaces, isFalse);
      expect(decoded.fontsAndAvatars, isFalse);
    });

    test('legacy getters on the configs match derivation', () {
      const scope = BackupContentScope(skills: false);
      expect(scope.anyFiles, isTrue);
      const cfg = WebDavConfig(content: scope);
      expect(cfg.includeChats, isTrue);
      expect(cfg.includeFiles, isTrue);
      expect(WebDavConfig(content: scope).toJson()['includeFiles'], isTrue);
      expect(WebDavConfig(content: scope).toJson()['includeChats'], isTrue);
    });
  });
}

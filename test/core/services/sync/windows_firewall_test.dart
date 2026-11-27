import 'package:Cuplivo/core/services/sync/windows_firewall.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WindowsFirewall', () {
    test('rule names avoid spaces and parentheses', () {
      final name = WindowsFirewall.ruleName(9527);
      expect(name, 'Cuplivo-Sync-TCP-9527');
      expect(name, isNot(contains(' ')));
      expect(name, isNot(contains('(')));
      expect(name, isNot(contains(')')));
    });

    test('the rule is port-scoped, not program-scoped', () {
      final args = WindowsFirewall.addRuleArgs(9527);
      expect(args.take(4), ['advfirewall', 'firewall', 'add', 'rule']);
      expect(args, contains('name=Cuplivo-Sync-TCP-9527'));
      expect(args, contains('dir=in'));
      expect(args, contains('action=allow'));
      expect(args, contains('protocol=TCP'));
      expect(args, contains('localport=9527'));
      // A program-scoped rule would break on every app update path change.
      expect(args, isNot(contains('program=')));
    });

    test('show and delete reuse the same name spelling', () {
      expect(
        WindowsFirewall.showRuleArgs(1234),
        contains('name=Cuplivo-Sync-TCP-1234'),
      );
      expect(
        WindowsFirewall.deleteRuleArgs(1234),
        contains('name=Cuplivo-Sync-TCP-1234'),
      );
      expect(WindowsFirewall.showRuleArgs(1234).take(4), [
        'advfirewall',
        'firewall',
        'show',
        'rule',
      ]);
      expect(WindowsFirewall.deleteRuleArgs(1234).take(4), [
        'advfirewall',
        'firewall',
        'delete',
        'rule',
      ]);
    });

    test(
      'the elevated command re-runs netsh via Start-Process -Verb RunAs',
      () {
        final command = WindowsFirewall.elevateAddRuleCommand(9527);
        expect(command, contains('Start-Process -Verb RunAs'));
        expect(command, contains('-Wait'));
        expect(command, contains('netsh'));
        expect(command, contains("'name=Cuplivo-Sync-TCP-9527'"));
        for (final arg in WindowsFirewall.addRuleArgs(9527)) {
          expect(command, contains("'$arg'"));
        }
      },
    );
  });
}

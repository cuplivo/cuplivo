import 'package:Cuplivo/core/services/api/kimi_formula_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KimiFormulaSearch.mergeTools', () {
    test('inserts unique Formula tools and returns exact inserted names', () {
      final body = <String, dynamic>{
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'web_search',
              'description': 'user custom search',
            },
          },
        ],
      };
      final formulaTools = [
        {
          'type': 'function',
          'function': {
            'name': 'web_search',
            'description': 'moonshot formula search',
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'moonshot_web_search_r1a2b3',
            'description': 'formula unique',
          },
        },
      ];

      final inserted = KimiFormulaSearch.mergeTools(body, formulaTools);

      expect(inserted, {'moonshot_web_search_r1a2b3'});
      final tools = body['tools'] as List;
      expect(tools, hasLength(2));
      expect(
        tools.map((t) => ((t as Map)['function'] as Map)['name']).toSet(),
        {'web_search', 'moonshot_web_search_r1a2b3'},
      );
      // Custom tool declaration is preserved (not overwritten by Formula).
      expect(
        ((tools.first as Map)['function'] as Map)['description'],
        'user custom search',
      );
    });

    test('does not treat heuristic names as Formula tools by themselves', () {
      final body = <String, dynamic>{
        'tools': [
          {
            'type': 'function',
            'function': {'name': 'search'},
          },
        ],
      };

      final inserted = KimiFormulaSearch.mergeTools(body, const []);

      expect(inserted, isEmpty);
      expect((body['tools'] as List).single['function']['name'], 'search');
    });
  });
}

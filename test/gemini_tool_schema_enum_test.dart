import 'package:flutter_test/flutter_test.dart';
import 'package:Cuplivo/core/services/api/chat_api_helpers.dart';

void main() {
  group('cleanSchemaForGemini stringEnumOnly', () {
    test('drops boolean enums nested inside array items', () {
      // Shape reported by the GitHub remote MCP server: an array property whose
      // item objects carry `enum: [true, false]` on a boolean field.
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'files': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'binary': {
                  'type': 'boolean',
                  'enum': [true, false],
                },
              },
            },
          },
        },
      }, stringEnumOnly: true);

      final item =
          (cleaned['properties']['files']['items']) as Map<String, dynamic>;
      final binary = item['properties']['binary'] as Map<String, dynamic>;
      expect(binary.containsKey('enum'), isFalse);
      expect(binary['type'], 'boolean');
    });

    test('stringifies enum values on string-typed schemas', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': ['read', 1, true],
          },
          'untyped': {
            'enum': ['a', 'b'],
          },
        },
      }, stringEnumOnly: true);

      expect(cleaned['properties']['mode']['enum'], ['read', '1', 'true']);
      expect(cleaned['properties']['untyped']['type'], 'string');
      expect(cleaned['properties']['untyped']['enum'], ['a', 'b']);
    });

    test('drops numeric enums on integer schemas', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'page': {
            'type': 'integer',
            'enum': [1, 2, 3],
          },
        },
      }, stringEnumOnly: true);

      expect(cleaned['properties']['page'].containsKey('enum'), isFalse);
      expect(cleaned['properties']['page']['type'], 'integer');
    });

    test('keeps an untyped all-string enum intact', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'mode': {
            'enum': ['a', 'b'],
          },
        },
      }, stringEnumOnly: true);

      final mode = cleaned['properties']['mode'] as Map<String, dynamic>;
      expect(mode['type'], 'string');
      expect(mode['enum'], ['a', 'b']);
    });

    test('infers the scalar type of an untyped non-string enum', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'flag': {
            'enum': [true, false],
          },
          'count': {
            'enum': [1, 2],
          },
          'ratio': {
            'enum': [1, 2.5],
          },
        },
      }, stringEnumOnly: true);

      final flag = cleaned['properties']['flag'] as Map<String, dynamic>;
      expect(flag['type'], 'boolean');
      expect(flag.containsKey('enum'), isFalse);
      final count = cleaned['properties']['count'] as Map<String, dynamic>;
      expect(count['type'], 'integer');
      expect(count.containsKey('enum'), isFalse);
      final ratio = cleaned['properties']['ratio'] as Map<String, dynamic>;
      expect(ratio['type'], 'number');
      expect(ratio.containsKey('enum'), isFalse);
    });

    test('keeps only the string members of an untyped mixed enum', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'mixed': {
            'enum': ['read', 1, true],
          },
          'noStrings': {
            'enum': [
              1,
              true,
              {'a': 1},
            ],
          },
        },
      }, stringEnumOnly: true);

      final mixed = cleaned['properties']['mixed'] as Map<String, dynamic>;
      expect(mixed['type'], 'string');
      expect(mixed['enum'], ['read']);
      // No string member: a string schema would accept nothing the tool takes,
      // so keep a type one of the members actually has.
      final noStrings =
          cleaned['properties']['noStrings'] as Map<String, dynamic>;
      expect(noStrings['type'], 'integer');
      expect(noStrings.containsKey('enum'), isFalse);
    });

    test('types an enum whose members are all composites', () {
      // `type` is required by Gemini, so this node must not end up as `{}`.
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'objects': {
            'enum': [
              {'a': 1},
              [1, 2],
            ],
          },
          'lists': {
            'enum': [
              [1, 2],
            ],
          },
        },
      }, stringEnumOnly: true);

      final objects = cleaned['properties']['objects'] as Map<String, dynamic>;
      expect(objects['type'], 'object');
      expect(objects.containsKey('enum'), isFalse);
      expect(objects['properties'], <String, dynamic>{});
      final lists = cleaned['properties']['lists'] as Map<String, dynamic>;
      expect(lists['type'], 'array');
      expect(lists.containsKey('enum'), isFalse);
      expect(lists['items'], {'type': 'string'});
    });

    test('types a null-only enum as null rather than string', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'nothing': {
            'enum': [null],
          },
        },
      }, stringEnumOnly: true);

      final nothing = cleaned['properties']['nothing'] as Map<String, dynamic>;
      expect(nothing['type'], 'null');
      expect(nothing.containsKey('enum'), isFalse);
    });

    test('leaves enums untouched without stringEnumOnly', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'flag': {
            'type': 'boolean',
            'enum': [true, false],
          },
        },
      });

      expect(cleaned['properties']['flag']['enum'], [true, false]);
    });

    test('still fills missing array items at any depth', () {
      final cleaned = cleanSchemaForGemini({
        'type': 'object',
        'properties': {
          'outer': {
            'type': 'object',
            'properties': {
              'tags': {'type': 'array'},
            },
          },
        },
        'required': ['outer', 'missing'],
      }, stringEnumOnly: true);

      expect(cleaned['properties']['outer']['properties']['tags']['items'], {
        'type': 'string',
      });
      expect(cleaned['properties']['missing'], {'type': 'string'});
    });
  });
}

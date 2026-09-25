import 'dart:collection';

import 'package:Cuplivo/core/services/auth/http_header_map.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `http.BaseRequest.headers`
/// (`http/src/base_request.dart`: the same `equals`/`hashCode` closures).
Map<String, String> _httpHeaders() => LinkedHashMap<String, String>(
  equals: (key1, key2) => key1.toLowerCase() == key2.toLowerCase(),
  hashCode: (key) => key.toLowerCase().hashCode,
);

void main() {
  test('a removed header can be re-inserted under the same name', () {
    final headers = _httpHeaders()
      ..['Authorization'] = 'Bearer wrong'
      ..['Accept'] = 'application/json';

    removeHeaderCaseInsensitive(headers, 'authorization');
    expect(headers.containsKey('authorization'), isFalse);

    // Regression guard: deleting in place leaves a slot whose marker reaches
    // the map's `equals` closure on this insert, throwing
    // `type 'List<dynamic>' is not a subtype of type 'String' of 'key1'`.
    headers['Authorization'] = 'Bearer fresh';
    expect(headers, hasLength(2));
    expect(headers['Authorization'], 'Bearer fresh');
  });

  test('removing an absent header changes nothing', () {
    final headers = _httpHeaders()..['Accept'] = 'application/json';

    removeHeaderCaseInsensitive(headers, 'x-api-key');

    expect(headers, hasLength(1));
    expect(headers['Accept'], 'application/json');
  });

  test('setting an existing header replaces its spelling, not its count', () {
    final headers = _httpHeaders()
      ..['content-type'] = 'text/plain'
      ..['Accept'] = 'application/json';

    setHeaderCaseInsensitive(headers, 'Content-Type', 'application/json');

    expect(headers, hasLength(2));
    expect(headers.keys.toSet(), {'Content-Type', 'Accept'});
    expect(headers['content-type'], 'application/json');
  });

  test('setting the same spelling keeps neighbouring headers untouched', () {
    final headers = _httpHeaders()
      ..['anthropic-beta'] = 'old'
      ..['Accept'] = 'application/json';

    setHeaderCaseInsensitive(headers, 'anthropic-beta', 'new');

    expect(headers, hasLength(2));
    expect(headers['anthropic-beta'], 'new');
  });

  test('setting on an empty header map inserts the header', () {
    final headers = _httpHeaders();

    setHeaderCaseInsensitive(headers, 'Authorization', 'Bearer fresh');

    expect(headers, hasLength(1));
    expect(headers['Authorization'], 'Bearer fresh');
  });
}

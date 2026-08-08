import 'package:Cuplivo/core/providers/mcp_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for McpProvider condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

McpProvider _buildMcp() {
  final mcp = McpProvider(contextProvider: () => throw UnimplementedError());
  addTearDown(mcp.dispose);
  return mcp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  test('reorderServers moves a server to a new index', () async {
    final mcp = _buildMcp();
    // Wait until built-in servers are seeded by the async load.
    await _waitUntil(() => mcp.servers.isNotEmpty);
    final base = mcp.servers.length;
    final idA = await mcp.addServer(
      enabled: false,
      name: 'A',
      transport: McpTransportType.http,
      url: 'http://a',
    );
    final idB = await mcp.addServer(
      enabled: false,
      name: 'B',
      transport: McpTransportType.http,
      url: 'http://b',
    );
    final idC = await mcp.addServer(
      enabled: false,
      name: 'C',
      transport: McpTransportType.http,
      url: 'http://c',
    );

    await mcp.reorderServers(base + 2, base + 0);

    final ids = mcp.servers.map((e) => e.id).toList();
    expect(ids.sublist(base, base + 3), [idC, idA, idB]);
  });

  test('reorderServers ignores out-of-range indices', () async {
    final mcp = _buildMcp();
    await _waitUntil(() => mcp.servers.isNotEmpty);
    final base = mcp.servers.length;
    final idA = await mcp.addServer(
      enabled: false,
      name: 'A',
      transport: McpTransportType.http,
      url: 'http://a',
    );
    final idB = await mcp.addServer(
      enabled: false,
      name: 'B',
      transport: McpTransportType.http,
      url: 'http://b',
    );

    await mcp.reorderServers(base, 99);

    final ids = mcp.servers.map((e) => e.id).toList();
    expect(ids.sublist(base, base + 2), [idA, idB]);
  });

  test('reorderServers ignores an out-of-range source index', () async {
    final mcp = _buildMcp();
    await _waitUntil(() => mcp.servers.isNotEmpty);
    final base = mcp.servers.length;
    final idA = await mcp.addServer(
      enabled: false,
      name: 'A',
      transport: McpTransportType.http,
      url: 'http://a',
    );
    final idB = await mcp.addServer(
      enabled: false,
      name: 'B',
      transport: McpTransportType.http,
      url: 'http://b',
    );

    await mcp.reorderServers(99, base);

    final ids = mcp.servers.map((e) => e.id).toList();
    expect(ids.sublist(base, base + 2), [idA, idB]);
  });

  test('reorderServers ignores negative source and target indices', () async {
    final mcp = _buildMcp();
    await _waitUntil(() => mcp.servers.isNotEmpty);
    final base = mcp.servers.length;
    final idA = await mcp.addServer(
      enabled: false,
      name: 'A',
      transport: McpTransportType.http,
      url: 'http://a',
    );
    final idB = await mcp.addServer(
      enabled: false,
      name: 'B',
      transport: McpTransportType.http,
      url: 'http://b',
    );

    await mcp.reorderServers(-1, base);
    expect(mcp.servers.map((e) => e.id).toList().sublist(base), [idA, idB]);

    await mcp.reorderServers(base, -1);
    expect(mcp.servers.map((e) => e.id).toList().sublist(base), [idA, idB]);

    await mcp.reorderServers(-1, -1);
    expect(mcp.servers.map((e) => e.id).toList().sublist(base), [idA, idB]);
  });
}

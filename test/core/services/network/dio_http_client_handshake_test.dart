import 'dart:io';
import 'dart:async';

import 'package:Cuplivo/core/services/network/dio_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('a terminated TLS handshake reports one client exception', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    server.listen((socket) async {
      await socket.first;
      socket.destroy();
    });

    final client = DioHttpClient();
    addTearDown(client.close);

    await expectLater(
      client.get(Uri.parse('https://127.0.0.1:${server.port}/usage')),
      throwsA(isA<http.ClientException>()),
    );
  });

  test('closing after an outer timeout has no secondary Dio error', () async {
    final sockets = <Socket>[];
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    server.listen(sockets.add);

    final client = DioHttpClient();
    await expectLater(
      client
          .get(Uri.parse('https://127.0.0.1:${server.port}/usage'))
          .timeout(const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    client.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}

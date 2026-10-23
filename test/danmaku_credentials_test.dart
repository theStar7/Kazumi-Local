import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

void main() {
  test(
    'missing build credentials fail before initializing the HTTP client',
    () async {
      // No storage, native network client, or real API is initialized here.
      await expectLater(
        DanmakuClient.instance.get(
          'https://api.dandanplay.net/api/v2/search/episodes',
          queryParameters: {'anime': 'fixture'},
        ),
        throwsA(
          isA<NetworkException>().having(
            (error) => error.message,
            'configuration guidance',
            allOf(contains('DANDANAPI_APPID'), contains('DANDANAPI_KEY')),
          ),
        ),
      );
    },
    skip:
        dandanCredentials['id']!.trim().isNotEmpty &&
        dandanCredentials['value']!.trim().isNotEmpty,
  );
}

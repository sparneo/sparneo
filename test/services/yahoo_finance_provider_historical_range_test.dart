// test/services/yahoo_finance_provider_historical_range_test.dart
//
// Test de YahooFinanceProvider.getHistoricalRange (chantier B16, import crypto
// lot 4, conception interne) : vérifie la construction de l'URL (period1/period2
// explicites, interval=1d — LA raison d'être de cette méthode par rapport à
// getHistoricalData, qui dégrade la granularité au-delà de quelques années), le
// parsing des barres en UTC EXPLICITE (contrairement à getHistoricalData, qui
// convertit en heure locale), et les repli null sur échec — même conventions que
// yahoo_finance_provider_symbol_exists_test.dart (`http.runWithClient` +
// `MockClient`, aucun appel réseau réel).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:portfolio_tracker/services/yahoo_finance_provider.dart';

void main() {
  group('YahooFinanceProvider.getHistoricalRange', () {
    test('construit period1/period2 (jours calendaires UTC, +1j sur period2) et interval=1d',
        () async {
      final provider = YahooFinanceProvider();
      Uri? capturedUrl;
      final mockClient = MockClient((request) async {
        capturedUrl = request.url;
        return http.Response('{"chart":{"result":[]}}', 200);
      });

      final from = DateTime.utc(2024, 2, 20);
      final to = DateTime.utc(2024, 2, 25);
      await http.runWithClient(
        () => provider.getHistoricalRange('STRK22691-USD', from, to),
        () => mockClient,
      );

      expect(capturedUrl, isNotNull);
      expect(capturedUrl!.path, '/v8/finance/chart/STRK22691-USD');
      expect(capturedUrl!.queryParameters['interval'], '1d');
      final expectedPeriod1 =
          DateTime.utc(2024, 2, 20).millisecondsSinceEpoch ~/ 1000;
      final expectedPeriod2 =
          DateTime.utc(2024, 2, 26).millisecondsSinceEpoch ~/ 1000;
      expect(capturedUrl!.queryParameters['period1'], '$expectedPeriod1');
      expect(capturedUrl!.queryParameters['period2'], '$expectedPeriod2');
    });

    test('200 avec barres : dates parsées en UTC EXPLICITE (jour exact préservé)',
        () async {
      final provider = YahooFinanceProvider();
      // 2024-02-20T00:00:00Z.
      const timestamp = 1708387200;
      final mockClient = MockClient((request) async {
        return http.Response(
          '{"chart":{"result":[{'
          '"timestamp":[$timestamp],'
          '"indicators":{"quote":[{"close":[1.954]}]}'
          '}]}}',
          200,
        );
      });

      final result = await http.runWithClient(
        () => provider.getHistoricalRange(
          'STRK22691-USD',
          DateTime.utc(2024, 2, 20),
          DateTime.utc(2024, 2, 20),
        ),
        () => mockClient,
      );

      expect(result, isNotNull);
      expect(result!.dates, hasLength(1));
      expect(result.dates.single.isUtc, isTrue);
      expect(result.dates.single.year, 2024);
      expect(result.dates.single.month, 2);
      expect(result.dates.single.day, 20);
      expect(result.prices.single, 1.954);
    });

    test('chart.result VIDE → null (symbole sans barre sur la fenêtre)', () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        return http.Response('{"chart":{"result":[]}}', 200);
      });

      final result = await http.runWithClient(
        () => provider.getHistoricalRange(
            'UNKNOWN-EUR', DateTime.utc(2024, 1, 1), DateTime.utc(2024, 1, 2)),
        () => mockClient,
      );

      expect(result, isNull);
    });

    test('404 (ticker inexistant) → null', () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      final result = await http.runWithClient(
        () => provider.getHistoricalRange(
            'NOPE-EUR', DateTime.utc(2024, 1, 1), DateTime.utc(2024, 1, 2)),
        () => mockClient,
      );

      expect(result, isNull);
    });

    test('panne réseau (après épuisement des tentatives) → null, jamais d\'exception',
        () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        throw const SocketException('panne réseau simulée');
      });

      final result = await http.runWithClient(
        () => provider.getHistoricalRange(
            'BTC-EUR', DateTime.utc(2024, 1, 1), DateTime.utc(2024, 1, 2)),
        () => mockClient,
      );

      expect(result, isNull);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

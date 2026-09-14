// test/services/yahoo_finance_provider_symbol_exists_test.dart
//
// Test de YahooFinanceProvider.symbolExists (lot 0, chantier B16 — import
// crypto, conception interne) : vérifie la distinction à trois issues (404 →
// false / 200+résultat → true / tout le reste → null = inconnu), LA raison
// d'être de cette méthode par rapport à getQuoteWithMetadata, qui aplatit
// aujourd'hui toute erreur en `null`.
//
// Aucun appel réseau réel : mêmes conventions que
// yahoo_finance_provider_search_test.dart (`http.runWithClient` +
// `MockClient`).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:portfolio_tracker/services/yahoo_finance_provider.dart';

void main() {
  group('YahooFinanceProvider.symbolExists', () {
    test('404 → false (symbole inexistant, réponse fiable, aucune retry)', () async {
      final provider = YahooFinanceProvider();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        expect(request.url.path, '/v8/finance/chart/POL-EUR');
        return http.Response('Not Found', 404);
      });

      final exists = await http.runWithClient(
        () => provider.symbolExists('POL-EUR'),
        () => mockClient,
      );

      expect(exists, isFalse);
      // 404 n'est pas réessayable : une seule requête.
      expect(callCount, equals(1));
    });

    test('200 avec chart.result non vide → true', () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        return http.Response(
          '{"chart":{"result":[{"meta":{"symbol":"BTC-EUR"}}]}}',
          200,
        );
      });

      final exists = await http.runWithClient(
        () => provider.symbolExists('BTC-EUR'),
        () => mockClient,
      );

      expect(exists, isTrue);
    });

    test('200 avec chart.result VIDE → null (ni confirmé ni infirmé, PAS false)',
        () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        return http.Response('{"chart":{"result":[]}}', 200);
      });

      final exists = await http.runWithClient(
        () => provider.symbolExists('XYZ-EUR'),
        () => mockClient,
      );

      expect(exists, isNull);
    });

    test('timeout/erreur réseau (après épuisement des tentatives) → null, '
        'JAMAIS false', () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        throw const SocketException('panne réseau simulée');
      });

      final exists = await http.runWithClient(
        () => provider.symbolExists('BTC-EUR'),
        () => mockClient,
      );

      expect(exists, isNull);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('429 épuisé après backoff → null, JAMAIS false', () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        return http.Response('Too Many Requests', 429);
      });

      final exists = await http.runWithClient(
        () => provider.symbolExists('BTC-EUR'),
        () => mockClient,
      );

      expect(exists, isNull);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

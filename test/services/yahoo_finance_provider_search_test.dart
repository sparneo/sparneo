// test/services/yahoo_finance_provider_search_test.dart
//
// Test de searchByIsin sur YahooFinanceProvider : vérifie que l'échec de
// TRANSPORT (statut HTTP non-200 après retries, exception réseau) est
// distingué d'une recherche ABOUTIE sans correspondance (P1.2 — cf.
// IsinSearchException dans market_data_service.dart).
//
// Aucun appel réseau réel : on intercepte les appels `http.get` du provider
// via `http.runWithClient` (zone HTTP, cf. package:http/testing.dart), qui
// substitue un `MockClient` piloté par le test au client par défaut, SANS
// modifier le provider (celui-ci utilise les fonctions top-level `http.get`).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/yahoo_finance_provider.dart';

void main() {
  group('YahooFinanceProvider.searchByIsin', () {
    test(
        'réponse 200 sans quote correspondant → liste vide (PAS une exception)',
        () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        expect(request.url.path, '/v1/finance/search');
        return http.Response('{"quotes": []}', 200);
      });

      final hits = await http.runWithClient(
        () => provider.searchByIsin('FR0000031122'),
        () => mockClient,
      );

      expect(hits, isEmpty);
    });

    test(
        'statut HTTP non-200 (non réessayable, ex. 404) → IsinSearchException levée',
        () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      // 404 -> ApiError non réessayable : une seule tentative, échec immédiat.
      await expectLater(
        http.runWithClient(
          () => provider.searchByIsin('FR0000031122'),
          () => mockClient,
        ),
        throwsA(isA<IsinSearchException>()),
      );
    });

    test(
        'exception réseau (après épuisement des tentatives) → IsinSearchException levée',
        () async {
      final provider = YahooFinanceProvider();
      final mockClient = MockClient((request) async {
        // Simule une panne réseau (host injoignable, hors-ligne...) : même
        // type que celui reconnu par ApiError.fromException (network,
        // réessayable) pour exercer réellement le chemin de backoff.
        throw const SocketException('panne réseau simulée');
      });

      // Erreur réseau -> réessayable : 3 tentatives avec backoff (500ms puis
      // 1s) avant l'échec final. Le test reste rapide comparé à un vrai
      // timeout HTTP (10s), mais paie ce délai de backoff réel.
      await expectLater(
        http.runWithClient(
          () => provider.searchByIsin('FR0000031122'),
          () => mockClient,
        ),
        throwsA(isA<IsinSearchException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}

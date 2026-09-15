// test/services/exchange_rate_service_daily_test.dart
//
// Tests de ExchangeRateService.getDailyRatesToEur (chantier B16, lot 2 —
// conception interne) : série FX historique JOURNALIÈRE pour la valorisation
// des échanges crypto sans jambe fiat. Aucun appel réseau réel — même patron
// que `yahoo_finance_provider_symbol_exists_test.dart` (`http.runWithClient` +
// `MockClient`).

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:portfolio_tracker/services/exchange_rate_service.dart';

/// Corps de réponse frankfurter minimal, mêmes clés que l'API réelle (vérifié
/// conception interne) : `{"rates": {"AAAA-MM-JJ": {"EUR": <taux>}}}`.
String _frankfurterBody(Map<String, double> ratesByDay) {
  final entries = ratesByDay.entries
      .map((e) => '"${e.key}":{"EUR":${e.value}}')
      .join(',');
  return '{"amount":1.0,"base":"USD","start_date":"2024-01-01",'
      '"end_date":"2024-01-31","rates":{$entries}}';
}

void main() {
  group('ExchangeRateService.getDailyRatesToEur', () {
    test('un SEUL appel HTTP pour toute la période, domaine .dev/v1', () async {
      final service = ExchangeRateService.forTesting();
      var callCount = 0;
      Uri? capturedUri;
      final mockClient = MockClient((request) async {
        callCount++;
        capturedUri = request.url;
        return http.Response(
          _frankfurterBody({'2024-01-05': 0.91, '2024-01-08': 0.92}),
          200,
        );
      });

      final rates = await http.runWithClient(
        () => service.getDailyRatesToEur(
          'usd', // insensible à la casse, comme getRateToEur
          from: DateTime(2024, 1, 5),
          to: DateTime(2024, 1, 8),
        ),
        () => mockClient,
      );

      expect(callCount, equals(1));
      expect(capturedUri!.host, equals('api.frankfurter.dev'));
      expect(capturedUri!.path, startsWith('/v1/'));
      expect(capturedUri!.queryParameters['base'], equals('USD'));
      expect(capturedUri!.queryParameters['symbols'], equals('EUR'));
      expect(rates[DateTime(2024, 1, 5)], equals(0.91));
      expect(rates[DateTime(2024, 1, 8)], equals(0.92));
    });

    test(
        'la requête élargit "from" de ~10 jours en amont (couvre un "from" '
        'tombant un week-end)', () async {
      final service = ExchangeRateService.forTesting();
      Uri? capturedUri;
      final mockClient = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      // `from` = samedi 13/01/2024.
      await http.runWithClient(
        () => service.getDailyRatesToEur(
          'USD',
          from: DateTime(2024, 1, 13),
          to: DateTime(2024, 1, 13),
        ),
        () => mockClient,
      );

      // La borne de départ RÉELLEMENT interrogée doit être ANTÉRIEURE à
      // `from` (élargissement), jamais `from` lui-même.
      final requestedFrom = capturedUri!.path.split('/').last.split('..').first;
      expect(DateTime.parse(requestedFrom).isBefore(DateTime(2024, 1, 13)), isTrue);
    });

    test('cache mémoire : deux appels sur la MÊME période → un seul appel HTTP', () async {
      final service = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({'2024-01-05': 0.91}), 200);
      });

      await http.runWithClient(() async {
        await service.getDailyRatesToEur(
          'USD',
          from: DateTime(2024, 1, 5),
          to: DateTime(2024, 1, 10),
        );
        await service.getDailyRatesToEur(
          'USD',
          from: DateTime(2024, 1, 5),
          to: DateTime(2024, 1, 10),
        );
      }, () => mockClient);

      expect(callCount, equals(1));
    });

    test('échec HTTP (500) → ExchangeRateUnavailable, JAMAIS un repli silencieux', () async {
      final service = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response('erreur serveur', 500);
      });

      expect(
        () => http.runWithClient(
          () => service.getDailyRatesToEur(
            'USD',
            from: DateTime(2024, 1, 5),
            to: DateTime(2024, 1, 10),
          ),
          () => mockClient,
        ),
        throwsA(isA<ExchangeRateUnavailable>()),
      );
    });

    test('réponse illisible (JSON sans champ "rates") → ExchangeRateUnavailable', () async {
      final service = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response('{"amount":1.0}', 200);
      });

      expect(
        () => http.runWithClient(
          () => service.getDailyRatesToEur(
            'USD',
            from: DateTime(2024, 1, 5),
            to: DateTime(2024, 1, 10),
          ),
          () => mockClient,
        ),
        throwsA(isA<ExchangeRateUnavailable>()),
      );
    });

    // M-3 (revue adversariale, mineur) : une réponse 200 avec `rates: {}`
    // (ex. période hors couverture frankfurter) n'est PAS un succès — sans le
    // correctif, `getDailyRatesToEur` renverrait silencieusement une map vide
    // ET la mettrait en cache, empêchant toute nouvelle tentative sur la même
    // période élargie pour le reste de la durée de vie de l'instance.
    test('réponse 200 avec "rates" VIDE → ExchangeRateUnavailable, JAMAIS mis en cache', () async {
      final service = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({}), 200);
      });

      Future<void> attempt() => http.runWithClient(
            () => service.getDailyRatesToEur(
              'USD',
              from: DateTime(2024, 1, 5),
              to: DateTime(2024, 1, 10),
            ),
            () => mockClient,
          );

      await expectLater(attempt(), throwsA(isA<ExchangeRateUnavailable>()));
      // Deuxième tentative sur la MÊME période élargie : si la série vide
      // avait été mise en cache, cet appel serait servi depuis le cache SANS
      // relancer de requête HTTP (callCount resterait au nombre de tentatives
      // du premier essai, cf. `retryWithBackoff`) — ici il doit repartir en
      // réseau, preuve qu'aucune entrée n'a été écrite dans `_dailyRatesCache`.
      final countAfterFirst = callCount;
      await expectLater(attempt(), throwsA(isA<ExchangeRateUnavailable>()));
      expect(callCount, greaterThan(countAfterFirst));
    }, timeout: const Timeout(Duration(seconds: 15))); // retries avec backoff.
  });
}

// test/services/crypto_valuation_service_test.dart
//
// Tests de CryptoValuationService.resolve (chantier B16, lot 2 — conception
// interne), couche I/O : cascade lisibilité → spread → FX historique pour
// l'étage 1 « fichier » du moteur de valorisation. Fixtures 100 % SYNTHÉTIQUES
// (codes AAA/BBB/STB…, montants ronds inventés). Aucun appel réseau réel — même
// patron que `exchange_rate_service_daily_test.dart` (`http.runWithClient` +
// `MockClient`).

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/services/crypto_valuation_service.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';

String _frankfurterBody(Map<String, double> ratesByDay) {
  final entries = ratesByDay.entries
      .map((e) => '"${e.key}":{"EUR":${e.value}}')
      .join(',');
  return '{"amount":1.0,"base":"USD","rates":{$entries}}';
}

UnvaluedExchange _exchange({
  required String importKey,
  required DateTime date,
  String codePaid = 'AAA',
  String quantityPaid = '2',
  String codeReceived = 'STB',
  String quantityReceived = '99',
  String? usdPaid,
  String? usdReceived,
}) =>
    UnvaluedExchange(
      kind: 'exchange',
      date: date,
      codePaid: codePaid,
      quantityPaid: quantityPaid,
      codeReceived: codeReceived,
      quantityReceived: quantityReceived,
      usdPaid: usdPaid,
      usdReceived: usdReceived,
      sourceLines: const [5],
      importKey: importKey,
      seq: 1,
    );

void main() {
  group('CryptoValuationService.resolve — cascade lisibilité/spread', () {
    test('aucune ligne valorisable (colonne amountusd absente) → AUCUN appel réseau', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(importKey: 'ref:a1:R1', date: DateTime(2024, 1, 5)),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(0));
      expect(resolution.valuations, isEmpty);
      expect(resolution.manual, hasLength(1));
      expect(resolution.manual.single.reason,
          equals(CryptoValuationManualReason.unreadable));
    });

    test('écart > 10 % entre les deux jambes → arbitrage manuel (spread), motif ET écart exposés', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:R2',
            date: DateTime(2024, 1, 5),
            usdPaid: '100',
            usdReceived: '115', // écart +15 %, au-delà du seuil de 10 %.
          ),
        ]),
        () => mockClient,
      );

      expect(resolution.valuations, isEmpty);
      expect(resolution.manual, hasLength(1));
      final m = resolution.manual.single;
      expect(m.reason, equals(CryptoValuationManualReason.spread));
      expect(Decimal.parse(m.valuationSpreadPct!),
          equals(Decimal.parse('0.15')));
    });

    test('écart ≤ 10 % → VALORISÉ (spread restitué pour l\'affichage, pas un blocage)', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:R3',
            date: DateTime(2024, 1, 5),
            usdPaid: '100',
            usdReceived: '105', // écart +5 %, sous le seuil.
          ),
        ]),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:R3']!;
      // Jambe PAYÉE retenue en priorité (conception interne) : 100 USD.
      expect(v.valuationUsd, equals(Decimal.parse('100')));
      expect(v.amountEur, equals(Decimal.parse('90'))); // 100 × 0,9
      expect(Decimal.parse(v.spreadPct!), equals(Decimal.parse('0.05')));
      expect(v.source, equals('statement'));
    });

    test('une seule jambe lisible (usdReceived) → valorisée SANS comparaison de spread', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:R4',
            date: DateTime(2024, 1, 5),
            usdPaid: null,
            usdReceived: '50',
          ),
        ]),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:R4']!;
      expect(v.valuationUsd, equals(Decimal.parse('50')));
      expect(v.spreadPct, isNull);
    });

    test('littéral "-" (illisible) sur les deux jambes → arbitrage manuel, AUCUN appel réseau', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      // Le moteur pose `null` (pas le littéral) pour une valeur illisible —
      // cf. `CryptoLedgerNormalizer` : `valuationUsd: ... ? null : parse(...)`.
      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(importKey: 'ref:a1:R5', date: DateTime(2024, 1, 5)),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(0));
      expect(resolution.manual.single.reason,
          equals(CryptoValuationManualReason.unreadable));
    });

    test('une seule récupération FX pour PLUSIEURS échanges (bornes englobantes)', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(
          _frankfurterBody({'2024-01-05': 0.9, '2024-02-10': 0.95}),
          200,
        );
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:R6',
            date: DateTime(2024, 1, 5),
            usdPaid: '10',
          ),
          _exchange(
            importKey: 'ref:a1:R7',
            date: DateTime(2024, 2, 10),
            usdPaid: '20',
          ),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(1));
      expect(resolution.valuations, hasLength(2));
    });

    test('FX indisponible (échec réseau) → LÈVE ExchangeRateUnavailable, PROPAGÉE (pas de repli ici)', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response('erreur', 500);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      await expectLater(
        http.runWithClient(
          () => service.resolve([
            _exchange(
              importKey: 'ref:a1:R8',
              date: DateTime(2024, 1, 5),
              usdPaid: '10',
            ),
          ]),
          () => mockClient,
        ),
        throwsA(isA<ExchangeRateUnavailable>()),
      );
    });

    test('date week-end → taux du dernier jour ouvré ANTÉRIEUR, jamais interpolé', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        // Série À TROUS : le week-end (samedi 13, dimanche 14) est ABSENT,
        // comme la vraie réponse frankfurter — seul le vendredi 12 est publié.
        return http.Response(
          _frankfurterBody({'2024-01-12': 0.88, '2024-01-15': 0.89}),
          200,
        );
      });
      final service = CryptoValuationService(exchangeService: rateService);

      // Échange daté SAMEDI 13/01/2024 (absent de la série).
      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:R9',
            date: DateTime(2024, 1, 13),
            usdPaid: '100',
          ),
        ]),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:R9']!;
      // Dernier jour ouvré ANTÉRIEUR = vendredi 12/01, PAS le lundi suivant
      // (15/01, postérieur) ni une moyenne interpolée des deux.
      expect(v.fxDate, equals(DateTime(2024, 1, 12)));
      expect(v.fxRate, equals(0.88));
      expect(v.amountEur, equals(Decimal.parse('88'))); // 100 × 0,88
    });
  });

  group('CryptoValuationService.resolve — B-1 (revue adversariale, BLOQUANT)', () {
    test(
        'clé importKey PARTAGÉE par 2 entrées → AUCUNE des deux valorisée, '
        'motif ambiguousGroup, ZÉRO appel réseau', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      // Les deux entrées sont par ailleurs PARFAITEMENT valorisables (USD
      // lisible, pas d'écart) — seule leur clé PARTAGÉE doit les écarter,
      // reproduisant le repli dégénéré du dustsweeping N→1 à `amountusd`
      // partiellement illisible (`CryptoLedgerNormalizer._processExchangeGroup`).
      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:RSHARED',
            date: DateTime(2024, 1, 5),
            codePaid: 'CCC',
            usdPaid: '10',
          ),
          _exchange(
            importKey: 'ref:a1:RSHARED', // MÊME clé.
            date: DateTime(2024, 1, 5),
            codePaid: 'DDD',
            usdPaid: '20',
          ),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(0)); // aucune candidate valorisable.
      expect(resolution.valuations, isEmpty);
      expect(resolution.manual, hasLength(2));
      expect(
        resolution.manual
            .every((m) => m.reason == CryptoValuationManualReason.ambiguousGroup),
        isTrue,
      );
    });

    test('clé UNIQUE parmi d\'autres partagées → seule celle-ci reste valorisable', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(importKey: 'ref:a1:RSOLO', date: DateTime(2024, 1, 5), usdPaid: '10'),
          _exchange(
              importKey: 'ref:a1:RSHARED2',
              date: DateTime(2024, 1, 5),
              codePaid: 'CCC',
              usdPaid: '10'),
          _exchange(
              importKey: 'ref:a1:RSHARED2',
              date: DateTime(2024, 1, 5),
              codePaid: 'DDD',
              usdPaid: '20'),
        ]),
        () => mockClient,
      );

      expect(resolution.valuations.keys, equals(['ref:a1:RSOLO']));
      expect(resolution.manual, hasLength(2));
      expect(
        resolution.manual
            .every((m) => m.reason == CryptoValuationManualReason.ambiguousGroup),
        isTrue,
      );
    });
  });

  group('CryptoValuationService.resolve — M-1 (revue adversariale, mineur)', () {
    test('maxLegValuationSpread par défaut reste 0.10 (Kraken inchangé)', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:RM1A',
            date: DateTime(2024, 1, 5),
            usdPaid: '100',
            usdReceived: '111', // écart +11 %, au-delà du défaut 10 %.
          ),
        ]),
        () => mockClient,
      );

      expect(resolution.valuations, isEmpty);
      expect(resolution.manual.single.reason,
          equals(CryptoValuationManualReason.spread));
    });

    test('seuil ÉLARGI (profil non-Kraken hypothétique) → un écart de 11 % passe', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve(
          [
            _exchange(
              importKey: 'ref:a1:RM1B',
              date: DateTime(2024, 1, 5),
              usdPaid: '100',
              usdReceived: '111', // écart +11 %, sous un seuil élargi à 15 %.
            ),
          ],
          maxLegValuationSpread: 0.15,
        ),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      expect(resolution.valuations, hasLength(1));
    });
  });
}

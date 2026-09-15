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

    test(
        'jambe stable STB déclarée + spread > 10 % → repli étage 1-ter, '
        'valorisé à la quantité NETTE de STB, source stableLeg, spread consigné',
        () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve(
          [
            _exchange(
              importKey: 'ref:a1:RSTB1',
              date: DateTime(2024, 1, 5),
              // codeReceived/quantityReceived par défaut : 'STB'/'99'.
              usdPaid: '100',
              usdReceived: '115', // écart +15 %, au-delà du seuil.
            ),
          ],
          usdStableCodes: {'STB'},
        ),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:RSTB1']!;
      // Quantité NETTE de la jambe STB (99), PAS la jambe payée USD (100).
      expect(v.valuationUsd, equals(Decimal.parse('99')));
      expect(v.amountEur, equals(Decimal.parse('89.1'))); // 99 × 0,9
      expect(v.source, equals('stableLeg'));
      // Écart calculé malgré le repli, consigné pour l'affichage.
      expect(Decimal.parse(v.spreadPct!), equals(Decimal.parse('0.15')));
    });

    test(
        'jambe stable STB déclarée + amountusd illisible des DEUX côtés → '
        'même repli étage 1-ter, spread NON consigné (rien à comparer)',
        () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve(
          [
            _exchange(
              importKey: 'ref:a1:RSTB2',
              date: DateTime(2024, 1, 5),
              // usdPaid/usdReceived absents (illisibles) par défaut.
            ),
          ],
          usdStableCodes: {'STB'},
        ),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:RSTB2']!;
      expect(v.valuationUsd, equals(Decimal.parse('99')));
      expect(v.source, equals('stableLeg'));
      expect(v.spreadPct, isNull);
    });

    test(
        'AUCUNE jambe stable déclarée pour ce code + spread > 10 % → reste '
        'manuel motif spread, INCHANGÉ (le repli 1-ter ne s\'applique pas)',
        () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve(
          [
            _exchange(
              importKey: 'ref:a1:RNOSTB',
              date: DateTime(2024, 1, 5),
              usdPaid: '100',
              usdReceived: '115', // écart +15 %.
            ),
          ],
          // 'STB' n'y figure PAS : aucune jambe de confiance pour cet échange.
          usdStableCodes: {'OTHERCOIN'},
        ),
        () => mockClient,
      );

      expect(resolution.valuations, isEmpty);
      expect(resolution.manual, hasLength(1));
      expect(resolution.manual.single.reason,
          equals(CryptoValuationManualReason.spread));
    });

    test(
        'jambe stable STB déclarée MAIS spread ≤ 10 % → étage 1 NORMAL '
        '(jambe payée, source statement) — le repli 1-ter ne s\'applique '
        'JAMAIS quand l\'étage 1 a réussi', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve(
          [
            _exchange(
              importKey: 'ref:a1:RSTB3',
              date: DateTime(2024, 1, 5),
              usdPaid: '100',
              usdReceived: '105', // écart +5 %, sous le seuil.
            ),
          ],
          usdStableCodes: {'STB'},
        ),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:RSTB3']!;
      // Jambe PAYÉE (100), PAS la quantité de STB (99) — comportement de
      // l'étage 1 inchangé.
      expect(v.valuationUsd, equals(Decimal.parse('100')));
      expect(v.source, equals('statement'));
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

  group(
      'CryptoValuationService.resolve — suggestions EUR (amendement drive '
      'lot 2 (suite))', () {
    test(
        'écart > seuil, AUCUNE jambe stable → reste manuel motif spread, '
        'AVEC les deux suggestions EUR EXACTES (taux mocké)', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(
            importKey: 'ref:a1:RSUG1',
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
      // 100 × 0,9 = 90 ; 115 × 0,9 = 103,5 — conversions EXACTES, même règle
      // que l'étage 1 (point 4 de la cascade).
      expect(m.suggestedPaidEur, equals(Decimal.parse('90')));
      expect(m.suggestedReceivedEur, equals(Decimal.parse('103.5')));
    });

    test(
        'motif unreadable (aucune jambe lisible) → AUCUNE suggestion, ZÉRO '
        'appel réseau (rien à convertir)', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(importKey: 'ref:a1:RSUG2', date: DateTime(2024, 1, 5)),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(0));
      final m = resolution.manual.single;
      expect(m.reason, equals(CryptoValuationManualReason.unreadable));
      expect(m.suggestedPaidEur, isNull);
      expect(m.suggestedReceivedEur, isNull);
    });

    test(
        'motif foreignFiat (jambe fiat NON-USD, ex. GBP — depuis l\'amendement '
        '(voie ii), seule `USD` est valorisée automatiquement à '
        'l\'étage 1-quater, cf. crypto_ledger_kraken_lot1_test.dart) → '
        'AUCUNE suggestion, ZÉRO appel réseau', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 1, 5),
            codePaid: 'GBP',
            quantityPaid: '100',
            codeReceived: 'AAA',
            quantityReceived: '2',
            usdPaid: '100',
            usdReceived: '100',
            sourceLines: const [7],
            importKey: 'ref:a1:RSUG3',
            codePaidIsFiat: true,
          ),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(0));
      final m = resolution.manual.single;
      expect(m.reason, equals(CryptoValuationManualReason.foreignFiat));
      expect(m.suggestedPaidEur, isNull);
      expect(m.suggestedReceivedEur, isNull);
    });

    test(
        'écart > seuil MAIS jambe stable déclarée → repli 1-ter (valorisé, '
        'PAS manuel) : aucune suggestion à produire, le cas ne s\'y prête '
        'même pas (contrôle négatif de la cascade)', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve(
          [
            _exchange(
              importKey: 'ref:a1:RSUG4',
              date: DateTime(2024, 1, 5),
              usdPaid: '100',
              usdReceived: '115',
            ),
          ],
          usdStableCodes: {'STB'},
        ),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      expect(resolution.valuations, hasLength(1));
    });

    test(
        'un échange sans suggestion (unreadable) N\'EMPÊCHE PAS la '
        'récupération FX pour un autre échange en spread dans le MÊME appel '
        '— une seule requête réseau pour les deux', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          _exchange(importKey: 'ref:a1:RSUG5A', date: DateTime(2024, 1, 5)),
          _exchange(
            importKey: 'ref:a1:RSUG5B',
            date: DateTime(2024, 1, 5),
            usdPaid: '100',
            usdReceived: '115',
          ),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(1));
      final unreadable = resolution.manual
          .firstWhere((m) => m.source.importKey == 'ref:a1:RSUG5A');
      expect(unreadable.suggestedPaidEur, isNull);
      final spread = resolution.manual
          .firstWhere((m) => m.source.importKey == 'ref:a1:RSUG5B');
      expect(spread.suggestedPaidEur, equals(Decimal.parse('90')));
      expect(spread.suggestedReceivedEur, equals(Decimal.parse('103.5')));
    });
  });

  group(
      'CryptoValuationService.resolve — étage 1-quater (amendement, '
      'voie ii, jambe fiat ÉTRANGÈRE USD)', () {
    test(
        'échange PROPRE crypto↔USD (USD payé) → valorisé source `fiatLeg`, '
        'quantité NETTE de la jambe USD (PAS `amountusd`), aucune '
        'suggestion (motif non-manuel)', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 1, 5),
            codePaid: 'USD',
            // Quantité NETTE de la jambe USD elle-même — DOIT être retenue
            // telle quelle, PAS la colonne `amountusd` (`usdPaid` ci-dessous,
            // volontairement DIFFÉRENTE pour distinguer les deux sources).
            quantityPaid: '100',
            codeReceived: 'AAA',
            quantityReceived: '2',
            usdPaid: '999', // jamais lu pour la jambe fiat elle-même.
            sourceLines: const [5],
            importKey: 'ref:a1:RFL1',
            codePaidIsFiat: true,
          ),
        ]),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:RFL1']!;
      expect(v.source, equals('fiatLeg'));
      expect(v.valuationUsd, equals(Decimal.parse('100')));
      expect(v.fxRate, equals(0.9));
      expect(v.fxDate, equals(DateTime(2024, 1, 5)));
      expect(v.amountEur, equals(Decimal.parse('90'))); // 100 × 0,9
      expect(v.spreadPct, isNull); // aucun spread pour une jambe fiat.
    });

    test(
        'échange PROPRE crypto↔USD (USD reçu) → valorisé source `fiatLeg`, '
        'même règle dans l\'AUTRE sens', () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-02-01': 0.85}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 2, 1),
            codePaid: 'BBB',
            quantityPaid: '4',
            codeReceived: 'USD',
            quantityReceived: '40',
            sourceLines: const [5],
            importKey: 'ref:a1:RFL2',
            codeReceivedIsFiat: true,
          ),
        ]),
        () => mockClient,
      );

      expect(resolution.manual, isEmpty);
      final v = resolution.valuations['ref:a1:RFL2']!;
      expect(v.source, equals('fiatLeg'));
      expect(v.valuationUsd, equals(Decimal.parse('40')));
      expect(v.amountEur, equals(Decimal.parse('34'))); // 40 × 0,85
    });

    test(
        'FX indisponible pour une jambe fiat USD (échec réseau) → LÈVE '
        'ExchangeRateUnavailable, PROPAGÉE (même politique que le chemin '
        'ordinaire — aucune coercition, aucun repli foreignFiat silencieux)',
        () async {
      final rateService = ExchangeRateService.forTesting();
      final mockClient = MockClient((request) async {
        return http.Response('erreur', 500);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      await expectLater(
        http.runWithClient(
          () => service.resolve([
            UnvaluedExchange(
              kind: 'exchange',
              date: DateTime(2024, 1, 5),
              codePaid: 'USD',
              quantityPaid: '100',
              codeReceived: 'AAA',
              quantityReceived: '2',
              sourceLines: const [5],
              importKey: 'ref:a1:RFL3',
              codePaidIsFiat: true,
            ),
          ]),
          () => mockClient,
        ),
        throwsA(isA<ExchangeRateUnavailable>()),
      );
    });

    test(
        'clé PARTAGÉE (B-1) impliquant une jambe fiat USD → reste '
        '`ambiguousGroup`, JAMAIS résolue automatiquement même si USD, '
        'ZÉRO appel réseau', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final shared = [
        UnvaluedExchange(
          kind: 'exchange',
          date: DateTime(2024, 1, 5),
          codePaid: 'CCC',
          quantityPaid: '5',
          codeReceived: 'USD',
          quantityReceived: '30',
          sourceLines: const [7],
          importKey: 'ref:a1:RFL4', // clé PARTAGÉE.
          codeReceivedIsFiat: true,
        ),
        UnvaluedExchange(
          kind: 'exchange',
          date: DateTime(2024, 1, 5),
          codePaid: 'DDD',
          quantityPaid: '3',
          codeReceived: 'USD',
          quantityReceived: '10',
          sourceLines: const [8],
          importKey: 'ref:a1:RFL4', // MÊME clé.
          codeReceivedIsFiat: true,
        ),
      ];

      final resolution = await http.runWithClient(
        () => service.resolve(shared),
        () => mockClient,
      );

      expect(callCount, equals(0));
      expect(resolution.valuations, isEmpty);
      expect(resolution.manual, hasLength(2));
      expect(
        resolution.manual
            .every((m) => m.reason == CryptoValuationManualReason.ambiguousGroup),
        isTrue,
      );
    });

    test(
        'T-3/I-2 : entrée à DEUX jambes fiat (double flag — jamais produite '
        'par le moteur réel, robustesse défensive) → reste `foreignFiat`, '
        'ZÉRO appel réseau, JAMAIS résolue automatiquement même si l\'une '
        'des deux vaut littéralement USD', () async {
      final rateService = ExchangeRateService.forTesting();
      var callCount = 0;
      final mockClient = MockClient((request) async {
        callCount++;
        return http.Response(_frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final service = CryptoValuationService(exchangeService: rateService);

      final resolution = await http.runWithClient(
        () => service.resolve([
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 1, 5),
            codePaid: 'USD',
            quantityPaid: '50',
            codeReceived: 'GBP',
            quantityReceived: '40',
            sourceLines: const [9],
            importKey: 'ref:a1:RFL5',
            codePaidIsFiat: true,
            codeReceivedIsFiat: true,
          ),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(0));
      expect(resolution.valuations, isEmpty);
      final m = resolution.manual.single;
      expect(m.reason, equals(CryptoValuationManualReason.foreignFiat));
    });

    test(
        'T-5 : un échange fiatLeg (USD) ET un échange crypto↔crypto '
        'ordinaire partagent la MÊME fenêtre FX → UN SEUL appel réseau, les '
        'DEUX valorisés', () async {
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
            importKey: 'ref:a1:RT5a',
            date: DateTime(2024, 1, 5),
            usdPaid: '10',
          ),
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 2, 10),
            codePaid: 'USD',
            quantityPaid: '20',
            codeReceived: 'BBB',
            quantityReceived: '3',
            sourceLines: const [9],
            importKey: 'ref:a1:RT5b',
            codePaidIsFiat: true,
          ),
        ]),
        () => mockClient,
      );

      expect(callCount, equals(1));
      expect(resolution.manual, isEmpty);
      final v1 = resolution.valuations['ref:a1:RT5a']!;
      expect(v1.source, equals('statement'));
      expect(v1.amountEur, equals(Decimal.parse('9'))); // 10 × 0,9
      final v2 = resolution.valuations['ref:a1:RT5b']!;
      expect(v2.source, equals('fiatLeg'));
      expect(v2.amountEur, equals(Decimal.parse('19'))); // 20 × 0,95
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

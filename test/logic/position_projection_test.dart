// test/logic/position_projection_test.dart
//
// Moteur de projection B* (arithmétique Decimal exacte) + parité avec
// computeTransactionAnalytics (qui est réimplémenté par-dessus le même rejeu).

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/logic/transaction_analytics.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';

AssetTransaction _tx({
  required String id,
  required TransactionKind kind,
  String? quantity,
  String? unitPrice,
  String? fee,
  DateTime? date,
}) {
  return AssetTransaction(
    id: id,
    accountId: 'acc1',
    symbol: 'TEST',
    kind: kind,
    quantity: quantity,
    unitPrice: unitPrice,
    fee: fee,
    currency: 'EUR',
    date: date ?? DateTime(2024, 1, int.parse(id)),
  );
}

void main() {
  group('projectPosition — quantité exacte (Decimal)', () {
    test('journal vide → quantité "0", PRU null', () {
      final p = projectPosition([]);
      expect(p.quantity, Decimal.zero);
      expect(p.quantity.toString(), '0');
      expect(p.averagePrice, isNull);
    });

    test('buys fractionnaires 0.1 + 0.2 → quantité EXACTE "0.3" (aucune dérive)',
        () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '0.1', unitPrice: '10', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '0.2', unitPrice: '10', date: DateTime(2024, 1, 2)),
      ]);
      // En double, 0.1 + 0.2 == 0.30000000000000004 : ici la String est canonique.
      expect(p.quantity.toString(), '0.3');
    });

    test('somme de nombreux 0.1 → String canonique sans zéros de fin', () {
      final txs = List.generate(
        10,
        (i) => _tx(
          id: '${i + 1}',
          kind: TransactionKind.buy,
          quantity: '0.1',
          unitPrice: '1',
          date: DateTime(2024, 1, i + 1),
        ),
      );
      final p = projectPosition(txs);
      expect(p.quantity.toString(), '1'); // 10 × 0.1 = 1 exact, pas "1.0"
    });

    test('quantité entière → String sans partie décimale', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100'),
      ]);
      expect(p.quantity.toString(), '10');
    });
  });

  group('projectPosition — PRU pondéré', () {
    test('buy 10@100 puis buy 10@200 → PRU 150', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '200', date: DateTime(2024, 1, 2)),
      ]);
      expect(p.quantity.toString(), '20');
      expect(p.averagePrice, closeTo(150.0, 1e-9));
    });

    test('openingBalance 10@50 puis buy 10@100 → PRU 75', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '50', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      expect(p.quantity.toString(), '20');
      expect(p.averagePrice, closeTo(75.0, 1e-9));
    });

    test('buy avec frais → PRU inclut les frais', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', fee: '5'),
      ]);
      expect(p.averagePrice, closeTo(100.5, 1e-9));
    });
  });

  group('projectPosition — adjustment / survente / clamp', () {
    test('adjustment négatif retire q×unitPrice, PRU conservé', () {
      // buy 10@100, adjustment -3@100 → 7 titres, PRU 100
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.adjustment, quantity: '-3', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      expect(p.quantity.toString(), '7');
      expect(p.averagePrice, closeTo(100.0, 1e-9));
    });

    test('adjustment négatif au-delà du stock → clamp quantité "0", PRU null', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.adjustment, quantity: '-10', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      expect(p.quantity, Decimal.zero);
      expect(p.quantity.toString(), '0');
      expect(p.averagePrice, isNull);
    });

    test('survente (vente > stock) → quantité "0", PRU null (pas de crash)', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '10', unitPrice: '150', date: DateTime(2024, 1, 2)),
      ]);
      expect(p.quantity, Decimal.zero);
      expect(p.averagePrice, isNull);
    });

    test('vente totale → quantité "0", PRU null', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '10', unitPrice: '120', date: DateTime(2024, 1, 2)),
      ]);
      expect(p.quantity.toString(), '0');
      expect(p.averagePrice, isNull);
    });
  });

  group('projectPosition — tri et ignorés', () {
    test('ordre d\'entrée indifférent (tri interne date puis id)', () {
      final a = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '200', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      final b = projectPosition([
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 2)),
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '200', date: DateTime(2024, 1, 1)),
      ]);
      expect(a.quantity.toString(), b.quantity.toString());
      expect(a.averagePrice, closeTo(b.averagePrice!, 1e-9));
    });

    test('dividend / deposit / withdrawal ignorés', () {
      final p = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 1)),
        AssetTransaction(id: '2', accountId: 'acc1', symbol: 'TEST', kind: TransactionKind.dividend, amount: '50', currency: 'EUR', date: DateTime(2024, 1, 2)),
        AssetTransaction(id: '3', accountId: 'acc1', symbol: null, kind: TransactionKind.deposit, amount: '500', currency: 'EUR', date: DateTime(2024, 1, 3)),
      ]);
      expect(p.quantity.toString(), '5');
      expect(p.averagePrice, closeTo(100.0, 1e-9));
    });
  });

  group('PARITÉ computeTransactionAnalytics(double) ↔ projectPosition(Decimal)', () {
    // Jeux communs : la quantité double des analytics doit égaler la projection
    // Decimal convertie, et les PRU doivent coïncider (même rejeu sous-jacent).
    final commonSets = <List<AssetTransaction>>[
      [],
      [_tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', fee: '5')],
      [
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '200', date: DateTime(2024, 1, 2)),
      ],
      [
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '4', unitPrice: '150', fee: '0', date: DateTime(2024, 1, 2)),
      ],
      [
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '50', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.adjustment, quantity: '-3', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ],
      [
        _tx(id: '1', kind: TransactionKind.buy, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '10', unitPrice: '150', date: DateTime(2024, 1, 2)),
      ],
    ];

    for (var i = 0; i < commonSets.length; i++) {
      test(
          'jeu #$i : netQuantity == quantity.toDouble(), PRU et realizedGain '
          'identiques', () {
        final txs = commonSets[i];
        final analytics = computeTransactionAnalytics(txs);
        final proj = projectPosition(txs);
        final replay = replayLedger(txs);

        expect(analytics.netQuantity, equals(proj.quantity.toDouble()),
            reason: 'quantité double doit égaler la projection Decimal convertie');

        if (proj.averagePrice == null) {
          expect(analytics.suggestedAveragePrice, isNull);
        } else {
          expect(analytics.suggestedAveragePrice, closeTo(proj.averagePrice!, 1e-9));
        }

        // M4 : la plus-value réalisée doit elle aussi être en parité — les deux
        // moteurs partagent le même rejeu ([replayLedger]).
        expect(analytics.realizedGain, closeTo(replay.realizedGain, 1e-9),
            reason: 'realizedGain doit être identique entre les deux moteurs');
      });
    }

    test(
        'jeu SELL avec plus-value réalisée : buy 10@100 puis sell 4@150 '
        '(sans frais) → realizedGain == 200.0 exact', () {
      // Coût des 4 titres cédés : PRU 100 × 4 = 400. Produit de cession : 4×150
      // = 600. Plus-value réalisée = 600 − 400 = 200.
      final txs = [
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '4', unitPrice: '150', fee: '0', date: DateTime(2024, 1, 2)),
      ];
      final analytics = computeTransactionAnalytics(txs);
      final replay = replayLedger(txs);

      expect(analytics.realizedGain, closeTo(200.0, 1e-9));
      expect(replay.realizedGain, closeTo(200.0, 1e-9));
    });

    test(
        'jeu SELL avec frais : buy 10@100 puis sell 4@150 fee 10 → '
        'realizedGain == 190.0 (frais déduits du produit de cession)', () {
      // Produit net de cession : 4×150 − 10 = 590. Coût cédé : 100×4 = 400.
      // Plus-value réalisée = 590 − 400 = 190.
      final txs = [
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '4', unitPrice: '150', fee: '10', date: DateTime(2024, 1, 2)),
      ];
      final analytics = computeTransactionAnalytics(txs);

      expect(analytics.realizedGain, closeTo(190.0, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // PROJECTION CASH (lot « cash comme projection du journal »)
  //
  // Invariant de partition : la projection cash lit UNIQUEMENT amount.
  // Sign-agnostique, sans clamp, par devise.
  // ---------------------------------------------------------------------------

  AssetTransaction cashTx({
    required String id,
    required TransactionKind kind,
    String? symbol,
    String? amount,
    String? quantity,
    String? unitPrice,
    String? fee,
    String currency = 'EUR',
    String? settlementCurrency,
    DateTime? date,
  }) {
    return AssetTransaction(
      id: id,
      accountId: 'acc1',
      symbol: symbol,
      kind: kind,
      quantity: quantity,
      unitPrice: unitPrice,
      amount: amount,
      fee: fee,
      currency: currency,
      settlementCurrency: settlementCurrency,
      date: date ?? DateTime(2024, 1, int.parse(id)),
    );
  }

  group('replayLedger — projection cash (Σ amount par devise)', () {
    test('journal vide → cashByCurrency vide', () {
      expect(replayLedger([]).cashByCurrency, isEmpty);
    });

    test('conservation : Σ amount signé (deposit + buy + sell)', () {
      // +1000 (deposit) −1502 (buy) +1995 (sell) = 1493.
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.deposit, amount: '1000', date: DateTime(2024, 1, 1)),
        cashTx(id: '2', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-1502', quantity: '10', unitPrice: '150', fee: '2', date: DateTime(2024, 1, 2)),
        cashTx(id: '3', kind: TransactionKind.sell, symbol: 'AAPL', amount: '1995', quantity: '10', unitPrice: '200', fee: '5', date: DateTime(2024, 1, 3)),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '1493');
    });

    test('agnostique au signe : charge négatif ET rebate positif se somment', () {
      // interest +3.14, charge −12, charge rebate +5 → −3.86.
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.interest, amount: '3.14'),
        cashTx(id: '2', kind: TransactionKind.charge, amount: '-12'),
        cashTx(id: '3', kind: TransactionKind.charge, amount: '5'),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '-3.86');
    });

    test('PAS de clamp à 0 : un solde négatif reste négatif', () {
      // Un seul buy sans dépôt → cash négatif (journal partiel / marge).
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-500', quantity: '5', unitPrice: '100'),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '-500');
    });

    test('exact décimal : 0.1 + 0.2 en amount → "0.3" (aucune dérive double)', () {
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.deposit, amount: '0.1'),
        cashTx(id: '2', kind: TransactionKind.deposit, amount: '0.2'),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '0.3');
    });

    test('multi-devises : chaque devise a son propre total (jamais sommées)', () {
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.deposit, amount: '1000', currency: 'EUR'),
        cashTx(id: '2', kind: TransactionKind.deposit, amount: '500', currency: 'USD'),
        cashTx(id: '3', kind: TransactionKind.withdrawal, amount: '-200', currency: 'USD'),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '1000');
      expect(r.cashByCurrency['USD'].toString(), '300');
    });

    test('openingBalance TITRE (amount null) N\'AFFECTE PAS le cash', () {
      // Lot titre déclaratif : quantité/prix portent la position, amount=null.
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.openingBalance, symbol: 'AAPL', quantity: '10', unitPrice: '100', amount: null),
      ]);
      // Aucun mouvement cash : la devise n'apparaît même pas.
      expect(r.cashByCurrency, isEmpty);
      // ... mais la position titre, elle, est bien projetée.
      expect(r.quantity.toString(), '10');
    });

    test('openingBalance ESPÈCES (symbol null, amount signé) alimente le cash', () {
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.openingBalance, symbol: null, amount: '2500'),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '2500');
      // Aucune position titre (symbol null, quantity null).
      expect(r.quantity.toString(), '0');
    });

    test('partition : le fee N\'est JAMAIS re-soustrait du cash (pas de double compte)', () {
      // amount d'un buy inclut déjà le fee : −(10×150 + 2) = −1502. Le cash doit
      // valoir exactement −1502, PAS −1504 (fee re-déduit).
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-1502', quantity: '10', unitPrice: '150', fee: '2'),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '-1502');
    });

    // ---- Devise de RÈGLEMENT (settlementCurrency, design §8) ----

    test('settlementCurrency=EUR sur titre USD → bucket EUR (PAS USD)', () {
      // CTO € détenant AAPL coté USD : cotation USD, règlement EUR figé.
      final r = replayLedger([
        cashTx(
          id: '1',
          kind: TransactionKind.buy,
          symbol: 'AAPL',
          amount: '-1620.00', // net réglé EUR
          quantity: '10',
          unitPrice: '175.50', // cotation USD
          fee: '1.99',
          currency: 'USD',
          settlementCurrency: 'EUR',
        ),
      ]);
      // Decimal normalise les zéros de fin (-1620.00 → -1620).
      expect(r.cashByCurrency['EUR'].toString(), '-1620');
      // AUCUNE poche USD fictive (le bug §8 corrigé).
      expect(r.cashByCurrency.containsKey('USD'), isFalse);
      // La projection titre reste en cotation USD (q inchangée).
      expect(r.quantity.toString(), '10');
    });

    test('settlementCurrency null → retombe sur currency (legacy préservé)', () {
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.deposit, amount: '500', currency: 'USD'),
      ]);
      expect(r.cashByCurrency['USD'].toString(), '500');
      expect(r.cashByCurrency.containsKey('EUR'), isFalse);
    });

    test('mono + croisé sur le MÊME compte : tout tombe dans le bucket règlement', () {
      // Un dépôt EUR natif + un achat USD réglé EUR → un seul bucket EUR, jamais
      // de bucket USD (les devises ne sont pas sommées, mais ici le règlement
      // est homogène = EUR).
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.deposit, amount: '2000', currency: 'EUR'),
        cashTx(
          id: '2',
          kind: TransactionKind.buy,
          symbol: 'AAPL',
          amount: '-1620.00',
          quantity: '10',
          unitPrice: '175.50',
          currency: 'USD',
          settlementCurrency: 'EUR',
        ),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '380'); // 2000 − 1620.00
      expect(r.cashByCurrency.containsKey('USD'), isFalse);
    });

    test('buckets de règlement hétérogènes : jamais sommés', () {
      final r = replayLedger([
        cashTx(id: '1', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-1620', quantity: '10', unitPrice: '175', currency: 'USD', settlementCurrency: 'EUR'),
        // Ligne legacy USD (règlement = cotation USD car settlement null).
        cashTx(id: '2', kind: TransactionKind.buy, symbol: 'MSFT', amount: '-500', quantity: '2', unitPrice: '250', currency: 'USD'),
      ]);
      expect(r.cashByCurrency['EUR'].toString(), '-1620');
      expect(r.cashByCurrency['USD'].toString(), '-500');
    });
  });

  group('journalHasCashAnchor — opt-in « espèces suivies »', () {
    test('buys seuls → PAS d\'ancrage (cash dérivé non affiché)', () {
      expect(
        journalHasCashAnchor([
          cashTx(id: '1', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-500', quantity: '5', unitPrice: '100'),
        ]),
        isFalse,
      );
    });

    test('deposit / withdrawal / interest / charge → ancrage', () {
      for (final k in [
        TransactionKind.deposit,
        TransactionKind.withdrawal,
        TransactionKind.interest,
        TransactionKind.charge,
      ]) {
        expect(journalHasCashAnchor([cashTx(id: '1', kind: k, amount: '10')]),
            isTrue,
            reason: '$k doit être un ancrage cash');
      }
    });

    test('openingBalance ESPÈCES (symbol null) → ancrage', () {
      expect(
        journalHasCashAnchor([
          cashTx(id: '1', kind: TransactionKind.openingBalance, symbol: null, amount: '1000'),
        ]),
        isTrue,
      );
    });

    test('openingBalance TITRE (symbol non null) → PAS un ancrage', () {
      expect(
        journalHasCashAnchor([
          cashTx(id: '1', kind: TransactionKind.openingBalance, symbol: 'AAPL', quantity: '10', unitPrice: '100'),
        ]),
        isFalse,
      );
    });

    test('adjustment ESPÈCES seul → PAS un ancrage (exclu par la spec)', () {
      expect(
        journalHasCashAnchor([
          cashTx(id: '1', kind: TransactionKind.adjustment, symbol: null, amount: '50'),
        ]),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // declaredMatchesProjection — critère d'ADOPTION AUTOMATIQUE à la
  // restauration d'une sauvegarde (AccountStorage.importRawData, étape 8).
  // ---------------------------------------------------------------------------
  group('declaredMatchesProjection', () {
    test('quantité et PRU exactement égaux → true', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100'),
      ]);
      expect(
        declaredMatchesProjection(proj, declaredQuantity: '10', declaredAveragePrice: 100.0),
        isTrue,
      );
    });

    test('quantité déclarée avec virgule décimale et espaces → normalisée puis comparée', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10.5', unitPrice: '100'),
      ]);
      expect(
        declaredMatchesProjection(proj, declaredQuantity: ' 10,5 ', declaredAveragePrice: 100.0),
        isTrue,
      );
    });

    test('quantité déclarée différente (même proche) → false (égalité EXACTE, pas de tolérance)', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100'),
      ]);
      expect(
        declaredMatchesProjection(proj, declaredQuantity: '10.0001', declaredAveragePrice: 100.0),
        isFalse,
      );
    });

    test('quantité déclarée non parsable ("abc") → false, même si la projection est nulle', () {
      final proj = projectPosition([]); // quantité 0, PRU null
      expect(
        declaredMatchesProjection(proj, declaredQuantity: 'abc', declaredAveragePrice: null),
        isFalse,
        reason: 'piège garbage→0 == projection 0 : ne doit JAMAIS adopter',
      );
    });

    test('quantité déclarée null → false', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100'),
      ]);
      expect(
        declaredMatchesProjection(proj, declaredQuantity: null, declaredAveragePrice: 100.0),
        isFalse,
      );
    });

    test('PRU déclaré et projeté tous deux null (position soldée) → true', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '10', unitPrice: '120', date: DateTime(2024, 1, 2)),
      ]);
      expect(proj.averagePrice, isNull);
      expect(
        declaredMatchesProjection(proj, declaredQuantity: '0', declaredAveragePrice: null),
        isTrue,
      );
    });

    test('PRU déclaré null, projeté non-null → false (asymétrie)', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100'),
      ]);
      expect(
        declaredMatchesProjection(proj, declaredQuantity: '10', declaredAveragePrice: null),
        isFalse,
      );
    });

    test('PRU déclaré non-null, projeté null → false (asymétrie inverse)', () {
      final proj = projectPosition([]); // quantité 0, PRU null
      expect(
        declaredMatchesProjection(proj, declaredQuantity: '0', declaredAveragePrice: 100.0),
        isFalse,
      );
    });

    test('PRU déclaré dans la tolérance (arrondi 6 décimales) → true, borne haute acceptée', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '3', unitPrice: '10'),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '7', unitPrice: '10.0000005', date: DateTime(2024, 1, 2)),
      ]);
      final exact = proj.averagePrice!;
      final rounded = double.parse(exact.toStringAsFixed(6));
      expect(rounded, isNot(exact), reason: 'précondition : l\'arrondi diffère de la valeur exacte');
      expect(
        declaredMatchesProjection(proj, declaredQuantity: '10', declaredAveragePrice: rounded),
        isTrue,
      );
    });

    test('PRU déclaré hors tolérance (juste au-delà de 1e-6·max) → false', () {
      final proj = projectPosition([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100'),
      ]);
      final exact = proj.averagePrice!; // 100.0
      // Tolérance = 1e-6 * max(1, 100, 100) = 1e-4. On dépasse largement.
      expect(
        declaredMatchesProjection(proj, declaredQuantity: '10', declaredAveragePrice: exact + 0.01),
        isFalse,
      );
    });
  });
}

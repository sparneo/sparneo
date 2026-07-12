// test/logic/transaction_analytics_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/transaction_analytics.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Construit un [AssetTransaction] minimal pour les tests.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('computeTransactionAnalytics', () {
    // 1. Liste vide
    test('liste vide → netQuantity 0, suggestedAveragePrice null, realizedGain 0',
        () {
      final result = computeTransactionAnalytics([]);
      expect(result.netQuantity, 0.0);
      expect(result.suggestedAveragePrice, isNull);
      expect(result.realizedGain, 0.0);
    });

    // 2. Un seul achat avec frais
    test('un achat 10 @ 100 fee 5 → PRU 100.5, netQty 10, realized 0', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', fee: '5'),
      ]);
      expect(result.netQuantity, 10.0);
      expect(result.suggestedAveragePrice, closeTo(100.5, 1e-9));
      expect(result.realizedGain, 0.0);
    });

    // 3. Deux achats à prix différents → PRU moyen pondéré
    test('deux achats (10@100 puis 10@200) → PRU 150, netQty 20', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '200', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 20.0);
      // (10*100 + 10*200) / 20 = 3000/20 = 150
      expect(result.suggestedAveragePrice, closeTo(150.0, 1e-9));
      expect(result.realizedGain, 0.0);
    });

    // 4. Achat puis vente partielle avec plus-value
    test('achat 10@100 puis vente 4@150 fee 0 → realized 200, netQty 6, PRU 100',
        () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '4', unitPrice: '150', fee: '0', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 6.0);
      expect(result.suggestedAveragePrice, closeTo(100.0, 1e-9));
      // proceeds = 4*150 = 600 ; costBasis = 4*100 = 400 ; realized = 200
      expect(result.realizedGain, closeTo(200.0, 1e-9));
    });

    // 5. Vente totale → netQty 0, suggestedAveragePrice null
    test('achat 10@100 puis vente 10@120 → netQty 0, PRU null, realized 200', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '10', unitPrice: '120', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 0.0);
      expect(result.suggestedAveragePrice, isNull);
      expect(result.realizedGain, closeTo(200.0, 1e-9));
    });

    // 6. Ordre d'entrée mélangé (dates dans le désordre) → tri interne
    test('transactions dans le désordre → même résultat que trié', () {
      // Achat 10@100 (date 2), puis achat 10@200 (date 1) — ordre inversé
      // Après tri : achat 10@200 (date 1) + achat 10@100 (date 2) = PRU 150
      final sorted = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '200', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      final reversed = computeTransactionAnalytics([
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 2)),
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '200', date: DateTime(2024, 1, 1)),
      ]);
      // PRU doit être identique quel que soit l'ordre d'entrée
      expect(sorted.suggestedAveragePrice, closeTo(150.0, 1e-9));
      expect(reversed.suggestedAveragePrice, closeTo(150.0, 1e-9));
      expect(sorted.netQuantity, equals(reversed.netQuantity));
    });

    // 7. Dividende présent → n'affecte ni PRU ni realized
    test('dividende présent → PRU et realized inchangés', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        AssetTransaction(
          id: '2',
          accountId: 'acc1',
          symbol: 'TEST',
          kind: TransactionKind.dividend,
          quantity: null,
          unitPrice: null,
          amount: '50',  // dividende de 50€
          currency: 'EUR',
          date: DateTime(2024, 1, 2),
        ),
      ]);
      expect(result.netQuantity, 10.0);
      expect(result.suggestedAveragePrice, closeTo(100.0, 1e-9));
      expect(result.realizedGain, 0.0);
    });

    // 8. Frais sur vente réduisent la plus-value
    test('frais de vente réduisent realized', () {
      // achat 10@100 (pas de frais), vente 10@120 fee 10
      // proceeds = 10*120 - 10 = 1190 ; costBasis = 10*100 = 1000 ; realized = 190
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '10', unitPrice: '120', fee: '10', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.realizedGain, closeTo(190.0, 1e-9));
    });

    // 9. Survente (vente > quantité détenue) → pas de crash, coût/qty bornés à 0
    test('survente (vente > stock) → pas de crash, qty et coût bornés à 0', () {
      // achat 5@100, puis vente 10@150 (survente de 5)
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '10', unitPrice: '150', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 0.0);
      expect(result.suggestedAveragePrice, isNull);
      // proceeds = 10*150 = 1500 ; costBasisSold = 5*100 = 500 (borné à qty détenue)
      // realized = 1500 - 500 = 1000
      expect(result.realizedGain, closeTo(1000.0, 1e-9));
    });

    // --- Tests supplémentaires de robustesse ---

    // Frais d'achat inclus dans PRU
    test("frais d'achat inclus dans la base de coût", () {
      // achat 10@100 fee 10 → coût total = 1010 → PRU = 101
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', fee: '10'),
      ]);
      expect(result.suggestedAveragePrice, closeTo(101.0, 1e-9));
    });

    // Valeurs avec virgule décimale (format FR)
    test('parse virgule décimale en valeur numérique', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100,50'),
      ]);
      expect(result.suggestedAveragePrice, closeTo(100.50, 1e-9));
    });

    // Dépôt/retrait ignorés défensivement
    test('deposit et withdrawal ignorés', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 1)),
        AssetTransaction(
          id: '2',
          accountId: 'acc1',
          symbol: null,
          kind: TransactionKind.deposit,
          quantity: null,
          unitPrice: null,
          amount: '500',
          currency: 'EUR',
          date: DateTime(2024, 1, 2),
        ),
      ]);
      expect(result.netQuantity, 5.0);
      expect(result.suggestedAveragePrice, closeTo(100.0, 1e-9));
    });

    // --- openingBalance : position initiale déclarative ---

    test('openingBalance 10 @ 50 → netQty 10, PRU 50 (entrée déclarative)', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '50'),
      ]);
      expect(result.netQuantity, 10.0);
      expect(result.suggestedAveragePrice, closeTo(50.0, 1e-9));
      expect(result.realizedGain, 0.0);
    });

    test('openingBalance sans unitPrice → quantité sans PRU (base de coût nulle → null)', () {
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '8'),
      ]);
      expect(result.netQuantity, 8.0);
      // Base de coût nulle (aucun prix déclaré) → PRU null (et non 0, qui
      // afficherait une plus-value latente fictive de +100 %). Cohérent avec
      // l'avant-B* : une position sans PRU avait averageBuyPrice == null.
      expect(result.suggestedAveragePrice, isNull);
      expect(result.realizedGain, 0.0);
    });

    test('openingBalance puis buy → PRU moyen pondéré combiné', () {
      // opening 10 @ 50 (coût 500), puis achat 10 @ 100 (coût 1000) → 1500/20 = 75
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '50', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 20.0);
      expect(result.suggestedAveragePrice, closeTo(75.0, 1e-9));
      expect(result.realizedGain, 0.0);
    });

    test('openingBalance puis vente → openingBalance ne génère pas de PV, la vente si', () {
      // opening 10 @ 50 (PRU 50), vente 4 @ 80 → realized = 4*80 - 4*50 = 120
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '50', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '4', unitPrice: '80', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 6.0);
      expect(result.suggestedAveragePrice, closeTo(50.0, 1e-9));
      expect(result.realizedGain, closeTo(120.0, 1e-9));
    });

    // --- adjustment : delta signé de quantité + coût ---

    test('adjustment positif → ajoute qty et coût (delta), pas de PV', () {
      // buy 10 @ 100 (coût 1000), adjustment +5 @ 100 (coût +500) → 1500/15 = 100
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.adjustment, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 15.0);
      expect(result.suggestedAveragePrice, closeTo(100.0, 1e-9));
      expect(result.realizedGain, 0.0);
    });

    test('adjustment négatif → retire qty et coût, sans plus-value réalisée', () {
      // buy 10 @ 100 (coût 1000), adjustment -3 @ 100 (coût -300) → 700/7 = 100
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '10', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.adjustment, quantity: '-3', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 7.0);
      expect(result.suggestedAveragePrice, closeTo(100.0, 1e-9));
      // adjustment n'est PAS une cession → aucune plus-value réalisée.
      expect(result.realizedGain, 0.0);
    });

    test('adjustment négatif au-delà du stock → qty et coût bornés à 0 (clamp)', () {
      // buy 5 @ 100, adjustment -10 @ 100 → clamp qty à 0, coût à 0
      final result = computeTransactionAnalytics([
        _tx(id: '1', kind: TransactionKind.buy, quantity: '5', unitPrice: '100', date: DateTime(2024, 1, 1)),
        _tx(id: '2', kind: TransactionKind.adjustment, quantity: '-10', unitPrice: '100', date: DateTime(2024, 1, 2)),
      ]);
      expect(result.netQuantity, 0.0);
      expect(result.suggestedAveragePrice, isNull);
      expect(result.realizedGain, 0.0);
    });
  });
}

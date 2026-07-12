// test/logic/allocation_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/allocation.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Crée une [PositionWithMarketData] minimale pour les tests.
PositionWithMarketData _pos({
  required String symbol,
  required AssetType type,
  required double price,
  required String quantity,
  String currency = 'EUR',
}) {
  final asset = Asset(symbol: symbol, type: type, currency: currency);
  final position = Position(accountId: 'acc1', asset: asset, quantity: quantity);
  return PositionWithMarketData(position: position, currentPrice: price);
}

void main() {
  // =========================================================================
  // AllocationCalculator.computeRealAllocations
  // =========================================================================

  group('AllocationCalculator.computeRealAllocations', () {
    // -----------------------------------------------------------------------
    // (a) totalValue ≤ 0 → liste vide
    // -----------------------------------------------------------------------

    test('retourne [] si totalValue vaut 0', () {
      final positions = [_pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '10')];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 0,
        usdToEurRate: 0.92,
      );
      expect(result, isEmpty);
    });

    test('retourne [] si totalValue est négatif', () {
      final result = AllocationCalculator.computeRealAllocations(
        positions: [],
        totalValue: -1000,
        usdToEurRate: 0.92,
      );
      expect(result, isEmpty);
    });

    // -----------------------------------------------------------------------
    // (b) Position EUR simple
    // -----------------------------------------------------------------------

    test('position EUR unique : valeur et percent corrects', () {
      // 10 parts à 200 € = 2000 € / totalValue 4000 € → 50 %
      final positions = [_pos(symbol: 'CSPX', type: AssetType.etf, price: 200, quantity: '10')];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 4000,
        usdToEurRate: 0.92,
      );
      expect(result, hasLength(1));
      expect(result.first.type, AssetType.etf);
      expect(result.first.value, closeTo(2000.0, 1e-9));
      expect(result.first.percent, closeTo(50.0, 1e-9));
    });

    // -----------------------------------------------------------------------
    // (c) Position USD convertie en EUR
    // -----------------------------------------------------------------------

    test('position USD est convertie avec usdToEurRate', () {
      // 5 parts à 100 USD × 0.90 = 450 EUR / 900 EUR → 50 %
      final positions = [
        _pos(symbol: 'AAPL', type: AssetType.stock, price: 100, quantity: '5', currency: 'USD'),
      ];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 900,
        usdToEurRate: 0.90,
      );
      expect(result, hasLength(1));
      expect(result.first.value, closeTo(450.0, 1e-9));
      expect(result.first.percent, closeTo(50.0, 1e-9));
    });

    // -----------------------------------------------------------------------
    // (d) Plusieurs positions du même type agrégées
    // -----------------------------------------------------------------------

    test('plusieurs positions du même AssetType sont agrégées', () {
      final positions = [
        _pos(symbol: 'SPY', type: AssetType.etf, price: 500, quantity: '2'),  // 1000 €
        _pos(symbol: 'CSPX', type: AssetType.etf, price: 300, quantity: '3'), // 900 €
      ];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 2000,
        usdToEurRate: 0.92,
      );
      expect(result, hasLength(1));
      expect(result.first.type, AssetType.etf);
      expect(result.first.value, closeTo(1900.0, 1e-9));
      expect(result.first.percent, closeTo(95.0, 1e-9));
    });

    // -----------------------------------------------------------------------
    // (e) Positions de types différents
    // -----------------------------------------------------------------------

    test('positions de types différents génèrent plusieurs entrées', () {
      final positions = [
        _pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '10'),   // 1000 €
        _pos(symbol: 'BTC', type: AssetType.crypto, price: 50, quantity: '4'),  // 200 €
      ];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 1200,
        usdToEurRate: 0.92,
      );
      expect(result, hasLength(2));
      final etf = result.firstWhere((a) => a.type == AssetType.etf);
      final crypto = result.firstWhere((a) => a.type == AssetType.crypto);
      expect(etf.percent, closeTo(1000.0 / 1200 * 100, 1e-6));
      expect(crypto.percent, closeTo(200.0 / 1200 * 100, 1e-6));
    });

    // -----------------------------------------------------------------------
    // (f) Positions avec valeur ≤ 0 exclues
    // -----------------------------------------------------------------------

    test('position avec prix nul est exclue', () {
      final positions = [
        _pos(symbol: 'SPY', type: AssetType.etf, price: 0, quantity: '10'),
        _pos(symbol: 'CSPX', type: AssetType.etf, price: 200, quantity: '5'), // 1000 €
      ];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 1000,
        usdToEurRate: 0.92,
      );
      // La position à prix 0 est exclue ; une seule entrée ETF à 100 %
      expect(result, hasLength(1));
      expect(result.first.percent, closeTo(100.0, 1e-9));
    });

    test('position avec quantité 0 est exclue', () {
      final positions = [
        _pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '0'),
        _pos(symbol: 'BTC', type: AssetType.crypto, price: 50, quantity: '2'), // 100 €
      ];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 100,
        usdToEurRate: 0.92,
      );
      expect(result, hasLength(1));
      expect(result.first.type, AssetType.crypto);
    });

    // -----------------------------------------------------------------------
    // (g) Tri par valeur décroissante
    // -----------------------------------------------------------------------

    test('résultat trié par valeur décroissante', () {
      final positions = [
        _pos(symbol: 'BTC', type: AssetType.crypto, price: 10, quantity: '5'),  // 50 €
        _pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '10'),   // 1000 €
        _pos(symbol: 'BOND', type: AssetType.bond, price: 200, quantity: '2'),  // 400 €
      ];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 1450,
        usdToEurRate: 0.92,
      );
      expect(result[0].type, AssetType.etf);
      expect(result[1].type, AssetType.bond);
      expect(result[2].type, AssetType.crypto);
    });

    // -----------------------------------------------------------------------
    // (h) percent = value / totalValue * 100 (cash dilue le dénominateur)
    // -----------------------------------------------------------------------

    test('le cash au dénominateur dilue le percent des positions', () {
      // 1000 € de positions ETF, mais totalValue = 2000 € (1000 € cash inclus)
      final positions = [_pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '10')];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 2000, // inclut 1000 € cash
        usdToEurRate: 0.92,
      );
      expect(result, hasLength(1));
      // Les ETF ne représentent que 50 % du patrimoine total
      expect(result.first.percent, closeTo(50.0, 1e-9));
    });

    // -----------------------------------------------------------------------
    // (i) Le cash forme une catégorie synthétique (type == null)
    // -----------------------------------------------------------------------

    test('cashValue > 0 ajoute une catégorie cash (type == null)', () {
      // 1000 € ETF + 1000 € cash, total 2000 € → chacun 50 %.
      final positions = [_pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '10')];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 2000,
        usdToEurRate: 0.92,
        cashValue: 1000,
      );
      expect(result, hasLength(2));
      final cash = result.firstWhere((a) => a.isCash);
      final etf = result.firstWhere((a) => a.type == AssetType.etf);
      expect(cash.type, isNull);
      expect(cash.value, closeTo(1000.0, 1e-9));
      expect(cash.percent, closeTo(50.0, 1e-9));
      expect(etf.percent, closeTo(50.0, 1e-9));
      // Types + cash somment à ~100 %.
      final sum = result.fold<double>(0, (s, a) => s + a.percent);
      expect(sum, closeTo(100.0, 1e-9));
    });

    test('cashValue == 0 n\'ajoute aucune catégorie cash', () {
      final positions = [_pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '10')];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 1000,
        usdToEurRate: 0.92,
        cashValue: 0,
      );
      expect(result, hasLength(1));
      expect(result.any((a) => a.isCash), isFalse);
    });

    test('la catégorie cash participe au tri décroissant par valeur', () {
      // Cash 1500 € > ETF 1000 € → cash en tête.
      final positions = [_pos(symbol: 'SPY', type: AssetType.etf, price: 100, quantity: '10')];
      final result = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: 2500,
        usdToEurRate: 0.92,
        cashValue: 1500,
      );
      expect(result.first.isCash, isTrue);
      expect(result[1].type, AssetType.etf);
    });
  });

  // =========================================================================
  // AllocationCalculator.computeGaps
  // =========================================================================

  group('AllocationCalculator.computeGaps', () {
    // -----------------------------------------------------------------------
    // (a) Cible vide → liste vide
    // -----------------------------------------------------------------------

    test('retourne [] si la cible est vide', () {
      const target = AllocationTarget.empty();
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: [],
      );
      expect(gaps, isEmpty);
    });

    // -----------------------------------------------------------------------
    // (b) Type ciblé absent des positions → realPercent = 0
    // -----------------------------------------------------------------------

    test('type ciblé absent des positions → realPercent = 0', () {
      final target = AllocationTarget(targets: {AssetType.bond.name: 20.0});
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: [], // aucune position
      );
      expect(gaps, hasLength(1));
      expect(gaps.first.type, AssetType.bond);
      expect(gaps.first.realPercent, 0.0);
      expect(gaps.first.targetPercent, 20.0);
      expect(gaps.first.delta, closeTo(-20.0, 1e-9));
    });

    // -----------------------------------------------------------------------
    // (c) delta = réel − cible
    // -----------------------------------------------------------------------

    test('delta = realPercent − targetPercent', () {
      final target = AllocationTarget(targets: {AssetType.etf.name: 60.0});
      final realAllocations = [
        AssetTypeAllocation(type: AssetType.etf, value: 800, percent: 80.0),
      ];
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: realAllocations,
      );
      expect(gaps.first.delta, closeTo(20.0, 1e-9)); // 80 - 60 = +20 (sur-pondéré)
    });

    // -----------------------------------------------------------------------
    // (d) Seuls les types ciblés apparaissent dans le résultat
    // -----------------------------------------------------------------------

    test('seuls les types ciblés apparaissent dans les gaps', () {
      final target = AllocationTarget(targets: {AssetType.etf.name: 50.0});
      final realAllocations = [
        AssetTypeAllocation(type: AssetType.etf, value: 500, percent: 50.0),
        AssetTypeAllocation(type: AssetType.crypto, value: 200, percent: 20.0),
      ];
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: realAllocations,
      );
      expect(gaps, hasLength(1));
      expect(gaps.first.type, AssetType.etf);
    });

    // -----------------------------------------------------------------------
    // (e) Clé inconnue dans les targets ignorée par computeGaps
    // -----------------------------------------------------------------------

    test('clé inconnue dans targets est ignorée sans exception', () {
      final target = AllocationTarget(targets: {
        'unknownType': 10.0,
        AssetType.stock.name: 30.0,
      });
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: [],
      );
      // Seule la clé connue (stock) génère un gap
      expect(gaps, hasLength(1));
      expect(gaps.first.type, AssetType.stock);
    });

    // -----------------------------------------------------------------------
    // (f) Tri par |delta| décroissant, puis par nom alphabétique
    // -----------------------------------------------------------------------

    test('tri par |delta| décroissant', () {
      final target = AllocationTarget(targets: {
        AssetType.etf.name: 50.0,
        AssetType.crypto.name: 20.0,
        AssetType.bond.name: 10.0,
      });
      final realAllocations = [
        AssetTypeAllocation(type: AssetType.etf, value: 600, percent: 60.0),   // delta = +10
        AssetTypeAllocation(type: AssetType.crypto, value: 50, percent: 5.0),   // delta = -15
        AssetTypeAllocation(type: AssetType.bond, value: 100, percent: 10.0),   // delta = 0
      ];
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: realAllocations,
      );
      // |delta| : crypto=15, etf=10, bond=0 → ordre : crypto, etf, bond
      expect(gaps[0].type, AssetType.crypto);
      expect(gaps[1].type, AssetType.etf);
      expect(gaps[2].type, AssetType.bond);
    });

    test('tri secondaire par nom pour |delta| égaux', () {
      // bond.name < etf.name alphabétiquement
      final target = AllocationTarget(targets: {
        AssetType.etf.name: 50.0,
        AssetType.bond.name: 50.0,
      });
      // Les deux ont realPercent = 0 → |delta| = 50 pour chacun
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: [],
      );
      expect(gaps[0].type!.name.compareTo(gaps[1].type!.name), lessThan(0),
          reason: 'le tri secondaire doit être alphabétique sur le nom du type');
    });

    // -----------------------------------------------------------------------
    // (g) AllocationGap.delta est un getter calculé
    // -----------------------------------------------------------------------

    test('AllocationGap.delta est realPercent − targetPercent', () {
      const gap = AllocationGap(type: AssetType.crypto, realPercent: 15.0, targetPercent: 25.0);
      expect(gap.delta, closeTo(-10.0, 1e-9));
    });

    // -----------------------------------------------------------------------
    // (h) La cible cash (kCashAllocationKey) produit un gap cash (type == null)
    // -----------------------------------------------------------------------

    test('cible cash produit un gap cash (type == null)', () {
      final target = AllocationTarget(targets: {kCashAllocationKey: 30.0});
      final realAllocations = [
        // Cash réel à 20 % (type == null).
        const AssetTypeAllocation(type: null, value: 200, percent: 20.0),
      ];
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: realAllocations,
      );
      expect(gaps, hasLength(1));
      expect(gaps.first.isCash, isTrue);
      expect(gaps.first.type, isNull);
      expect(gaps.first.realPercent, closeTo(20.0, 1e-9));
      expect(gaps.first.targetPercent, closeTo(30.0, 1e-9));
      expect(gaps.first.delta, closeTo(-10.0, 1e-9)); // sous-pondéré
    });

    test('cible cash sans cash réel → realPercent = 0', () {
      final target = AllocationTarget(targets: {kCashAllocationKey: 15.0});
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: [
          AssetTypeAllocation(type: AssetType.etf, value: 1000, percent: 100.0),
        ],
      );
      expect(gaps, hasLength(1));
      expect(gaps.first.isCash, isTrue);
      expect(gaps.first.realPercent, 0.0);
      expect(gaps.first.delta, closeTo(-15.0, 1e-9));
    });

    test('cash et types coexistent dans les gaps', () {
      final target = AllocationTarget(targets: {
        AssetType.etf.name: 60.0,
        kCashAllocationKey: 40.0,
      });
      final realAllocations = [
        AssetTypeAllocation(type: AssetType.etf, value: 700, percent: 70.0),
        const AssetTypeAllocation(type: null, value: 300, percent: 30.0),
      ];
      final gaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: realAllocations,
      );
      expect(gaps, hasLength(2));
      final etfGap = gaps.firstWhere((g) => g.type == AssetType.etf);
      final cashGap = gaps.firstWhere((g) => g.isCash);
      expect(etfGap.delta, closeTo(10.0, 1e-9)); // 70 - 60
      expect(cashGap.delta, closeTo(-10.0, 1e-9)); // 30 - 40
    });
  });

  // =========================================================================
  // AllocationCalculator.isTargetSumValid
  // =========================================================================

  group('AllocationCalculator.isTargetSumValid', () {
    test('somme < 100 est valide', () {
      expect(
        AllocationCalculator.isTargetSumValid({
          AssetType.etf.name: 40.0,
          AssetType.stock.name: 30.0,
        }),
        isTrue,
      );
    });

    test('somme exactement égale à 100 est valide', () {
      expect(
        AllocationCalculator.isTargetSumValid({
          AssetType.etf.name: 60.0,
          AssetType.stock.name: 40.0,
        }),
        isTrue,
      );
    });

    test('somme légèrement au-dessus de 100 (mais dans la tolérance flottante) est valide', () {
      // Résultat de 3 × 33.33… = 99.99 → OK
      expect(
        AllocationCalculator.isTargetSumValid({
          AssetType.etf.name: 33.33,
          AssetType.stock.name: 33.33,
          AssetType.crypto.name: 33.34,
        }),
        isTrue,
      );
    });

    test('somme > 100 est invalide', () {
      expect(
        AllocationCalculator.isTargetSumValid({
          AssetType.etf.name: 60.0,
          AssetType.stock.name: 50.0, // 60+50 = 110
        }),
        isFalse,
      );
    });

    test('map vide → somme = 0 → valide', () {
      expect(AllocationCalculator.isTargetSumValid({}), isTrue);
    });
  });
}

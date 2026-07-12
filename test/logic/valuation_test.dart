// test/logic/valuation_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/valuation.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Construit un [PositionWithMarketData] minimal pour les tests.
PositionWithMarketData _makePos({
  required String currency,
  required double? price,
  required String quantity,
}) {
  final asset = Asset(symbol: 'TEST', currency: currency);
  final position = Position(accountId: 'acc1', asset: asset, quantity: quantity);
  return PositionWithMarketData(position: position, currentPrice: price);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  const double rate = 0.92; // taux USD→EUR de référence pour les tests

  // -------------------------------------------------------------------------
  // positionValueEur
  // -------------------------------------------------------------------------

  group('Valuation.positionValueEur', () {
    test('position EUR : price × qty, sans conversion', () {
      final pos = _makePos(currency: 'EUR', price: 100.0, quantity: '10');
      expect(Valuation.positionValueEur(positionData: pos, usdToEurRate: rate), 1000.0);
    });

    test('position USD : price × qty × rate', () {
      final pos = _makePos(currency: 'USD', price: 100.0, quantity: '5');
      expect(
        Valuation.positionValueEur(positionData: pos, usdToEurRate: rate),
        closeTo(100.0 * 5 * 0.92, 1e-9),
      );
    });

    test('quantité non parsable → 0', () {
      final pos = _makePos(currency: 'EUR', price: 100.0, quantity: 'abc');
      expect(Valuation.positionValueEur(positionData: pos, usdToEurRate: rate), 0.0);
    });

    test('price null → 0', () {
      final pos = _makePos(currency: 'EUR', price: null, quantity: '10');
      expect(Valuation.positionValueEur(positionData: pos, usdToEurRate: rate), 0.0);
    });

    test('métal précieux (currency EUR) : pas de re-conversion', () {
      // Les métaux précieux arrivent déjà convertis en EUR par MarketDataService.
      // currency == 'EUR' → aucune multiplication par le taux.
      final asset = Asset(
        symbol: 'NAPOLEON-20F',
        currency: 'EUR',
        type: AssetType.preciousMetal,
      );
      final position = Position(accountId: 'acc1', asset: asset, quantity: '2');
      final pos = PositionWithMarketData(position: position, currentPrice: 450.0);
      // Valeur attendue : 450 × 2 = 900 (pas × 0.92)
      expect(Valuation.positionValueEur(positionData: pos, usdToEurRate: rate), 900.0);
    });

    test('price et qty tous deux à zéro → 0', () {
      final pos = _makePos(currency: 'USD', price: 0.0, quantity: '0');
      expect(Valuation.positionValueEur(positionData: pos, usdToEurRate: rate), 0.0);
    });

    test('position USD avec qty non parsable → 0 (pas de conversion car qty = 0)', () {
      final pos = _makePos(currency: 'USD', price: 100.0, quantity: 'nope');
      expect(Valuation.positionValueEur(positionData: pos, usdToEurRate: rate), 0.0);
    });
  });

  // -------------------------------------------------------------------------
  // accountInvestmentTotalEur
  // -------------------------------------------------------------------------

  group('Valuation.accountInvestmentTotalEur', () {
    test('somme de plusieurs positions EUR et USD', () {
      final positions = [
        _makePos(currency: 'EUR', price: 100.0, quantity: '3'),   // 300
        _makePos(currency: 'USD', price: 200.0, quantity: '2'),   // 400 × 0.92 = 368
      ];
      final total = Valuation.accountInvestmentTotalEur(
        positions: positions,
        usdToEurRate: rate,
      );
      expect(total, closeTo(300.0 + 368.0, 1e-9));
    });

    test('liste vide → 0', () {
      expect(
        Valuation.accountInvestmentTotalEur(positions: [], usdToEurRate: rate),
        0.0,
      );
    });

    test('position avec price null : ne contribue pas au total', () {
      final positions = [
        _makePos(currency: 'EUR', price: null, quantity: '10'),
        _makePos(currency: 'EUR', price: 50.0, quantity: '2'),
      ];
      expect(
        Valuation.accountInvestmentTotalEur(positions: positions, usdToEurRate: rate),
        closeTo(100.0, 1e-9),
      );
    });
  });

  // -------------------------------------------------------------------------
  // cashBalanceEur
  // -------------------------------------------------------------------------

  group('Valuation.cashBalanceEur', () {
    test('retourne la valeur telle quelle (déjà en EUR)', () {
      expect(Valuation.cashBalanceEur(1234.56), 1234.56);
    });

    test('zéro → zéro', () {
      expect(Valuation.cashBalanceEur(0.0), 0.0);
    });
  });
}

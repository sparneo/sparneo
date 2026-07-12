import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Asset _asset({
  String symbol = 'AAPL',
  String? name,
  String currency = 'EUR',
}) =>
    Asset(symbol: symbol, name: name, currency: currency);

Position _position({
  String accountId = 'acc1',
  Asset? asset,
  String quantity = '10',
  double? averageBuyPrice,
  String? customName,
}) =>
    Position(
      accountId: accountId,
      asset: asset ?? _asset(),
      quantity: quantity,
      averageBuyPrice: averageBuyPrice,
      customName: customName,
    );

// ---------------------------------------------------------------------------
// Account tests
// ---------------------------------------------------------------------------

void main() {
  group('Account.totalValue', () {
    test('cash account returns cashBalance when set', () {
      final account = Account(
        id: '1',
        walletId: 'w1',
        name: 'Livret A',
        kind: AccountKind.cash,
        cashBalance: 2500.0,
      );
      expect(account.totalValue, 2500.0);
    });

    test('cash account with null cashBalance returns 0.0', () {
      final account = Account(
        id: '2',
        walletId: 'w1',
        name: 'Vide',
        kind: AccountKind.cash,
        cashBalance: null,
      );
      expect(account.totalValue, 0.0);
    });

    test('investment account always returns 0.0 (computed via positions)', () {
      final account = Account(
        id: '3',
        walletId: 'w1',
        name: 'PEA',
        kind: AccountKind.autre,
        cashBalance: 9999.0, // ignored for investment accounts
      );
      expect(account.totalValue, 0.0);
    });
  });

  group('Account.copyWith', () {
    test('copies with updated name only', () {
      final original = Account(
        id: 'x',
        walletId: 'w',
        name: 'Old',
        kind: AccountKind.cash,
        cashBalance: 100.0,
      );
      final copy = original.copyWith(name: 'New');
      expect(copy.name, 'New');
      expect(copy.id, original.id);
      expect(copy.cashBalance, original.cashBalance);
    });

    test('copies with updated cashBalance', () {
      final original = Account(
        id: 'x',
        walletId: 'w',
        name: 'Test',
        kind: AccountKind.cash,
        cashBalance: 50.0,
      );
      final copy = original.copyWith(cashBalance: 200.0);
      expect(copy.cashBalance, 200.0);
      expect(copy.name, original.name);
    });
  });

  // -------------------------------------------------------------------------
  // Asset tests
  // -------------------------------------------------------------------------

  group('Asset.isUsd', () {
    test('USD currency returns true', () {
      final asset = _asset(currency: 'USD');
      expect(asset.isUsd, isTrue);
    });

    test('lowercase usd is normalised and returns true', () {
      final asset = _asset(currency: 'usd');
      expect(asset.isUsd, isTrue);
    });

    test('EUR currency returns false', () {
      final asset = _asset(currency: 'EUR');
      expect(asset.isUsd, isFalse);
    });

    test('GBP currency returns false', () {
      final asset = _asset(currency: 'GBP');
      expect(asset.isUsd, isFalse);
    });
  });

  group('Asset.displayName', () {
    test('returns name when provided', () {
      final asset = _asset(symbol: 'AAPL', name: 'Apple Inc.');
      expect(asset.displayName, 'Apple Inc.');
    });

    test('falls back to symbol when name is null', () {
      final asset = _asset(symbol: 'BTC', name: null);
      expect(asset.displayName, 'BTC');
    });
  });

  // -------------------------------------------------------------------------
  // Precious metal pricing tests
  // -------------------------------------------------------------------------

  group('Asset.unitPriceFromSpot', () {
    test('non precious-metal asset returns the spot unchanged', () {
      final asset = _asset(currency: 'USD');
      expect(asset.unitPriceFromSpot(2000), 2000.0);
    });

    test('ounce-quoted coin applies fine weight and premium', () {
      // Napoléon 20F: 5.807 g fin, prime 8%, spot 2000 $/oz.
      final asset = Asset(
        symbol: 'NAP',
        type: AssetType.preciousMetal,
        refSymbol: 'GC=F',
        refQuoteUnit: MetalQuoteUnit.ounce,
        fineWeightGrams: 5.807,
        premiumPercent: 8.0,
      );
      final expected = 2000 / Asset.gramsPerTroyOunce * 5.807 * 1.08;
      expect(asset.unitPriceFromSpot(2000), closeTo(expected, 1e-9));
    });

    test('gram-quoted reference does not divide by ounce', () {
      // ETC euro coté au gramme : 10 g, sans prime.
      final asset = Asset(
        symbol: 'BAR10',
        type: AssetType.preciousMetal,
        refSymbol: '4GLD.DE',
        refQuoteUnit: MetalQuoteUnit.gram,
        fineWeightGrams: 10.0,
        premiumPercent: 0.0,
      );
      expect(asset.unitPriceFromSpot(80), closeTo(800.0, 1e-9));
    });

    test('missing fine weight falls back to raw spot', () {
      final asset = Asset(
        symbol: 'X',
        type: AssetType.preciousMetal,
        refSymbol: 'GC=F',
        fineWeightGrams: null,
      );
      expect(asset.unitPriceFromSpot(1234), 1234.0);
    });

    test('quoteSymbol uses the reference symbol for precious metals', () {
      final asset = Asset(
        symbol: 'NAP',
        type: AssetType.preciousMetal,
        refSymbol: 'GC=F',
        fineWeightGrams: 5.807,
      );
      expect(asset.quoteSymbol, 'GC=F');
    });

    test('quoteSymbol falls back to symbol for classic assets', () {
      expect(_asset(symbol: 'AAPL').quoteSymbol, 'AAPL');
    });
  });

  group('Asset precious-metal JSON round-trip', () {
    test('serialises and restores metal fields', () {
      final asset = Asset(
        symbol: 'NAP',
        name: 'Napoléon 20 F',
        type: AssetType.preciousMetal,
        currency: 'EUR',
        refSymbol: 'GC=F',
        refQuoteUnit: MetalQuoteUnit.ounce,
        fineWeightGrams: 5.807,
        premiumPercent: 8.0,
      );
      final restored = Asset.fromJson(asset.toJson());
      expect(restored.type, AssetType.preciousMetal);
      expect(restored.refSymbol, 'GC=F');
      expect(restored.refQuoteUnit, MetalQuoteUnit.ounce);
      expect(restored.fineWeightGrams, 5.807);
      expect(restored.premiumPercent, 8.0);
    });

    test('classic asset JSON omits metal fields', () {
      final json = _asset(symbol: 'AAPL').toJson();
      expect(json.containsKey('fineWeightGrams'), isFalse);
      expect(json.containsKey('refQuoteUnit'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Position tests
  // -------------------------------------------------------------------------

  group('Position.displayName', () {
    test('returns customName when set', () {
      final pos = _position(customName: 'Mon ETF Monde');
      expect(pos.displayName, 'Mon ETF Monde');
    });

    test('falls back to asset.name when no customName', () {
      final pos = _position(
        asset: _asset(symbol: 'MSFT', name: 'Microsoft'),
        customName: null,
      );
      expect(pos.displayName, 'Microsoft');
    });

    test('falls back to asset.symbol when no customName and no asset.name', () {
      final pos = _position(
        asset: _asset(symbol: 'XYZ', name: null),
        customName: null,
      );
      expect(pos.displayName, 'XYZ');
    });
  });

  // -------------------------------------------------------------------------
  // PositionWithMarketData tests
  // -------------------------------------------------------------------------

  group('PositionWithMarketData.totalValue', () {
    test('price * quantity', () {
      final pwmd = PositionWithMarketData(
        position: _position(quantity: '5'),
        currentPrice: 100.0,
      );
      expect(pwmd.totalValue, closeTo(500.0, 0.001));
    });

    test('null currentPrice treated as 0', () {
      final pwmd = PositionWithMarketData(
        position: _position(quantity: '10'),
        currentPrice: null,
      );
      expect(pwmd.totalValue, 0.0);
    });

    test('fractional quantity is parsed correctly', () {
      final pwmd = PositionWithMarketData(
        position: _position(quantity: '2.5'),
        currentPrice: 200.0,
      );
      expect(pwmd.totalValue, closeTo(500.0, 0.001));
    });

    test('unparseable quantity treated as 0', () {
      final pwmd = PositionWithMarketData(
        position: _position(quantity: 'N/A'),
        currentPrice: 50.0,
      );
      expect(pwmd.totalValue, 0.0);
    });
  });

  group('PositionWithMarketData.totalChange', () {
    test('change per share * quantity', () {
      final pwmd = PositionWithMarketData(
        position: _position(quantity: '4'),
        currentPrice: 110.0,
        change: 2.5,
      );
      expect(pwmd.totalChange, closeTo(10.0, 0.001));
    });

    test('null change treated as 0', () {
      final pwmd = PositionWithMarketData(
        position: _position(quantity: '10'),
        currentPrice: 100.0,
        change: null,
      );
      expect(pwmd.totalChange, 0.0);
    });

    test('negative change is preserved', () {
      final pwmd = PositionWithMarketData(
        position: _position(quantity: '3'),
        currentPrice: 80.0,
        change: -5.0,
      );
      expect(pwmd.totalChange, closeTo(-15.0, 0.001));
    });
  });

  group('PositionWithMarketData.isPositive', () {
    test('positive change returns true', () {
      final pwmd = PositionWithMarketData(
        position: _position(),
        change: 1.0,
      );
      expect(pwmd.isPositive, isTrue);
    });

    test('zero change returns true', () {
      final pwmd = PositionWithMarketData(
        position: _position(),
        change: 0.0,
      );
      expect(pwmd.isPositive, isTrue);
    });

    test('negative change returns false', () {
      final pwmd = PositionWithMarketData(
        position: _position(),
        change: -0.01,
      );
      expect(pwmd.isPositive, isFalse);
    });

    test('null change returns false', () {
      final pwmd = PositionWithMarketData(
        position: _position(),
        change: null,
      );
      expect(pwmd.isPositive, isFalse);
    });
  });

  group('PositionWithMarketData.isLoading', () {
    test('no price and no error means loading', () {
      final pwmd = PositionWithMarketData(
        position: _position(),
        currentPrice: null,
      );
      expect(pwmd.isLoading, isTrue);
    });

    test('price present means not loading', () {
      final pwmd = PositionWithMarketData(
        position: _position(),
        currentPrice: 50.0,
      );
      expect(pwmd.isLoading, isFalse);
    });

    test('error present means not loading even without price', () {
      final pwmd = PositionWithMarketData(
        position: _position(),
        currentPrice: null,
        errorMessage: 'timeout',
      );
      expect(pwmd.isLoading, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Tests de non-collision des identifiants
  // -------------------------------------------------------------------------

  group('Wallet.generateId', () {
    test('génère 1000 IDs tous uniques et non vides', () {
      final ids = <String>{};
      for (var i = 0; i < 1000; i++) {
        final id = Wallet.generateId();
        expect(id, isNotEmpty);
        ids.add(id);
      }
      expect(ids.length, 1000);
    });
  });

  group('Account.generateId', () {
    test('génère 1000 IDs tous uniques et non vides', () {
      final ids = <String>{};
      for (var i = 0; i < 1000; i++) {
        final id = Account.generateId();
        expect(id, isNotEmpty);
        ids.add(id);
      }
      expect(ids.length, 1000);
    });
  });
}

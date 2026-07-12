// test/model/asset_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset.dart';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('AssetType.fromYahooInstrumentType', () {
    test('EQUITY → stock', () {
      expect(AssetType.fromYahooInstrumentType('EQUITY'), equals(AssetType.stock));
    });

    test('ETF → etf', () {
      expect(AssetType.fromYahooInstrumentType('ETF'), equals(AssetType.etf));
    });

    test('MUTUALFUND → fund', () {
      expect(AssetType.fromYahooInstrumentType('MUTUALFUND'), equals(AssetType.fund));
    });

    test('CRYPTOCURRENCY → crypto', () {
      expect(AssetType.fromYahooInstrumentType('CRYPTOCURRENCY'), equals(AssetType.crypto));
    });

    test('INDEX → other', () {
      expect(AssetType.fromYahooInstrumentType('INDEX'), equals(AssetType.other));
    });

    test('CURRENCY → other (fallback)', () {
      expect(AssetType.fromYahooInstrumentType('CURRENCY'), equals(AssetType.other));
    });

    test('FUTURE → other (fallback)', () {
      expect(AssetType.fromYahooInstrumentType('FUTURE'), equals(AssetType.other));
    });

    test('null → other', () {
      expect(AssetType.fromYahooInstrumentType(null), equals(AssetType.other));
    });

    test('valeur inconnue → other', () {
      expect(AssetType.fromYahooInstrumentType('SOMETHING_NEW'), equals(AssetType.other));
    });

    test(
        'ne renvoie jamais preciousMetal, bond ni realEstate (choix manuels '
        'uniquement)', () {
      const inputs = [
        'EQUITY',
        'ETF',
        'MUTUALFUND',
        'CRYPTOCURRENCY',
        'CURRENCY',
        'FUTURE',
        'INDEX',
        null,
        'INCONNU',
      ];
      for (final input in inputs) {
        final mapped = AssetType.fromYahooInstrumentType(input);
        expect(mapped, isNot(equals(AssetType.preciousMetal)));
        expect(mapped, isNot(equals(AssetType.bond)));
        expect(mapped, isNot(equals(AssetType.realEstate)));
      }
    });
  });

  group('Asset.typeLocked (sérialisation)', () {
    test('défaut false ; omis de toJson pour ne pas alourdir le round-trip', () {
      final asset = Asset(symbol: 'AIR.PA', type: AssetType.stock);
      expect(asset.typeLocked, isFalse);
      expect(asset.toJson().containsKey('typeLocked'), isFalse);
    });

    test('true → présent dans toJson et round-trip via fromJson', () {
      final asset = Asset(
        symbol: 'OAT',
        type: AssetType.bond,
        typeLocked: true,
      );
      final json = asset.toJson();
      expect(json['typeLocked'], isTrue);

      final restored = Asset.fromJson(json);
      expect(restored.type, equals(AssetType.bond));
      expect(restored.typeLocked, isTrue);
    });

    test('fromJson sans la clé → typeLocked false (rétro-compat schémas ≤ actuel)',
        () {
      final restored = Asset.fromJson({
        'symbol': 'AAPL',
        'type': 'stock',
        'currency': 'USD',
      });
      expect(restored.typeLocked, isFalse);
    });

    test('copyWith(typeLocked:) modifie le flag sans toucher au reste', () {
      final base = Asset(symbol: 'AIR.PA', type: AssetType.stock);
      final locked = base.copyWith(type: AssetType.realEstate, typeLocked: true);
      expect(locked.type, equals(AssetType.realEstate));
      expect(locked.typeLocked, isTrue);
      expect(locked.symbol, equals('AIR.PA'));
      // L'original reste inchangé (immutabilité).
      expect(base.typeLocked, isFalse);
    });
  });

  group('Asset.hasMetalPricing (bucket vs modèle de pricing)', () {
    test('type non-métal → false', () {
      expect(Asset(symbol: 'AAPL', type: AssetType.stock).hasMetalPricing,
          isFalse);
    });

    test('preciousMetal SANS refSymbol (override de bucket) → false', () {
      // Cas de l'override manuel : classé « métal » pour l'allocation mais sans
      // modèle pièce/lingot → doit garder le pricing d'un actif ordinaire.
      final overridden = Asset(
        symbol: '4GLD.DE',
        type: AssetType.preciousMetal,
        typeLocked: true,
        currency: 'EUR',
      );
      expect(overridden.hasMetalPricing, isFalse);
    });

    test('preciousMetal avec refSymbol (vrai métal) → true', () {
      final metal = Asset(
        symbol: 'NAP',
        type: AssetType.preciousMetal,
        refSymbol: 'GC=F',
        fineWeightGrams: 5.807,
      );
      expect(metal.hasMetalPricing, isTrue);
    });

    test('refSymbol vide → false (pas de cours de référence exploitable)', () {
      final metal = Asset(
        symbol: 'NAP',
        type: AssetType.preciousMetal,
        refSymbol: '',
      );
      expect(metal.hasMetalPricing, isFalse);
    });
  });
}

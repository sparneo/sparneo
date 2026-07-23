// test/asset_isin_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset.dart';

void main() {
  group('Asset.isin (round-trip JSON)', () {
    test('absent à la création → null, omis de toJson', () {
      final asset = Asset(symbol: 'AIR.PA', type: AssetType.stock);
      expect(asset.isin, isNull);
      expect(asset.toJson().containsKey('isin'), isFalse);
    });

    test('fourni → présent dans toJson et round-trip via fromJson', () {
      final asset = Asset(
        symbol: 'AIR.PA',
        type: AssetType.stock,
        isin: 'FR0000031122',
      );
      final json = asset.toJson();
      expect(json['isin'], equals('FR0000031122'));

      final restored = Asset.fromJson(json);
      expect(restored.isin, equals('FR0000031122'));
      expect(restored.symbol, equals('AIR.PA'));
    });

    test('fromJson SANS la clé isin (position/backup antérieur) → null, '
        'pas d\'exception', () {
      final restored = Asset.fromJson({
        'symbol': 'AAPL',
        'type': 'stock',
        'currency': 'USD',
        // Pas de clé 'isin' du tout — simule un asset_json antérieur au champ.
      });
      expect(restored.isin, isNull);
    });

    test('copyWith(isin:) modifie le champ sans toucher au reste', () {
      final base = Asset(symbol: 'AIR.PA', type: AssetType.stock);
      final withIsin = base.copyWith(isin: 'FR0000031122');
      expect(withIsin.isin, equals('FR0000031122'));
      expect(withIsin.symbol, equals('AIR.PA'));
      // L'original reste inchangé (immutabilité).
      expect(base.isin, isNull);
    });

    test('round-trip complet préserve les autres champs métaux précieux '
        'en plus de isin', () {
      final metal = Asset(
        symbol: 'NAP',
        type: AssetType.preciousMetal,
        refSymbol: 'GC=F',
        fineWeightGrams: 5.807,
        isin: 'XX0000000000',
      );
      final restored = Asset.fromJson(metal.toJson());
      expect(restored.isin, equals('XX0000000000'));
      expect(restored.refSymbol, equals('GC=F'));
      expect(restored.fineWeightGrams, equals(5.807));
    });
  });
}

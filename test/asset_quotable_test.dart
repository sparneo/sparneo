// test/asset_quotable_test.dart
//
// Marqueur « non coté » d'Asset : sérialisation TOLÉRANTE (même politique que
// isin) — défaut `true`, omis de l'export quand true, round-trip bit-identique
// pour l'existant, aucune migration.

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset.dart';

void main() {
  group('Asset.quotable (round-trip JSON)', () {
    test('défaut true, omis de toJson (round-trip bit-identique pour l\'existant)',
        () {
      final asset = Asset(symbol: 'AIR.PA', type: AssetType.stock);
      expect(asset.quotable, isTrue);
      expect(asset.toJson().containsKey('quotable'), isFalse);
    });

    test('quotable=false → présent (false) dans toJson et round-trip', () {
      final asset = Asset(
        symbol: 'FR0000000000',
        name: 'Titre délisté',
        isin: 'FR0000000000',
        quotable: false,
      );
      final json = asset.toJson();
      expect(json['quotable'], isFalse);

      final restored = Asset.fromJson(json);
      expect(restored.quotable, isFalse);
      expect(restored.symbol, equals('FR0000000000'));
      expect(restored.isin, equals('FR0000000000'));
    });

    test('fromJson SANS la clé quotable (asset_json antérieur) → true', () {
      final restored = Asset.fromJson({
        'symbol': 'AAPL',
        'type': 'stock',
        'currency': 'USD',
      });
      expect(restored.quotable, isTrue);
    });

    test('copyWith(quotable:) modifie le champ sans toucher au reste', () {
      final base = Asset(symbol: 'AIR.PA', type: AssetType.stock);
      final nonQuotable = base.copyWith(quotable: false);
      expect(nonQuotable.quotable, isFalse);
      expect(nonQuotable.symbol, equals('AIR.PA'));
      expect(base.quotable, isTrue); // original inchangé
    });

    test('round-trip d\'un actif non coté préserve tout', () {
      final asset = Asset(
        symbol: 'US0000000000',
        name: 'Vieux titre',
        type: AssetType.stock,
        currency: 'USD',
        isin: 'US0000000000',
        quotable: false,
      );
      final restored = Asset.fromJson(asset.toJson());
      expect(restored.quotable, isFalse);
      expect(restored.currency, equals('USD'));
      expect(restored.isin, equals('US0000000000'));
      expect(restored.name, equals('Vieux titre'));
    });
  });
}

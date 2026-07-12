// test/model/allocation_target_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/model/asset.dart';

void main() {
  // -------------------------------------------------------------------------
  // (a) Constructeurs
  // -------------------------------------------------------------------------

  group('AllocationTarget — constructeurs', () {
    test('AllocationTarget.empty() produit une cible sans aucune entrée', () {
      const target = AllocationTarget.empty();
      expect(target.targets, isEmpty);
      expect(target.isEmpty, isTrue);
      expect(target.totalPercent, 0.0);
    });

    test('AllocationTarget({targets}) conserve les valeurs fournies', () {
      final target = AllocationTarget(targets: {
        AssetType.etf.name: 60.0,
        AssetType.stock.name: 25.0,
      });
      expect(target.targets, hasLength(2));
      expect(target.isEmpty, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // (b) targetFor
  // -------------------------------------------------------------------------

  group('AllocationTarget.targetFor', () {
    test('retourne le pourcentage cible si le type est présent', () {
      final target = AllocationTarget(targets: {AssetType.crypto.name: 10.0});
      expect(target.targetFor(AssetType.crypto), 10.0);
    });

    test('retourne null si le type est absent', () {
      const target = AllocationTarget.empty();
      expect(target.targetFor(AssetType.bond), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // (c) totalPercent
  // -------------------------------------------------------------------------

  group('AllocationTarget.totalPercent', () {
    test('somme correcte pour plusieurs types', () {
      final target = AllocationTarget(targets: {
        AssetType.etf.name: 40.0,
        AssetType.stock.name: 30.0,
        AssetType.crypto.name: 15.0,
      });
      expect(target.totalPercent, closeTo(85.0, 1e-9));
    });

    test('vaut 0.0 pour une cible vide', () {
      const target = AllocationTarget.empty();
      expect(target.totalPercent, 0.0);
    });
  });

  // -------------------------------------------------------------------------
  // (d) fromJson — round-trip toJson → fromJson
  // -------------------------------------------------------------------------

  group('AllocationTarget — round-trip JSON', () {
    test('toJson → fromJson conserve tous les types et pourcentages', () {
      final original = AllocationTarget(targets: {
        AssetType.etf.name: 50.0,
        AssetType.crypto.name: 20.0,
        AssetType.bond.name: 15.5,
      });
      final restored = AllocationTarget.fromJson(original.toJson());

      expect(restored.targets, hasLength(3));
      expect(restored.targetFor(AssetType.etf), 50.0);
      expect(restored.targetFor(AssetType.crypto), 20.0);
      expect(restored.targetFor(AssetType.bond), 15.5);
    });
  });

  // -------------------------------------------------------------------------
  // (e) fromJson — tolérance aux données invalides
  // -------------------------------------------------------------------------

  group('AllocationTarget.fromJson — tolérance', () {
    test("clé 'targets' absente → AllocationTarget.empty()", () {
      final target = AllocationTarget.fromJson({});
      expect(target.isEmpty, isTrue);
    });

    test("clé 'targets' est null → AllocationTarget.empty()", () {
      final target = AllocationTarget.fromJson({'targets': null});
      expect(target.isEmpty, isTrue);
    });

    test("'targets' n'est pas une Map → AllocationTarget.empty()", () {
      final target = AllocationTarget.fromJson({'targets': 'invalid'});
      expect(target.isEmpty, isTrue);
    });

    test('valeur nulle dans targets est ignorée', () {
      final target = AllocationTarget.fromJson({
        'targets': {
          AssetType.etf.name: null,
          AssetType.stock.name: 30.0,
        },
      });
      // La clé 'etf' avec valeur null doit être ignorée
      expect(target.targets.containsKey(AssetType.etf.name), isFalse);
      expect(target.targetFor(AssetType.stock), 30.0);
    });

    test('valeur négative dans targets est ignorée', () {
      final target = AllocationTarget.fromJson({
        'targets': {
          AssetType.etf.name: -5.0,
          AssetType.crypto.name: 20.0,
        },
      });
      expect(target.targets.containsKey(AssetType.etf.name), isFalse);
      expect(target.targetFor(AssetType.crypto), 20.0);
    });

    test('clé inconnue (AssetType futur) est conservée telle quelle', () {
      // Le modèle ne filtre PAS les clés inconnues, il les conserve.
      // (La logique computeGaps les ignorera côté AllocationCalculator.)
      final target = AllocationTarget.fromJson({
        'targets': {
          'unknownFutureType': 10.0,
          AssetType.etf.name: 50.0,
        },
      });
      expect(target.targets.containsKey('unknownFutureType'), isTrue);
      expect(target.targetFor(AssetType.etf), 50.0);
    });
  });

  // -------------------------------------------------------------------------
  // (f) copyWith
  // -------------------------------------------------------------------------

  group('AllocationTarget.copyWith', () {
    test('remplace les targets si fourni', () {
      final original = AllocationTarget(targets: {AssetType.etf.name: 60.0});
      final copy = original.copyWith(targets: {AssetType.crypto.name: 25.0});
      expect(copy.targets, hasLength(1));
      expect(copy.targetFor(AssetType.crypto), 25.0);
      expect(copy.targetFor(AssetType.etf), isNull);
    });

    test('conserve les targets si non fourni', () {
      final original = AllocationTarget(targets: {AssetType.etf.name: 60.0});
      final copy = original.copyWith();
      expect(copy.targets, equals(original.targets));
    });
  });
}

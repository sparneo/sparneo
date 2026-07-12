// test/model/position_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Asset _etf() => Asset(
      symbol: 'CW8',
      name: 'Amundi MSCI World',
      type: AssetType.etf,
      currency: 'EUR',
    );

/// Position avec tous les champs optionnels renseignés.
Position _full() => Position(
      accountId: 'acc_1',
      asset: _etf(),
      quantity: '10.5',
      averageBuyPrice: 42.50,
      lastUpdated: DateTime.utc(2025, 6, 1),
      customName: 'Mon ETF Monde',
    );

/// Position sans champs optionnels (customName = null, averageBuyPrice = null).
Position _minimal() => Position(
      accountId: 'acc_2',
      asset: _etf(),
      quantity: '3',
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // copyWith — champs non-nullable (comportement classique ??)
  // -------------------------------------------------------------------------

  group('Position.copyWith — champs non-nullable', () {
    test('copyWith() sans argument retourne un objet équivalent', () {
      final original = _full();
      final copy = original.copyWith();
      expect(copy.accountId, original.accountId);
      expect(copy.asset, original.asset);
      expect(copy.quantity, original.quantity);
    });

    test('copyWith(accountId:) met à jour accountId', () {
      final copy = _full().copyWith(accountId: 'acc_99');
      expect(copy.accountId, 'acc_99');
      expect(copy.quantity, '10.5'); // autres champs préservés
    });

    test('copyWith(quantity:) met à jour quantity', () {
      final copy = _full().copyWith(quantity: '20');
      expect(copy.quantity, '20');
      expect(copy.accountId, 'acc_1');
    });
  });

  // -------------------------------------------------------------------------
  // copyWith — customName (sentinelle)
  // -------------------------------------------------------------------------

  group('Position.copyWith — customName (sentinelle)', () {
    test('copyWith() sans argument PRÉSERVE customName non-null', () {
      final original = _full();
      expect(original.customName, 'Mon ETF Monde');
      final copy = original.copyWith();
      // Régression : avant le fix, customName était effacé à null.
      expect(copy.customName, 'Mon ETF Monde');
    });

    test('copyWith() sans argument PRÉSERVE customName null', () {
      final original = _minimal();
      expect(original.customName, isNull);
      final copy = original.copyWith();
      expect(copy.customName, isNull);
    });

    test('copyWith(customName: "X") met à jour customName', () {
      final copy = _full().copyWith(customName: 'Nouveau nom');
      expect(copy.customName, 'Nouveau nom');
      expect(copy.accountId, 'acc_1'); // autres champs préservés
    });

    test('copyWith(customName: "X") peut définir customName depuis null', () {
      final copy = _minimal().copyWith(customName: 'Ajouté');
      expect(copy.customName, 'Ajouté');
    });

    test('copyWith(customName: null) EFFACE explicitement customName', () {
      // Cas d'usage : réinitialisation depuis position_detail_page.dart (l.449).
      final original = _full();
      expect(original.customName, isNotNull);
      final copy = original.copyWith(customName: null);
      expect(copy.customName, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // copyWith — averageBuyPrice (sentinelle déjà présente, régression)
  // -------------------------------------------------------------------------

  group('Position.copyWith — averageBuyPrice (sentinelle)', () {
    test('copyWith() sans argument PRÉSERVE averageBuyPrice non-null', () {
      final original = _full();
      expect(original.averageBuyPrice, 42.50);
      final copy = original.copyWith();
      expect(copy.averageBuyPrice, 42.50);
    });

    test('copyWith() sans argument PRÉSERVE averageBuyPrice null', () {
      final original = _minimal();
      expect(original.averageBuyPrice, isNull);
      final copy = original.copyWith();
      expect(copy.averageBuyPrice, isNull);
    });

    test('copyWith(averageBuyPrice: 99.0) met à jour le PRU', () {
      final copy = _full().copyWith(averageBuyPrice: 99.0);
      expect(copy.averageBuyPrice, 99.0);
      expect(copy.customName, 'Mon ETF Monde'); // autres champs préservés
    });

    test('copyWith(averageBuyPrice: null) EFFACE explicitement le PRU', () {
      final original = _full();
      expect(original.averageBuyPrice, isNotNull);
      final copy = original.copyWith(averageBuyPrice: null);
      expect(copy.averageBuyPrice, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // copyWith — lastUpdated (comportement ??, pas de sémantique d'effacement)
  // -------------------------------------------------------------------------

  group('Position.copyWith — lastUpdated', () {
    test('copyWith() sans argument PRÉSERVE lastUpdated', () {
      final original = _full();
      final copy = original.copyWith();
      expect(copy.lastUpdated, original.lastUpdated);
    });

    test('copyWith(lastUpdated:) met à jour lastUpdated', () {
      final newDate = DateTime.utc(2026, 1, 1);
      final copy = _full().copyWith(lastUpdated: newDate);
      expect(copy.lastUpdated, newDate);
    });
  });

  // -------------------------------------------------------------------------
  // displayName — cohérence avec customName
  // -------------------------------------------------------------------------

  group('Position.displayName', () {
    test('retourne customName quand défini', () {
      expect(_full().displayName, 'Mon ETF Monde');
    });

    test('retourne asset.name quand customName est null', () {
      expect(_minimal().displayName, 'Amundi MSCI World');
    });

    test('retourne asset.symbol si ni customName ni asset.name', () {
      final p = Position(
        accountId: 'a',
        asset: Asset(symbol: 'XYZ', type: AssetType.other, currency: 'EUR'),
        quantity: '1',
      );
      expect(p.displayName, 'XYZ');
    });

    test('displayName reflète la suppression du customName via copyWith(null)', () {
      final original = _full();
      expect(original.displayName, 'Mon ETF Monde');
      final reset = original.copyWith(customName: null);
      // Après effacement : retombe sur asset.name
      expect(reset.displayName, 'Amundi MSCI World');
    });
  });
}

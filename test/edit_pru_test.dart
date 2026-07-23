// test/edit_pru_test.dart
//
// Action « Corriger le PRU… » (position_detail_page.dart).
//
// Deux niveaux couverts, sans aucun appel réseau :
//   - [canEditPru] (logic/position_projection.dart) : décision PURE qui pilote
//     l'affichage de l'action dans le menu ⋮ — legacy toujours éditable,
//     journalisée éditable seulement si aucun VRAI trade (buy/sell).
//   - Le chemin de stockage LEGACY que [_PositionDetailPageState._openEditPru]
//     emprunte réellement (`AccountStorage.savePosition` avec seul le PRU
//     modifié) : on vérifie directement, sur une base SQLite in-memory, que le
//     PRU stocké est mis à jour, que `derived_at` reste NULL (la position
//     reste legacy) et qu'aucun mouvement n'est créé dans le journal.

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import 'helpers/test_database.dart';

AssetTransaction _tx({
  required String id,
  required TransactionKind kind,
  String? quantity,
  String? unitPrice,
  DateTime? date,
}) {
  return AssetTransaction(
    id: id,
    accountId: 'a1',
    symbol: 'AAPL',
    kind: kind,
    quantity: quantity,
    unitPrice: unitPrice,
    currency: 'EUR',
    date: date ?? DateTime(2024, 1, 1),
  );
}

void main() {
  group('canEditPru — décision pure (menu ⋮)', () {
    test('legacy (derived_at NULL) → toujours éditable, journal vide ou non', () {
      expect(canEditPru(isLegacy: true, txs: const []), isTrue);
      // Cas défensif : une position legacy est garantie journal-vide en
      // pratique (invariant du ledger), mais la fonction reste vraie même si
      // on lui passait par erreur un journal non vide.
      expect(
        canEditPru(
          isLegacy: true,
          txs: [_tx(id: '1', kind: TransactionKind.buy, quantity: '1', unitPrice: '10')],
        ),
        isTrue,
      );
    });

    test('journalisée, journal vide → NON éditable (action "définir la position initiale")', () {
      expect(canEditPru(isLegacy: false, txs: const []), isFalse);
    });

    test('journalisée, purement déclarative (openingBalance seul) → éditable', () {
      final txs = [
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '100'),
      ];
      expect(canEditPru(isLegacy: false, txs: txs), isTrue);
    });

    test('journalisée, openingBalance + adjustment (aucun vrai trade) → éditable', () {
      final txs = [
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '100'),
        _tx(id: '2', kind: TransactionKind.adjustment, quantity: '2', unitPrice: '100'),
      ];
      expect(canEditPru(isLegacy: false, txs: txs), isTrue);
    });

    test('journalisée avec un VRAI trade (buy) → NON éditable', () {
      final txs = [
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '100'),
        _tx(id: '2', kind: TransactionKind.buy, quantity: '5', unitPrice: '120'),
      ];
      expect(canEditPru(isLegacy: false, txs: txs), isFalse);
    });

    test('journalisée avec un VRAI trade (sell) → NON éditable', () {
      final txs = [
        _tx(id: '1', kind: TransactionKind.openingBalance, quantity: '10', unitPrice: '100'),
        _tx(id: '2', kind: TransactionKind.sell, quantity: '3', unitPrice: '150'),
      ];
      expect(canEditPru(isLegacy: false, txs: txs), isFalse);
    });
  });

  group('Correction du PRU — position legacy (chemin de stockage réel)', () {
    late AppDatabase appDb;
    late AccountStorage storage;
    late TransactionStorage txStorage;

    const accountId = 'a1';
    const symbol = 'AAPL';

    setUp(() async {
      appDb = await openTestDatabase();
      storage = AccountStorage(database: appDb);
      txStorage = TransactionStorage(database: appDb);

      final db = await appDb.database;
      await db.insert('wallets', {
        'id': 'w1',
        'name': 'W',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await db.insert('accounts', {
        'id': accountId,
        'wallet_id': 'w1',
        'name': 'CTO',
        'type': 'investment',
        'currency': 'EUR',
        'kind': 'autre',
      });

      // Position LEGACY : quantité/PRU saisis à la main, derived_at NULL
      // (savePosition ne le renseigne jamais).
      await storage.savePosition(
        accountId,
        Position(
          accountId: accountId,
          asset: Asset(symbol: symbol, name: 'Apple', type: AssetType.stock, currency: 'EUR'),
          quantity: '10',
          averageBuyPrice: 100.0,
          customName: 'Mon Apple',
        ),
      );
    });

    tearDown(() async {
      await appDb.close();
    });

    test('PRU stocké mis à jour, derived_at reste NULL, aucun mouvement créé', () async {
      final before = await storage.getPositionDerivedAt(accountId, symbol);
      expect(before, isNull, reason: 'position seedée = legacy');

      // Reproduit exactement le chemin emprunté par
      // _PositionDetailPageState._openEditPru dans le cas legacy : on relit la
      // position courante, on ne change QUE le PRU, on réécrit via
      // savePosition (jamais via le ledger).
      final current = await storage.getPosition(accountId, symbol);
      expect(current, isNotNull);
      final updated = current!.copyWith(averageBuyPrice: 142.5);
      await storage.savePosition(accountId, updated);

      final after = await storage.getPosition(accountId, symbol);
      expect(after!.averageBuyPrice, closeTo(142.5, 1e-9));
      // Quantité et métadonnées préservées (mêmes valeurs qu'avant l'édition).
      expect(after.quantity, '10');
      expect(after.customName, 'Mon Apple');

      // Reste legacy : derived_at toujours NULL.
      final derivedAt = await storage.getPositionDerivedAt(accountId, symbol);
      expect(derivedAt, isNull, reason: 'la correction ne doit pas faire sortir la position du legacy');

      // Aucun mouvement de journal créé par cette correction.
      final journal = await txStorage.getBySymbol(accountId, symbol);
      expect(journal, isEmpty);
    });

    test('PRU effacé (champ vidé) → averageBuyPrice devient null, reste legacy', () async {
      final current = await storage.getPosition(accountId, symbol);
      final updated = current!.copyWith(averageBuyPrice: null);
      await storage.savePosition(accountId, updated);

      final after = await storage.getPosition(accountId, symbol);
      expect(after!.averageBuyPrice, isNull);
      expect(after.quantity, '10');

      final derivedAt = await storage.getPositionDerivedAt(accountId, symbol);
      expect(derivedAt, isNull);
      expect(await txStorage.getBySymbol(accountId, symbol), isEmpty);
    });
  });
}

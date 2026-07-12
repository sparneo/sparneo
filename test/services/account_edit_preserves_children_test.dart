// test/services/account_edit_preserves_children_test.dart
//
// Régression du bug de perte de données : éditer un compte (renommage ou
// changement de nature) ou un wallet NE DOIT PAS effacer ses enfants.
//
// Cause historique : `saveAccount` / `saveWallet` utilisaient
// `INSERT OR REPLACE`. SQLite implémente REPLACE en DELETE-puis-INSERT, ce qui
// déclenche les `ON DELETE CASCADE` de `positions` et `transactions`. Éditer un
// compte existant effaçait donc silencieusement toutes ses positions et tous
// ses mouvements. Ces tests échoueraient (0 position / 0 transaction) sur
// l'ancienne implémentation et passent avec l'UPDATE ciblé.

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';

import '../helpers/test_database.dart';

/// Insère un mouvement minimal directement en base (évite de dépendre de l'API
/// d'écriture de TransactionStorage : ce test cible la FK cascade, pas l'écrit).
Future<void> seedTransaction(
  AppDatabase db,
  String accountId,
  String id,
) async {
  final database = await db.database;
  await database.insert('transactions', {
    'id': id,
    'account_id': accountId,
    'symbol': 'AAPL',
    'kind': 'buy',
    'quantity': '1',
    'unit_price': 100.0,
    'amount': -100.0,
    'currency': 'EUR',
    'date': '2024-01-01',
  });
}

Future<int> countRows(AppDatabase db, String table, String accountId) async {
  final database = await db.database;
  final rows = await database.query(
    table,
    where: 'account_id = ?',
    whereArgs: [accountId],
  );
  return rows.length;
}

void main() {
  late AppDatabase db;
  late AccountStorage storage;

  setUp(() async {
    db = await openTestDatabase();
    storage = AccountStorage(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  final position = Position(
    accountId: 'acc1',
    asset: Asset(symbol: 'AAPL', name: 'Apple', currency: 'USD'),
    quantity: '3',
    averageBuyPrice: 150.0,
  );

  Future<void> seedTree() async {
    await storage.saveWallet(
      Wallet(id: 'w1', name: 'Mon wallet', createdAt: DateTime(2024, 1, 1)),
    );
    await storage.saveAccount(
      Account(id: 'acc1', walletId: 'w1', name: 'CTO', kind: AccountKind.cto),
    );
    await storage.savePosition('acc1', position);
    await seedTransaction(db, 'acc1', 'tx-1');
  }

  group('saveAccount — édition non destructive', () {
    test('changer la nature conserve positions ET transactions', () async {
      await seedTree();
      expect(await countRows(db, 'positions', 'acc1'), 1);
      expect(await countRows(db, 'transactions', 'acc1'), 1);

      // L'utilisateur change la nature du compte (CTO → PEA).
      await storage.saveAccount(
        Account(id: 'acc1', walletId: 'w1', name: 'CTO', kind: AccountKind.pea),
      );

      expect(
        await countRows(db, 'positions', 'acc1'),
        1,
        reason: 'les positions ne doivent pas être effacées par une édition',
      );
      expect(
        await countRows(db, 'transactions', 'acc1'),
        1,
        reason: 'les mouvements ne doivent pas être effacés par une édition',
      );

      final accounts = await storage.getAccountsByWallet('w1');
      expect(
        accounts.single.kind,
        AccountKind.pea,
        reason: 'la nouvelle nature doit bien être persistée',
      );
    });

    test('renommer le compte conserve positions ET transactions', () async {
      await seedTree();

      await storage.saveAccount(
        Account(
          id: 'acc1',
          walletId: 'w1',
          name: 'CTO renommé',
          kind: AccountKind.cto,
        ),
      );

      expect(await countRows(db, 'positions', 'acc1'), 1);
      expect(await countRows(db, 'transactions', 'acc1'), 1);
      final accounts = await storage.getAccountsByWallet('w1');
      expect(accounts.single.name, 'CTO renommé');
    });

    test('créer un compte inexistant fonctionne toujours (INSERT)', () async {
      await storage.saveWallet(
        Wallet(id: 'w1', name: 'W', createdAt: DateTime(2024, 1, 1)),
      );
      await storage.saveAccount(
        Account(
          id: 'accX',
          walletId: 'w1',
          name: 'Nouveau',
          kind: AccountKind.pea,
        ),
      );
      final accounts = await storage.getAccountsByWallet('w1');
      expect(accounts.single.id, 'accX');
    });
  });

  group('saveWallet — édition non destructive', () {
    test('renommer le wallet conserve tout son arbre', () async {
      await seedTree();

      await storage.saveWallet(
        Wallet(
          id: 'w1',
          name: 'Wallet renommé',
          createdAt: DateTime(2024, 1, 1),
        ),
      );

      final accounts = await storage.getAccountsByWallet('w1');
      expect(accounts.length, 1, reason: 'le compte ne doit pas disparaître');
      expect(await countRows(db, 'positions', 'acc1'), 1);
      expect(await countRows(db, 'transactions', 'acc1'), 1);

      final wallets = await storage.getAllWallets();
      expect(wallets.single.name, 'Wallet renommé');
    });
  });
}

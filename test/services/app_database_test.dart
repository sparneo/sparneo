// test/services/app_database_test.dart
//
// Tests de la couche d'accès SQLite (AppDatabase) :
//   (a) les 5 tables du schéma v1 existent dans sqlite_master
//   (b) PRAGMA foreign_keys renvoie 1 après ouverture
//   (c) suppression d'un wallet supprime son account en cascade (FK ON)
//   (d) deux bases in-memory sont isolées (pas de pollution croisée)

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import '../helpers/test_database.dart';

void main() {
  // Initialisation ffi avant toute ouverture de base.
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ---------------------------------------------------------------------------
  // (a) Les 5 tables existent dans sqlite_master
  // ---------------------------------------------------------------------------
  test('schéma v1 : les 5 tables sont créées', () async {
    final appDb = await openTestDatabase();
    final db = await appDb.database;

    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    );
    final tableNames = rows.map((r) => r['name'] as String).toSet();

    expect(tableNames, containsAll(<String>[
      'wallets',
      'accounts',
      'positions',
      'snapshots',
      'allocation_targets',
    ]));

    await appDb.close();
  });

  // ---------------------------------------------------------------------------
  // (b) PRAGMA foreign_keys renvoie 1 après ouverture
  // ---------------------------------------------------------------------------
  test('PRAGMA foreign_keys est activé (= 1) à l\'ouverture', () async {
    final appDb = await openTestDatabase();
    final db = await appDb.database;

    final result = await db.rawQuery('PRAGMA foreign_keys');
    expect(result, hasLength(1));
    expect(result.first['foreign_keys'], equals(1));

    await appDb.close();
  });

  // ---------------------------------------------------------------------------
  // (c) ON DELETE CASCADE : suppression wallet → suppression account
  // ---------------------------------------------------------------------------
  test('FK cascade : supprimer un wallet supprime ses accounts', () async {
    final appDb = await openTestDatabase();
    final db = await appDb.database;

    const walletId = 'wallet-cascade-test';
    const accountId = 'account-cascade-test';

    // Insertion du wallet parent.
    await db.insert('wallets', {
      'id': walletId,
      'name': 'Test Wallet',
      'created_at': '2024-01-01T00:00:00.000',
    });

    // Insertion de l'account enfant.
    await db.insert('accounts', {
      'id': accountId,
      'wallet_id': walletId,
      'name': 'Test Account',
      'type': 'investment',
      'currency': 'EUR',
    });

    // Vérifie que l'account existe bien avant la suppression.
    final before = await db.query(
      'accounts',
      where: 'id = ?',
      whereArgs: [accountId],
    );
    expect(before, hasLength(1));

    // Suppression du wallet parent.
    await db.delete('wallets', where: 'id = ?', whereArgs: [walletId]);

    // L'account doit avoir été supprimé en cascade.
    final after = await db.query(
      'accounts',
      where: 'id = ?',
      whereArgs: [accountId],
    );
    expect(after, isEmpty,
        reason: 'L\'account doit être supprimé par FK ON DELETE CASCADE');

    await appDb.close();
  });

  // ---------------------------------------------------------------------------
  // (d) Deux bases in-memory sont isolées
  // ---------------------------------------------------------------------------
  test('deux bases in-memory sont indépendantes', () async {
    final appDb1 = AppDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    final appDb2 = AppDatabase(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );

    final db1 = await appDb1.database;
    final db2 = await appDb2.database;

    // Insertion d'un wallet uniquement dans db1.
    await db1.insert('wallets', {
      'id': 'wallet-isolation-test',
      'name': 'Wallet db1',
      'created_at': '2024-01-01T00:00:00.000',
    });

    // db2 ne doit PAS voir ce wallet.
    final rowsInDb2 = await db2.query(
      'wallets',
      where: 'id = ?',
      whereArgs: ['wallet-isolation-test'],
    );
    expect(rowsInDb2, isEmpty,
        reason: 'Les bases in-memory distinctes ne partagent pas leurs données');

    await appDb1.close();
    await appDb2.close();
  });
}

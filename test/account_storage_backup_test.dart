// test/account_storage_backup_test.dart
//
// Vérifie exportRawData / importRawData de AccountStorage sur SQLite.
// Aucun appel réseau, aucune écriture disque réelle (bases in-memory).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/valuation_snapshot.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';

import 'helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Helpers de niveau fichier
// ---------------------------------------------------------------------------

/// Snapshots valides (ValuationSnapshot.toJson()) pour le wallet 'w1'.
final snapshotsW1 = [
  ValuationSnapshot(
    date: '2024-01-01',
    totalValue: 1000.0,
    currency: 'EUR',
    capturedAt: 1704067200000,
    accountCount: 2,
    schemaVersion: 1,
  ).toJson(),
  ValuationSnapshot(
    date: '2024-02-01',
    totalValue: 1100.0,
    currency: 'EUR',
    capturedAt: 1706745600000,
    accountCount: 2,
    schemaVersion: 1,
  ).toJson(),
];

/// Snapshots valides pour le wallet 'w2'.
final snapshotsW2 = [
  ValuationSnapshot(
    date: '2024-01-15',
    totalValue: 500.0,
    currency: 'EUR',
    capturedAt: 1705276800000,
    accountCount: 1,
    schemaVersion: 1,
  ).toJson(),
];

/// Cibles d'allocation pour le wallet 'w1'.
final allocationTargetsW1 =
    AllocationTarget(targets: {AssetType.etf.name: 60.0, AssetType.crypto.name: 20.0}).toJson();

/// Cibles d'allocation pour le wallet 'w2'.
final allocationTargetsW2 =
    AllocationTarget(targets: {AssetType.stock.name: 40.0}).toJson();

/// Insère un wallet puis ses snapshots directement dans la DB.
Future<void> seedWalletWithSnapshots(
  AppDatabase db,
  String walletId,
  List<Map<String, dynamic>> snapJsonList,
) async {
  final database = await db.database;
  await database.insert(
    'wallets',
    {
      'id': walletId,
      'name': 'Wallet $walletId',
      'created_at': '2024-01-01T00:00:00.000',
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  for (final sJson in snapJsonList) {
    final s = ValuationSnapshot.fromJson(sJson);
    await database.rawInsert(
      '''
      INSERT OR REPLACE INTO snapshots
        (wallet_id, date, total_value, currency, captured_at, account_count, schema_version)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [walletId, s.date, s.totalValue, s.currency, s.capturedAt, s.accountCount, s.schemaVersion],
    );
  }
}

/// Insère un wallet puis ses allocation_targets directement dans la DB.
Future<void> seedWalletWithTargets(
  AppDatabase db,
  String walletId,
  Map<String, dynamic> targetJson,
) async {
  final database = await db.database;
  await database.insert(
    'wallets',
    {
      'id': walletId,
      'name': 'Wallet $walletId',
      'created_at': '2024-01-01T00:00:00.000',
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  await database.rawInsert(
    'INSERT OR REPLACE INTO allocation_targets(wallet_id, target_json) VALUES(?, ?)',
    [walletId, jsonEncode(targetJson)],
  );
}

/// Insère un wallet + un compte directement dans la DB (parent FK des
/// transactions). Retourne l'id du compte créé.
Future<void> seedWalletAndAccount(
  AppDatabase db,
  String walletId,
  String accountId,
) async {
  final database = await db.database;
  // ConflictAlgorithm.ignore sur le wallet : réinsérer w1 en REPLACE
  // cascade-supprimerait les comptes enfants déjà créés (FK ON DELETE CASCADE),
  // faussant les seeds multi-comptes sous un même wallet.
  await database.insert(
    'wallets',
    {
      'id': walletId,
      'name': 'Wallet $walletId',
      'created_at': '2024-01-01T00:00:00.000',
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
  await database.insert(
    'accounts',
    {
      'id': accountId,
      'wallet_id': walletId,
      'name': 'Compte $accountId',
      'type': 'investment',
      'currency': 'EUR',
      'created_at': '2024-01-01T00:00:00.000',
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

/// Insère une transaction directement dans la DB via le mapping colonnes.
Future<void> seedTransaction(AppDatabase db, AssetTransaction tx) async {
  final database = await db.database;
  await database.rawInsert(
    '''
    INSERT OR REPLACE INTO transactions
      (id, account_id, symbol, kind, quantity, unit_price, amount,
       currency, date, fee, note, meta_json)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      tx.id,
      tx.accountId,
      tx.symbol,
      tx.kind.wire,
      tx.quantity,
      tx.unitPrice,
      tx.amount,
      tx.currency,
      tx.date.toIso8601String(),
      tx.fee,
      tx.note,
      tx.meta != null ? jsonEncode(tx.meta) : null,
    ],
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // (a) Export inclut les clés snapshots regroupées par walletId
  // ---------------------------------------------------------------------------

  group('exportRawData – snapshots', () {
    test('inclut les snapshots existants regroupés par walletId', () async {
      await seedWalletWithSnapshots(db, 'w1', snapshotsW1);
      await seedWalletWithSnapshots(db, 'w2', snapshotsW2);

      final exported = await storage.exportRawData();

      expect(exported.containsKey('snapshots'), isTrue);

      final snapshots = exported['snapshots'] as Map<String, dynamic>;
      expect(snapshots.containsKey('w1'), isTrue);
      expect(snapshots.containsKey('w2'), isTrue);

      // Les données exportées doivent correspondre aux originaux.
      expect(snapshots['w1'], equals(snapshotsW1));
      expect(snapshots['w2'], equals(snapshotsW2));
    });

    test("renvoie une map snapshots vide quand aucun snapshot n'existe", () async {
      final exported = await storage.exportRawData();

      expect(exported['snapshots'], isA<Map>());
      expect((exported['snapshots'] as Map).isEmpty, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (a-bis) Enveloppe fiscale : fidélité du round-trip + rétro-compat backup.
  // ---------------------------------------------------------------------------

  group('exportRawData / importRawData – kind', () {
    test('une nature non-défaut survit au round-trip export→import', () async {
      // Wallet parent (FK), puis un compte PEA sauvé via l'API métier.
      final database = await db.database;
      await database.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await storage.saveAccount(Account(
        id: 'acc-pea',
        walletId: 'w1',
        name: 'Mon PEA',
        kind: AccountKind.pea,
      ));

      // Export : le JSON du compte porte la nature.
      final exported = await storage.exportRawData();
      final accounts = exported['accounts'] as List;
      expect(accounts.single['kind'], equals('pea'));

      // Round-trip import → relecture : la nature est préservée.
      await storage.importRawData(exported);
      final reloaded = await storage.getAllAccounts();
      expect(reloaded.single.kind, equals(AccountKind.pea));
    });

    test('un backup ancien SANS clé kind importe en "autre"', () async {
      // Simule une sauvegarde d'avant l'introduction de la nature : la clé
      // 'kind' est absente du JSON du compte.
      final legacyBackup = {
        'wallets': [
          {'id': 'w1', 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
        ],
        'accounts': [
          {
            'id': 'acc-legacy',
            'walletId': 'w1',
            'name': 'Compte historique',
            'type': 'investment',
            'currency': 'EUR',
            // pas de clé 'kind'
          }
        ],
      };

      await expectLater(storage.importRawData(legacyBackup), completes);

      final reloaded = await storage.getAllAccounts();
      expect(reloaded.single.kind, equals(AccountKind.autre),
          reason: 'clé absente (backup pré-nature) → défaut AUTRE');
    });
  });

  // ---------------------------------------------------------------------------
  // (b) Import d'une sauvegarde SANS clé 'snapshots' : pas d'exception,
  //     snapshots préexistants purgés
  // ---------------------------------------------------------------------------

  group('importRawData – tolérance ascendante', () {
    test(
        'sauvegarde sans clé snapshots importe sans erreur et purge les snapshots préexistants',
        () async {
      // État initial : un snapshot existe déjà
      await seedWalletWithSnapshots(db, 'w1', snapshotsW1);

      // Sauvegarde ancienne sans la clé 'snapshots'
      final ancienneBackup = <String, dynamic>{
        'wallets': [],
        'accounts': [],
        'positions': <String, dynamic>{},
        // pas de clé 'snapshots' — volontairement absente
      };

      // Ne doit pas lever d'exception
      await expectLater(storage.importRawData(ancienneBackup), completes);

      // Les snapshots préexistants doivent avoir été supprimés
      final exported = await storage.exportRawData();
      final snapshots = exported['snapshots'] as Map<String, dynamic>;
      expect(snapshots.containsKey('w1'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // (c) Round-trip export → import → export : résultat identique
  // ---------------------------------------------------------------------------

  group('round-trip export → import → export', () {
    test('les données snapshots sont identiques après un cycle complet', () async {
      // Seed : wallet w1 avec snapshots
      await seedWalletWithSnapshots(db, 'w1', snapshotsW1);

      // Premier export
      final export1 = await storage.exportRawData();

      // Import des données exportées
      await storage.importRawData(export1);

      // Second export
      final export2 = await storage.exportRawData();

      // Les deux exports doivent être identiques
      expect(export2['snapshots'], equals(export1['snapshots']));
      expect(export2['wallets'], equals(export1['wallets']));
      expect(export2['accounts'], equals(export1['accounts']));
      expect(export2['positions'], equals(export1['positions']));
    });
  });

  // ---------------------------------------------------------------------------
  // (d) deleteWallet supprime les snapshots du wallet (cascade FK)
  // ---------------------------------------------------------------------------

  group('deleteWallet – suppression en cascade des snapshots', () {
    test('supprime les snapshots du wallet supprimé, laisse l\'autre intact', () async {
      await seedWalletWithSnapshots(db, 'w1', snapshotsW1);
      await seedWalletWithSnapshots(db, 'w2', snapshotsW2);

      await storage.deleteWallet('w1');

      final exported = await storage.exportRawData();
      final snapshots = exported['snapshots'] as Map<String, dynamic>;

      // La clé du wallet supprimé doit avoir disparu
      expect(snapshots.containsKey('w1'), isFalse);

      // La clé de l'autre wallet ne doit pas avoir été touchée
      expect(snapshots.containsKey('w2'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (e) Export inclut les allocationTargets regroupées par walletId
  // ---------------------------------------------------------------------------

  group('exportRawData – allocationTargets', () {
    test('inclut les cibles existantes regroupées par walletId', () async {
      await seedWalletWithTargets(db, 'w1', allocationTargetsW1);
      await seedWalletWithTargets(db, 'w2', allocationTargetsW2);

      final exported = await storage.exportRawData();

      expect(exported.containsKey('allocationTargets'), isTrue);

      final targets = exported['allocationTargets'] as Map<String, dynamic>;
      expect(targets.containsKey('w1'), isTrue);
      expect(targets.containsKey('w2'), isTrue);
      expect(targets['w1'], equals(allocationTargetsW1));
      expect(targets['w2'], equals(allocationTargetsW2));
    });

    test("renvoie une map allocationTargets vide quand aucune cible n'existe", () async {
      final exported = await storage.exportRawData();

      expect(exported['allocationTargets'], isA<Map>());
      expect((exported['allocationTargets'] as Map).isEmpty, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (f) Import d'une sauvegarde SANS clé 'allocationTargets' : pas d'exception,
  //     cibles préexistantes purgées
  // ---------------------------------------------------------------------------

  group('importRawData – tolérance ascendante allocationTargets', () {
    test(
        'sauvegarde sans clé allocationTargets importe sans erreur et purge les cibles préexistantes',
        () async {
      await seedWalletWithTargets(db, 'w1', allocationTargetsW1);

      // Sauvegarde ancienne sans la clé 'allocationTargets'
      final ancienneBackup = <String, dynamic>{
        'wallets': [],
        'accounts': [],
        'positions': <String, dynamic>{},
        // pas de clé 'allocationTargets' — volontairement absente
      };

      // Ne doit pas lever d'exception
      await expectLater(storage.importRawData(ancienneBackup), completes);

      // La cible orpheline doit avoir été supprimée
      final exported = await storage.exportRawData();
      final targets = exported['allocationTargets'] as Map<String, dynamic>;
      expect(targets.containsKey('w1'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // (g) Round-trip export → import → export : allocationTargets identiques
  // ---------------------------------------------------------------------------

  group('round-trip export → import → export — allocationTargets', () {
    test('les cibles sont identiques après un cycle complet', () async {
      await seedWalletWithTargets(db, 'w1', allocationTargetsW1);

      final export1 = await storage.exportRawData();
      await storage.importRawData(export1);
      final export2 = await storage.exportRawData();

      expect(export2['allocationTargets'], equals(export1['allocationTargets']));
      expect(export2['wallets'], equals(export1['wallets']));
    });
  });

  // ---------------------------------------------------------------------------
  // (h) deleteWallet supprime les allocation_targets du wallet (cascade FK)
  // ---------------------------------------------------------------------------

  group('deleteWallet – suppression en cascade des allocationTargets', () {
    test('supprime les cibles du wallet supprimé, laisse l\'autre intact', () async {
      await seedWalletWithTargets(db, 'w1', allocationTargetsW1);
      await seedWalletWithTargets(db, 'w2', allocationTargetsW2);

      await storage.deleteWallet('w1');

      final exported = await storage.exportRawData();
      final targets = exported['allocationTargets'] as Map<String, dynamic>;

      expect(targets.containsKey('w1'), isFalse);
      expect(targets.containsKey('w2'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (i) deleteAccount supprime les positions en cascade (FK ON DELETE CASCADE)
  // ---------------------------------------------------------------------------

  group('deleteAccount – suppression en cascade des positions', () {
    test('les positions du compte supprimé disparaissent, l\'autre compte est intact', () async {
      // Seed : un wallet, deux comptes, une position chacun
      final database = await db.database;
      await database.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await database.insert('accounts', {
        'id': 'acc1',
        'wallet_id': 'w1',
        'name': 'Compte 1',
        'type': 'investment',
        'currency': 'EUR',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await database.insert('accounts', {
        'id': 'acc2',
        'wallet_id': 'w1',
        'name': 'Compte 2',
        'type': 'investment',
        'currency': 'EUR',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await database.rawInsert(
        '''INSERT INTO positions(account_id, symbol, quantity, asset_json)
           VALUES(?, ?, ?, ?)''',
        ['acc1', 'AAPL', '5', '{"symbol":"AAPL","type":"other","currency":"USD"}'],
      );
      await database.rawInsert(
        '''INSERT INTO positions(account_id, symbol, quantity, asset_json)
           VALUES(?, ?, ?, ?)''',
        ['acc2', 'SPY', '3', '{"symbol":"SPY","type":"etf","currency":"EUR"}'],
      );

      await storage.deleteAccount('acc1');

      // Les positions de acc1 ont disparu
      final pos1 = await storage.getPositions('acc1');
      expect(pos1, isEmpty);

      // Les positions de acc2 sont intactes
      final pos2 = await storage.getPositions('acc2');
      expect(pos2, hasLength(1));
      expect(pos2.first.symbol, 'SPY');
    });
  });

  // ---------------------------------------------------------------------------
  // (j) deleteWallet supprime tout l'arbre (cascade complète)
  // ---------------------------------------------------------------------------

  group('deleteWallet – cascade complète de l\'arbre', () {
    test(
        'supprimer w1 efface accounts, positions, snapshots, targets ; w2 est intact',
        () async {
      // Seed : deux wallets complets
      final database = await db.database;

      for (final wid in ['w1', 'w2']) {
        await database.insert('wallets', {
          'id': wid,
          'name': 'Wallet $wid',
          'created_at': '2024-01-01T00:00:00.000',
        });
        await database.insert('accounts', {
          'id': 'acc-$wid',
          'wallet_id': wid,
          'name': 'Compte $wid',
          'type': 'investment',
          'currency': 'EUR',
          'created_at': '2024-01-01T00:00:00.000',
        });
        await database.rawInsert(
          '''INSERT INTO positions(account_id, symbol, quantity, asset_json)
             VALUES(?, ?, ?, ?)''',
          ['acc-$wid', 'SYM', '1', '{"symbol":"SYM","type":"other","currency":"EUR"}'],
        );
        final s = ValuationSnapshot(
          date: '2024-06-01',
          totalValue: 1000.0,
          currency: 'EUR',
          capturedAt: 1717200000000,
        );
        await database.rawInsert(
          '''INSERT INTO snapshots
               (wallet_id, date, total_value, currency, captured_at, account_count, schema_version)
             VALUES(?, ?, ?, ?, ?, ?, ?)''',
          [wid, s.date, s.totalValue, s.currency, s.capturedAt, s.accountCount, s.schemaVersion],
        );
        await database.rawInsert(
          'INSERT INTO allocation_targets(wallet_id, target_json) VALUES(?, ?)',
          [wid, jsonEncode(AllocationTarget(targets: {AssetType.etf.name: 50.0}).toJson())],
        );
      }

      await storage.deleteWallet('w1');

      // w1 et tout son arbre ont disparu
      final wallets = await storage.getAllWallets();
      expect(wallets.any((w) => w.id == 'w1'), isFalse);

      final accounts = await storage.getAllAccounts();
      expect(accounts.any((a) => a.walletId == 'w1'), isFalse);

      final positions = await storage.getPositions('acc-w1');
      expect(positions, isEmpty);

      final exported = await storage.exportRawData();
      expect((exported['snapshots'] as Map).containsKey('w1'), isFalse);
      expect((exported['allocationTargets'] as Map).containsKey('w1'), isFalse);

      // w2 est intact
      expect(wallets.any((w) => w.id == 'w2'), isTrue);
      expect(accounts.any((a) => a.walletId == 'w2'), isTrue);
      expect((exported['snapshots'] as Map).containsKey('w2'), isTrue);
      expect((exported['allocationTargets'] as Map).containsKey('w2'), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (k) LOT E — Export inclut les transactions regroupées par accountId
  // ---------------------------------------------------------------------------

  group('exportRawData – transactions', () {
    test('inclut les transactions existantes regroupées par accountId', () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');
      await seedWalletAndAccount(db, 'w1', 'acc2');

      final txBuy = AssetTransaction(
        id: 'tx-1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '150.5',
        amount: '-1505.00',
        currency: 'USD',
        date: DateTime.parse('2024-03-01T10:00:00.000'),
        fee: '1.20',
        note: 'achat',
        meta: {'source': 'test', 'tags': [1, 2, 3]},
      );
      final txDiv = AssetTransaction(
        id: 'tx-2',
        accountId: 'acc2',
        symbol: null,
        kind: TransactionKind.deposit,
        quantity: null,
        unitPrice: null,
        amount: '500.00',
        currency: 'EUR',
        date: DateTime.parse('2024-04-01T09:00:00.000'),
        fee: null,
        note: null,
        meta: null,
      );
      await seedTransaction(db, txBuy);
      await seedTransaction(db, txDiv);

      final exported = await storage.exportRawData();

      expect(exported.containsKey('transactions'), isTrue);
      final transactions = exported['transactions'] as Map<String, dynamic>;
      expect(transactions.containsKey('acc1'), isTrue);
      expect(transactions.containsKey('acc2'), isTrue);

      expect(transactions['acc1'], equals([txBuy.toJson()]));
      expect(transactions['acc2'], equals([txDiv.toJson()]));
    });

    test("renvoie une map transactions vide quand aucune transaction n'existe",
        () async {
      final exported = await storage.exportRawData();
      expect(exported['transactions'], isA<Map>());
      expect((exported['transactions'] as Map).isEmpty, isTrue);
    });

    test('ORDER BY déterministe : plusieurs transactions triées account_id/date/id',
        () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');

      // Insérées dans le désordre : l'export doit les ordonner par date puis id.
      final txLate = AssetTransaction(
        id: 'b',
        accountId: 'acc1',
        kind: TransactionKind.buy,
        currency: 'EUR',
        amount: '-10',
        date: DateTime.parse('2024-05-02T00:00:00.000'),
      );
      final txEarly = AssetTransaction(
        id: 'a',
        accountId: 'acc1',
        kind: TransactionKind.sell,
        currency: 'EUR',
        amount: '20',
        date: DateTime.parse('2024-05-01T00:00:00.000'),
      );
      await seedTransaction(db, txLate);
      await seedTransaction(db, txEarly);

      final exported = await storage.exportRawData();
      final list = (exported['transactions'] as Map)['acc1'] as List;
      expect(list.map((e) => e['id']).toList(), equals(['a', 'b']));
    });
  });

  // ---------------------------------------------------------------------------
  // (l) LOT E — Round-trip export → import → export : transactions identiques
  // ---------------------------------------------------------------------------

  group('round-trip export → import → export — transactions', () {
    test('les transactions sont identiques après un cycle complet', () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');
      await seedTransaction(
        db,
        AssetTransaction(
          id: 'tx-1',
          accountId: 'acc1',
          symbol: 'AAPL',
          kind: TransactionKind.buy,
          quantity: '10',
          unitPrice: '150.5',
          amount: '-1505.00',
          currency: 'USD',
          date: DateTime.parse('2024-03-01T10:00:00.000'),
          fee: '1.20',
          note: 'achat',
          meta: {'source': 'test'},
        ),
      );
      await seedTransaction(
        db,
        AssetTransaction(
          id: 'tx-2',
          accountId: 'acc1',
          kind: TransactionKind.deposit,
          amount: '500.00',
          currency: 'EUR',
          date: DateTime.parse('2024-04-01T09:00:00.000'),
        ),
      );

      final export1 = await storage.exportRawData();
      await storage.importRawData(export1);
      final export2 = await storage.exportRawData();

      expect(export2['transactions'], equals(export1['transactions']));
      // Les autres collections restent stables aussi.
      expect(export2['wallets'], equals(export1['wallets']));
      expect(export2['accounts'], equals(export1['accounts']));
    });

    test('fidélité : meta non-null, amount signé, symbol null round-trip sans perte',
        () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');
      final cashTx = AssetTransaction(
        id: 'cash-1',
        accountId: 'acc1',
        symbol: null, // cash pur
        kind: TransactionKind.withdrawal,
        quantity: null,
        unitPrice: null,
        amount: '-42.99', // signé négatif
        currency: 'EUR',
        date: DateTime.parse('2024-06-15T12:34:56.000'),
        fee: null,
        note: 'retrait',
        meta: {'nested': {'k': 'v'}, 'n': 7},
      );
      await seedTransaction(db, cashTx);

      final export1 = await storage.exportRawData();
      await storage.importRawData(export1);
      final exported = await storage.exportRawData();

      final list = (exported['transactions'] as Map)['acc1'] as List;
      expect(list, hasLength(1));
      expect(list.first, equals(cashTx.toJson()));
    });
  });

  // ---------------------------------------------------------------------------
  // (m) LOT E — Tolérance ascendante : backup SANS clé 'transactions'
  // ---------------------------------------------------------------------------

  group('importRawData – tolérance ascendante transactions', () {
    test(
        'sauvegarde sans clé transactions importe sans erreur et purge les transactions préexistantes',
        () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');
      await seedTransaction(
        db,
        AssetTransaction(
          id: 'tx-1',
          accountId: 'acc1',
          kind: TransactionKind.buy,
          amount: '-10',
          currency: 'EUR',
          date: DateTime.parse('2024-03-01T10:00:00.000'),
        ),
      );

      // Ancienne sauvegarde SANS la clé 'transactions'.
      final ancienneBackup = <String, dynamic>{
        'wallets': [],
        'accounts': [],
        'positions': <String, dynamic>{},
        // pas de clé 'transactions' — volontairement absente
      };

      await expectLater(storage.importRawData(ancienneBackup), completes);

      final exported = await storage.exportRawData();
      final transactions = exported['transactions'] as Map<String, dynamic>;
      expect(transactions.containsKey('acc1'), isFalse);
      expect(transactions.isEmpty, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // (n) LOT E — Cascade / atomicité : transaction orpheline → rollback
  // ---------------------------------------------------------------------------

  group('importRawData – transaction orpheline rejetée atomiquement', () {
    test(
        'un backup dont une transaction référence un accountId absent est rejeté, données existantes préservées',
        () async {
      // État initial cohérent : un wallet + compte + transaction valides.
      await seedWalletAndAccount(db, 'w1', 'acc1');
      await seedTransaction(
        db,
        AssetTransaction(
          id: 'existing',
          accountId: 'acc1',
          kind: TransactionKind.buy,
          amount: '-10',
          currency: 'EUR',
          date: DateTime.parse('2024-01-01T00:00:00.000'),
        ),
      );

      // Backup incohérent : transaction sous un accountId 'ghost' inexistant.
      final backupCorrompu = <String, dynamic>{
        'wallets': [
          {'id': 'w1', 'name': 'Wallet w1', 'createdAt': '2024-01-01T00:00:00.000'},
        ],
        'accounts': [
          {
            'id': 'acc1',
            'walletId': 'w1',
            'name': 'Compte',
            'type': 'investment',
            'currency': 'EUR',
            'createdAt': '2024-01-01T00:00:00.000',
          },
        ],
        'positions': <String, dynamic>{},
        'transactions': {
          'ghost': [
            AssetTransaction(
              id: 'orphan',
              accountId: 'ghost',
              kind: TransactionKind.buy,
              amount: '-5',
              currency: 'EUR',
              date: DateTime.parse('2024-02-01T00:00:00.000'),
            ).toJson(),
          ],
        },
      };

      // La FK account_id → accounts échoue → rollback de TOUTE la transaction.
      await expectLater(storage.importRawData(backupCorrompu), throwsA(anything));

      // Données préexistantes intactes (rollback atomique).
      final exported = await storage.exportRawData();
      final transactions = exported['transactions'] as Map<String, dynamic>;
      expect(transactions.containsKey('acc1'), isTrue);
      expect((transactions['acc1'] as List).first['id'], equals('existing'));
      expect(transactions.containsKey('ghost'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // (n2) Chantier B* prérequis : nouveaux kinds openingBalance / adjustment
  // ---------------------------------------------------------------------------

  group('importRawData – nouveaux kinds (openingBalance / adjustment)', () {
    test(
        'round-trip export→import→export des kinds openingBalance et adjustment '
        '(kind, quantité signée et meta préservés)', () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');
      // openingBalance déclaratif avec meta.declarative.
      await seedTransaction(
        db,
        AssetTransaction(
          id: 'tx-ob',
          accountId: 'acc1',
          symbol: 'FOO',
          kind: TransactionKind.openingBalance,
          quantity: '10',
          unitPrice: '50',
          currency: 'EUR',
          date: DateTime.parse('2024-01-01T00:00:00.000'),
          meta: const {'declarative': true},
        ),
      );
      // adjustment à quantité NÉGATIVE (delta signé).
      await seedTransaction(
        db,
        AssetTransaction(
          id: 'tx-adj',
          accountId: 'acc1',
          symbol: 'FOO',
          kind: TransactionKind.adjustment,
          quantity: '-3',
          unitPrice: '50',
          currency: 'EUR',
          date: DateTime.parse('2024-02-01T00:00:00.000'),
        ),
      );

      final export1 = await storage.exportRawData();
      await storage.importRawData(export1);
      final export2 = await storage.exportRawData();

      // Round-trip stable.
      expect(export2['transactions'], equals(export1['transactions']));

      final txs = (export2['transactions'] as Map)['acc1'] as List;
      final ob = txs.firstWhere((t) => (t as Map)['id'] == 'tx-ob') as Map;
      final adj = txs.firstWhere((t) => (t as Map)['id'] == 'tx-adj') as Map;
      expect(ob['kind'], 'openingBalance');
      expect(ob['meta'], {'declarative': true});
      expect(adj['kind'], 'adjustment');
      expect(adj['quantity'], '-3'); // signe préservé
    });
  });

  // ---------------------------------------------------------------------------
  // (n3) Sûreté ascendante : un kind INCONNU est rejeté atomiquement à l'import,
  //      jamais coercé en buy (cœur de l'étape prérequis B*).
  // ---------------------------------------------------------------------------

  group('importRawData – kind inconnu rejeté atomiquement (pas de coercition)', () {
    test(
        'un backup dont une transaction porte un kind inconnu est rejeté, '
        'données existantes préservées', () async {
      // État initial cohérent.
      await seedWalletAndAccount(db, 'w1', 'acc1');
      await seedTransaction(
        db,
        AssetTransaction(
          id: 'existing',
          accountId: 'acc1',
          kind: TransactionKind.buy,
          amount: '-10',
          currency: 'EUR',
          date: DateTime.parse('2024-01-01T00:00:00.000'),
        ),
      );

      // Backup avec une transaction au kind inconnu (simule une sauvegarde
      // produite par une version plus récente, avant le versionnement).
      final backupFutur = <String, dynamic>{
        'wallets': [
          {'id': 'w1', 'name': 'Wallet w1', 'createdAt': '2024-01-01T00:00:00.000'},
        ],
        'accounts': [
          {
            'id': 'acc1',
            'walletId': 'w1',
            'name': 'Compte',
            'type': 'investment',
            'currency': 'EUR',
            'createdAt': '2024-01-01T00:00:00.000',
          },
        ],
        'positions': <String, dynamic>{},
        'transactions': {
          'acc1': [
            {
              'id': 'tx-future',
              'accountId': 'acc1',
              'symbol': 'FOO',
              'kind': 'someFutureKind', // INCONNU
              'quantity': '1',
              'unitPrice': '1',
              'amount': '-1',
              'currency': 'EUR',
              'date': '2024-03-01T00:00:00.000',
            },
          ],
        },
      };

      // Rejet (FormatException) → rollback atomique de TOUTE la restauration.
      await expectLater(storage.importRawData(backupFutur), throwsA(anything));

      // Données préexistantes intactes, et surtout AUCUNE transaction coercée
      // en buy n'a été insérée.
      final exported = await storage.exportRawData();
      final transactions = exported['transactions'] as Map<String, dynamic>;
      final accTxs = transactions['acc1'] as List;
      expect(accTxs.length, 1);
      expect((accTxs.single as Map)['id'], equals('existing'));
      expect(accTxs.any((t) => (t as Map)['id'] == 'tx-future'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // (o) LOT E — Cascade FK : deleteAccount / deleteWallet purgent les transactions
  // ---------------------------------------------------------------------------

  group('cascade FK – transactions supprimées avec le compte / wallet', () {
    test('deleteAccount efface les transactions du compte, laisse l\'autre intact',
        () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');
      await seedWalletAndAccount(db, 'w1', 'acc2');
      await seedTransaction(
        db,
        AssetTransaction(
          id: 't1',
          accountId: 'acc1',
          kind: TransactionKind.buy,
          amount: '-10',
          currency: 'EUR',
          date: DateTime.parse('2024-01-01T00:00:00.000'),
        ),
      );
      await seedTransaction(
        db,
        AssetTransaction(
          id: 't2',
          accountId: 'acc2',
          kind: TransactionKind.buy,
          amount: '-20',
          currency: 'EUR',
          date: DateTime.parse('2024-01-02T00:00:00.000'),
        ),
      );

      await storage.deleteAccount('acc1');

      final exported = await storage.exportRawData();
      final transactions = exported['transactions'] as Map<String, dynamic>;
      expect(transactions.containsKey('acc1'), isFalse);
      expect(transactions.containsKey('acc2'), isTrue);
    });

    test('deleteWallet efface les transactions de tous ses comptes', () async {
      await seedWalletAndAccount(db, 'w1', 'acc1');
      await seedWalletAndAccount(db, 'w2', 'acc2');
      await seedTransaction(
        db,
        AssetTransaction(
          id: 't1',
          accountId: 'acc1',
          kind: TransactionKind.buy,
          amount: '-10',
          currency: 'EUR',
          date: DateTime.parse('2024-01-01T00:00:00.000'),
        ),
      );
      await seedTransaction(
        db,
        AssetTransaction(
          id: 't2',
          accountId: 'acc2',
          kind: TransactionKind.buy,
          amount: '-20',
          currency: 'EUR',
          date: DateTime.parse('2024-01-02T00:00:00.000'),
        ),
      );

      await storage.deleteWallet('w1');

      final exported = await storage.exportRawData();
      final transactions = exported['transactions'] as Map<String, dynamic>;
      expect(transactions.containsKey('acc1'), isFalse);
      expect(transactions.containsKey('acc2'), isTrue);
    });
  });
}

// test/services/app_database_upgrade_test.dart
//
// Migration de schéma v1 → v2 (ajout de la table `transactions`, vague 4 LOT A).
//
// Prouve les quatre propriétés critiques d'une migration SQLite :
//   (1) DB FRAÎCHE ouverte en v2 (via openTestDatabase, version courante = 2) :
//       la table `transactions` + ses index existent, ET les 5 tables v1 aussi.
//   (2) UPGRADE v1 → v2 : une base réellement créée en version 1 (5 tables v1
//       seulement), fermée puis rouverte via le vrai onUpgrade d'AppDatabase,
//       gagne la table `transactions` SANS perdre les tables v1 ni leurs données.
//   (3) FK CASCADE : wallet → account → transaction ; DELETE de l'account purge
//       la transaction (ON DELETE CASCADE actif, PRAGMA foreign_keys = ON).
//   (4) IDEMPOTENCE : rejouer la création de la table (double open) ne lève pas
//       (grâce à CREATE TABLE / INDEX IF NOT EXISTS).
//
// NB migration réelle : une base in-memory sqflite est DÉTRUITE à la fermeture,
// ce qui empêche de simuler open(v1) → close → open(v2). On utilise donc un
// fichier temporaire ffi (dans le répertoire temp système), nettoyé en tearDown
// — aucun `.db` ne doit rester dans l'arbre git.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:portfolio_tracker/services/app_database.dart';

import '../helpers/test_database.dart';

/// DDL des 5 tables de la v1 (copie fidèle de _onCreate figé à la version 1).
/// Utilisé UNIQUEMENT pour fabriquer une base « d'époque » v1, afin de tester
/// l'upgrade v1 → v2 par le vrai onUpgrade d'AppDatabase.
Future<void> _createSchemaV1(Database db) async {
  await db.execute('''
    CREATE TABLE wallets (
      id         TEXT PRIMARY KEY,
      name       TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE accounts (
      id           TEXT PRIMARY KEY,
      wallet_id    TEXT NOT NULL,
      name         TEXT NOT NULL,
      type         TEXT NOT NULL,
      currency     TEXT NOT NULL DEFAULT 'EUR',
      description  TEXT,
      created_at   TEXT,
      cash_balance REAL,
      FOREIGN KEY (wallet_id) REFERENCES wallets(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_accounts_wallet_id ON accounts(wallet_id)',
  );
  await db.execute('''
    CREATE TABLE positions (
      account_id        TEXT NOT NULL,
      symbol            TEXT NOT NULL,
      quantity          TEXT NOT NULL,
      average_buy_price REAL,
      custom_name       TEXT,
      asset_json        TEXT NOT NULL,
      PRIMARY KEY (account_id, symbol),
      FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
    )
  ''');
  await db.execute('''
    CREATE TABLE snapshots (
      wallet_id      TEXT NOT NULL,
      date           TEXT NOT NULL,
      total_value    REAL NOT NULL,
      currency       TEXT NOT NULL,
      captured_at    INTEGER NOT NULL,
      account_count  INTEGER NOT NULL DEFAULT 0,
      schema_version INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (wallet_id, date),
      FOREIGN KEY (wallet_id) REFERENCES wallets(id) ON DELETE CASCADE
    )
  ''');
  await db.execute(
    'CREATE INDEX idx_snapshots_wallet_date ON snapshots(wallet_id, date)',
  );
  await db.execute('''
    CREATE TABLE allocation_targets (
      wallet_id   TEXT PRIMARY KEY,
      target_json TEXT NOT NULL,
      FOREIGN KEY (wallet_id) REFERENCES wallets(id) ON DELETE CASCADE
    )
  ''');
}

const _v1Tables = <String>[
  'wallets',
  'accounts',
  'positions',
  'snapshots',
  'allocation_targets',
];

Future<Set<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

Future<Set<String>> _indexNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'index'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ---------------------------------------------------------------------------
  // (1) DB FRAÎCHE ouverte en v2 : transactions + index + tables v1 présents.
  // ---------------------------------------------------------------------------
  group('DB fraîche en v2 (onCreate)', () {
    test('crée transactions + ses index ET conserve les 5 tables v1', () async {
      final appDb = await openTestDatabase();
      final db = await appDb.database;

      // La version effective de la base est bien la version courante (5).
      expect(await db.getVersion(), equals(7));

      final tables = await _tableNames(db);
      expect(tables, containsAll(_v1Tables),
          reason: 'onCreate en v2 doit créer aussi les 5 tables v1');
      expect(tables, contains('transactions'),
          reason: 'onCreate en v2 doit créer la table transactions');

      final indexes = await _indexNames(db);
      expect(
        indexes,
        containsAll(<String>[
          'idx_transactions_account_date',
          'idx_transactions_symbol_date',
        ]),
        reason: 'les deux index de transactions doivent exister',
      );

      // Le schéma de colonnes de transactions correspond au DDL v2.
      final cols = await db.rawQuery('PRAGMA table_info(transactions)');
      final colNames = cols.map((c) => c['name'] as String).toSet();
      expect(
        colNames,
        containsAll(<String>[
          'id',
          'account_id',
          'symbol',
          'kind',
          'quantity',
          'unit_price',
          'amount',
          'currency',
          'date',
          'fee',
          'note',
          'meta_json',
          // v7 : settlement_currency présente dès la création (base fraîche) —
          // ajoutée par le MÊME ALTER que _onUpgrade, après la DDL v2 figée.
          'settlement_currency',
        ]),
      );

      // v3 : la colonne kind existe dès la création (base fraîche).
      final accCols = await db.rawQuery('PRAGMA table_info(accounts)');
      expect(
        accCols.map((c) => c['name'] as String).toSet(),
        contains('kind'),
        reason: 'onCreate en v3 doit inclure la colonne accounts.kind',
      );

      // v5 : la colonne positions.derived_at existe dès la création (base
      // fraîche) — miroir du DDL partagé avec l'ALTER de _onUpgrade.
      final posCols = await db.rawQuery('PRAGMA table_info(positions)');
      expect(
        posCols.map((c) => c['name'] as String).toSet(),
        contains('derived_at'),
        reason: 'onCreate en v5 doit inclure la colonne positions.derived_at',
      );

      // v6 : les colonnes accounts.derived_cash / derived_cash_at existent dès
      // la création (base fraîche) — miroir du DDL partagé avec l'ALTER v5→v6.
      expect(
        accCols.map((c) => c['name'] as String).toSet(),
        containsAll(<String>['derived_cash', 'derived_cash_at']),
        reason: 'onCreate en v6 doit inclure accounts.derived_cash(_at)',
      );

      // v4 : la table last_known_quotes existe dès la création (base fraîche).
      expect(
        tables,
        contains('last_known_quotes'),
        reason: 'onCreate en v4 doit créer la table last_known_quotes',
      );
      final lkqCols = await db.rawQuery('PRAGMA table_info(last_known_quotes)');
      expect(
        lkqCols.map((c) => c['name'] as String).toSet(),
        containsAll(<String>[
          'symbol',
          'name',
          'price',
          'change',
          'change_percent',
          'previous_close',
          'currency',
          'exchange',
          'cached_at',
        ]),
      );

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (2bis) UPGRADE v2 → v3 : la colonne accounts.kind APPARAÎT et les
  //        comptes préexistants sont backfillés à 'autre', sans perte de données.
  // ---------------------------------------------------------------------------
  group('Upgrade v2 → v3 (kind)', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('pt_upgrade_v3_test_');
      dbPath = '${tmpDir.path}/portfolio_v2.db';
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('la colonne kind apparaît, backfill "autre", données v2 intactes',
        () async {
      // --- Étape 1 : fabriquer une base d'époque v2 (schéma v1 SANS
      //     kind + table transactions) et y insérer un compte.
      final legacyDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, version) async {
            await _createSchemaV1(db);
            await db.execute('''
              CREATE TABLE transactions (
                id           TEXT PRIMARY KEY,
                account_id   TEXT NOT NULL,
                symbol       TEXT,
                kind         TEXT NOT NULL,
                quantity     TEXT,
                unit_price   TEXT,
                amount       TEXT,
                currency     TEXT NOT NULL,
                date         TEXT NOT NULL,
                fee          TEXT,
                note         TEXT,
                meta_json    TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
              )
            ''');
          },
        ),
      );
      expect(await legacyDb.getVersion(), equals(2));
      // La base v2 n'a PAS la colonne kind.
      final v2Cols =
          await legacyDb.rawQuery('PRAGMA table_info(accounts)');
      expect(v2Cols.map((c) => c['name'] as String), isNot(contains('kind')),
          reason: 'une base v2 ne doit pas avoir la colonne kind');
      await legacyDb.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet v2',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await legacyDb.insert('accounts', {
        'id': 'a-legacy',
        'wallet_id': 'w1',
        'name': 'CTO historique',
        'type': 'investment',
        'currency': 'EUR',
      });
      await legacyDb.insert('accounts', {
        'id': 'a-cash',
        'wallet_id': 'w1',
        'name': 'Livret historique',
        'type': 'cash',
        'currency': 'EUR',
      });
      await legacyDb.close();

      // --- Étape 2 : rouvrir via AppDatabase (version courante 3) → onUpgrade
      //     ne joue que le palier v2→v3 (ADD COLUMN kind + backfill).
      final appDb = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final upgraded = await appDb.database;

      // La réouverture applique TOUS les paliers cumulatifs jusqu'à la
      // version courante (4), pas seulement le palier v2→v3 testé ici.
      expect(await upgraded.getVersion(), equals(7));

      final accCols = await upgraded.rawQuery('PRAGMA table_info(accounts)');
      expect(accCols.map((c) => c['name'] as String).toSet(),
          contains('kind'),
          reason: 'onUpgrade v2→v3 doit ajouter la colonne kind');

      // Le compte préexistant a survécu ET a été backfillé à 'autre'
      // (type 'investment' → kind 'autre' via le CASE de backfill).
      final rows =
          await upgraded.query('accounts', where: 'id = ?', whereArgs: ['a-legacy']);
      expect(rows, hasLength(1),
          reason: 'les données v2 doivent survivre à une migration additive');
      expect(rows.first['kind'], equals('autre'),
          reason: 'un compte type=investment doit être backfillé à "autre"');

      // Le compte cash reçoit sa nature exacte via le CASE de backfill.
      final cashRows =
          await upgraded.query('accounts', where: 'id = ?', whereArgs: ['a-cash']);
      expect(cashRows.first['kind'], equals('cash'),
          reason: 'un compte type=cash doit être backfillé à "cash"');

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (2ter) UPGRADE v3 → v4 : la table `last_known_quotes` APPARAÎT sans perte
  //        des données préexistantes (cache LOT 2, purement additif).
  // ---------------------------------------------------------------------------
  group('Upgrade v3 → v4 (last_known_quotes)', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('pt_upgrade_v4_test_');
      dbPath = '${tmpDir.path}/portfolio_v3.db';
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('la table last_known_quotes apparaît, données v3 intactes',
        () async {
      // --- Étape 1 : fabriquer une base d'époque v3 (schéma v1 + kind +
      //     table transactions, SANS last_known_quotes) et y insérer un
      //     compte témoin.
      final legacyDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await _createSchemaV1(db);
            await db.execute('ALTER TABLE accounts ADD COLUMN kind TEXT NOT NULL DEFAULT \'autre\'');
            await db.execute('''
              CREATE TABLE transactions (
                id           TEXT PRIMARY KEY,
                account_id   TEXT NOT NULL,
                symbol       TEXT,
                kind         TEXT NOT NULL,
                quantity     TEXT,
                unit_price   TEXT,
                amount       TEXT,
                currency     TEXT NOT NULL,
                date         TEXT NOT NULL,
                fee          TEXT,
                note         TEXT,
                meta_json    TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
              )
            ''');
          },
        ),
      );
      expect(await legacyDb.getVersion(), equals(3));
      // La base v3 n'a PAS la table last_known_quotes.
      expect(await _tableNames(legacyDb), isNot(contains('last_known_quotes')),
          reason: 'une base v3 ne doit pas avoir la table last_known_quotes');
      await legacyDb.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet v3',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await legacyDb.insert('accounts', {
        'id': 'a-legacy',
        'wallet_id': 'w1',
        'name': 'CTO historique',
        'type': 'investment',
        'currency': 'EUR',
        'kind': 'autre',
      });
      await legacyDb.close();

      // --- Étape 2 : rouvrir via AppDatabase (version courante 4) → onUpgrade
      //     joue le palier v3→v4 (création de last_known_quotes).
      final appDb = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final upgraded = await appDb.database;

      expect(await upgraded.getVersion(), equals(7));

      final tables = await _tableNames(upgraded);
      expect(tables, contains('last_known_quotes'),
          reason: 'onUpgrade v3→v4 doit créer la table last_known_quotes');

      final lkqCols = await upgraded.rawQuery('PRAGMA table_info(last_known_quotes)');
      expect(
        lkqCols.map((c) => c['name'] as String).toSet(),
        containsAll(<String>[
          'symbol',
          'name',
          'price',
          'change',
          'change_percent',
          'previous_close',
          'currency',
          'exchange',
          'cached_at',
        ]),
      );

      // La table est bien fonctionnelle (upsert simple).
      await upgraded.insert('last_known_quotes', {
        'symbol': 'AAPL',
        'price': '150.0',
        'cached_at': 1000,
      });
      final lkqRows = await upgraded.query('last_known_quotes', where: 'symbol = ?', whereArgs: ['AAPL']);
      expect(lkqRows, hasLength(1));

      // Le compte préexistant a survécu sans perte de données.
      final rows =
          await upgraded.query('accounts', where: 'id = ?', whereArgs: ['a-legacy']);
      expect(rows, hasLength(1),
          reason: 'les données v3 doivent survivre à une migration additive');
      expect(rows.first['kind'], equals('autre'));

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (2quater) UPGRADE v4 → v5 : la colonne `positions.derived_at` APPARAÎT à
  //           NULL (legacy) sans toucher quantity/average_buy_price (projection
  //           B* — migration additive non destructive).
  // ---------------------------------------------------------------------------
  group('Upgrade v4 → v5 (positions.derived_at)', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('pt_upgrade_v5_test_');
      dbPath = '${tmpDir.path}/portfolio_v4.db';
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('derived_at apparaît à NULL, quantity/average_buy_price intacts',
        () async {
      // --- Étape 1 : fabriquer une base d'époque v4 (positions SANS
      //     derived_at) et y insérer une position q/PRU témoin.
      final legacyDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 4,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, version) async {
            await _createSchemaV1(db);
            await db.execute(
                'ALTER TABLE accounts ADD COLUMN kind TEXT NOT NULL DEFAULT \'autre\'');
            await db.execute('''
              CREATE TABLE transactions (
                id           TEXT PRIMARY KEY,
                account_id   TEXT NOT NULL,
                symbol       TEXT,
                kind         TEXT NOT NULL,
                quantity     TEXT,
                unit_price   TEXT,
                amount       TEXT,
                currency     TEXT NOT NULL,
                date         TEXT NOT NULL,
                fee          TEXT,
                note         TEXT,
                meta_json    TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
              )
            ''');
            await db.execute('''
              CREATE TABLE last_known_quotes (
                symbol          TEXT PRIMARY KEY,
                name            TEXT,
                price           TEXT,
                change          TEXT,
                change_percent  TEXT,
                previous_close  TEXT,
                currency        TEXT,
                exchange        TEXT,
                cached_at       INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      expect(await legacyDb.getVersion(), equals(4));
      // La base v4 n'a PAS la colonne positions.derived_at.
      final v4PosCols = await legacyDb.rawQuery('PRAGMA table_info(positions)');
      expect(v4PosCols.map((c) => c['name'] as String), isNot(contains('derived_at')),
          reason: 'une base v4 ne doit pas avoir la colonne derived_at');
      await legacyDb.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet v4',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await legacyDb.insert('accounts', {
        'id': 'a1',
        'wallet_id': 'w1',
        'name': 'CTO',
        'type': 'investment',
        'currency': 'EUR',
        'kind': 'autre',
      });
      await legacyDb.insert('positions', {
        'account_id': 'a1',
        'symbol': 'AAPL',
        'quantity': '12.5',
        'average_buy_price': 187.25,
        'custom_name': 'Pomme',
        'asset_json': '{"symbol":"AAPL","type":"stock","currency":"USD"}',
      });
      await legacyDb.close();

      // --- Étape 2 : rouvrir via AppDatabase (version courante 5) → onUpgrade
      //     joue le palier v4→v5 (ADD COLUMN derived_at).
      final appDb = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final upgraded = await appDb.database;

      expect(await upgraded.getVersion(), equals(7));

      final posCols = await upgraded.rawQuery('PRAGMA table_info(positions)');
      expect(posCols.map((c) => c['name'] as String).toSet(),
          contains('derived_at'),
          reason: 'onUpgrade v4→v5 doit ajouter la colonne derived_at');

      // La position préexistante a survécu SANS altération de q/PRU, et
      // derived_at est NULL (legacy jamais projeté).
      final rows =
          await upgraded.query('positions', where: 'account_id = ? AND symbol = ?', whereArgs: ['a1', 'AAPL']);
      expect(rows, hasLength(1),
          reason: 'les données v4 doivent survivre à une migration additive');
      expect(rows.first['quantity'], equals('12.5'),
          reason: 'la quantité stockée ne doit pas être altérée');
      expect(rows.first['average_buy_price'], equals(187.25),
          reason: 'le PRU stocké ne doit pas être altéré');
      expect(rows.first['custom_name'], equals('Pomme'));
      expect(rows.first['derived_at'], isNull,
          reason: 'une position legacy jamais projetée doit avoir derived_at NULL');

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (2quinquies) UPGRADE v5 → v6 : les colonnes `accounts.derived_cash` /
  //              `derived_cash_at` APPARAISSENT à NULL (jamais projeté) sans
  //              toucher cash_balance ni les autres colonnes (solde espèces
  //              dérivé — migration additive non destructive).
  // ---------------------------------------------------------------------------
  group('Upgrade v5 → v6 (accounts.derived_cash)', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('pt_upgrade_v6_test_');
      dbPath = '${tmpDir.path}/portfolio_v5.db';
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('derived_cash(_at) apparaissent à NULL, cash_balance/données intacts',
        () async {
      // --- Étape 1 : fabriquer une base d'époque v5 (accounts SANS
      //     derived_cash, positions AVEC derived_at) et la peupler.
      final legacyDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 5,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, version) async {
            await _createSchemaV1(db);
            await db.execute(
                'ALTER TABLE accounts ADD COLUMN kind TEXT NOT NULL DEFAULT \'autre\'');
            await db.execute('''
              CREATE TABLE transactions (
                id           TEXT PRIMARY KEY,
                account_id   TEXT NOT NULL,
                symbol       TEXT,
                kind         TEXT NOT NULL,
                quantity     TEXT,
                unit_price   TEXT,
                amount       TEXT,
                currency     TEXT NOT NULL,
                date         TEXT NOT NULL,
                fee          TEXT,
                note         TEXT,
                meta_json    TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
              )
            ''');
            await db.execute('''
              CREATE TABLE last_known_quotes (
                symbol TEXT PRIMARY KEY, name TEXT, price TEXT, change TEXT,
                change_percent TEXT, previous_close TEXT, currency TEXT,
                exchange TEXT, cached_at INTEGER NOT NULL
              )
            ''');
            await db.execute(
                'ALTER TABLE positions ADD COLUMN derived_at INTEGER');
          },
        ),
      );
      expect(await legacyDb.getVersion(), equals(5));
      final v5AccCols = await legacyDb.rawQuery('PRAGMA table_info(accounts)');
      expect(v5AccCols.map((c) => c['name'] as String),
          isNot(contains('derived_cash')),
          reason: 'une base v5 ne doit pas avoir la colonne derived_cash');
      await legacyDb.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet v5',
        'created_at': '2024-01-01T00:00:00.000',
      });
      // Un compte titres ET un compte cash (cash_balance renseigné) : on prouve
      // que cash_balance survit intacte et n'est jamais confondue avec le
      // nouveau cash dérivé.
      await legacyDb.insert('accounts', {
        'id': 'a-cto',
        'wallet_id': 'w1',
        'name': 'CTO',
        'type': 'investment',
        'currency': 'EUR',
        'kind': 'autre',
      });
      await legacyDb.insert('accounts', {
        'id': 'a-livret',
        'wallet_id': 'w1',
        'name': 'Livret',
        'type': 'cash',
        'currency': 'EUR',
        'kind': 'cash',
        'cash_balance': 1234.56,
      });
      await legacyDb.close();

      // --- Étape 2 : rouvrir via AppDatabase (version courante 6) → onUpgrade
      //     joue le palier v5→v6 (ADD COLUMN derived_cash + derived_cash_at).
      final appDb = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final upgraded = await appDb.database;

      expect(await upgraded.getVersion(), equals(7));

      final accCols = await upgraded.rawQuery('PRAGMA table_info(accounts)');
      expect(accCols.map((c) => c['name'] as String).toSet(),
          containsAll(<String>['derived_cash', 'derived_cash_at']),
          reason: 'onUpgrade v5→v6 doit ajouter derived_cash(_at)');

      // Les comptes préexistants survivent ; derived_cash(_at) = NULL (jamais
      // projeté) ; cash_balance du livret INTACTE (jamais réutilisée).
      final cto = (await upgraded
              .query('accounts', where: 'id = ?', whereArgs: ['a-cto']))
          .first;
      expect(cto['derived_cash'], isNull);
      expect(cto['derived_cash_at'], isNull);

      final livret = (await upgraded
              .query('accounts', where: 'id = ?', whereArgs: ['a-livret']))
          .first;
      expect(livret['derived_cash'], isNull,
          reason: 'le cash dérivé est distinct du cash_balance manuel');
      expect(livret['cash_balance'], equals(1234.56),
          reason: 'cash_balance (comptes kind=cash) doit rester intacte');

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (2sexies) UPGRADE v6 → v7 : la colonne `transactions.settlement_currency`
  //           APPARAÎT à NULL (règlement == cotation, legacy) sans toucher les
  //           autres colonnes (devise de règlement — migration additive non
  //           destructive, design cash-ledger §8).
  // ---------------------------------------------------------------------------
  group('Upgrade v6 → v7 (transactions.settlement_currency)', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('pt_upgrade_v7_test_');
      dbPath = '${tmpDir.path}/portfolio_v6.db';
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('settlement_currency apparaît à NULL, transactions/données intactes',
        () async {
      // --- Étape 1 : fabriquer une base d'époque v6 (transactions SANS
      //     settlement_currency, accounts AVEC derived_cash) et la peupler.
      final legacyDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 6,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, version) async {
            await _createSchemaV1(db);
            await db.execute(
                'ALTER TABLE accounts ADD COLUMN kind TEXT NOT NULL DEFAULT \'autre\'');
            await db.execute('''
              CREATE TABLE transactions (
                id           TEXT PRIMARY KEY,
                account_id   TEXT NOT NULL,
                symbol       TEXT,
                kind         TEXT NOT NULL,
                quantity     TEXT,
                unit_price   TEXT,
                amount       TEXT,
                currency     TEXT NOT NULL,
                date         TEXT NOT NULL,
                fee          TEXT,
                note         TEXT,
                meta_json    TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
              )
            ''');
            await db.execute('''
              CREATE TABLE last_known_quotes (
                symbol TEXT PRIMARY KEY, name TEXT, price TEXT, change TEXT,
                change_percent TEXT, previous_close TEXT, currency TEXT,
                exchange TEXT, cached_at INTEGER NOT NULL
              )
            ''');
            await db.execute(
                'ALTER TABLE positions ADD COLUMN derived_at INTEGER');
            await db.execute(
                'ALTER TABLE accounts ADD COLUMN derived_cash TEXT');
            await db.execute(
                'ALTER TABLE accounts ADD COLUMN derived_cash_at INTEGER');
          },
        ),
      );
      expect(await legacyDb.getVersion(), equals(6));
      final v6TxCols =
          await legacyDb.rawQuery('PRAGMA table_info(transactions)');
      expect(v6TxCols.map((c) => c['name'] as String),
          isNot(contains('settlement_currency')),
          reason: 'une base v6 ne doit pas avoir settlement_currency');
      await legacyDb.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet v6',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await legacyDb.insert('accounts', {
        'id': 'a-cto',
        'wallet_id': 'w1',
        'name': 'CTO',
        'type': 'investment',
        'currency': 'EUR',
        'kind': 'autre',
      });
      // Mouvement legacy (USD) sans settlement_currency : preuve de survie.
      await legacyDb.insert('transactions', {
        'id': 't-legacy',
        'account_id': 'a-cto',
        'symbol': 'AAPL',
        'kind': 'buy',
        'quantity': '10',
        'unit_price': '175.50',
        'amount': '-1755.00',
        'currency': 'USD',
        'date': '2024-03-15T10:30:00.000',
        'fee': '1.99',
      });
      await legacyDb.close();

      // --- Étape 2 : rouvrir via AppDatabase (version courante 7) → onUpgrade
      //     joue le palier v6→v7 (ADD COLUMN settlement_currency).
      final appDb = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final upgraded = await appDb.database;

      expect(await upgraded.getVersion(), equals(7));

      final txCols = await upgraded.rawQuery('PRAGMA table_info(transactions)');
      expect(txCols.map((c) => c['name'] as String).toSet(),
          contains('settlement_currency'),
          reason: 'onUpgrade v6→v7 doit ajouter settlement_currency');

      // La transaction legacy survit ; settlement_currency = NULL (règlement ==
      // cotation) ; les autres champs intacts.
      final tx = (await upgraded
              .query('transactions', where: 'id = ?', whereArgs: ['t-legacy']))
          .first;
      expect(tx['settlement_currency'], isNull,
          reason: 'ligne legacy → règlement identique à la cotation');
      expect(tx['currency'], equals('USD'));
      expect(tx['amount'], equals('-1755.00'));
      expect(tx['fee'], equals('1.99'));

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (2) UPGRADE v1 → v2 sur base fichier réelle : transactions APPARAÎT sans
  //     perte des tables v1 ni de leurs données.
  // ---------------------------------------------------------------------------
  group('Upgrade v1 → v2 (onUpgrade)', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('pt_upgrade_test_');
      dbPath = '${tmpDir.path}/portfolio_v1.db';
    });

    tearDown(() async {
      // Nettoyage : aucun .db ne doit survivre (ni dans l'arbre git ni ailleurs).
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('la table transactions apparaît sans perte des tables/données v1',
        () async {
      // --- Étape 1 : fabriquer une base d'époque v1 (5 tables seulement) et
      //     y insérer une donnée pour prouver l'absence de perte à l'upgrade.
      final legacyDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) => _createSchemaV1(db),
        ),
      );
      expect(await legacyDb.getVersion(), equals(1));
      expect(await _tableNames(legacyDb), isNot(contains('transactions')),
          reason: 'une base v1 ne doit PAS avoir la table transactions');
      await legacyDb.insert('wallets', {
        'id': 'w1',
        'name': 'Wallet v1',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await legacyDb.close();

      // --- Étape 2 : rouvrir la MÊME base via AppDatabase (version courante 2)
      //     → déclenche le vrai onUpgrade.
      final appDb = AppDatabase(
        factory: databaseFactoryFfi,
        path: dbPath,
      );
      final upgraded = await appDb.database;

      expect(await upgraded.getVersion(), equals(7),
          reason: 'la base doit être migrée en version courante (5)');

      final tables = await _tableNames(upgraded);
      expect(tables, containsAll(_v1Tables),
          reason: 'aucune table v1 ne doit être perdue à l\'upgrade');
      expect(tables, contains('transactions'),
          reason: 'onUpgrade doit créer la table transactions');

      final indexes = await _indexNames(upgraded);
      expect(
        indexes,
        containsAll(<String>[
          'idx_transactions_account_date',
          'idx_transactions_symbol_date',
        ]),
      );

      // La donnée v1 pré-migration a survécu.
      final wallets = await upgraded.query('wallets', where: 'id = ?', whereArgs: ['w1']);
      expect(wallets, hasLength(1),
          reason: 'les données v1 doivent survivre à une migration additive');

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (3) FK CASCADE : DELETE account purge ses transactions.
  // ---------------------------------------------------------------------------
  group('FK cascade sur transactions', () {
    test('supprimer un account supprime ses transactions (ON DELETE CASCADE)',
        () async {
      final appDb = await openTestDatabase();
      final db = await appDb.database;

      // PRAGMA foreign_keys doit être actif (posé par onConfigure).
      final fk = await db.rawQuery('PRAGMA foreign_keys');
      expect(fk.first['foreign_keys'], equals(1));

      await db.insert('wallets', {
        'id': 'w-cascade',
        'name': 'W',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await db.insert('accounts', {
        'id': 'a-cascade',
        'wallet_id': 'w-cascade',
        'name': 'A',
        'type': 'investment',
        'currency': 'EUR',
      });
      await db.insert('transactions', {
        'id': 't1',
        'account_id': 'a-cascade',
        'symbol': 'AAPL',
        'kind': 'buy',
        'quantity': '10',
        'unit_price': '150.5',
        'amount': '-1505.0',
        'currency': 'EUR',
        'date': '2024-06-01T09:30:00.000',
      });

      final before = await db.query('transactions', where: 'id = ?', whereArgs: ['t1']);
      expect(before, hasLength(1));

      // Suppression de l'account parent → la transaction doit disparaître.
      await db.delete('accounts', where: 'id = ?', whereArgs: ['a-cascade']);

      final after = await db.query('transactions', where: 'id = ?', whereArgs: ['t1']);
      expect(after, isEmpty,
          reason: 'ON DELETE CASCADE doit purger les transactions de l\'account');

      await appDb.close();
    });

    test('cascade transitive : supprimer le wallet purge les transactions',
        () async {
      final appDb = await openTestDatabase();
      final db = await appDb.database;

      await db.insert('wallets', {
        'id': 'w-trans',
        'name': 'W',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await db.insert('accounts', {
        'id': 'a-trans',
        'wallet_id': 'w-trans',
        'name': 'A',
        'type': 'investment',
        'currency': 'EUR',
      });
      await db.insert('transactions', {
        'id': 't-trans',
        'account_id': 'a-trans',
        'kind': 'deposit',
        'amount': '1000.0',
        'currency': 'EUR',
        'date': '2024-06-01T09:30:00.000',
      });

      await db.delete('wallets', where: 'id = ?', whereArgs: ['w-trans']);

      final after = await db.query('transactions', where: 'id = ?', whereArgs: ['t-trans']);
      expect(after, isEmpty,
          reason: 'wallet → account → transaction : cascade transitive attendue');

      await appDb.close();
    });
  });

  // ---------------------------------------------------------------------------
  // (4) IDEMPOTENCE : double open de la même base fichier (donc re-passage
  //     potentiel dans les chemins de création) ne lève pas.
  // ---------------------------------------------------------------------------
  group('Idempotence', () {
    late Directory tmpDir;
    late String dbPath;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('pt_idem_test_');
      dbPath = '${tmpDir.path}/portfolio_idem.db';
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('rouvrir une base déjà en v2 ne relance aucune migration ni erreur',
        () async {
      // Premier open : crée le schéma v2 complet (onCreate).
      final appDb1 = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final db1 = await appDb1.database;
      expect(await db1.getVersion(), equals(7));
      expect(await _tableNames(db1), contains('transactions'));
      await appDb1.close();

      // Second open sur le MÊME fichier, déjà en v2 : ni onCreate ni onUpgrade
      // ne rejouent, mais on prouve qu'aucune erreur ne survient et que le
      // schéma reste cohérent.
      final appDb2 = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final db2 = await appDb2.database;
      expect(await db2.getVersion(), equals(7));
      expect(await _tableNames(db2), contains('transactions'));
      await appDb2.close();
    });

    test('upgrade v1 → v2 rejoué (v1 → close → v2 → close → v2) ne lève pas',
        () async {
      // Base v1 d'époque.
      final legacy = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) => _createSchemaV1(db),
        ),
      );
      await legacy.close();

      // Premier upgrade v1 → v2.
      final appDb1 = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final db1 = await appDb1.database;
      expect(await db1.getVersion(), equals(7));
      expect(await _tableNames(db1), contains('transactions'));
      await appDb1.close();

      // Réouverture en v2 (déjà migrée) : aucune migration rejouée, aucune
      // erreur, table toujours présente. Le IF NOT EXISTS garantit qu'un
      // hypothétique re-passage dans _createTransactionsTable serait sans effet.
      final appDb2 = AppDatabase(factory: databaseFactoryFfi, path: dbPath);
      final db2 = await appDb2.database;
      expect(await db2.getVersion(), equals(7));
      expect(await _tableNames(db2), contains('transactions'));
      await appDb2.close();
    });
  });
}

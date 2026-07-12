// test/services/sqlite_migration_test.dart
//
// Vérifie la migration one-shot SharedPreferences → SQLite :
//   - migration nominale (données cohérentes) + flag posé + SP JAMAIS effacée ;
//   - flag déjà posé → no-op ;
//   - utilisateur neuf → flag posé, DB vide ;
//   - DB déjà peuplée sans flag (récup crash) → flag posé, pas de doublon ;
//   - assainissement d'orphelins → migration OK, orphelin absent, flag posé ;
//   - rétrocompat (sans clés snapshots/allocationTargets) ;
//   - mismatch de counts simulé → exception, flag NON posé, SP intacte.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/legacy_shared_prefs_reader.dart';
import 'package:portfolio_tracker/services/sqlite_migration.dart';

import '../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late AccountStorage storage;

  setUp(() async {
    db = await openTestDatabase();
    storage = AccountStorage(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  // --- Fixtures legacy cohérentes ---

  Map<String, Object> coherentSpValues() => {
        'wallets': jsonEncode([
          {
            'id': 'w1',
            'name': 'Wallet 1',
            'createdAt': '2024-01-01T00:00:00.000',
          },
        ]),
        'accounts': jsonEncode([
          {
            'id': 'a1',
            'walletId': 'w1',
            'name': 'Compte',
            'type': 'brokerage',
            'currency': 'EUR',
          },
        ]),
        'positions_a1': jsonEncode([
          {
            'accountId': 'a1',
            'asset': {'symbol': 'AAPL', 'name': 'Apple', 'type': 'stock'},
            'quantity': '10',
            'averageBuyPrice': 150.0,
          },
        ]),
        'snapshots_w1': jsonEncode([
          {
            'date': '2024-01-01',
            'totalValue': 1000.0,
            'currency': 'EUR',
            'capturedAt': 1000,
            'accountCount': 1,
            'schemaVersion': 1,
          },
        ]),
        'allocation_targets_w1': jsonEncode({
          'someKey': 'someValue',
        }),
      };

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('migration nominale → DB peuplée, flag posé, SP intacte', () async {
    final initial = coherentSpValues();
    final prefs = await prefsWith(initial);

    await SqliteMigration.runIfNeeded(database: db, prefs: prefs);

    // DB peuplée
    final wallets = await storage.getAllWallets();
    expect(wallets.map((w) => w.id), ['w1']);
    final accounts = await storage.getAllAccounts();
    expect(accounts.map((a) => a.id), ['a1']);
    final positions = await storage.getPositions('a1');
    expect(positions.map((p) => p.symbol), ['AAPL']);
    expect(positions.first.quantity, '10');

    // Flag posé
    expect(prefs.getBool(SqliteMigration.migrationDoneKey), isTrue);

    // SP JAMAIS effacée : les clés legacy sont toujours là
    expect(prefs.getString('wallets'), initial['wallets']);
    expect(prefs.getString('accounts'), initial['accounts']);
    expect(prefs.getString('positions_a1'), initial['positions_a1']);
    expect(prefs.getString('snapshots_w1'), initial['snapshots_w1']);
    expect(prefs.getString('allocation_targets_w1'),
        initial['allocation_targets_w1']);
  });

  test('flag déjà posé → no-op (aucune écriture DB)', () async {
    final values = coherentSpValues();
    values[SqliteMigration.migrationDoneKey] = true;
    final prefs = await prefsWith(values);

    await SqliteMigration.runIfNeeded(database: db, prefs: prefs);

    // DB reste vide : rien n'a été importé
    expect(await storage.getAllWallets(), isEmpty);
    expect(await storage.getAllAccounts(), isEmpty);
  });

  test('utilisateur neuf (SP vide) → flag posé, DB vide, pas d\'erreur',
      () async {
    final prefs = await prefsWith({});

    await SqliteMigration.runIfNeeded(database: db, prefs: prefs);

    expect(prefs.getBool(SqliteMigration.migrationDoneKey), isTrue);
    expect(await storage.getAllWallets(), isEmpty);
  });

  test('DB déjà peuplée sans flag (récup crash) → flag posé, pas de ré-import',
      () async {
    // Simule un crash : la DB contient déjà des données, mais le flag n'a pas
    // été posé. On importe directement dans la DB une donnée DISTINCTE de la SP.
    await storage.importRawData({
      'wallets': [
        {'id': 'wDB', 'name': 'DejaEnDB', 'createdAt': '2023-01-01T00:00:00.000'},
      ],
      'accounts': [],
      'positions': {},
      'snapshots': {},
      'allocationTargets': {},
    });

    // La SP contient d'AUTRES données (w1) qui NE doivent PAS être réimportées.
    final prefs = await prefsWith(coherentSpValues());

    await SqliteMigration.runIfNeeded(database: db, prefs: prefs);

    // Flag posé
    expect(prefs.getBool(SqliteMigration.migrationDoneKey), isTrue);

    // Pas de ré-import : la DB contient toujours uniquement wDB (pas w1),
    // pas de doublon ni d'écrasement.
    final wallets = await storage.getAllWallets();
    expect(wallets.map((w) => w.id), ['wDB']);
  });

  test('assainissement : position orpheline retirée, cohérent conservé',
      () async {
    final values = coherentSpValues();
    // Ajoute une position orpheline (accountId inexistant) + un compte orphelin
    // (walletId inexistant) + un snapshot orphelin (wallet inexistant).
    values['positions_ORPHAN'] = jsonEncode([
      {
        'accountId': 'ORPHAN',
        'asset': {'symbol': 'GHOST', 'type': 'stock'},
        'quantity': '1',
      },
    ]);
    values['accounts'] = jsonEncode([
      {
        'id': 'a1',
        'walletId': 'w1',
        'name': 'Compte',
        'type': 'brokerage',
        'currency': 'EUR',
      },
      {
        'id': 'aOrphan',
        'walletId': 'wGhost',
        'name': 'CompteOrphelin',
        'type': 'brokerage',
        'currency': 'EUR',
      },
    ]);
    values['snapshots_wGhost'] = jsonEncode([
      {
        'date': '2024-01-02',
        'totalValue': 5.0,
        'currency': 'EUR',
        'capturedAt': 2000,
      },
    ]);
    values['allocation_targets_wGhost'] = jsonEncode({'x': 1});

    final prefs = await prefsWith(values);

    // Ne DOIT PAS lever d'exception.
    await SqliteMigration.runIfNeeded(database: db, prefs: prefs);

    // Flag posé
    expect(prefs.getBool(SqliteMigration.migrationDoneKey), isTrue);

    // Données cohérentes présentes
    expect((await storage.getAllWallets()).map((w) => w.id), ['w1']);
    final accounts = await storage.getAllAccounts();
    expect(accounts.map((a) => a.id), ['a1']); // aOrphan retiré
    final positions = await storage.getPositions('a1');
    expect(positions.map((p) => p.symbol), ['AAPL']);

    // Orphelins absents
    expect(await storage.getPositions('ORPHAN'), isEmpty);
    expect(await storage.getPositions('aOrphan'), isEmpty);

    // SP toujours intacte (orphelins compris : filet de sécurité)
    expect(prefs.getString('positions_ORPHAN'), values['positions_ORPHAN']);
    expect(prefs.getString('snapshots_wGhost'), values['snapshots_wGhost']);
  });

  test('rétrocompat : sans clés snapshots/allocationTargets', () async {
    final prefs = await prefsWith({
      'wallets': jsonEncode([
        {'id': 'w1', 'name': 'W', 'createdAt': '2024-01-01T00:00:00.000'},
      ]),
      'accounts': jsonEncode([
        {'id': 'a1', 'walletId': 'w1', 'name': 'C', 'type': 'brokerage'},
      ]),
      'positions_a1': jsonEncode([
        {
          'accountId': 'a1',
          'asset': {'symbol': 'BTC', 'type': 'crypto'},
          'quantity': '2',
        },
      ]),
    });

    await SqliteMigration.runIfNeeded(database: db, prefs: prefs);

    expect(prefs.getBool(SqliteMigration.migrationDoneKey), isTrue);
    expect((await storage.getAllWallets()).map((w) => w.id), ['w1']);
    expect((await storage.getPositions('a1')).map((p) => p.symbol), ['BTC']);
  });

  test('mismatch de counts simulé → exception, flag NON posé, SP intacte',
      () async {
    // Reader qui renvoie 2 positions avec le MÊME symbole dans le même compte :
    // sanitized comptera 2 positions, mais importRawData (INSERT OR REPLACE sur
    // PK composite account_id+symbol) n'insérera qu'1 ligne → mismatch.
    final prefs = await prefsWith({});

    await expectLater(
      SqliteMigration.runIfNeeded(
        database: db,
        prefs: prefs,
        reader: const _DuplicateSymbolReader(),
      ),
      throwsA(isA<SqliteMigrationException>()),
    );

    // Flag NON posé
    expect(prefs.getBool(SqliteMigration.migrationDoneKey), isNull);
  });
}

/// Reader factice produisant 2 positions au même symbole (collision PK) pour
/// forcer un mismatch de counts à l'import.
class _DuplicateSymbolReader extends LegacySharedPrefsReader {
  const _DuplicateSymbolReader();

  @override
  Map<String, dynamic> read(SharedPreferences prefs) {
    return {
      'wallets': [
        {'id': 'w1', 'name': 'W', 'createdAt': '2024-01-01T00:00:00.000'},
      ],
      'accounts': [
        {'id': 'a1', 'walletId': 'w1', 'name': 'C', 'type': 'brokerage'},
      ],
      'positions': {
        'a1': [
          {
            'accountId': 'a1',
            'asset': {'symbol': 'DUP', 'type': 'stock'},
            'quantity': '1',
          },
          {
            'accountId': 'a1',
            'asset': {'symbol': 'DUP', 'type': 'stock'},
            'quantity': '2',
          },
        ],
      },
      'snapshots': <String, dynamic>{},
      'allocationTargets': <String, dynamic>{},
    };
  }
}

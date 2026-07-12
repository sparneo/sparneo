// test/sample_data_demo_backup_test.dart
//
// Valide le jeu de démonstration `sample_data/demo-backup.json` (celui du
// README, utilisé pour les captures d'écran) avec les moteurs de l'application
// elle-même :
//   1. le fichier s'importe sans erreur (importRawData, transaction atomique) ;
//   2. chaque position déclarée est EXACTEMENT la projection WAC de son journal
//      (quantité Decimal + PRU) — la réconciliation D3 est donc sans perte ;
//   3. le solde espèces dérivé de chaque compte est cohérent (une seule devise,
//      jamais négatif) ;
//   4. le jeu EXPOSE TOUTES les fonctionnalités : tous les TransactionKind (y
//      compris les variantes espèces d'openingBalance/adjustment), la devise de
//      règlement découplée (settlementCurrency), les frais, les overrides de
//      type verrouillés (typeLocked), le pricing métal (refSymbol/poids/prime),
//      les cibles d'allocation et les snapshots.
//
// Ce test est la SPEC du jeu de démo : si le format de backup évolue (bump de
// version) ou si une fonctionnalité vitrine disparaît du fichier, il casse.

import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';

import 'helpers/test_database.dart';

void main() {
  late Map<String, dynamic> backup;
  late Map<String, dynamic> data;
  late AppDatabase db;
  late AccountStorage storage;

  setUpAll(() async {
    final content =
        await File('sample_data/demo-backup.json').readAsString();
    backup = jsonDecode(content) as Map<String, dynamic>;
    data = Map<String, dynamic>.from(backup['data'] as Map);

    db = await openTestDatabase();
    storage = AccountStorage(database: db);
    // L'import DOIT réussir (cohérence référentielle + kinds tous connus).
    await storage.importRawData(data);
  });

  tearDownAll(() async {
    await (await db.database).close();
  });

  // Journal d'un compte, désérialisé par le modèle de l'app.
  List<AssetTransaction> journalOf(String accountId) {
    final txsMap = data['transactions'] as Map;
    final list = (txsMap[accountId] as List?) ?? const [];
    return list
        .map((j) => AssetTransaction.fromJson(
              Map<String, dynamic>.from(j as Map),
              fallbackAccountId: accountId,
            ))
        .toList();
  }

  test('enveloppe : format reconnu, version de backup courante (3)', () {
    expect(backup['format'], 'sparneo_backup');
    // Doit suivre BackupService._version : un bump du format doit régénérer /
    // revalider le jeu de démo.
    expect(backup['version'], 3);
  });

  test('import : les données restaurées correspondent au fichier', () async {
    final accounts = await storage.getAllAccounts();
    expect(accounts, hasLength((data['accounts'] as List).length));
    final wallets = await storage.getAllWallets();
    expect(wallets, hasLength(1));
  });

  test('chaque position déclarée == projection WAC exacte de son journal', () {
    final positionsMap = data['positions'] as Map;
    var checked = 0;
    for (final entry in positionsMap.entries) {
      final accountId = entry.key as String;
      final journal = journalOf(accountId);
      for (final pJson in entry.value as List) {
        final p = Map<String, dynamic>.from(pJson as Map);
        final symbol =
            (p['asset'] as Map)['symbol'] as String;
        final proj = projectPosition(
          journal.where((t) => t.symbol == symbol).toList(),
        );
        expect(
          proj.quantity,
          Decimal.parse(p['quantity'] as String),
          reason: '$accountId/$symbol : quantité déclarée ≠ projection',
        );
        final declaredPru = (p['averageBuyPrice'] as num?)?.toDouble();
        expect(declaredPru, isNotNull,
            reason: '$accountId/$symbol : PRU manquant');
        expect(
          proj.averagePrice,
          closeTo(declaredPru!, declaredPru.abs() * 1e-6),
          reason: '$accountId/$symbol : PRU déclaré ≠ projection WAC',
        );
        checked++;
      }
    }
    expect(checked, greaterThanOrEqualTo(14));
  });

  test('cash dérivé : une seule devise par compte, jamais négatif', () {
    for (final aJson in data['accounts'] as List) {
      final account =
          Account.fromJson(Map<String, dynamic>.from(aJson as Map));
      final replay = replayLedger(journalOf(account.id));
      final nonZero = replay.cashByCurrency.entries
          .where((e) => e.value != Decimal.zero)
          .toList();
      // Contrainte multi-devises V1 : tout l'effet cash est dans la devise du
      // compte (les lignes USD portent settlementCurrency=EUR).
      for (final e in nonZero) {
        expect(e.key, account.currency,
            reason: '${account.name} : bucket cash étranger ${e.key}');
        expect(e.value >= Decimal.zero, isTrue,
            reason: '${account.name} : cash dérivé négatif (${e.value})');
      }
    }
  });

  test('Livret A : compte cash à solde manuel, sans journal', () {
    final livret = (data['accounts'] as List)
        .map((a) => Account.fromJson(Map<String, dynamic>.from(a as Map)))
        .singleWhere((a) => a.kind == AccountKind.cash);
    expect(livret.cashBalance, greaterThan(0));
    expect(journalOf(livret.id), isEmpty);
  });

  test('vitrine : tous les TransactionKind sont représentés', () {
    final allTxs = (data['transactions'] as Map)
        .keys
        .expand((accId) => journalOf(accId as String))
        .toList();

    for (final kind in TransactionKind.values) {
      expect(allTxs.any((t) => t.kind == kind), isTrue,
          reason: 'kind ${kind.wire} absent du jeu de démo');
    }
    // Variantes TITRE et ESPÈCES d'openingBalance / adjustment.
    expect(
      allTxs.any((t) =>
          t.kind == TransactionKind.openingBalance && t.symbol != null),
      isTrue,
      reason: 'openingBalance TITRE absent',
    );
    expect(
      allTxs.any((t) =>
          t.kind == TransactionKind.openingBalance && t.symbol == null),
      isTrue,
      reason: 'openingBalance ESPÈCES absent',
    );
    expect(
      allTxs
          .any((t) => t.kind == TransactionKind.adjustment && t.symbol != null),
      isTrue,
      reason: 'adjustment TITRE absent',
    );
    expect(
      allTxs
          .any((t) => t.kind == TransactionKind.adjustment && t.symbol == null),
      isTrue,
      reason: 'adjustment ESPÈCES absent',
    );
    // Découplage cotation / règlement (titre USD réglé en EUR).
    expect(
      allTxs.any((t) =>
          t.settlementCurrency != null && t.settlementCurrency != t.currency),
      isTrue,
      reason: 'aucune ligne avec settlementCurrency ≠ currency',
    );
    // Frais d'ordre et lots déclaratifs.
    expect(allTxs.any((t) => t.fee != null && t.fee != '0'), isTrue);
    expect(allTxs.any((t) => t.meta?['declarative'] == true), isTrue);
    expect(allTxs.any((t) => t.note != null), isTrue);
  });

  test('vitrine : natures de compte, overrides de type et pricing métal', () {
    final kinds = (data['accounts'] as List)
        .map((a) =>
            Account.fromJson(Map<String, dynamic>.from(a as Map)).kind)
        .toSet();
    expect(
      kinds,
      containsAll({
        AccountKind.pea,
        AccountKind.cto,
        AccountKind.assuranceVie,
        AccountKind.crypto,
        AccountKind.cash,
        AccountKind.preciousMetal,
      }),
    );

    final assets = (data['positions'] as Map)
        .values
        .expand((l) => l as List)
        .map((p) =>
            Asset.fromJson(Map<String, dynamic>.from((p as Map)['asset'])))
        .toList();
    final types = assets.map((a) => a.type).toSet();
    expect(
      types,
      containsAll({
        AssetType.etf,
        AssetType.stock,
        AssetType.bond,
        AssetType.crypto,
        AssetType.preciousMetal,
        AssetType.realEstate,
      }),
    );
    // Les types non auto-détectables sont bien verrouillés (typeLocked).
    for (final a in assets.where((a) =>
        a.type == AssetType.bond ||
        a.type == AssetType.preciousMetal ||
        a.type == AssetType.realEstate)) {
      expect(a.typeLocked, isTrue,
          reason: '${a.symbol} : override de type non verrouillé');
    }
    // Au moins un métal physique complet (cours de référence + poids + prime).
    expect(
      assets.any((a) =>
          a.hasMetalPricing &&
          a.fineWeightGrams != null &&
          a.premiumPercent != null),
      isTrue,
      reason: 'aucun métal physique avec pricing complet',
    );
    // Et un « or papier » : bucket métal SANS pricing métal (override pur).
    expect(
      assets.any((a) => a.isPreciousMetal && !a.hasMetalPricing),
      isTrue,
      reason: 'aucun ETC or (bucket métal sans refSymbol)',
    );
  });

  test('cibles d’allocation : somme ≤ 100, cash ciblé', () {
    final targets = Map<String, dynamic>.from(
      ((data['allocationTargets'] as Map)['w-demo'] as Map)['targets'] as Map,
    );
    final total =
        targets.values.fold<double>(0, (s, v) => s + (v as num).toDouble());
    expect(total, lessThanOrEqualTo(100));
    expect(targets.keys, contains('cash'));
  });

  // ---------------------------------------------------------------------------
  // Reprojection post-restauration (étape 8 de importRawData) : le jeu de
  // démo, importé au setUpAll, doit ressortir ENTIÈREMENT reprojeté — c'est
  // la SPEC de la restauration, pas seulement du jeu de démo.
  // ---------------------------------------------------------------------------

  test('reprojection : toutes les positions ont derived_at non NULL après import', () async {
    final database = await db.database;
    final rows = await database.query('positions', columns: ['account_id', 'symbol', 'derived_at']);
    expect(rows, isNotEmpty);
    for (final row in rows) {
      expect(row['derived_at'], isNotNull,
          reason: '${row['account_id']}/${row['symbol']} : derived_at NULL après import '
              '(déclaration du jeu de démo censée matcher sa projection — test '
              'précédent « chaque position déclarée == projection »)');
    }
  });

  test('reprojection : derived_cash de chaque compte == bucket devise-compte de replayLedger',
      () async {
    final database = await db.database;
    for (final aJson in data['accounts'] as List) {
      final account = Account.fromJson(Map<String, dynamic>.from(aJson as Map));
      final rows = await database.query(
        'accounts',
        columns: ['derived_cash', 'derived_cash_at'],
        where: 'id = ?',
        whereArgs: [account.id],
      );
      expect(rows, hasLength(1));
      expect(rows.first['derived_cash_at'], isNotNull,
          reason: '${account.name} : derived_cash_at NULL après import');
      final replay = replayLedger(journalOf(account.id));
      final expected = replay.cashByCurrency[account.currency] ?? Decimal.zero;
      expect(rows.first['derived_cash'], expected.toString(),
          reason: '${account.name} : derived_cash ≠ Σ amount du journal');
    }
  });

  test('reprojection : settlement_currency persisté pour exactement les mouvements qui le déclarent',
      () async {
    final database = await db.database;
    final countRows = await database.rawQuery(
      'SELECT COUNT(*) AS n FROM transactions WHERE settlement_currency IS NOT NULL',
    );
    final persistedCount = (countRows.first['n'] as num).toInt();

    final declaredCount = (data['transactions'] as Map)
        .values
        .expand((l) => l as List)
        .where((t) => (t as Map)['settlementCurrency'] != null)
        .length;

    expect(declaredCount, greaterThan(0),
        reason: 'précondition : le jeu de démo doit déclarer au moins une settlementCurrency');
    expect(persistedCount, declaredCount);
  });

  test('snapshots : série strictement croissante en dates, valeurs > 0', () {
    final snaps = ((data['snapshots'] as Map)['w-demo'] as List)
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();
    expect(snaps.length, greaterThanOrEqualTo(52),
        reason: 'au moins un an de snapshots hebdomadaires');
    String? prev;
    for (final s in snaps) {
      final date = s['date'] as String;
      if (prev != null) {
        expect(date.compareTo(prev), greaterThan(0),
            reason: 'dates de snapshots non croissantes');
      }
      prev = date;
      expect((s['totalValue'] as num).toDouble(), greaterThan(0));
    }
  });
}

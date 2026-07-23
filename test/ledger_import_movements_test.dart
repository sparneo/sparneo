// test/ledger_import_movements_test.dart
//
// Couche d'écriture de l'import ADDITIF de relevés : LedgerService.importMovements.
//
// Base in-memory (openTestDatabase) seedée avec un wallet + un compte. Les
// positions sont créées soit par l'import lui-même (symboles nouveaux), soit
// à la main (savePosition = legacy, derived_at NULL) pour éprouver la garde
// anti-écrasement.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;

import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import 'helpers/test_database.dart';

/// Double de test : hérite du [TransactionStorage] réel (constructeur
/// `forTesting`, jamais de connexion propre — l'exécuteur de transaction lui est
/// toujours passé) mais force [getBySymbol] à lever. [getBySymbol] est appelée
/// par [LedgerService.reprojectSymbolWithin] APRÈS que les mouvements ont déjà
/// été upsertés dans la MÊME transaction SQL : simule un échec au milieu de
/// l'import et vérifie que le rollback défait tout (mouvements ET position).
class _ThrowOnReprojectTransactionStorage extends TransactionStorage {
  _ThrowOnReprojectTransactionStorage() : super.forTesting();

  @override
  Future<List<AssetTransaction>> getBySymbol(
    String accountId,
    String symbol, {
    DatabaseExecutor? executor,
  }) {
    throw Exception('échec forcé de la reprojection (rollback atomique)');
  }
}

void main() {
  late AppDatabase appDb;
  late LedgerService ledger;
  late AccountStorage accounts;
  late TransactionStorage txStorage;

  const accountId = 'a1';

  Future<void> seedAccount() async {
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
  }

  Asset asset(String symbol) => Asset(
        symbol: symbol,
        name: symbol,
        type: AssetType.stock,
        currency: 'EUR',
        isin: 'ISIN_$symbol',
      );

  /// Position LEGACY : quantité/PRU saisis à la main, derived_at NULL (chemin
  /// savePosition, jamais projeté).
  Future<void> seedLegacyPosition(
      String symbol, String qty, double? pru) async {
    await accounts.savePosition(
      accountId,
      Position(
        accountId: accountId,
        asset: asset(symbol),
        quantity: qty,
        averageBuyPrice: pru,
      ),
    );
  }

  AssetTransaction buy(
    String id,
    String symbol,
    String qty,
    String price, {
    String? amount,
    DateTime? date,
  }) =>
      AssetTransaction(
        id: id,
        accountId: accountId,
        symbol: symbol,
        kind: TransactionKind.buy,
        quantity: qty,
        unitPrice: price,
        amount: amount,
        currency: 'EUR',
        date: date ?? DateTime(2024, 1, 1),
      );

  AssetTransaction opening(
    String id,
    String symbol,
    String qty,
    String price, {
    DateTime? date,
  }) =>
      AssetTransaction(
        id: id,
        accountId: accountId,
        symbol: symbol,
        kind: TransactionKind.openingBalance,
        quantity: qty,
        unitPrice: price,
        currency: 'EUR',
        date: date ?? DateTime(2023, 1, 1),
      );

  AssetTransaction cash(
    String id,
    TransactionKind kind,
    String amount, {
    DateTime? date,
  }) =>
      AssetTransaction(
        id: id,
        accountId: accountId,
        symbol: null,
        kind: kind,
        amount: amount,
        currency: 'EUR',
        date: date ?? DateTime(2024, 1, 1),
      );

  AssetTransaction transferOut(
    String id,
    String symbol,
    String qty, {
    DateTime? date,
  }) =>
      AssetTransaction(
        id: id,
        accountId: accountId,
        symbol: symbol,
        kind: TransactionKind.transferOut,
        quantity: qty,
        currency: 'EUR',
        date: date ?? DateTime(2024, 3, 1),
      );

  setUp(() async {
    appDb = await openTestDatabase();
    ledger = LedgerService(database: appDb);
    accounts = AccountStorage(database: appDb);
    txStorage = TransactionStorage(database: appDb);
    await seedAccount();
  });

  tearDown(() async {
    await appDb.close();
  });

  test('import additif : le journal préexistant n\'est PAS effacé', () async {
    // OLD : position déjà projetée + son journal (via ledger).
    await seedLegacyPosition('OLD', '0', null);
    await ledger.recordTransaction(
      buy('old1', 'OLD', '5', '100', amount: '-500', date: DateTime(2024, 1, 1)),
    );
    expect((await accounts.getPosition(accountId, 'OLD'))!.quantity, '5');

    // Import d'un NOUVEAU symbole : n'a rien à voir avec OLD.
    final res = await ledger.importMovements(
      accountId: accountId,
      movements: [buy('new1', 'NEW', '3', '10', date: DateTime(2024, 2, 1))],
      newAssets: [asset('NEW')],
    );

    // OLD intact (position ET journal).
    final old = await accounts.getPosition(accountId, 'OLD');
    expect(old!.quantity, '5');
    expect(await txStorage.getBySymbol(accountId, 'OLD'), hasLength(1));

    // NEW créé + projeté.
    expect(res.createdSymbols, ['NEW']);
    expect(res.reprojectedSymbols, ['NEW']);
    expect(res.movementsWritten, 1);
    expect((await accounts.getPosition(accountId, 'NEW'))!.quantity, '3');
  });

  test('symbole NOUVEAU : position créée + reprojetée depuis le journal importé',
      () async {
    final res = await ledger.importMovements(
      accountId: accountId,
      movements: [
        buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)),
        buy('2', 'AAPL', '10', '200', date: DateTime(2024, 1, 2)),
      ],
      newAssets: [asset('AAPL')],
    );

    expect(res.createdSymbols, ['AAPL']);
    expect(res.reprojectedSymbols, ['AAPL']);
    expect(res.legacySymbols, isEmpty);
    expect(res.movementsWritten, 2);

    final pos = await accounts.getPosition(accountId, 'AAPL');
    expect(pos!.quantity, '20');
    expect(pos.averageBuyPrice, closeTo(150.0, 1e-9));
    // Position bien projetée (pas legacy).
    expect(await accounts.getPositionDerivedAt(accountId, 'AAPL'), isNotNull);
    // ISIN persisté dans asset_json.
    expect(pos.asset.isin, 'ISIN_AAPL');
  });

  test('symbole DÉJÀ PROJETÉ : la reprojection englobe ancien + nouveau',
      () async {
    // Amorçage : AAPL projeté à 10 @ 100.
    await seedLegacyPosition('AAPL', '0', null);
    await ledger.recordTransaction(
      buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)),
    );
    expect(await accounts.getPositionDerivedAt(accountId, 'AAPL'), isNotNull);

    // Import additif : +10 @ 200. newAssets vide (position existe déjà).
    final res = await ledger.importMovements(
      accountId: accountId,
      movements: [buy('2', 'AAPL', '10', '200', date: DateTime(2024, 1, 2))],
      newAssets: const [],
    );

    expect(res.createdSymbols, isEmpty);
    expect(res.reprojectedSymbols, ['AAPL']);

    final pos = await accounts.getPosition(accountId, 'AAPL');
    expect(pos!.quantity, '20');
    expect(pos.averageBuyPrice, closeTo(150.0, 1e-9));
  });

  test(
      'CARDINAL — legacy déclaré SANS ancre : déclaration PRÉSERVÉE, seul le '
      'cash bouge', () async {
    // Position legacy : 100 @ 50, saisie main, derived_at NULL, aucun journal.
    await seedLegacyPosition('LEG', '100', 50.0);
    expect(await accounts.getPositionDerivedAt(accountId, 'LEG'), isNull);

    // Import partiel : un achat récent, SANS openingBalance d'ancrage.
    final res = await ledger.importMovements(
      accountId: accountId,
      movements: [
        buy('1', 'LEG', '10', '60', amount: '-600', date: DateTime(2024, 6, 1)),
      ],
      newAssets: const [],
    );

    // Déclaration INTACTE : ni la quantité ni le PRU n'ont bougé, toujours legacy.
    final pos = await accounts.getPosition(accountId, 'LEG');
    expect(pos!.quantity, '100',
        reason: 'la déclaration manuelle ne doit JAMAIS être écrasée par une '
            'projection partielle');
    expect(pos.averageBuyPrice, closeTo(50.0, 1e-9));
    expect(await accounts.getPositionDerivedAt(accountId, 'LEG'), isNull,
        reason: 'la position reste legacy (non adoptée)');

    // Consigné comme legacy, jamais reprojeté.
    expect(res.legacySymbols, ['LEG']);
    expect(res.reprojectedSymbols, isEmpty);

    // Le mouvement EST journalisé et le cash reprojeté (−600).
    expect(await txStorage.getBySymbol(accountId, 'LEG'), hasLength(1));
    expect((await accounts.getAccountDerivedCash(accountId)).cash, '-600');
  });

  test(
      'legacy déclaré AVEC ancre openingBalance cohérente : adoption '
      '(projection englobe antériorité + période)', () async {
    // Position legacy : 60 @ 50 (holding déclaré = solde d'ouverture du relevé).
    await seedLegacyPosition('LEG', '60', 50.0);

    // Import : ancre openingBalance (60 @ 50, reproduit la déclaration) + achat
    // de la période (40 @ 100).
    final res = await ledger.importMovements(
      accountId: accountId,
      movements: [
        opening('anchor', 'LEG', '60', '50', date: DateTime(2023, 1, 1)),
        buy('p1', 'LEG', '40', '100', date: DateTime(2024, 3, 1)),
      ],
      newAssets: const [],
    );

    expect(res.reprojectedSymbols, ['LEG']);
    expect(res.legacySymbols, isEmpty);

    // Projection du journal complet : 100 titres, coût 60×50 + 40×100 = 7000 →
    // PRU 70.
    final pos = await accounts.getPosition(accountId, 'LEG');
    expect(pos!.quantity, '100');
    expect(pos.averageBuyPrice, closeTo(70.0, 1e-9));
    expect(await accounts.getPositionDerivedAt(accountId, 'LEG'), isNotNull);
  });

  test('cash reprojeté UNE fois, cohérent (deposit/withdrawal/charge/interest)',
      () async {
    final res = await ledger.importMovements(
      accountId: accountId,
      movements: [
        cash('d', TransactionKind.deposit, '1000', date: DateTime(2024, 1, 1)),
        cash('w', TransactionKind.withdrawal, '-300', date: DateTime(2024, 1, 2)),
        cash('c', TransactionKind.charge, '-50', date: DateTime(2024, 1, 3)),
        cash('i', TransactionKind.interest, '20', date: DateTime(2024, 1, 4)),
      ],
      newAssets: const [],
    );

    expect(res.movementsWritten, 4);
    expect(res.createdSymbols, isEmpty);
    expect(res.reprojectedSymbols, isEmpty);
    // 1000 − 300 − 50 + 20 = 670.
    expect((await accounts.getAccountDerivedCash(accountId)).cash, '670');
  });

  test('atomicité : une exception au milieu laisse la base INCHANGÉE (rollback)',
      () async {
    // Journal préexistant sur OLD (via ledger : projeté).
    await seedLegacyPosition('OLD', '0', null);
    await ledger.recordTransaction(
      buy('old1', 'OLD', '5', '100', amount: '-500', date: DateTime(2024, 1, 1)),
    );
    final oldJournalBefore = await txStorage.getBySymbol(accountId, 'OLD');
    final cashBefore = (await accounts.getAccountDerivedCash(accountId)).cash;

    // Import qui échoue à la reprojection (getBySymbol lève).
    final failing = LedgerService(
      database: appDb,
      transactionStorage: _ThrowOnReprojectTransactionStorage(),
    );
    await expectLater(
      failing.importMovements(
        accountId: accountId,
        movements: [buy('new1', 'NEW', '3', '10', date: DateTime(2024, 2, 1))],
        newAssets: [asset('NEW')],
      ),
      throwsException,
    );

    // (a) rien de neuf : NEW n'existe ni en position ni au journal.
    expect(await accounts.getPosition(accountId, 'NEW'), isNull);
    expect(await txStorage.getBySymbol(accountId, 'NEW'), isEmpty);
    // (b) l'existant est intact.
    expect(await txStorage.getBySymbol(accountId, 'OLD'),
        hasLength(oldJournalBefore.length));
    expect((await accounts.getPosition(accountId, 'OLD'))!.quantity, '5');
    expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);
  });

  test('transferOut : sortie intégrale → quantité projetée 0, cash inchangé '
      'par le transfert', () async {
    // Achat (déplace le cash), puis sortie de TITRES par transfert (aucun cash).
    final res = await ledger.importMovements(
      accountId: accountId,
      movements: [
        buy('b1', 'SUB', '5', '100', amount: '-500', date: DateTime(2024, 1, 1)),
        transferOut('t1', 'SUB', '5', date: DateTime(2024, 2, 1)),
      ],
      newAssets: [asset('SUB')],
    );

    expect(res.createdSymbols, ['SUB']);
    // Position projetée à 0 (soldée par le transfert) — reste en base.
    expect((await accounts.getPosition(accountId, 'SUB'))!.quantity, '0');
    // Le cash ne reflète QUE l'achat (-500) : le transferOut n'a aucun amount.
    expect((await accounts.getAccountDerivedCash(accountId)).cash, '-500');
    // Les deux mouvements sont bien journalisés.
    expect(await txStorage.getBySymbol(accountId, 'SUB'), hasLength(2));
  });

  test('intraday : seq (meta) survit au round-trip SQLite et pilote la '
      'reprojection → net 0 (pas de résidu fantôme)', () async {
    // Achat 11 puis vente 11 le MÊME jour. La LISTE est ordonnée vente-avant-
    // achat, et l\'id de la vente (\'001\') trierait AVANT l\'achat (\'999\') :
    // sans seq, le clamp anti-survente laisserait un résidu de 11. seq(achat)=0
    // < seq(vente)=1 → ordre réel préservé jusque dans la position persistée.
    AssetTransaction m(
      String id,
      TransactionKind kind,
      String qty,
      String price,
      int seq,
    ) =>
        AssetTransaction(
          id: id,
          accountId: accountId,
          symbol: 'RT',
          kind: kind,
          quantity: qty,
          unitPrice: price,
          amount: kind == TransactionKind.buy ? '-1100' : '1210',
          currency: 'EUR',
          date: DateTime(2020, 6, 15),
          meta: {'seq': seq},
        );

    await ledger.importMovements(
      accountId: accountId,
      movements: [
        m('001', TransactionKind.sell, '11', '110', 1),
        m('999', TransactionKind.buy, '11', '100', 0),
      ],
      newAssets: [asset('RT')],
    );

    // Position nette 0 (soldée) — aucun résidu fantôme malgré l'ordre d'entrée.
    expect((await accounts.getPosition(accountId, 'RT'))!.quantity, '0');
  });
}

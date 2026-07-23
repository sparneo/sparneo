// test/ledger_undo_import_test.dart
//
// ANNULATION d'un import de relevé (P1.1) : inverse ciblé de
// LedgerService.importMovements.
//
//   - Couche LEDGER : LedgerService.removeImportBatch — suppression atomique du
//     LOT (meta['importBatch']) + reprojections titre/cash en sens inverse,
//     garde anti-écrasement legacy respectée, isolation stricte des autres lots.
//   - Couche CONTRÔLEUR : AccountController.confirmStatementImport expose le
//     batchId via lastImportBatchId ; undoStatementImport le rejoue et revient à
//     l'état d'avant.
//
// Base in-memory (openTestDatabase). L'estampille meta['importBatch'] est posée
// par importMovements quand on lui passe importBatchId.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import 'helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Groupe LEDGER : LedgerService.removeImportBatch
// ---------------------------------------------------------------------------

void main() {
  const accountId = 'a1';

  group('LedgerService.removeImportBatch', () {
    late AppDatabase appDb;
    late LedgerService ledger;
    late AccountStorage accounts;
    late TransactionStorage txStorage;

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

    Future<void> seedLegacyPosition(String symbol, String qty, double? pru) =>
        accounts.savePosition(
          accountId,
          Position(
            accountId: accountId,
            asset: asset(symbol),
            quantity: qty,
            averageBuyPrice: pru,
          ),
        );

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
          date: date ?? DateTime(2024, 1, 2),
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

    test(
        'NOMINAL (achat + dividende + cash) : import → undo restaure journal, '
        'cash et position ; un mouvement HORS-LOT survit', () async {
      // --- État PRÉ-import ---
      // AAPL déjà projetée (10 @ 100, cash -1000).
      await seedLegacyPosition('AAPL', '0', null);
      await ledger.recordTransaction(
        buy('pre-aapl', 'AAPL', '10', '100',
            amount: '-1000', date: DateTime(2024, 1, 1)),
      );
      // Un dépôt HORS-LOT saisi à la main (ne doit JAMAIS être supprimé).
      await ledger.recordTransaction(
        cash('manual-dep', TransactionKind.deposit, '500',
            date: DateTime(2024, 1, 1)),
      );

      final journalBefore = await txStorage.getByAccount(accountId);
      final cashBefore = (await accounts.getAccountDerivedCash(accountId)).cash;
      final aaplBefore = await accounts.getPosition(accountId, 'AAPL');
      final aaplDerivedAtBefore =
          await accounts.getPositionDerivedAt(accountId, 'AAPL');
      expect(cashBefore, '-500'); // -1000 + 500

      // --- Import d'un LOT (achat AAPL + dividende + apport) ---
      const batchId = 'imp-nominal';
      final res = await ledger.importMovements(
        accountId: accountId,
        movements: [
          buy('b-aapl', 'AAPL', '5', '200',
              amount: '-1000', date: DateTime(2024, 2, 1)),
          cash('b-div', TransactionKind.dividend, '30',
              date: DateTime(2024, 2, 2)),
          cash('b-dep', TransactionKind.deposit, '1000',
              date: DateTime(2024, 2, 3)),
        ],
        newAssets: const [],
        importBatchId: batchId,
      );
      expect(res.movementsWritten, 3);
      // Après import : AAPL 15, cash -500 -1000 +30 +1000 = -470.
      expect((await accounts.getPosition(accountId, 'AAPL'))!.quantity, '15');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '-470');

      // --- Annulation du LOT ---
      final removed = await ledger.removeImportBatch(accountId, batchId);
      expect(removed, 3);

      // Journal revenu EXACTEMENT à l'état d'avant (mêmes ids).
      final journalAfter = await txStorage.getByAccount(accountId);
      expect(
        journalAfter.map((t) => t.id).toSet(),
        journalBefore.map((t) => t.id).toSet(),
      );
      // Le mouvement hors-lot est toujours là.
      expect(journalAfter.any((t) => t.id == 'manual-dep'), isTrue);

      // Cash et position restaurés.
      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);
      final aaplAfter = await accounts.getPosition(accountId, 'AAPL');
      expect(aaplAfter!.quantity, aaplBefore!.quantity);
      expect(aaplAfter.averageBuyPrice, aaplBefore.averageBuyPrice);
      expect(await accounts.getPositionDerivedAt(accountId, 'AAPL'),
          isNotNull, reason: 'AAPL reste projetée (derived_at non NULL)');
      expect(aaplDerivedAtBefore, isNotNull);
    });

    test(
        'symbole CRÉÉ par le lot : undo vide le journal → position laissée à '
        'quantité 0 (ligne conservée, non supprimée)', () async {
      const batchId = 'imp-new';
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          buy('n1', 'NEW', '3', '10',
              amount: '-30', date: DateTime(2024, 2, 1)),
        ],
        newAssets: [asset('NEW')],
        importBatchId: batchId,
      );
      expect((await accounts.getPosition(accountId, 'NEW'))!.quantity, '3');

      final removed = await ledger.removeImportBatch(accountId, batchId);
      expect(removed, 1);

      // Journal du symbole vidé, mais la LIGNE position subsiste, reprojetée 0.
      expect(await txStorage.getBySymbol(accountId, 'NEW'), isEmpty);
      final pos = await accounts.getPosition(accountId, 'NEW');
      expect(pos, isNotNull, reason: 'position orpheline conservée (choix v1)');
      expect(pos!.quantity, '0');
      // Cash revenu à 0.
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '0');
    });

    test(
        'legacy déclaré NON adopté : undo n\'écrase PAS la déclaration, seul le '
        'cash revient', () async {
      // Position legacy 100 @ 50, derived_at NULL, aucun journal.
      await seedLegacyPosition('LEG', '100', 50.0);
      expect(await accounts.getPositionDerivedAt(accountId, 'LEG'), isNull);

      const batchId = 'imp-legacy';
      // Import partiel SANS ancre → laissé legacy, seul le cash bouge (-600).
      final res = await ledger.importMovements(
        accountId: accountId,
        movements: [
          buy('l1', 'LEG', '10', '60',
              amount: '-600', date: DateTime(2024, 6, 1)),
        ],
        newAssets: const [],
        importBatchId: batchId,
      );
      expect(res.legacySymbols, ['LEG']);
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '-600');

      final removed = await ledger.removeImportBatch(accountId, batchId);
      expect(removed, 1);

      // Déclaration INTACTE (jamais reprojetée), cash revenu à 0.
      final leg = await accounts.getPosition(accountId, 'LEG');
      expect(leg!.quantity, '100');
      expect(leg.averageBuyPrice, closeTo(50.0, 1e-9));
      expect(await accounts.getPositionDerivedAt(accountId, 'LEG'), isNull,
          reason: 'la position reste legacy (derived_at NULL)');
      expect(await txStorage.getBySymbol(accountId, 'LEG'), isEmpty);
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '0');
    });

    test('isolation : undo d\'un lot ne touche PAS les autres lots', () async {
      // Lot A crée AAPL (projetée) : +5 @ 100.
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          buy('a1', 'AAPL', '5', '100',
              amount: '-500', date: DateTime(2024, 1, 1)),
        ],
        newAssets: [asset('AAPL')],
        importBatchId: 'batch-A',
      );
      // Lot B : +7 @ 200.
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          buy('b1', 'AAPL', '7', '200',
              amount: '-1400', date: DateTime(2024, 2, 1)),
        ],
        newAssets: const [],
        importBatchId: 'batch-B',
      );
      expect((await accounts.getPosition(accountId, 'AAPL'))!.quantity, '12');

      // Annulation du LOT B uniquement.
      final removed = await ledger.removeImportBatch(accountId, 'batch-B');
      expect(removed, 1);

      // Le LOT A survit ; AAPL = 5.
      expect((await accounts.getPosition(accountId, 'AAPL'))!.quantity, '5');
      expect(await txStorage.getBySymbol(accountId, 'AAPL'), hasLength(1));
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '-500');
    });

    test('lot inconnu / déjà annulé : no-op, retourne 0', () async {
      await ledger.importMovements(
        accountId: accountId,
        movements: [buy('x1', 'AAPL', '5', '100', amount: '-500')],
        newAssets: [asset('AAPL')],
        importBatchId: 'batch-X',
      );
      final cashBefore = (await accounts.getAccountDerivedCash(accountId)).cash;

      expect(await ledger.removeImportBatch(accountId, 'inconnu'), 0);

      // Rien n'a bougé.
      expect((await accounts.getPosition(accountId, 'AAPL'))!.quantity, '5');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);

      // Double annulation : la seconde est un no-op.
      expect(await ledger.removeImportBatch(accountId, 'batch-X'), 1);
      expect(await ledger.removeImportBatch(accountId, 'batch-X'), 0);
    });

    test('importBatchId fusionne meta sans écraser importKey/seq', () async {
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          AssetTransaction(
            id: 'm1',
            accountId: accountId,
            symbol: 'NEW',
            kind: TransactionKind.buy,
            quantity: '1',
            unitPrice: '10',
            amount: '-10',
            currency: 'EUR',
            date: DateTime(2024, 1, 1),
            meta: const {'importKey': 'k1', 'seq': 3},
          ),
        ],
        newAssets: [asset('NEW')],
        importBatchId: 'batch-meta',
      );

      final tx = await txStorage.getById('m1');
      expect(tx!.meta?['importKey'], 'k1');
      expect(tx.meta?['seq'], 3);
      expect(tx.meta?['importBatch'], 'batch-meta');
    });

    test('importMovements SANS importBatchId : meta inchangé (legacy)', () async {
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          AssetTransaction(
            id: 'm2',
            accountId: accountId,
            symbol: 'NEW',
            kind: TransactionKind.buy,
            quantity: '1',
            unitPrice: '10',
            amount: '-10',
            currency: 'EUR',
            date: DateTime(2024, 1, 1),
            meta: const {'importKey': 'k2'},
          ),
        ],
        newAssets: [asset('NEW')],
      );
      final tx = await txStorage.getById('m2');
      expect(tx!.meta?.containsKey('importBatch'), isFalse);
      expect(tx.meta?['importKey'], 'k2');
    });
  });

  // -------------------------------------------------------------------------
  // Groupe CONTRÔLEUR : confirmStatementImport → lastImportBatchId → undo
  // -------------------------------------------------------------------------

  group('AccountController undo (bout-en-bout via CSV)', () {
    const walletId = 'wallet-1';
    const ctrlAccountId = 'account-1';

    const header =
        'Date;Operation;ISIN;Symbole;Libelle;Quantite;Cours;Frais;Montant;Ref';

    BrokerProfile profile() => BrokerProfile.genericManual(
          delimiter: ';',
          encoding: utf8,
          hasHeaderRow: true,
          decimalSeparator: DecimalSeparator.dot,
          columns: const ColumnMapping(byIndex: {
            MovementField.date: 0,
            MovementField.kindLabel: 1,
            MovementField.isin: 2,
            MovementField.symbol: 3,
            MovementField.label: 4,
            MovementField.quantity: 5,
            MovementField.unitPrice: 6,
            MovementField.fee: 7,
            MovementField.amount: 8,
            MovementField.operationReference: 9,
          }),
          kindLexicon: const {'Achat': TransactionKind.buy},
        );

    Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

    // Deux achats d'un symbole neuf, mappé directement par le CSV.
    String csv() => '$header\r\n'
        '10/01/2024;Achat;;NEWCO;New Co;2;10;0;-20;REF-1\r\n'
        '11/01/2024;Achat;;NEWCO;New Co;3;20;0;-60;REF-2\r\n';

    Future<void> seed(AppDatabase db) async {
      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: walletId, name: 'W'));
      await storage.saveAccount(Account(
        id: ctrlAccountId,
        walletId: walletId,
        name: 'Compte',
        kind: AccountKind.cto,
        currency: 'EUR',
      ));
    }

    AccountController makeCtrl(AppDatabase db) => AccountController(
          initialAccountId: ctrlAccountId,
          storage: AccountStorage(database: db),
          ledgerService: LedgerService(database: db),
          transactionStorage: TransactionStorage(database: db),
          marketService: _NoNetworkMarketDataService(),
        );

    test(
        'confirmStatementImport expose lastImportBatchId ; undoStatementImport '
        'revient à l\'état d\'avant', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await seed(db);

      final accounts = AccountStorage(database: db);
      final txStorage = TransactionStorage(database: db);

      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();
      expect(ctrl.lastImportBatchId, isNull);

      final preview = await ctrl.previewStatementImport(
        bytes(csv()),
        profile(),
        accountId: ctrlAccountId,
      );
      final err =
          await ctrl.confirmStatementImport(preview, accountId: ctrlAccountId);
      expect(err, isNull);

      // Le batchId est exposé pour l'UI.
      final batchId = ctrl.lastImportBatchId;
      expect(batchId, isNotNull);

      // Import effectif : NEWCO 5 titres, cash -80.
      expect((await accounts.getPosition(ctrlAccountId, 'NEWCO'))!.quantity, '5');
      expect((await accounts.getAccountDerivedCash(ctrlAccountId)).cash, '-80');
      expect(await txStorage.getByAccount(ctrlAccountId), hasLength(2));

      // --- Annulation ---
      final removed = await ctrl.undoStatementImport(
        accountId: ctrlAccountId,
        batchId: batchId!,
      );
      expect(removed, 2);
      expect(ctrl.lastImportBatchId, isNull, reason: 'plus rien à annuler');

      // Journal vidé, cash revenu à 0, NEWCO reprojetée à 0.
      expect(await txStorage.getByAccount(ctrlAccountId), isEmpty);
      expect((await accounts.getAccountDerivedCash(ctrlAccountId)).cash, '0');
      expect((await accounts.getPosition(ctrlAccountId, 'NEWCO'))!.quantity, '0');
    });
  });
}

/// Fake SANS RÉSEAU : _initService() recharge les cours après chaque mutation ;
/// on court-circuite tout appel réseau (interdit en test).
class _NoNetworkMarketDataService extends MarketDataService {
  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async => null;

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(Asset asset,
          {int days = 30}) async =>
      null;

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol,
          {int days = 30}) async =>
      null;
}

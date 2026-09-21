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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
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

  // ---------------------------------------------------------------------------
  // Groupe CRYPTO (chantier B16, conception interne) : dernier geste du chantier —
  // PROUVER que `LedgerService.removeImportBatch` (inchangé, ce groupe ne le modifie
  // pas) défait aussi les formes que seul le pipeline crypto écrit : échange à deux
  // jambes N4 (`_processExchangeGroup`), paire de frais tiers `feeInKind` (`sell`
  // valorisé + `charge` liés par `meta.feeForGroup`), agrégat mensuel de récompenses
  // (`meta.importKey` préfixé `agg:`). Les mouvements ci-dessous reproduisent
  // EXACTEMENT les kinds/clés de meta que
  // `CryptoLedgerNormalizer.finalizeCryptoExchanges` et l'agrégation §5.1.8 émettent
  // en production (vérifié sur pièce dans crypto_ledger_normalizer.dart) —
  // construits directement (sans repasser par tout le pipeline CSV) puisque
  // `removeImportBatch` n'agit que sur `meta['importBatch']`, un symbole et un
  // montant : c'est la même preuve, sans la machinerie de parsing.
  // ---------------------------------------------------------------------------

  group('LedgerService.removeImportBatch — formes CRYPTO (B16)', () {
    const accountId = 'c1';

    late AppDatabase appDb;
    late LedgerService ledger;
    late AccountStorage accounts;
    late TransactionStorage txStorage;

    Future<void> seedCryptoAccount() async {
      final db = await appDb.database;
      await db.insert('wallets', {
        'id': 'w-crypto',
        'name': 'W-crypto',
        'created_at': '2024-01-01T00:00:00.000',
      });
      await db.insert('accounts', {
        'id': accountId,
        'wallet_id': 'w-crypto',
        'name': 'Crypto',
        'type': 'investment',
        'currency': 'EUR',
        'kind': 'crypto',
      });
    }

    Asset cryptoAsset(String code) => Asset(
          symbol: code,
          name: code,
          type: AssetType.crypto,
          currency: 'EUR',
          ledgerCode: code,
        );

    // Pose une position PROJETÉE (derived_at non NULL) avant le lot testé —
    // même rôle que `seedLegacyPosition` du groupe LEDGER ci-dessus, mais
    // suivie d'un `recordTransaction` HORS-LOT qui l'adopte immédiatement
    // (symétrique du « pre-aapl » de la NOMINALE) : c'est ce qui permet de
    // vérifier un retour à un état antérieur NON NUL, pas seulement à 0.
    Future<void> seedPosition(String symbol) => accounts.savePosition(
          accountId,
          Position(
            accountId: accountId,
            asset: cryptoAsset(symbol),
            quantity: '0',
            averageBuyPrice: null,
          ),
        );

    AssetTransaction plain(
      String id,
      TransactionKind kind, {
      String? symbol,
      String? quantity,
      String? unitPrice,
      String? amount,
      DateTime? date,
      Map<String, dynamic>? meta,
    }) =>
        AssetTransaction(
          id: id,
          accountId: accountId,
          symbol: symbol,
          kind: kind,
          quantity: quantity,
          unitPrice: unitPrice,
          amount: amount,
          currency: 'EUR',
          date: date ?? DateTime(2024, 1, 1),
          meta: meta,
        );

    setUp(() async {
      appDb = await openTestDatabase();
      ledger = LedgerService(database: appDb);
      accounts = AccountStorage(database: appDb);
      txStorage = TransactionStorage(database: appDb);
      await seedCryptoAccount();
    });

    tearDown(() async {
      await appDb.close();
    });

    test(
        '1. échange à deux jambes (vente+achat liés, une seule valeur N4) : '
        'import puis annulation → journal ET positions reviennent EXACTEMENT '
        'à l\'état antérieur, aucune jambe orpheline', () async {
      // Pré-import HORS-LOT : ADA déjà projetée (50 @ 1 EUR).
      await seedPosition('ADA');
      await ledger.recordTransaction(
        plain('pre-ada', TransactionKind.buy,
            symbol: 'ADA', quantity: '50', unitPrice: '1', amount: '-50',
            date: DateTime(2024, 1, 1)),
      );

      final journalBefore = await txStorage.getByAccount(accountId);
      final cashBefore = (await accounts.getAccountDerivedCash(accountId)).cash;
      final adaBefore = await accounts.getPosition(accountId, 'ADA');
      expect(cashBefore, '-50');
      expect(adaBefore!.quantity, '50');

      // --- Import du LOT : échange ADA→BTC. Règle N4 (conception interne) :
      // amount(sell) et amount(buy) sont LA MÊME valeur en signes opposés — aucun
      // cash réel ne bouge, seules les deux positions crypto changent.
      const batchId = 'imp-exchange';
      final res = await ledger.importMovements(
        accountId: accountId,
        movements: [
          plain('x-sell-ada', TransactionKind.sell,
              symbol: 'ADA', quantity: '20', unitPrice: '2', amount: '40',
              date: DateTime(2024, 2, 1),
              meta: const {
                'valuationSource': 'file',
                'importKey': 'ref:c1:R1#sell:ADA',
              }),
          plain('x-buy-btc', TransactionKind.buy,
              symbol: 'BTC', quantity: '0.001', unitPrice: '40000', amount: '-40',
              date: DateTime(2024, 2, 1),
              meta: const {
                'valuationSource': 'file',
                'importKey': 'ref:c1:R1#buy:BTC',
              }),
        ],
        newAssets: [cryptoAsset('BTC')],
        importBatchId: batchId,
      );
      expect(res.movementsWritten, 2);

      // Après import : ADA 30 (50-20), BTC 0.001 ; cash INCHANGÉ (N4).
      expect((await accounts.getPosition(accountId, 'ADA'))!.quantity, '30');
      expect((await accounts.getPosition(accountId, 'BTC'))!.quantity, '0.001');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);

      // --- Annulation : les DEUX jambes reviennent ENSEMBLE ---
      final removed = await ledger.removeImportBatch(accountId, batchId);
      expect(removed, 2);

      final journalAfter = await txStorage.getByAccount(accountId);
      expect(
        journalAfter.map((t) => t.id).toSet(),
        journalBefore.map((t) => t.id).toSet(),
      );
      expect(journalAfter.any((t) => t.id == 'x-sell-ada'), isFalse,
          reason: 'jambe vendue retirée');
      expect(journalAfter.any((t) => t.id == 'x-buy-btc'), isFalse,
          reason: 'jambe achetée retirée — pas d\'orpheline');

      // ADA (préexistante) revenue EXACTEMENT à l'état antérieur.
      final adaAfter = await accounts.getPosition(accountId, 'ADA');
      expect(adaAfter!.quantity, adaBefore.quantity);
      expect(adaAfter.averageBuyPrice, adaBefore.averageBuyPrice);

      // BTC (créée par le lot) : ligne conservée, reprojetée à 0 — même choix
      // v1 que le pipeline titres (cf. groupe LEDGER ci-dessus).
      final btcAfter = await accounts.getPosition(accountId, 'BTC');
      expect(btcAfter, isNotNull);
      expect(btcAfter!.quantity, '0');

      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);
    });

    test(
        '2. paire de frais BNB tiers (feeInKind → sell valorisé + charge '
        'espèces, liés par meta.feeForGroup) : import puis annulation retire '
        'les DEUX mouvements ensemble, solde espèces revenu à l\'identique',
        () async {
      // Pré-import HORS-LOT : ADA 100 @ 1, BNB 10 @ 20.
      await seedPosition('ADA');
      await seedPosition('BNB');
      await ledger.recordTransaction(
        plain('pre-ada2', TransactionKind.buy,
            symbol: 'ADA', quantity: '100', unitPrice: '1', amount: '-100',
            date: DateTime(2024, 1, 1)),
      );
      await ledger.recordTransaction(
        plain('pre-bnb', TransactionKind.buy,
            symbol: 'BNB', quantity: '10', unitPrice: '20', amount: '-200',
            date: DateTime(2024, 1, 1)),
      );

      final journalBefore = await txStorage.getByAccount(accountId);
      final cashBefore = (await accounts.getAccountDerivedCash(accountId)).cash;
      final bnbBefore = await accounts.getPosition(accountId, 'BNB');
      expect(cashBefore, '-300');

      // --- Import du LOT : trade primaire ADA→SOL + frais réglé en BNB (conception
      // interne « feeInKind ») : `sell` BNB valorisé (cash ENTRANT +2) et `charge`
      // espèces (cash SORTANT -2), liés par `meta.feeForGroup` == clé du trade
      // primaire — cash net ZÉRO, seule la position BNB porte la consommation.
      const batchId = 'imp-fee';
      const feeGroupKey = 'ref:c1:R2#sell:ADA';
      final res = await ledger.importMovements(
        accountId: accountId,
        movements: [
          plain('f-sell-ada', TransactionKind.sell,
              symbol: 'ADA', quantity: '30', unitPrice: '1.5', amount: '45',
              date: DateTime(2024, 3, 1),
              meta: const {'importKey': feeGroupKey}),
          plain('f-buy-sol', TransactionKind.buy,
              symbol: 'SOL', quantity: '2', unitPrice: '22.5', amount: '-45',
              date: DateTime(2024, 3, 1),
              meta: const {'importKey': 'ref:c1:R2#buy:SOL'}),
          plain('f-fee-sell-bnb', TransactionKind.sell,
              symbol: 'BNB', quantity: '0.1', unitPrice: '20', amount: '2',
              date: DateTime(2024, 3, 1),
              meta: const {
                'feeForGroup': feeGroupKey,
                'importKey': '$feeGroupKey#sell:BNB',
              }),
          plain('f-fee-charge', TransactionKind.charge,
              amount: '-2',
              date: DateTime(2024, 3, 1),
              meta: const {
                'feeForGroup': feeGroupKey,
                'importKey': '$feeGroupKey#charge',
              }),
        ],
        newAssets: [cryptoAsset('SOL')],
        importBatchId: batchId,
      );
      expect(res.movementsWritten, 4);

      // Après import : ADA 70, SOL 2, BNB 9.9 ; cash INCHANGÉ (trade N4 net 0
      // + paire de frais net 0 par construction).
      expect((await accounts.getPosition(accountId, 'ADA'))!.quantity, '70');
      expect((await accounts.getPosition(accountId, 'SOL'))!.quantity, '2');
      expect((await accounts.getPosition(accountId, 'BNB'))!.quantity, '9.9');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);

      // --- Annulation ---
      final removed = await ledger.removeImportBatch(accountId, batchId);
      expect(removed, 4);

      final journalAfter = await txStorage.getByAccount(accountId);
      expect(
        journalAfter.map((t) => t.id).toSet(),
        journalBefore.map((t) => t.id).toSet(),
      );
      // Le `charge` de frais ne reste PAS orphelin : les deux membres de la
      // paire sont partis ensemble.
      expect(journalAfter.any((t) => t.id == 'f-fee-sell-bnb'), isFalse);
      expect(journalAfter.any((t) => t.id == 'f-fee-charge'), isFalse);

      final bnbAfter = await accounts.getPosition(accountId, 'BNB');
      expect(bnbAfter!.quantity, bnbBefore!.quantity);
      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);
    });

    test(
        '3. agrégat mensuel de récompenses (clé agg:) : import puis '
        'annulation → l\'agrégat est retiré, position revenue à l\'identique',
        () async {
      expect(await txStorage.getByAccount(accountId), isEmpty);

      const batchId = 'imp-agg';
      const importKey = 'agg:c1:kraken:ADA:2024-03';
      final res = await ledger.importMovements(
        accountId: accountId,
        movements: [
          plain('agg-mar', TransactionKind.adjustment,
              symbol: 'ADA', quantity: '12.5',
              date: DateTime(2024, 3, 1),
              meta: const {
                'corporateAction': 'stakingReward',
                'aggregation': 'monthly',
                'replaceable': true,
                'aggregatedMonth': '2024-03',
                'aggregatedRows': 27,
                'aggregatedFrom': '2024-03-01',
                'aggregatedTo': '2024-03-30',
                'ledgerCode': 'ADA',
                'seq': 1,
                'importKey': importKey,
              }),
        ],
        newAssets: [cryptoAsset('ADA')],
        importBatchId: batchId,
      );
      expect(res.movementsWritten, 1);
      expect((await accounts.getPosition(accountId, 'ADA'))!.quantity, '12.5');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '0');

      final removed = await ledger.removeImportBatch(accountId, batchId);
      expect(removed, 1);

      expect(await txStorage.getByAccount(accountId), isEmpty);
      final adaAfter = await accounts.getPosition(accountId, 'ADA');
      expect(adaAfter, isNotNull, reason: 'ligne position conservée (choix v1)');
      expect(adaAfter!.quantity, '0');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '0');
    });

    test(
        '4. REMPLACEMENT (le point dur, conception interne) : import n°2 '
        'remplace l\'agrégat n°1 (même mois allongé) ; annuler l\'import n°2 '
        'ne restaure PAS la version n°1 — limite ASSUMÉE, figée ici',
        () async {
      const importKey = 'agg:c1:kraken:ADA:2024-09';

      // --- Import n°1 : Septembre, 12 lignes, +10 ADA ---
      const batch1 = 'imp-agg-sep-v1';
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          plain('agg-sep-v1', TransactionKind.adjustment,
              symbol: 'ADA', quantity: '10',
              date: DateTime(2024, 9, 1),
              meta: const {
                'corporateAction': 'stakingReward',
                'aggregation': 'monthly',
                'replaceable': true,
                'aggregatedMonth': '2024-09',
                'aggregatedRows': 12,
                'importKey': importKey,
              }),
        ],
        newAssets: [cryptoAsset('ADA')],
        importBatchId: batch1,
      );
      expect((await accounts.getPosition(accountId, 'ADA'))!.quantity, '10');

      // --- Import n°2 : le mois s'est allongé (30 lignes, +25 ADA) — MÊME clé
      // `importKey`, REMPLACE la version n°1 (conception interne, `replaceImportKeys`)
      // : la version n°1 est physiquement DÉTRUITE avant écriture, dans la même
      // transaction que l'écriture n°2.
      const batch2 = 'imp-agg-sep-v2';
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          plain('agg-sep-v2', TransactionKind.adjustment,
              symbol: 'ADA', quantity: '25',
              date: DateTime(2024, 9, 1),
              meta: const {
                'corporateAction': 'stakingReward',
                'aggregation': 'monthly',
                'replaceable': true,
                'aggregatedMonth': '2024-09',
                'aggregatedRows': 30,
                'importKey': importKey,
              }),
        ],
        newAssets: const [],
        importBatchId: batch2,
        replaceImportKeys: {importKey},
      );
      // Le remplacement a eu lieu : une seule ligne en base, la n°2.
      final afterV2 = await txStorage.getBySymbol(accountId, 'ADA');
      expect(afterV2.map((t) => t.id).toList(), ['agg-sep-v2']);
      expect((await accounts.getPosition(accountId, 'ADA'))!.quantity, '25');

      // --- Annulation de l'import n°2 : retire la ligne n°2 (stampée
      // batch2) — mais NE RESTAURE PAS la ligne n°1 (détruite au
      // remplacement, aucun instantané pré-remplacement n'est conservé,
      // cf. doc « LIMITE V1 » de `removeImportBatch`). LIMITE ASSUMÉE DU
      // DESIGN (§5.1.8b « Limite assumée » / §5.5.5, message d'avertissement
      // testé plus bas), FIGÉE ici volontairement : ce test ÉCHOUERAIT si un
      // futur changement restaurait silencieusement la version n°1 sans
      // qu'on l'ait décidé explicitement.
      final removed = await ledger.removeImportBatch(accountId, batch2);
      expect(removed, 1);

      expect(
        await txStorage.getByAccount(accountId),
        isEmpty,
        reason: 'la version n°1 n\'est PAS restaurée — limite assumée §5.1.8b',
      );
      final adaAfter = await accounts.getPosition(accountId, 'ADA');
      expect(
        adaAfter!.quantity,
        '0',
        reason: 'ni 10 (v1) ni 25 (v2) : l\'agrégat a disparu, comportement '
            'voulu par le design, pas un bug',
      );

      // Corollaire : le lot n°1 n'a plus rien à annuler (déjà « absorbé »
      // par le remplacement du lot n°2) — no-op sûr, pas d'erreur.
      expect(await ledger.removeImportBatch(accountId, batch1), 0);
    });

    test(
        '5. import crypto complet multi-formes (échange + frais + agrégat + '
        'positions créées) : annulation → compte au bit près', () async {
      // Pré-import HORS-LOT : ADA 200 @ 1, BNB 10 @ 20.
      await seedPosition('ADA');
      await seedPosition('BNB');
      await ledger.recordTransaction(
        plain('pre-ada5', TransactionKind.buy,
            symbol: 'ADA', quantity: '200', unitPrice: '1', amount: '-200',
            date: DateTime(2024, 1, 1)),
      );
      await ledger.recordTransaction(
        plain('pre-bnb5', TransactionKind.buy,
            symbol: 'BNB', quantity: '10', unitPrice: '20', amount: '-200',
            date: DateTime(2024, 1, 1)),
      );

      final journalBefore = await txStorage.getByAccount(accountId);
      final cashBefore = (await accounts.getAccountDerivedCash(accountId)).cash;
      final adaBefore = await accounts.getPosition(accountId, 'ADA');
      final bnbBefore = await accounts.getPosition(accountId, 'BNB');
      expect(cashBefore, '-400');

      const batchId = 'imp-full';
      const feeGroupKey = 'ref:c1:R5#sell:ADA';
      final res = await ledger.importMovements(
        accountId: accountId,
        movements: [
          // Échange ADA→BTC (N4).
          plain('m5-sell-ada', TransactionKind.sell,
              symbol: 'ADA', quantity: '20', unitPrice: '2', amount: '40',
              date: DateTime(2024, 4, 1),
              meta: const {'importKey': feeGroupKey}),
          plain('m5-buy-btc', TransactionKind.buy,
              symbol: 'BTC', quantity: '0.001', unitPrice: '40000', amount: '-40',
              date: DateTime(2024, 4, 1),
              meta: const {'importKey': 'ref:c1:R5#buy:BTC'}),
          // Frais BNB tiers de CET échange.
          plain('m5-fee-sell-bnb', TransactionKind.sell,
              symbol: 'BNB', quantity: '0.05', unitPrice: '20', amount: '1',
              date: DateTime(2024, 4, 1),
              meta: const {
                'feeForGroup': feeGroupKey,
                'importKey': '$feeGroupKey#sell:BNB',
              }),
          plain('m5-fee-charge', TransactionKind.charge,
              amount: '-1',
              date: DateTime(2024, 4, 1),
              meta: const {
                'feeForGroup': feeGroupKey,
                'importKey': '$feeGroupKey#charge',
              }),
          // Agrégat mensuel de récompenses SOL (position CRÉÉE par le lot).
          plain('m5-agg-sol', TransactionKind.adjustment,
              symbol: 'SOL', quantity: '3.4',
              date: DateTime(2024, 4, 1),
              meta: const {
                'corporateAction': 'stakingReward',
                'aggregation': 'monthly',
                'replaceable': true,
                'aggregatedMonth': '2024-04',
                'aggregatedRows': 9,
                'importKey': 'agg:c1:kraken:SOL:2024-04',
              }),
        ],
        newAssets: [cryptoAsset('BTC'), cryptoAsset('SOL')],
        importBatchId: batchId,
      );
      expect(res.movementsWritten, 5);

      // État intermédiaire (ancrage du test, pas l'objet de la preuve) :
      // ADA 180, BNB 9.95, BTC 0.001, SOL 3.4 ; cash inchangé (N4 + frais
      // nets 0 + agrégat sans cash).
      expect((await accounts.getPosition(accountId, 'ADA'))!.quantity, '180');
      expect((await accounts.getPosition(accountId, 'BNB'))!.quantity, '9.95');
      expect((await accounts.getPosition(accountId, 'BTC'))!.quantity, '0.001');
      expect((await accounts.getPosition(accountId, 'SOL'))!.quantity, '3.4');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);

      // --- Annulation du lot complet ---
      final removed = await ledger.removeImportBatch(accountId, batchId);
      expect(removed, 5);

      // Journal : exactement les deux mouvements HORS-LOT, rien d'autre.
      final journalAfter = await txStorage.getByAccount(accountId);
      expect(
        journalAfter.map((t) => t.id).toSet(),
        journalBefore.map((t) => t.id).toSet(),
      );

      // ADA/BNB (préexistantes) reviennent AU BIT PRÈS.
      final adaAfter = await accounts.getPosition(accountId, 'ADA');
      expect(adaAfter!.quantity, adaBefore!.quantity);
      expect(adaAfter.averageBuyPrice, adaBefore.averageBuyPrice);
      final bnbAfter = await accounts.getPosition(accountId, 'BNB');
      expect(bnbAfter!.quantity, bnbBefore!.quantity);
      expect(bnbAfter.averageBuyPrice, bnbBefore.averageBuyPrice);

      // BTC/SOL (créées par le lot) : lignes conservées, reprojetées à 0.
      expect((await accounts.getPosition(accountId, 'BTC'))!.quantity, '0');
      expect((await accounts.getPosition(accountId, 'SOL'))!.quantity, '0');

      // Solde espèces identique au bit près.
      expect((await accounts.getAccountDerivedCash(accountId)).cash, cashBefore);
    });

    test(
        '6. idempotence : annuler deux fois un import crypto ne casse pas '
        '(no-op la seconde)', () async {
      // Pré-import HORS-LOT : ADA 20 (pour que la vente du lot soit
      // réaliste — un `sell` sur une position vide donnerait un solde
      // négatif, ce qui ne changerait rien à la preuve d'idempotence mais
      // brouillerait la lecture).
      await seedPosition('ADA');
      await ledger.recordTransaction(
        plain('pre-ada6', TransactionKind.buy,
            symbol: 'ADA', quantity: '20', unitPrice: '1', amount: '-20',
            date: DateTime(2024, 1, 1)),
      );

      const batchId = 'imp-idem';
      await ledger.importMovements(
        accountId: accountId,
        movements: [
          plain('i-sell-ada', TransactionKind.sell,
              symbol: 'ADA', quantity: '5', unitPrice: '2', amount: '10',
              date: DateTime(2024, 5, 1)),
          plain('i-buy-btc', TransactionKind.buy,
              symbol: 'BTC', quantity: '0.0002', unitPrice: '50000', amount: '-10',
              date: DateTime(2024, 5, 1)),
        ],
        newAssets: [cryptoAsset('BTC')],
        importBatchId: batchId,
      );
      expect((await accounts.getPosition(accountId, 'ADA'))!.quantity, '15');

      final firstRemoved = await ledger.removeImportBatch(accountId, batchId);
      expect(firstRemoved, 2);
      final journalAfterFirst = await txStorage.getByAccount(accountId);
      final cashAfterFirst = (await accounts.getAccountDerivedCash(accountId)).cash;
      final adaAfterFirst = await accounts.getPosition(accountId, 'ADA');
      final btcAfterFirst = await accounts.getPosition(accountId, 'BTC');
      // Le lot est parti, seul le mouvement HORS-LOT (ADA pré-import) reste.
      expect(journalAfterFirst.map((t) => t.id).toList(), ['pre-ada6']);

      // Seconde annulation du MÊME lot : no-op sûr, rien ne bouge.
      final secondRemoved = await ledger.removeImportBatch(accountId, batchId);
      expect(secondRemoved, 0);

      expect(
        (await txStorage.getByAccount(accountId)).map((t) => t.id).toList(),
        journalAfterFirst.map((t) => t.id).toList(),
      );
      expect(
        (await accounts.getAccountDerivedCash(accountId)).cash,
        cashAfterFirst,
      );
      expect(
        (await accounts.getPosition(accountId, 'ADA'))!.quantity,
        adaAfterFirst!.quantity,
      );
      expect(
        (await accounts.getPosition(accountId, 'BTC'))!.quantity,
        btcAfterFirst!.quantity,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Groupe MESSAGE (conception interne) : l'avertissement de remplacement d'agrégat
  // ANNONCÉ par le design existe déjà en l10n — contrairement à ce que le point 4 de
  // la mission envisageait comme manque possible. `importSummaryRewardsUpdated`
  // (app_fr.arb) est câblé dans `statement_import_page.dart` (`_buildDoneStep`,
  // conditionné à `summary.replacedRewardMonths.isNotEmpty`, autour de la ligne
  // 4060) : ce test fige uniquement le TEXTE produit par la clé l10n — la condition
  // de déclenchement elle-même vit dans un état privé de la page (widget, hors
  // périmètre unitaire de ce fichier), non repompée ici (cf. rapport de livraison
  // pour le détail de cette limite).
  // ---------------------------------------------------------------------------

  group('Message d\'avertissement de remplacement (conception interne)', () {
    testWidgets(
        'importSummaryRewardsUpdated produit le texte exact annoncé par le '
        'design', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('fr'),
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return const SizedBox.shrink();
          },
        ),
      ));

      expect(
        l10n.importSummaryRewardsUpdated('septembre'),
        'Les récompenses de septembre ont été mises à jour ; annuler cet '
        'import ne restaurera pas leur version précédente.',
      );
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

// test/account_controller_import_test.dart
//
// Couche CONTRÔLEUR de l'import de relevés (lot B4) : relie
// StatementImportService (parsing/normalisation, PUR) à
// LedgerService.importMovements (écriture atomique). Base in-memory isolée
// par test, aucun appel réseau (fake MarketDataService inutile ici : l'import
// ne cote rien au MVP manuel/direct).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/import_preview.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import 'helpers/test_database.dart';

/// Fake SANS RÉSEAU : l'import ne cote rien au MVP manuel/direct, mais
/// `_initService()` (appelé après confirmation, comme les autres mutations)
/// recharge quand même les cours de toutes les positions du compte —
/// [AccountController] utiliserait sinon le vrai [MarketDataService] (appel
/// réseau interdit en test).
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

// ---------------------------------------------------------------------------
// Profil de test : Date;Operation;ISIN;Symbole;Libelle;Quantite;Cours;Frais;
//                   Montant;Ref
// ---------------------------------------------------------------------------

const _colDate = 0;
const _colOp = 1;
const _colIsin = 2;
const _colSymbol = 3;
const _colLabel = 4;
const _colQty = 5;
const _colPrice = 6;
const _colFee = 7;
const _colAmount = 8;
const _colRef = 9;

const _header =
    'Date;Operation;ISIN;Symbole;Libelle;Quantite;Cours;Frais;Montant;Ref';

BrokerProfile _profile() => BrokerProfile.genericManual(
      delimiter: ';',
      encoding: utf8,
      hasHeaderRow: true,
      decimalSeparator: DecimalSeparator.dot,
      columns: const ColumnMapping(byIndex: {
        MovementField.date: _colDate,
        MovementField.kindLabel: _colOp,
        MovementField.isin: _colIsin,
        MovementField.symbol: _colSymbol,
        MovementField.label: _colLabel,
        MovementField.quantity: _colQty,
        MovementField.unitPrice: _colPrice,
        MovementField.fee: _colFee,
        MovementField.amount: _colAmount,
        MovementField.operationReference: _colRef,
      }),
      kindLexicon: const {
        'Achat': TransactionKind.buy,
      },
    );

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

const _walletId = 'wallet-1';
const _accountId = 'account-1';

/// Relevé de test couvrant les 5 chemins de résolution/dédup/rejet exercés :
///   - REF-OLD  : déjà importé (doublon)
///   - REF-NEW1 : titre existant retrouvé par ISIN (le symbole CSV diffère
///     volontairement du symbole stocké — vérifie la priorité ISIN)
///   - REF-NEW2 : symbole neuf mappé directement par le CSV (actif à créer)
///   - REF-NEW3 : ISIN inconnu ET pas de symbole mappé → non résolu
///   - REF-NEW4 : symbole existant mais LEGACY (derived_at NULL, sans journal)
///   - (aucune Ref) : nature d'opération non reconnue → rejet
String _statementCsv() => '$_header\r\n'
    '10/01/2024;Achat;ISIN_AAPL;AAPLX;Apple;5;150;0;-750;REF-OLD\r\n'
    '11/01/2024;Achat;ISIN_AAPL;AAPLX;Apple;3;160;0;-480;REF-NEW1\r\n'
    '12/01/2024;Achat;;NEWCO;New Co;2;10;0;-20;REF-NEW2\r\n'
    '13/01/2024;Achat;FR000UNKNOWN;;Unknown Corp;1;5;0;-5;REF-NEW3\r\n'
    '14/01/2024;Achat;;LEG;Legacy Corp;10;60;0;-600;REF-NEW4\r\n'
    '15/01/2024;Inconnu;;;Mystere;;;;;\r\n';

Asset _assetWithIsin(String symbol, String isin) => Asset(
      symbol: symbol,
      name: symbol,
      currency: 'EUR',
      isin: isin,
    );

/// Peuple wallet + compte + positions de départ :
///   - AAPL : projetée (derived_at non NULL), un mouvement déjà importé
///     (meta.importKey = REF-OLD) pour éprouver la dédup.
///   - LEG  : LEGACY déclarée (derived_at NULL), AUCUN journal.
Future<void> _seed(AppDatabase db) async {
  final storage = AccountStorage(database: db);
  final ledger = LedgerService(database: db);

  await storage.saveWallet(Wallet(id: _walletId, name: 'Test Wallet'));
  await storage.saveAccount(Account(
    id: _accountId,
    walletId: _walletId,
    name: 'Compte test',
    kind: AccountKind.cto,
    currency: 'EUR',
  ));

  // AAPL : position projetée avec un premier achat déjà journalisé, marqué
  // comme provenant d'un import précédent (clé de dédup).
  await storage.savePosition(
    _accountId,
    Position(
      accountId: _accountId,
      asset: _assetWithIsin('AAPL', 'ISIN_AAPL'),
      quantity: '0',
    ),
  );
  await ledger.recordTransaction(AssetTransaction(
    id: 'tx-old',
    accountId: _accountId,
    symbol: 'AAPL',
    kind: TransactionKind.buy,
    quantity: '5',
    unitPrice: '150',
    amount: '-750',
    currency: 'EUR',
    date: DateTime(2024, 1, 10),
    meta: {'importKey': 'ref:$_accountId:REF-OLD'},
  ));

  // LEG : déclarée à la main (quantité/PRU saisis), jamais projetée, AUCUN
  // mouvement en journal — le cas central du garde-fou §8.1.
  await storage.savePosition(
    _accountId,
    Position(
      accountId: _accountId,
      asset: Asset(symbol: 'LEG', name: 'Legacy Corp', currency: 'EUR'),
      quantity: '100',
      averageBuyPrice: 50.0,
    ),
  );
}

AccountController _makeCtrl(AppDatabase db) => AccountController(
      initialAccountId: _accountId,
      storage: AccountStorage(database: db),
      ledgerService: LedgerService(database: db),
      transactionStorage: TransactionStorage(database: db),
      marketService: _NoNetworkMarketDataService(),
    );

void main() {
  group('previewStatementImport', () {
    test(
        'classe correctement créés / doublons / rejets / actifs neufs / delta',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await _seed(db);

      final ctrl = _makeCtrl(db);
      await ctrl.initAccounts();

      final preview = await ctrl.previewStatementImport(
        _bytes(_statementCsv()),
        _profile(),
        accountId: _accountId,
      );

      // Rejet : nature d'opération non reconnue.
      expect(preview.rejects, hasLength(1));
      expect(preview.rejects.single.rejectReason, equals('unknownKind'));

      // Doublon : REF-OLD déjà présent dans le journal du compte.
      expect(preview.duplicates, hasLength(1));

      // 4 mouvements à créer : AAPL (ISIN), NEWCO (symbole direct),
      // FR000UNKNOWN (non résolu), LEG (symbole existant legacy).
      expect(preview.toCreate, hasLength(4));

      // Résolution par ISIN : le symbole CSV ('AAPLX') est ignoré au profit
      // du symbole existant ('AAPL') retrouvé via l'ISIN.
      final aaplMovement = preview.toCreate
          .firstWhere((m) => m.transaction?.symbol == 'AAPL');
      expect(aaplMovement.transaction!.quantity, equals('3'));

      // Actifs neufs : NEWCO (proposedSymbol déjà résolu par mapping direct)
      // + FR000UNKNOWN (non résolu, aucun symbole).
      expect(preview.newAssets, hasLength(2));
      final newco =
          preview.newAssets.firstWhere((a) => a.proposedSymbol == 'NEWCO');
      expect(newco.isin, isNull);
      expect(newco.label, equals('New Co'));
      final unresolved =
          preview.newAssets.firstWhere((a) => a.proposedSymbol == null);
      expect(unresolved.isin, equals('FR000UNKNOWN'));
      expect(unresolved.label, equals('Unknown Corp'));

      // Garde-fou legacy (§8.1) : LEG est signalé, jamais silencieusement
      // reprojeté.
      expect(preview.legacySymbols, equals(['LEG']));

      // Delta projeté : AAPL (3 titres supplémentaires @160, en plus des 5
      // déjà projetés @150) + NEWCO (0 → 2) + cash (delta = somme des
      // montants entrants non dupliqués).
      final aaplDelta =
          preview.projectedDeltas.firstWhere((d) => d.symbol == 'AAPL');
      expect(aaplDelta.quantityBefore, equals('5'));
      expect(aaplDelta.quantityAfter, equals('8'));

      final newcoDelta =
          preview.projectedDeltas.firstWhere((d) => d.symbol == 'NEWCO');
      expect(newcoDelta.quantityBefore, equals('0'));
      expect(newcoDelta.quantityAfter, equals('2'));

      // Pas de delta pour un mouvement non résolu (aucun symbole connu).
      expect(
        preview.projectedDeltas.where((d) => d.symbol == 'FR000UNKNOWN'),
        isEmpty,
      );

      final cashDelta =
          preview.projectedDeltas.firstWhere((d) => d.symbol == null);
      // -480 (AAPL) -20 (NEWCO) -5 (inconnu) -600 (LEG) = -1105.
      expect(cashDelta.cashAfter! - cashDelta.cashBefore!, closeTo(-1105.0, 1e-9));
    });

    test(
        'opération cash portant un ISIN (TTF/frais) n\'est PAS prise pour un actif',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await _seed(db);

      final ctrl = _makeCtrl(db);
      await ctrl.initAccounts();

      // Profil avec un lexique reconnaissant un frais (charge). La ligne TTF
      // référence l'ISIN du titre taxé ET porte un libellé — elle NE doit ni
      // apparaître dans les actifs neufs ni déclencher de résolution de ticker.
      final profile = BrokerProfile.genericManual(
        delimiter: ';',
        encoding: utf8,
        hasHeaderRow: true,
        decimalSeparator: DecimalSeparator.dot,
        columns: const ColumnMapping(byIndex: {
          MovementField.date: _colDate,
          MovementField.kindLabel: _colOp,
          MovementField.isin: _colIsin,
          MovementField.symbol: _colSymbol,
          MovementField.label: _colLabel,
          MovementField.quantity: _colQty,
          MovementField.unitPrice: _colPrice,
          MovementField.fee: _colFee,
          MovementField.amount: _colAmount,
          MovementField.operationReference: _colRef,
        }),
        kindLexicon: const {
          'Achat': TransactionKind.buy,
          'TTF': TransactionKind.charge,
        },
      );

      final csv = '$_header\r\n'
          '10/02/2024;TTF;ISIN_TAX;;TTF;;;;-3.20;REF-TTF\r\n';

      final preview = await ctrl.previewStatementImport(
        _bytes(csv),
        profile,
        accountId: _accountId,
      );

      // Retenu comme mouvement d'ESPÈCES, mais aucun actif neuf.
      expect(preview.newAssets, isEmpty);
      expect(preview.toCreate, hasLength(1));
      expect(preview.toCreate.single.transaction!.kind,
          equals(TransactionKind.charge));
      expect(preview.toCreate.single.transaction!.symbol, isNull);
    });

    test(
        'identité NEUVE soldée (net 0, ISIN) : actif non coté auto, sans prompt '
        'ni delta « 0 → 0 » ; une neuve net>0 reste à résoudre', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await _seed(db);

      final ctrl = _makeCtrl(db);
      await ctrl.initAccounts();

      // Profil reconnaissant achat ET vente (pour projeter un net nul).
      final profile = BrokerProfile.genericManual(
        delimiter: ';',
        encoding: utf8,
        hasHeaderRow: true,
        decimalSeparator: DecimalSeparator.dot,
        columns: const ColumnMapping(byIndex: {
          MovementField.date: _colDate,
          MovementField.kindLabel: _colOp,
          MovementField.isin: _colIsin,
          MovementField.symbol: _colSymbol,
          MovementField.label: _colLabel,
          MovementField.quantity: _colQty,
          MovementField.unitPrice: _colPrice,
          MovementField.fee: _colFee,
          MovementField.amount: _colAmount,
          MovementField.operationReference: _colRef,
        }),
        kindLexicon: const {
          'Achat': TransactionKind.buy,
          'Vente': TransactionKind.sell,
        },
      );

      // SOLD : titre NEUF (aucune position, symbole non mappé) porteur d'un
      // ISIN, acheté 4 puis revendu 4 → net 0 (soldé DANS le relevé).
      // HELD : titre NEUF net > 0 (ISIN, pas de symbole) — non-régression :
      // doit rester « à associer » (proposedSymbol == null).
      const isinSold = 'FR000SOLDEE';
      const isinHeld = 'FR000HELD';
      final csv = '$_header\r\n'
          '20/03/2024;Achat;$isinSold;;Soldee Corp;4;25;0;-100;REF-S1\r\n'
          '21/03/2024;Vente;$isinSold;;Soldee Corp;4;30;0;120;REF-S2\r\n'
          '22/03/2024;Achat;$isinHeld;;Held Corp;2;10;0;-20;REF-H1\r\n';

      final preview = await ctrl.previewStatementImport(
        _bytes(csv),
        profile,
        accountId: _accountId,
      );

      // SOLD : proposé en actif non coté, symbole = ISIN, AUCUN prompt.
      final soldAsset =
          preview.newAssets.firstWhere((a) => a.isin == isinSold);
      expect(soldAsset.proposedSymbol, equals(isinSold));
      expect(soldAsset.quotable, isFalse);
      // Ligne soldée : marquée closedLine → exclue de la liste « Nouveaux
      // actifs » de l'aperçu (seules les positions OUVERTES y figurent).
      expect(soldAsset.closedLine, isTrue);

      // HELD : encore « à associer » (proposedSymbol null) — non-régression.
      final heldAsset =
          preview.newAssets.firstWhere((a) => a.isin == isinHeld);
      expect(heldAsset.proposedSymbol, isNull);
      expect(heldAsset.quotable, isTrue);

      // Aucun actif SOLD laissé sans symbole (donc plus aucun prompt pour lui).
      expect(
        preview.newAssets.where(
            (a) => a.isin == isinSold && a.proposedSymbol == null),
        isEmpty,
      );

      // Les deux mouvements SOLD sont journalisés avec symbol = ISIN.
      final soldMovements =
          preview.toCreate.where((m) => m.transaction!.symbol == isinSold);
      expect(soldMovements, hasLength(2));

      // AUCUN delta titre pour l'identité soldée (pas de ligne « 0 → 0 »).
      expect(
        preview.projectedDeltas.where((d) => d.symbol == isinSold),
        isEmpty,
      );
      // Le titre encore détenu, lui, garde son delta (non-régression du delta).
      expect(
        preview.projectedDeltas.where((d) => d.symbol == isinHeld),
        isEmpty,
        reason: 'HELD reste non résolu (symbole null) → pas de delta titre',
      );

      // ---- Confirmation : la position soldée existe, se projette à 0, non
      // cotée ; le journal (cash + plus-value réalisée) est conservé. ----
      final erreur =
          await ctrl.confirmStatementImport(preview, accountId: _accountId);
      expect(erreur, isNull);

      final accounts = AccountStorage(database: db);
      final txStorage = TransactionStorage(database: db);

      final soldPos = await accounts.getPosition(_accountId, isinSold);
      expect(soldPos, isNotNull);
      expect(soldPos!.quantity, equals('0'));
      expect(soldPos.asset.quotable, isFalse);
      expect(soldPos.asset.isin, equals(isinSold));

      // Les mouvements titres sont bien journalisés (2 pour SOLD).
      expect(await txStorage.getBySymbol(_accountId, isinSold), hasLength(2));
    });

    test(
        'droit de souscription (DS + SOUSC + RTFIS) : soldé, non coté, sans '
        'prompt ni delta ; cash réel préservé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await _seed(db);

      final ctrl = _makeCtrl(db);
      await ctrl.initAccounts();

      // Profil type Bourse Direct (CSV pour ce test) : DS = à revoir
      // (manualReview) → marqueur « ISIN = droit », SOUSC = souscription (buy),
      // RTFIS = sortie de titres, ODOST = cash pur (paiement de la souscription).
      final profile = BrokerProfile(
        id: 'bd-test',
        label: 'BD test',
        delimiter: ';',
        encoding: utf8,
        hasHeaderRow: true,
        dateFormat: const DateFormatSpec(),
        decimalSeparator: DecimalSeparator.dot,
        columns: const ColumnMapping(byIndex: {
          MovementField.date: _colDate,
          MovementField.kindLabel: _colOp,
          MovementField.isin: _colIsin,
          MovementField.symbol: _colSymbol,
          MovementField.label: _colLabel,
          MovementField.quantity: _colQty,
          MovementField.unitPrice: _colPrice,
          MovementField.fee: _colFee,
          MovementField.amount: _colAmount,
          MovementField.operationReference: _colRef,
          MovementField.cashDirection: 10,
        }),
        kindLexicon: const {
          'SOUSC': TransactionKind.buy,
          'Depot': TransactionKind.deposit,
        },
        corporateActions: const {
          'DS': CorporateActionKind.manualReview,
          'RTFIS': CorporateActionKind.transferOut,
          'ODOST': CorporateActionKind.cashRegularization,
        },
      );

      const rightsIsin = 'FR0014000IK6'; // ISIN factice « DRONE VOLT DS 20 »
      // Colonnes : Date;Op;ISIN;Symbole;Libelle;Qte;Cours;Frais;Montant;Ref;SensEsp
      final csv = 'Date;Operation;ISIN;Symbole;Libelle;Quantite;Cours;Frais;'
          'Montant;Ref;SensEsp\r\n'
          // Cash RÉEL : versement d'espèces (+5000).
          '01/06/2020;Depot;;;Versement;;;;5000;REF-DEP;\r\n'
          // Cash RÉEL : paiement de la souscription, ligne DISTINCTE (−100).
          '02/06/2020;ODOST;;;Espèces sur OST;;;;100;REF-ODOST;D\r\n'
          // Les 3 jambes de QUANTITÉ du droit, même ISIN.
          '03/06/2020;DS;$rightsIsin;;DRONE VOLT DS;3568;;;;REF-DS;\r\n'
          // Net=0 sur la jambe de quantité (le cash est sur ODOST) : SOUSC→buy
          // aurait contribué 0 au cash → le reclassement n'altère PAS le cash.
          '04/06/2020;SOUSC;$rightsIsin;;DRONE VOLT DS;3560;;;0;REF-SO;\r\n'
          '05/06/2020;RTFIS;$rightsIsin;;DRONE VOLT DS;8;;;;REF-RT;\r\n';

      final preview = await ctrl.previewStatementImport(
        _bytes(csv),
        profile,
        accountId: _accountId,
      );

      // DS : rejeté (à revoir), jamais journalisé.
      expect(preview.rejects.map((m) => m.rejectReason),
          contains('corporateActionReview'));

      // Le droit finit en actif NON COTÉ (symbole = ISIN), soldé → AUCUN prompt.
      final droit = preview.newAssets.firstWhere((a) => a.isin == rightsIsin);
      expect(droit.proposedSymbol, equals(rightsIsin));
      expect(droit.quotable, isFalse);
      // Aucun candidat « à associer » (proposedSymbol == null) pour le droit.
      expect(
        preview.newAssets
            .where((a) => a.isin == rightsIsin && a.proposedSymbol == null),
        isEmpty,
      );

      // AUCUN delta titre pour le droit (pas de ligne « 0 → 0 » bruyante).
      expect(
        preview.projectedDeltas.where((d) => d.symbol == rightsIsin),
        isEmpty,
      );

      // CASH réel préservé : delta = +5000 (dépôt) − 100 (ODOST) = +4900.
      // Les jambes SOUSC/RTFIS du droit (transferOut) ne règlent aucune espèce ;
      // avec Net=0, un SOUSC→buy aurait aussi contribué 0 → cash INCHANGÉ par le
      // reclassement.
      final cashDelta =
          preview.projectedDeltas.firstWhere((d) => d.symbol == null);
      expect(cashDelta.cashAfter! - cashDelta.cashBefore!,
          closeTo(4900.0, 1e-9));

      // ---- Confirmation : le droit existe, projeté à 0, non coté. ----
      final erreur =
          await ctrl.confirmStatementImport(preview, accountId: _accountId);
      expect(erreur, isNull);

      final accounts = AccountStorage(database: db);
      final droitPos = await accounts.getPosition(_accountId, rightsIsin);
      expect(droitPos, isNotNull);
      expect(droitPos!.quantity, equals('0'));
      expect(droitPos.asset.quotable, isFalse);
    });

    test('accountId inconnu du contrôleur → preview vide (pas de crash)',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await _seed(db);

      final ctrl = _makeCtrl(db);
      // Pas d'initAccounts() : aucun compte connu du contrôleur.
      final preview = await ctrl.previewStatementImport(
        _bytes(_statementCsv()),
        _profile(),
        accountId: 'inexistant',
      );

      expect(preview.toCreate, isEmpty);
      expect(preview.duplicates, isEmpty);
      expect(preview.rejects, isEmpty);
      expect(preview.newAssets, isEmpty);
    });
  });

  group('confirmStatementImport', () {
    test('écrit via importMovements ; un ré-import identique ne crée rien',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await _seed(db);

      final ctrl = _makeCtrl(db);
      await ctrl.initAccounts();

      final preview = await ctrl.previewStatementImport(
        _bytes(_statementCsv()),
        _profile(),
        accountId: _accountId,
      );

      final erreur =
          await ctrl.confirmStatementImport(preview, accountId: _accountId);
      expect(erreur, isNull);

      final accounts = AccountStorage(database: db);
      final txStorage = TransactionStorage(database: db);

      // AAPL : reprojeté (5 + 3 = 8, PRU pondéré).
      final aapl = await accounts.getPosition(_accountId, 'AAPL');
      expect(aapl!.quantity, equals('8'));

      // NEWCO : créé, projeté, ISIN persisté.
      final newco = await accounts.getPosition(_accountId, 'NEWCO');
      expect(newco, isNotNull);
      expect(newco!.quantity, equals('2'));

      // LEG : déclaration INTACTE (garde anti-écrasement de importMovements),
      // mais le mouvement est bien journalisé (cash affecté).
      final leg = await accounts.getPosition(_accountId, 'LEG');
      expect(leg!.quantity, equals('100'));
      expect(leg.averageBuyPrice, closeTo(50.0, 1e-9));
      expect(await txStorage.getBySymbol(_accountId, 'LEG'), hasLength(1));

      // Mouvement non résolu (FR000UNKNOWN) : journalisé quand même (symbole
      // null), sans créer de position — pas de crash.
      final allTx = await txStorage.getByAccount(_accountId);
      expect(
        allTx.where((t) => t.meta?['importKey'] == 'ref:$_accountId:REF-NEW3'),
        hasLength(1),
      );

      // ---- Ré-import du MÊME relevé : plus rien à créer (idempotence) ----
      final ctrl2 = _makeCtrl(db);
      await ctrl2.initAccounts();
      final preview2 = await ctrl2.previewStatementImport(
        _bytes(_statementCsv()),
        _profile(),
        accountId: _accountId,
      );

      // Les 5 mouvements valides sont maintenant tous des doublons (les 4
      // précédemment créés + REF-OLD initial) ; seule la ligne rejetée reste.
      expect(preview2.toCreate, isEmpty);
      expect(preview2.duplicates, hasLength(5));
      expect(preview2.rejects, hasLength(1));

      final erreur2 = await ctrl2.confirmStatementImport(
        preview2,
        accountId: _accountId,
      );
      expect(erreur2, isNull);

      // Aucun mouvement supplémentaire écrit.
      final allTxAfter = await txStorage.getByAccount(_accountId);
      expect(allTxAfter, hasLength(allTx.length));
    });

    test(
        'repli ISIN : actif non coté créé avec symbol=ISIN, quotable=false ; '
        'réimport ne le duplique pas', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      await _seed(db);

      final ctrl = _makeCtrl(db);
      await ctrl.initAccounts();

      final preview = await ctrl.previewStatementImport(
        _bytes(_statementCsv()),
        _profile(),
        accountId: _accountId,
      );

      // Simule le choix UI « non coté » pour l'actif non résolu FR000UNKNOWN :
      // symbole == ISIN, quotable == false (cf. _applyResolvedSymbols).
      const isin = 'FR000UNKNOWN';
      final patched = ImportPreview(
        toCreate: preview.toCreate.map((m) {
          if (m.transaction?.symbol == null && m.isin == isin) {
            return ImportedMovement.candidate(
              sourceRow: m.sourceRow,
              sourceRowIndex: m.sourceRowIndex,
              transaction: m.transaction!.copyWith(symbol: isin),
              isin: m.isin,
              label: m.label,
              resolvedSymbol: isin,
              importKey: m.importKey!,
            );
          }
          return m;
        }).toList(),
        duplicates: preview.duplicates,
        rejects: preview.rejects,
        newAssets: preview.newAssets.map((a) {
          if (a.isin == isin && a.proposedSymbol == null) {
            return NewAssetCandidate(
              isin: a.isin,
              label: a.label,
              proposedSymbol: isin,
              quotable: false,
            );
          }
          return a;
        }).toList(),
        projectedDeltas: preview.projectedDeltas,
        legacySymbols: preview.legacySymbols,
      );

      final erreur =
          await ctrl.confirmStatementImport(patched, accountId: _accountId);
      expect(erreur, isNull);

      final accounts = AccountStorage(database: db);
      final txStorage = TransactionStorage(database: db);

      // Position créée avec l'ISIN comme clé, marquée NON COTÉE.
      final delisted = await accounts.getPosition(_accountId, isin);
      expect(delisted, isNotNull);
      expect(delisted!.asset.quotable, isFalse);
      expect(delisted.asset.isin, equals(isin));
      // Le mouvement est bien journalisé (compte dans la plus-value réalisée).
      expect(await txStorage.getBySymbol(_accountId, isin), hasLength(1));

      // ---- Réimport du même relevé : la résolution ISIN-first retrouve la
      // position déjà créée → aucun nouvel actif, mouvement dédupliqué. ----
      final ctrl2 = _makeCtrl(db);
      await ctrl2.initAccounts();
      final preview2 = await ctrl2.previewStatementImport(
        _bytes(_statementCsv()),
        _profile(),
        accountId: _accountId,
      );
      expect(
        preview2.newAssets.where((a) => a.isin == isin),
        isEmpty,
        reason: 'l\'actif non coté existant ne doit pas réapparaître comme neuf',
      );
      expect(
        preview2.toCreate.where((m) => m.isin == isin),
        isEmpty,
        reason: 'le mouvement de l\'actif non coté est un doublon',
      );

      // Une seule position ISIN, un seul mouvement : pas de duplication.
      final delistedTxAfter = await txStorage.getBySymbol(_accountId, isin);
      expect(delistedTxAfter, hasLength(1));
    });

    test('sans compte actif → noActiveAccount', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final ctrl = _makeCtrl(db);
      // Pas d'initAccounts() : _activeAccount reste null.
      final erreur = await ctrl.confirmStatementImport(
        const ImportPreview(),
        accountId: _accountId,
      );
      expect(erreur, equals('noActiveAccount'));
    });
  });
}

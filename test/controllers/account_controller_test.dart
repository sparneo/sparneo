// test/controllers/account_controller_test.dart
//
// Tests de caractérisation du contrôleur de la vue compte.
// Pas d'appel réseau : fakes en mémoire pour les services.
// La persistance est assurée par une base SQLite in-memory isolée par test.
//
// ExchangeRateService est un singleton factory non sous-classable :
// on injecte le taux directement via AccountController(initialUsdToEurRate:).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;
import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';

import '../helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Fake MarketDataService (sans réseau)
// ---------------------------------------------------------------------------

/// Fake de [MarketDataService] : retourne des données fixes sans réseau.
class _FakeMarketDataService extends MarketDataService {
  /// Cours par symbole (null → erreur simulée).
  final Map<String, AssetQuoteData?> quotes;

  /// Historique par symbole.
  final Map<String, AssetHistoricalData?> history;

  _FakeMarketDataService({
    this.quotes = const {},
    this.history = const {},
  });

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async =>
      quotes[asset.symbol];

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async =>
      quotes[symbol];

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(
    Asset asset, {
    int days = 30,
  }) async =>
      history[asset.symbol];

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol,
      {int days = 30}) async =>
      history[symbol];
}

/// Fake dont la réponse aux cotations ET à l'historique est retardée via un
/// [Completer] — permet de simuler une continuation post-dispose (correctif B1).
class _DelayedMarketDataService extends MarketDataService {
  final Completer<AssetQuoteData?> _quoteCompleter;

  _DelayedMarketDataService({required Completer<AssetQuoteData?> quoteCompleter})
      : _quoteCompleter = quoteCompleter;

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) => _quoteCompleter.future;

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) =>
      _quoteCompleter.future;

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(Asset asset,
          {int days = 30}) async =>
      null;

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol,
          {int days = 30}) async =>
      null;
}

/// Storage qui renvoie toujours une position VERROUILLÉE lors de la relecture
/// ciblée ([getPosition]) — simule un verrou manuel posé pendant un refresh en
/// vol. Sert à exercer la garde anti-course du backfill (re-lecture avant
/// écriture) dans [AccountController._backfillAssetTypeIfNeeded].
class _LockOnReadStorage extends AccountStorage {
  _LockOnReadStorage(AppDatabase db) : super(database: db);

  @override
  Future<Position?> getPosition(
    String accountId,
    String symbol, {
    DatabaseExecutor? executor,
  }) async {
    final p = await super.getPosition(accountId, symbol, executor: executor);
    if (p == null) return null;
    return p.copyWith(asset: p.asset.copyWith(typeLocked: true));
  }
}

// ---------------------------------------------------------------------------
// Helpers de construction
// ---------------------------------------------------------------------------

const _walletId = 'wallet-1';
const _accountId = 'account-1';
const _defaultRate = 0.92;

/// Peuple la base in-memory avec un wallet, un compte et des positions.
Future<void> seedStorage(
  AppDatabase db, {
  AccountKind accountKind = AccountKind.autre,
  List<Position> positions = const [],
}) async {
  final storage = AccountStorage(database: db);

  await storage.saveWallet(Wallet(id: _walletId, name: 'Test Wallet'));

  await storage.saveAccount(Account(
    id: _accountId,
    walletId: _walletId,
    name: 'Compte test',
    kind: accountKind,
  ));

  for (final pos in positions) {
    await storage.savePosition(_accountId, pos);
  }
}

Position makeEurPosition({
  required String symbol,
  String quantity = '10',
  double? pru,
}) {
  final asset = Asset(symbol: symbol, name: 'Asset $symbol', currency: 'EUR');
  return Position(
      accountId: _accountId,
      asset: asset,
      quantity: quantity,
      averageBuyPrice: pru);
}

Position makeUsdPosition({required String symbol, String quantity = '5'}) {
  final asset = Asset(symbol: symbol, name: 'Asset $symbol', currency: 'USD');
  return Position(accountId: _accountId, asset: asset, quantity: quantity);
}

Position makeMetalPosition({required String symbol, String quantity = '2'}) {
  final asset = Asset(
    symbol: symbol,
    name: 'Or $symbol',
    currency: 'EUR',
    type: AssetType.preciousMetal,
    refSymbol: 'GC=F',
    fineWeightGrams: 5.807,
    premiumPercent: 8.0,
  );
  return Position(accountId: _accountId, asset: asset, quantity: quantity);
}

AssetQuoteData quote(String symbol, double price, {String currency = 'EUR'}) =>
    AssetQuoteData(
      symbol: symbol,
      name: 'Asset $symbol',
      price: price,
      change: 1.0,
      changePercent: 0.5,
      currency: currency,
    );

AssetHistoricalData historyData(String symbol, List<double> prices) {
  final base = DateTime(2024, 1, 10);
  return AssetHistoricalData(
    symbol: symbol,
    dates: List.generate(prices.length, (i) => base.add(Duration(days: i))),
    prices: prices,
  );
}

/// Crée un [AccountController] avec fakes, taux fixe et storage injecté.
AccountController makeCtrl(
  AppDatabase db, {
  String? accountId = _accountId,
  double rate = _defaultRate,
  Map<String, AssetQuoteData?> quotes = const {},
  Map<String, AssetHistoricalData?> history = const {},
}) =>
    AccountController(
      initialAccountId: accountId,
      initialUsdToEurRate: rate,
      storage: AccountStorage(database: db),
      ledgerService: LedgerService(database: db),
      // Isolation stricte sur la db de test (lot cash-ledger, dérivation du
      // cash — sinon lecture par défaut sur le singleton de production).
      transactionStorage: TransactionStorage(database: db),
      marketService: _FakeMarketDataService(quotes: quotes, history: history),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Chargement nominal
  // -------------------------------------------------------------------------

  group('initAccounts — chargement nominal', () {
    test('charge le compte et les positions, isLoadingAccounts passe à false',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final pos = makeEurPosition(symbol: 'SYM1');
      await seedStorage(db, positions: [pos]);

      final ctrl = makeCtrl(db, quotes: {'SYM1': quote('SYM1', 100.0)});
      await ctrl.initAccounts();

      expect(ctrl.isLoadingAccounts, isFalse);
      expect(ctrl.activeAccount?.id, equals(_accountId));
      expect(ctrl.positionsData.length, equals(1));
      expect(ctrl.positionsData.first.symbol, equals('SYM1'));
      expect(ctrl.globalError, isNull);
    });

    test('crée un wallet par défaut si la base est vide', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      // Pas de seedStorage → aucun wallet
      final ctrl = makeCtrl(db, accountId: null);
      await ctrl.initAccounts();

      expect(ctrl.isLoadingAccounts, isFalse);
      expect(ctrl.positionsData, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Conversion devise
  // -------------------------------------------------------------------------

  group('conversion devise', () {
    test('position USD : valeur = price × qty × rate', () async {
      const rate = 0.85;
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeUsdPosition(symbol: 'AAPL', quantity: '4')]);

      final ctrl = makeCtrl(
        db,
        rate: rate,
        quotes: {'AAPL': quote('AAPL', 200.0, currency: 'USD')},
      );
      await ctrl.initAccounts();

      final valeur = ctrl.assetValues['AAPL'] ?? 0.0;
      expect(valeur, closeTo(200.0 * 4 * rate, 1e-9));
    });

    test('métal précieux EUR : pas de re-conversion (invariant R3)', () async {
      const rate = 0.85;
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeMetalPosition(symbol: 'NAPOLEON', quantity: '3')]);

      final ctrl = makeCtrl(
        db,
        rate: rate,
        quotes: {'NAPOLEON': quote('NAPOLEON', 500.0, currency: 'EUR')},
      );
      await ctrl.initAccounts();

      final valeur = ctrl.assetValues['NAPOLEON'] ?? 0.0;
      // Doit être 500*3, PAS 500*3*rate
      expect(valeur, closeTo(500.0 * 3, 1e-9));
      expect(valeur, isNot(closeTo(500.0 * 3 * rate, 1e-9)));
    });
  });

  // -------------------------------------------------------------------------
  // Ajout de position
  // -------------------------------------------------------------------------

  group('addNewPosition', () {
    test('retourne null en cas de succès et recharge les positions', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);

      final ctrl = makeCtrl(db, quotes: {
        'SPY': AssetQuoteData(
            symbol: 'SPY', name: 'SPDR S&P 500', price: 450.0, currency: 'USD'),
      });
      await ctrl.initAccounts();
      expect(ctrl.positionsData, isEmpty);

      final erreur = await ctrl.addNewPosition('SPY', '2');
      expect(erreur, isNull);
      expect(ctrl.positionsData.length, equals(1));
      expect(ctrl.positionsData.first.symbol, equals('SPY'));
    });

    test(
        'émet un openingBalance déclaratif et projette la position (derived_at '
        'non null, q/PRU = projection)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);

      final ctrl = makeCtrl(db, quotes: {
        'SPY': AssetQuoteData(
            symbol: 'SPY', name: 'SPDR S&P 500', price: 450.0, currency: 'EUR'),
      });
      await ctrl.initAccounts();

      final erreur = await ctrl.addNewPosition('SPY', '2', '400');
      expect(erreur, isNull);

      // Journal : un unique openingBalance déclaratif.
      final txStorage = TransactionStorage(database: db);
      final journal = await txStorage.getBySymbol(_accountId, 'SPY');
      expect(journal, hasLength(1));
      expect(journal.first.kind, equals(TransactionKind.openingBalance));
      expect(journal.first.meta?['declarative'], isTrue);

      // Position = projection du journal, avec derived_at horodaté.
      final accounts = AccountStorage(database: db);
      final pos = await accounts.getPosition(_accountId, 'SPY');
      expect(pos, isNotNull);
      expect(pos!.quantity, equals('2'));
      expect(pos.averageBuyPrice, closeTo(400.0, 1e-9));
      expect(
        await accounts.getPositionDerivedAt(_accountId, 'SPY'),
        isNotNull,
      );
    });

    test('retourne invalidQuantity si quantité <= 0 ou non parsable', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      expect(await ctrl.addNewPosition('SPY', '0'), equals('invalidQuantity'));
      expect(await ctrl.addNewPosition('SPY', '-1'), equals('invalidQuantity'));
      expect(await ctrl.addNewPosition('SPY', 'abc'), equals('invalidQuantity'));
    });

    test('retourne assetNotFound si le symbole est introuvable', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      // Pas de quote → getQuoteWithMetadata retourne null
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      expect(await ctrl.addNewPosition('INCONNU', '1'), equals('assetNotFound'));
    });

    test(
        'instrumentType renseigné par le provider → détermine le type',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);

      // Sans instrumentType 'XYZ' tomberait sur `other` ; Yahoo le déclare
      // MUTUALFUND : ce fait de marché détermine le type.
      final ctrl = makeCtrl(db, quotes: {
        'XYZ': AssetQuoteData(
          symbol: 'XYZ',
          name: 'Fonds XYZ',
          price: 100.0,
          currency: 'EUR',
          instrumentType: 'MUTUALFUND',
        ),
      });
      await ctrl.initAccounts();

      final erreur = await ctrl.addNewPosition('XYZ', '1');
      expect(erreur, isNull);

      final accounts = AccountStorage(database: db);
      final pos = await accounts.getPosition(_accountId, 'XYZ');
      expect(pos!.asset.type, equals(AssetType.fund));
    });

    test(
        'instrumentType absent → other (aucune heuristique, pas de faux '
        '« action » par défaut)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);

      // Provider sans instrumentType (mock / provider alternatif) : on ne
      // prétend pas connaître le type, fromYahooInstrumentType(null) → other.
      final ctrl = makeCtrl(db, quotes: {
        'SPY': AssetQuoteData(
          symbol: 'SPY',
          name: 'SPDR S&P 500',
          price: 450.0,
          currency: 'USD',
        ),
      });
      await ctrl.initAccounts();

      final erreur = await ctrl.addNewPosition('SPY', '1');
      expect(erreur, isNull);

      final accounts = AccountStorage(database: db);
      final pos = await accounts.getPosition(_accountId, 'SPY');
      expect(pos!.asset.type, equals(AssetType.other));
      expect(pos.asset.typeLocked, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Backfill lazy du type au rafraîchissement (_fetchAllPrices)
  // -------------------------------------------------------------------------

  group('backfill du type au rafraîchissement', () {
    AssetQuoteData quoteWithType(String symbol, String instrumentType) =>
        AssetQuoteData(
          symbol: symbol,
          price: 100.0,
          currency: 'EUR',
          instrumentType: instrumentType,
        );

    Position posWith(Asset asset) =>
        Position(accountId: _accountId, asset: asset, quantity: '1');

    test('position auto non verrouillée → reclassée et persistée', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      // Position historique classée `other` (avant détection instrumentType).
      await seedStorage(db, positions: [
        posWith(Asset(symbol: 'IWDA', currency: 'EUR', type: AssetType.other)),
      ]);

      final ctrl = makeCtrl(db, quotes: {
        'IWDA': quoteWithType('IWDA', 'ETF'),
      });
      await ctrl.initAccounts();

      // Reclassée en mémoire ET persistée (asset_json), sans verrouiller.
      expect(ctrl.positionsData.first.asset.type, equals(AssetType.etf));
      final persisted =
          await AccountStorage(database: db).getPosition(_accountId, 'IWDA');
      expect(persisted!.asset.type, equals(AssetType.etf));
      expect(persisted.asset.typeLocked, isFalse);
    });

    test('type verrouillé (choix manuel) → jamais écrasé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      // Obligation détenue en direct : Yahoo la déclare EQUITY, mais le choix
      // manuel (verrouillé) doit primer.
      await seedStorage(db, positions: [
        posWith(Asset(
          symbol: 'OAT',
          currency: 'EUR',
          type: AssetType.bond,
          typeLocked: true,
        )),
      ]);

      final ctrl = makeCtrl(db, quotes: {
        'OAT': quoteWithType('OAT', 'EQUITY'),
      });
      await ctrl.initAccounts();

      expect(ctrl.positionsData.first.asset.type, equals(AssetType.bond));
      final persisted =
          await AccountStorage(database: db).getPosition(_accountId, 'OAT');
      expect(persisted!.asset.type, equals(AssetType.bond));
    });

    test('actif métal (refSymbol) → jamais reclassé par le cours de référence',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [
        makeMetalPosition(symbol: 'NAPOLEON'),
      ]);

      // Même si le fake propage un instrumentType (EQUITY pour un ETC),
      // la garde refSymbol!=null empêche tout reclassement.
      final ctrl = makeCtrl(db, quotes: {
        'NAPOLEON': quoteWithType('NAPOLEON', 'EQUITY'),
      });
      await ctrl.initAccounts();

      final persisted =
          await AccountStorage(database: db).getPosition(_accountId, 'NAPOLEON');
      expect(persisted!.asset.type, equals(AssetType.preciousMetal));
    });

    test('déverrouillage (Automatique) → la position redevient reclassable',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      // Verrouillée à la main sur bond (ex. mauvais verrou à corriger).
      await seedStorage(db, positions: [
        posWith(Asset(
          symbol: 'IWDA',
          currency: 'EUR',
          type: AssetType.bond,
          typeLocked: true,
        )),
      ]);
      final storage = AccountStorage(database: db);

      // Verrouillé → backfill s'abstient malgré instrumentType ETF.
      await makeCtrl(db, quotes: {'IWDA': quoteWithType('IWDA', 'ETF')})
          .initAccounts();
      expect((await storage.getPosition(_accountId, 'IWDA'))!.asset.type,
          equals(AssetType.bond));

      // « Automatique » : déverrouille (ce que fait l'UI via updatePositionMetadata).
      final p = (await storage.getPosition(_accountId, 'IWDA'))!;
      await storage.updatePositionMetadata(
        _accountId,
        'IWDA',
        asset: p.asset.copyWith(typeLocked: false),
      );

      // Rafraîchissement suivant : reclassé automatiquement en etf.
      await makeCtrl(db, quotes: {'IWDA': quoteWithType('IWDA', 'ETF')})
          .initAccounts();
      final after = (await storage.getPosition(_accountId, 'IWDA'))!;
      expect(after.asset.type, equals(AssetType.etf));
      expect(after.asset.typeLocked, isFalse);
    });

    test(
        're-lecture avant écriture : un verrou posé pendant le refresh n\'est '
        'pas écrasé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      // Position auto (other) éligible au backfill au moment de la lecture liste.
      await seedStorage(db, positions: [
        posWith(Asset(symbol: 'IWDA', currency: 'EUR', type: AssetType.other)),
      ]);

      // _LockOnReadStorage simule l'utilisateur qui verrouille le type PENDANT
      // le refresh : la relecture fraîche (getPosition, juste avant l'écriture)
      // renvoie une version verrouillée → le backfill doit s'abstenir d'écrire.
      final ctrl = AccountController(
        initialAccountId: _accountId,
        initialUsdToEurRate: _defaultRate,
        storage: _LockOnReadStorage(db),
        ledgerService: LedgerService(database: db),
        marketService: _FakeMarketDataService(
          quotes: {'IWDA': quoteWithType('IWDA', 'ETF')},
        ),
      );
      await ctrl.initAccounts();

      // Type NON réécrit en etf : la relecture l'a vu verrouillé entre-temps.
      final persisted =
          await AccountStorage(database: db).getPosition(_accountId, 'IWDA');
      expect(persisted!.asset.type, equals(AssetType.other));
    });
  });

  // -------------------------------------------------------------------------
  // Suppression de position
  // -------------------------------------------------------------------------

  group('removePosition', () {
    test('supprime la position et met à jour positionsData', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeEurPosition(symbol: 'BND')]);

      final ctrl = makeCtrl(db, quotes: {'BND': quote('BND', 80.0)});
      await ctrl.initAccounts();
      expect(ctrl.positionsData.length, equals(1));

      await ctrl.removePosition('BND');
      expect(ctrl.positionsData, isEmpty);
    });

    test(
        'deletePositionWithJournal : supprime position + journal du symbole, '
        'un autre symbole survit', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);

      final ctrl = makeCtrl(db, quotes: {
        'AAA': quote('AAA', 10.0),
        'BBB': quote('BBB', 20.0),
      });
      await ctrl.initAccounts();

      // Deux positions avec journal (openingBalance émis par addNewPosition).
      await ctrl.addNewPosition('AAA', '5', '10');
      await ctrl.addNewPosition('BBB', '3', '20');

      final accounts = AccountStorage(database: db);
      final txStorage = TransactionStorage(database: db);
      expect(await txStorage.getBySymbol(_accountId, 'AAA'), hasLength(1));

      await ctrl.removePosition('AAA');

      // AAA : position ET journal effacés.
      expect(await accounts.getPosition(_accountId, 'AAA'), isNull);
      expect(await txStorage.getBySymbol(_accountId, 'AAA'), isEmpty);
      // BBB : intact.
      expect(await accounts.getPosition(_accountId, 'BBB'), isNotNull);
      expect(await txStorage.getBySymbol(_accountId, 'BBB'), hasLength(1));

      final symbols = ctrl.positionsData.map((p) => p.symbol).toList();
      expect(symbols, contains('BBB'));
      expect(symbols, isNot(contains('AAA')));
    });
  });

  // -------------------------------------------------------------------------
  // Changement de période
  // -------------------------------------------------------------------------

  group('onPeriodChanged', () {
    test('met à jour selectedPeriod et recharge l\'historique', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeEurPosition(symbol: 'TKR')]);

      final ctrl = makeCtrl(
        db,
        quotes: {'TKR': quote('TKR', 105.0)},
        history: {'TKR': historyData('TKR', [100.0, 102.0, 105.0])},
      );
      await ctrl.initAccounts();
      expect(ctrl.selectedPeriod, equals(ChartPeriod.month1));

      await ctrl.onPeriodChanged(ChartPeriod.month3);

      expect(ctrl.selectedPeriod, equals(ChartPeriod.month3));
      expect(ctrl.chartValues, isNotEmpty);
      expect(ctrl.isLoadingHistory, isFalse);
    });

    test('ne recharge pas l\'historique si la période est identique', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      final periodBefore = ctrl.selectedPeriod;
      await ctrl.onPeriodChanged(periodBefore); // même période

      // Aucune position → chartDates reste vide, pas d'erreur
      expect(ctrl.chartDates, isEmpty);
      expect(ctrl.selectedPeriod, equals(periodBefore));
    });
  });

  // -------------------------------------------------------------------------
  // Renommage de compte
  // -------------------------------------------------------------------------

  group('renameAccount', () {
    test('met à jour le nom du compte actif', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      expect(ctrl.activeAccount?.name, equals('Compte test'));
      final erreur = await ctrl.renameAccount('Nouveau Nom');

      expect(erreur, isNull);
      expect(ctrl.activeAccount?.name, equals('Nouveau Nom'));
    });
  });

  group('setAccountKind', () {
    test('met à jour et persiste la nature du compte actif', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      expect(ctrl.activeAccount?.kind, equals(AccountKind.autre));
      final erreur = await ctrl.setAccountKind(AccountKind.cto);

      expect(erreur, isNull);
      expect(ctrl.activeAccount?.kind, equals(AccountKind.cto));

      // Persistance : un contrôleur neuf relit la valeur depuis le storage.
      final ctrl2 = makeCtrl(db);
      await ctrl2.initAccounts();
      expect(ctrl2.activeAccount?.kind, equals(AccountKind.cto));
    });
  });

  // -------------------------------------------------------------------------
  // Solde espèces dérivé (lot cash-ledger) — opt-in + actions dédiées
  // -------------------------------------------------------------------------

  group('cash dérivé (lot cash-ledger)', () {
    test(
        'compte neuf (journal vide) : derivedCash null, hasCashAnchor false',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      expect(ctrl.derivedCash, isNull);
      expect(ctrl.hasCashAnchor, isFalse);
    });

    test(
        'journal composé UNIQUEMENT de buy → hasCashAnchor reste false '
        '(opt-in, même si derivedCash est déjà projeté)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeEurPosition(symbol: 'AAA')]);
      final ledger = LedgerService(database: db);
      await ledger.recordTransaction(AssetTransaction(
        id: 'tx-buy-1',
        accountId: _accountId,
        symbol: 'AAA',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '50',
        amount: '-500',
        currency: 'EUR',
        date: DateTime(2025, 1, 1),
      ));

      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      // derived_cash a bien été reprojeté (buy → -500), mais SANS ancrage :
      // l'opt-in doit rester fermé (design §3 — pas de solde négatif faux).
      expect(ctrl.derivedCash, isNotNull);
      expect(ctrl.hasCashAnchor, isFalse);
    });

    test('emitCashOpeningBalance déclare le solde initial et ouvre l\'opt-in',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      final erreur = await ctrl.emitCashOpeningBalance(
        amount: '1500',
        date: DateTime(2025, 2, 1),
      );

      expect(erreur, isNull);
      expect(ctrl.hasCashAnchor, isTrue);
      expect(double.parse(ctrl.derivedCash!), closeTo(1500.0, 1e-9));
    });

    test('emitCashAdjustment corrige le solde dérivé par un delta signé',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db);
      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();

      await ctrl.emitCashOpeningBalance(
        amount: '1000',
        date: DateTime(2025, 2, 1),
      );
      expect(double.parse(ctrl.derivedCash!), closeTo(1000.0, 1e-9));

      final erreur = await ctrl.emitCashAdjustment(
        amount: '-200', // correction : le solde constaté est 200 de moins
        date: DateTime(2025, 3, 1),
      );

      expect(erreur, isNull);
      expect(double.parse(ctrl.derivedCash!), closeTo(800.0, 1e-9));
    });

    test('emitCashOpeningBalance sans compte actif → noActiveAccount',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final ctrl = makeCtrl(db, accountId: 'inexistant');
      // Aucun seed : la base est vide, initAccounts() ne trouve aucun compte.

      final erreur = await ctrl.emitCashOpeningBalance(
        amount: '100',
        date: DateTime(2025, 1, 1),
      );

      expect(erreur, equals('noActiveAccount'));
    });
  });

  // -------------------------------------------------------------------------
  // Garde-fou d'affichage : mouvements en devise étrangère (design §8.5)
  // -------------------------------------------------------------------------

  group('foreignCashMovementCount (garde-fou §8.5)', () {
    test('aucun mouvement étranger → count 0', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeEurPosition(symbol: 'AAA')]);
      final ledger = LedgerService(database: db);
      await ledger.recordTransaction(AssetTransaction(
        id: 'tx-dep',
        accountId: _accountId,
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'EUR', // devise du compte
        date: DateTime(2025, 1, 1),
      ));

      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();
      expect(ctrl.foreignCashMovementCount, 0);
    });

    test('ligne legacy USD (bucket étranger non nul) → count 1', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeUsdPosition(symbol: 'AAPL')]);
      final ledger = LedgerService(database: db);
      // Achat coté ET réglé USD (settlementCurrency null) sur un compte EUR :
      // alimente un bucket USD ≠ devise du compte → doit être signalé.
      await ledger.recordTransaction(AssetTransaction(
        id: 'tx-usd',
        accountId: _accountId,
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '175',
        amount: '-1750',
        currency: 'USD',
        date: DateTime(2025, 1, 1),
      ));

      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();
      expect(ctrl.foreignCashMovementCount, 1);
    });

    test('achat corrigé (settlementCurrency=EUR) → count 0 (bucket EUR)',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeUsdPosition(symbol: 'AAPL')]);
      final ledger = LedgerService(database: db);
      // Cotation USD mais règlement EUR : le cash tombe dans le bucket EUR
      // (devise du compte) → aucun mouvement étranger à signaler.
      await ledger.recordTransaction(AssetTransaction(
        id: 'tx-cross',
        accountId: _accountId,
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '175',
        amount: '-1620',
        currency: 'USD',
        settlementCurrency: 'EUR',
        date: DateTime(2025, 1, 1),
      ));

      final ctrl = makeCtrl(db);
      await ctrl.initAccounts();
      expect(ctrl.foreignCashMovementCount, 0);
    });
  });

  // -------------------------------------------------------------------------
  // Helper generateMetalSymbol
  // -------------------------------------------------------------------------

  group('generateMetalSymbol', () {
    final ctrl = AccountController(
      initialAccountId: null,
      marketService: _FakeMarketDataService(),
    );

    test('normalise le nom en majuscules sans caractères spéciaux', () {
      expect(
        ctrl.generateMetalSymbol('Napoléon 20 F', {}),
        equals('NAPOL-ON-20-F'),
      );
    });

    test('évite les collisions avec les symboles existants', () {
      expect(
        ctrl.generateMetalSymbol('Napoleon', {'NAPOLEON'}),
        equals('NAPOLEON-2'),
      );
    });

    test('incrémente jusqu\'à trouver un symbole libre', () {
      expect(
        ctrl.generateMetalSymbol('Napoleon', {'NAPOLEON', 'NAPOLEON-2', 'NAPOLEON-3'}),
        equals('NAPOLEON-4'),
      );
    });

    test('utilise METAL si le nom produit une base vide', () {
      expect(ctrl.generateMetalSymbol('', {}), equals('METAL'));
    });
  });

  // -------------------------------------------------------------------------
  // Correctif B1 — notifyListeners après dispose
  // -------------------------------------------------------------------------

  group('AccountController – dispose avant continuation (B1)', () {
    test(
        'dispose() pendant initAccounts() en cours : aucune exception levée',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await seedStorage(db, positions: [makeEurPosition(symbol: 'B1ACC')]);

      // Completer bloqué : la cotation ne se résoudra qu'après dispose.
      final quoteCompleter = Completer<AssetQuoteData?>();

      final ctrl = AccountController(
        initialAccountId: _accountId,
        initialUsdToEurRate: _defaultRate,
        storage: AccountStorage(database: db),
        marketService: _DelayedMarketDataService(
          quoteCompleter: quoteCompleter,
        ),
      );

      // Lance initAccounts() SANS await : la continuation reste en attente
      // sur _fetchAllPrices (qui attend quoteCompleter).
      final initFuture = ctrl.initAccounts();

      // Dépile la vue : dispose le contrôleur avant que la Future se termine.
      ctrl.dispose();

      // Débloque la Future de cotation → les _safeNotify() post-await
      // ne doivent PAS lever d'exception.
      quoteCompleter.complete(null);

      // Aucune exception ne doit remonter.
      await expectLater(initFuture, completes);
    });
  });
}

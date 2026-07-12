// test/controllers/wallet_controller_test.dart
//
// Tests du WalletController avec des fakes en mémoire.
// Aucun appel réseau : les services de marché retournent des données fixes.
// La persistance est assurée par une base SQLite in-memory isolée par test.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/wallet_controller.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/valuation_snapshot.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/allocation_target_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/snapshot_storage.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';

import '../helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Fakes (pas d'appels réseau)
// ---------------------------------------------------------------------------

/// Fake du service de taux de change : retourne toujours 0.90 pour USD.
class _FakeExchangeRateService extends ExchangeRateService {
  _FakeExchangeRateService() : super.forTesting();

  @override
  Future<double> getUsdToEurRate() async => 0.90;

  @override
  Future<double> getRateToEur(String currency) async {
    if (currency.toUpperCase() == 'EUR') return 1.0;
    return 0.90;
  }
}

/// Fake du service de données de marché.
///
/// [quotesBySymbol] : map symbole → quote (null = cotation absente).
/// [historicalBySymbol] : map symbole → données historiques.
class _FakeMarketDataService extends MarketDataService {
  final Map<String, AssetQuoteData?> quotesBySymbol;
  final Map<String, AssetHistoricalData?> historicalBySymbol;

  _FakeMarketDataService({
    this.quotesBySymbol = const {},
    this.historicalBySymbol = const {},
  }) : super.forTesting(_FakeExchangeRateService());

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async =>
      quotesBySymbol[asset.symbol];

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(
    Asset asset, {
    int days = 30,
  }) async =>
      historicalBySymbol[asset.symbol];
}

/// Fake du service de snapshots : stocke les snapshots en mémoire.
class _FakeSnapshotStorage extends SnapshotStorage {
  _FakeSnapshotStorage() : super.forTesting();

  final Map<String, List<ValuationSnapshot>> _store = {};

  @override
  Future<List<ValuationSnapshot>> getSnapshots(String walletId) async =>
      List.unmodifiable(_store[walletId] ?? []);

  @override
  Future<void> upsertSnapshot(
      String walletId, ValuationSnapshot snapshot) async {
    _store.putIfAbsent(walletId, () => []);
    // Idempotence : on écrase l'éventuel snapshot du même jour
    _store[walletId]!.removeWhere((s) => s.date == snapshot.date);
    _store[walletId]!.add(snapshot);
  }

  bool hasSnapshotFor(String walletId) =>
      (_store[walletId]?.isNotEmpty) ?? false;
}

/// Fake du service de marché dont la réponse historique est retardée via un
/// [Completer] — permet de simuler une continuation post-dispose (correctif B1)
/// et un changement de wallet pendant l'attente (correctif I2).
class _DelayedMarketDataService extends MarketDataService {
  final Completer<AssetHistoricalData?> _historyCompleter;
  final Map<String, AssetQuoteData?> _quotesBySymbol;

  _DelayedMarketDataService({
    required Completer<AssetHistoricalData?> historyCompleter,
    Map<String, AssetQuoteData?> quotesBySymbol = const {},
  })  : _historyCompleter = historyCompleter,
        _quotesBySymbol = quotesBySymbol,
        super.forTesting(_FakeExchangeRateService());

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async =>
      _quotesBySymbol[asset.symbol];

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(
    Asset asset, {
    int days = 30,
  }) =>
      _historyCompleter.future;
}

// ---------------------------------------------------------------------------
// Helpers de construction de données de test
// ---------------------------------------------------------------------------

/// Crée un [WalletController] en injectant les deux storages sur la même [db].
WalletController _makeController({
  required AppDatabase db,
  MarketDataService? marketService,
  SnapshotStorage? snapshotStorage,
  String defaultWalletName = 'Mon Patrimoine',
}) =>
    WalletController(
      storage: AccountStorage(database: db),
      allocationTargetStorage: AllocationTargetStorage(database: db),
      marketService: marketService ?? _FakeMarketDataService(),
      exchangeService: _FakeExchangeRateService(),
      snapshotStorage: snapshotStorage ?? _FakeSnapshotStorage(),
      // Isolation stricte sur la db de test (sinon lecture par défaut sur le
      // singleton de production — cf. lot cash-ledger, dérivation du cash).
      transactionStorage: TransactionStorage(database: db),
      defaultWalletName: defaultWalletName,
    );

/// Seed : un wallet, un compte investissement, une position.
Future<void> setupSingleWalletWithInvestment({
  required AppDatabase db,
  required String walletId,
  required String walletName,
  required String accountId,
  required String accountName,
  required String symbol,
  required String quantity,
  String currency = 'EUR',
}) async {
  final storage = AccountStorage(database: db);
  final wallet = Wallet(id: walletId, name: walletName);
  await storage.saveWallet(wallet);

  final account = Account(
    id: accountId,
    walletId: walletId,
    name: accountName,
    kind: AccountKind.autre,
  );
  await storage.saveAccount(account);

  final asset = Asset(symbol: symbol, currency: currency);
  final position = Position(accountId: accountId, asset: asset, quantity: quantity);
  await storage.savePosition(accountId, position);
}

/// Seed : un wallet et un compte cash.
Future<void> setupSingleWalletWithCash({
  required AppDatabase db,
  required String walletId,
  required String accountId,
  required double cashBalance,
}) async {
  final storage = AccountStorage(database: db);
  final wallet = Wallet(id: walletId, name: 'Mon portefeuille');
  await storage.saveWallet(wallet);

  final account = Account(
    id: accountId,
    walletId: walletId,
    name: 'Livret A',
    kind: AccountKind.cash,
    cashBalance: cashBalance,
  );
  await storage.saveAccount(account);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // Chargement nominal
  // =========================================================================

  group('WalletController – chargement nominal', () {
    test('charge wallet, comptes et positions EUR correctement', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w1',
        walletName: 'Portefeuille test',
        accountId: 'acc1',
        accountName: 'PEA',
        symbol: 'MC.PA',
        quantity: '10',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'MC.PA': AssetQuoteData(symbol: 'MC.PA', price: 700.0, currency: 'EUR'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);

      await controller.loadAllData();

      expect(controller.wallets.length, 1);
      expect(controller.activeWallet?.name, 'Portefeuille test');
      expect(controller.accounts.length, 1);
      expect(controller.accounts.first.type, AccountType.investment);
      expect(controller.accountValues['acc1'], closeTo(7000.0, 1e-9));
      expect(controller.isLoading, false);
      expect(controller.error, isNull);
    });

    test('position USD : applique la conversion usdToEurRate', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w-usd',
        walletName: 'USD wallet',
        accountId: 'acc-usd',
        accountName: 'CTO',
        symbol: 'AAPL',
        quantity: '5',
        currency: 'USD',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'AAPL': AssetQuoteData(symbol: 'AAPL', price: 200.0, currency: 'USD'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);

      await controller.loadAllData();

      // 200 USD × 5 qty × 0.90 = 900 EUR
      expect(controller.accountValues['acc-usd'], closeTo(900.0, 1e-9));
    });

    test('wallet cash-only : valeur correcte, pas de positions', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithCash(
        db: db,
        walletId: 'w-cash',
        accountId: 'acc-cash',
        cashBalance: 3000.0,
      );

      final controller = _makeController(db: db);

      await controller.loadAllData();

      expect(controller.accountValues['acc-cash'], closeTo(3000.0, 1e-9));
      expect(controller.allPositionsData, isEmpty);
      expect(controller.isLoading, false);
    });

    test('aucun wallet existant → wallet par défaut créé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      // Base vide — aucun seed
      final controller = _makeController(
        db: db,
        defaultWalletName: 'Mon Patrimoine',
      );

      await controller.loadAllData();

      expect(controller.wallets.length, 1);
      expect(controller.activeWallet?.name, 'Mon Patrimoine');
    });
  });

  // =========================================================================
  // Complétude des données de marché et snapshot
  // =========================================================================

  group('WalletController – marketDataComplete & snapshot', () {
    test('quote null → marketDataComplete false → snapshot non capturé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w2',
        walletName: 'Test',
        accountId: 'acc2',
        accountName: 'PEA',
        symbol: 'FAIL',
        quantity: '10',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {'FAIL': null},
      );
      final fakeSnap = _FakeSnapshotStorage();
      final controller = _makeController(
        db: db,
        marketService: fakeMarket,
        snapshotStorage: fakeSnap,
      );

      await controller.loadAllData();

      expect(fakeSnap.hasSnapshotFor('w2'), false);
    });

    test('quote.price null → marketDataComplete false → pas de snapshot', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w3',
        walletName: 'Test',
        accountId: 'acc3',
        accountName: 'PEA',
        symbol: 'BAD',
        quantity: '10',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'BAD': AssetQuoteData(symbol: 'BAD', price: null),
        },
      );
      final fakeSnap = _FakeSnapshotStorage();
      final controller = _makeController(
        db: db,
        marketService: fakeMarket,
        snapshotStorage: fakeSnap,
      );

      await controller.loadAllData();

      expect(fakeSnap.hasSnapshotFor('w3'), false);
    });

    test('toutes les cotations valides → marketDataComplete true → snapshot capturé',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w4',
        walletName: 'Test',
        accountId: 'acc4',
        accountName: 'PEA',
        symbol: 'SYM',
        quantity: '5',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'SYM': AssetQuoteData(symbol: 'SYM', price: 100.0, currency: 'EUR'),
        },
      );
      final fakeSnap = _FakeSnapshotStorage();
      final controller = _makeController(
        db: db,
        marketService: fakeMarket,
        snapshotStorage: fakeSnap,
      );

      await controller.loadAllData();

      // Total = 100 × 5 = 500 > 0 → snapshot capturé
      expect(fakeSnap.hasSnapshotFor('w4'), true);
    });

    test('wallet 100% cash → marketDataComplete reste true → snapshot capturé',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithCash(
        db: db,
        walletId: 'w-cash2',
        accountId: 'acc-cash2',
        cashBalance: 1000.0,
      );

      final fakeSnap = _FakeSnapshotStorage();
      final controller = _makeController(
        db: db,
        snapshotStorage: fakeSnap,
      );

      await controller.loadAllData();

      // Les comptes cash sautent la boucle de vérification des cotations →
      // marketDataComplete reste true → snapshot capturé.
      expect(fakeSnap.hasSnapshotFor('w-cash2'), true);
    });

    test(
        'quote.asOf non-null (prix issu du cache LOT 2) → marketDataComplete false → pas de snapshot',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w5',
        walletName: 'Test',
        accountId: 'acc5',
        accountName: 'PEA',
        symbol: 'STALE',
        quantity: '10',
      );

      // Prix valide (price non-null) mais servi depuis le cache « dernier
      // cours connu » (asOf non-null) : le patrimoine affiché utilise quand
      // même ce prix, mais le garde-fou snapshot doit interdire la capture
      // (on ne veut pas persister un total fondé sur des prix périmés).
      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'STALE': AssetQuoteData(
            symbol: 'STALE',
            price: 100.0,
            currency: 'EUR',
            asOf: DateTime(2026, 1, 1),
          ),
        },
      );
      final fakeSnap = _FakeSnapshotStorage();
      final controller = _makeController(
        db: db,
        marketService: fakeMarket,
        snapshotStorage: fakeSnap,
      );

      await controller.loadAllData();

      expect(fakeSnap.hasSnapshotFor('w5'), false);
    });

    test(
        'quote.asOf null (prix live) → marketDataComplete reste true → snapshot capturé',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w6',
        walletName: 'Test',
        accountId: 'acc6',
        accountName: 'PEA',
        symbol: 'FRESH',
        quantity: '10',
      );

      // Même prix que le test précédent, mais asOf == null (cotation live,
      // pas servie depuis le cache) : preuve symétrique que c'est bien asOf
      // qui pilote la garde, pas la seule présence d'un prix.
      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'FRESH': AssetQuoteData(symbol: 'FRESH', price: 100.0, currency: 'EUR'),
        },
      );
      final fakeSnap = _FakeSnapshotStorage();
      final controller = _makeController(
        db: db,
        marketService: fakeMarket,
        snapshotStorage: fakeSnap,
      );

      await controller.loadAllData();

      expect(fakeSnap.hasSnapshotFor('w6'), true);
    });
  });

  // =========================================================================
  // Changement de wallet
  // =========================================================================

  group('WalletController – selectWallet', () {
    test('selectWallet charge les données du nouveau wallet actif', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);

      final wallet1 = Wallet(id: 'w-a', name: 'Wallet A');
      final wallet2 = Wallet(id: 'w-b', name: 'Wallet B');
      await storage.saveWallet(wallet1);
      await storage.saveWallet(wallet2);

      final account1 = Account(
        id: 'acc-a', walletId: 'w-a', name: 'PEA A', kind: AccountKind.autre,
      );
      final account2 = Account(
        id: 'acc-b', walletId: 'w-b', name: 'PEA B', kind: AccountKind.autre,
      );
      await storage.saveAccount(account1);
      await storage.saveAccount(account2);

      final posA = Position(
        accountId: 'acc-a', asset: Asset(symbol: 'AAAA', currency: 'EUR'), quantity: '2',
      );
      final posB = Position(
        accountId: 'acc-b', asset: Asset(symbol: 'BBBB', currency: 'EUR'), quantity: '3',
      );
      await storage.savePosition('acc-a', posA);
      await storage.savePosition('acc-b', posB);

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'AAAA': AssetQuoteData(symbol: 'AAAA', price: 10.0, currency: 'EUR'),
          'BBBB': AssetQuoteData(symbol: 'BBBB', price: 20.0, currency: 'EUR'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);

      // Chargement initial → wallet A actif (premier de la liste)
      await controller.loadAllData();
      expect(controller.activeWallet?.id, 'w-a');
      expect(controller.accounts.any((a) => a.id == 'acc-a'), true);

      // Bascule vers wallet B
      await controller.selectWallet(wallet2);
      expect(controller.activeWallet?.id, 'w-b');
      expect(controller.accounts.any((a) => a.id == 'acc-b'), true);
      // Le compte A ne doit plus être présent
      expect(controller.accounts.any((a) => a.id == 'acc-a'), false);
    });

    test('selectWallet avec même wallet : aucun rechargement', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w-same',
        walletName: 'Wallet same',
        accountId: 'acc-same',
        accountName: 'PEA',
        symbol: 'SAME',
        quantity: '1',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'SAME': AssetQuoteData(symbol: 'SAME', price: 50.0, currency: 'EUR'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);

      await controller.loadAllData();
      final walletBefore = controller.activeWallet!;

      // Sélectionner le même wallet → early return, pas de rechargement
      await controller.selectWallet(walletBefore);

      expect(controller.activeWallet?.id, walletBefore.id);
      expect(controller.isLoading, false);
    });
  });

  // =========================================================================
  // Changement de période
  // =========================================================================

  group('WalletController – onPeriodChanged', () {
    test('onPeriodChanged met à jour selectedPeriod', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w-period',
        walletName: 'Test',
        accountId: 'acc-period',
        accountName: 'PEA',
        symbol: 'PERIO',
        quantity: '1',
      );

      final baseDate = DateTime(2024, 1, 1);
      final fakeDates = List<DateTime>.generate(30, (i) => baseDate.add(Duration(days: i)));
      final fakePrices = List<num>.generate(30, (i) => 100.0 + i);
      final fakeHistorical = AssetHistoricalData(
        symbol: 'PERIO',
        dates: fakeDates,
        prices: fakePrices,
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'PERIO': AssetQuoteData(symbol: 'PERIO', price: 130.0, currency: 'EUR'),
        },
        historicalBySymbol: {'PERIO': fakeHistorical},
      );
      final controller = _makeController(db: db, marketService: fakeMarket);

      await controller.loadAllData();

      expect(controller.selectedPeriod, ChartPeriod.month1);

      controller.onPeriodChanged(ChartPeriod.month3);
      expect(controller.selectedPeriod, ChartPeriod.month3);
    });

    test('onPeriodChanged avec même période : selectedPeriod inchangé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w-period2',
        walletName: 'Test',
        accountId: 'acc-period2',
        accountName: 'PEA',
        symbol: 'PERIO2',
        quantity: '1',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'PERIO2': AssetQuoteData(symbol: 'PERIO2', price: 50.0, currency: 'EUR'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);

      await controller.loadAllData();

      final periodBefore = controller.selectedPeriod;
      controller.onPeriodChanged(periodBefore);
      expect(controller.selectedPeriod, periodBefore);
    });
  });

  // =========================================================================
  // Actions données
  // =========================================================================

  group('WalletController – actions données', () {
    test('deleteAccount supprime le compte et recharge', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final wallet = Wallet(id: 'w-del', name: 'Test');
      await storage.saveWallet(wallet);

      final acc1 = Account(
        id: 'acc-del-1', walletId: 'w-del', name: 'Compte 1',
        kind: AccountKind.cash, cashBalance: 100.0,
      );
      final acc2 = Account(
        id: 'acc-del-2', walletId: 'w-del', name: 'Compte 2',
        kind: AccountKind.cash, cashBalance: 200.0,
      );
      await storage.saveAccount(acc1);
      await storage.saveAccount(acc2);

      final controller = _makeController(db: db);

      await controller.loadAllData();
      expect(controller.accounts.length, 2);

      final deleted = await controller.deleteAccount('acc-del-1');
      expect(deleted, true);
      expect(controller.accounts.length, 1);
      expect(controller.accounts.first.id, 'acc-del-2');
    });

    test('deleteAccount refuse si dernier compte', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithCash(
        db: db,
        walletId: 'w-nodal',
        accountId: 'acc-nodal',
        cashBalance: 500.0,
      );

      final controller = _makeController(db: db);

      await controller.loadAllData();
      final deleted = await controller.deleteAccount('acc-nodal');
      expect(deleted, false);
      expect(controller.accounts.length, 1);
    });

    test('updateCashBalance met à jour le solde et recharge', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithCash(
        db: db,
        walletId: 'w-upd',
        accountId: 'acc-upd',
        cashBalance: 1000.0,
      );

      final controller = _makeController(db: db);

      await controller.loadAllData();
      expect(controller.accountValues['acc-upd'], closeTo(1000.0, 1e-9));

      final account = controller.accounts.first;
      await controller.updateCashBalance(account, 2500.0);

      expect(controller.accountValues['acc-upd'], closeTo(2500.0, 1e-9));
    });
  });

  // =========================================================================
  // Cash dérivé des comptes titres (lot cash-ledger, risque §6.7)
  // =========================================================================

  group('WalletController – cash dérivé des comptes titres', () {
    test(
        'compte titres avec ancrage cash (solde initial espèces) → inclus dans '
        'accountValues ET cashBalances, sans doublon', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: 'w-cl1', name: 'Test'));
      final account = Account(
        id: 'acc-cl1',
        walletId: 'w-cl1',
        name: 'CTO',
        kind: AccountKind.autre,
      );
      await storage.saveAccount(account);

      // Ancrage espèces (openingBalance symbol=null) : opt-in d'agrégation.
      final ledger = LedgerService(database: db);
      await ledger.emitCashOpeningBalance(
        accountId: 'acc-cl1',
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2025, 1, 1),
      );

      final controller = _makeController(db: db);
      await controller.loadAllData();

      expect(controller.accountValues['acc-cl1'], closeTo(1000.0, 1e-9));
      expect(controller.cashBalances['acc-cl1'], closeTo(1000.0, 1e-9));
      expect(controller.totalPatrimoine, closeTo(1000.0, 1e-9));
    });

    test(
        'compte titres SANS ancrage cash (seulement des buy) → cash dérivé NON '
        'agrégé (opt-in) — accountValues reste la seule valeur des positions',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: 'w-cl2', name: 'Test'));
      final account = Account(
        id: 'acc-cl2',
        walletId: 'w-cl2',
        name: 'CTO',
        kind: AccountKind.autre,
      );
      await storage.saveAccount(account);

      final asset = Asset(symbol: 'SYM2', currency: 'EUR');
      final position =
          Position(accountId: 'acc-cl2', asset: asset, quantity: '10');
      await storage.savePosition('acc-cl2', position);

      // openingBalance TITRE (symbol non null) : mouvement du journal, mais
      // PAS un ancrage espèces → derived_cash devient négatif (frais/prix nuls
      // ici, donc 0) mais reste non agrégé de toute façon en l'absence
      // d'ancrage. On vérifie surtout la non-agrégation.
      final ledger = LedgerService(database: db);
      await ledger.emitOpeningBalance(
        accountId: 'acc-cl2',
        symbol: 'SYM2',
        quantity: '10',
        unitPrice: '50',
        currency: 'EUR',
        date: DateTime(2025, 1, 1),
        declarative: true,
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'SYM2': AssetQuoteData(symbol: 'SYM2', price: 55.0, currency: 'EUR'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);
      await controller.loadAllData();

      // 10 × 55 = 550, AUCUN cash agrégé (pas d'ancrage).
      expect(controller.accountValues['acc-cl2'], closeTo(550.0, 1e-9));
      expect(controller.cashBalances.containsKey('acc-cl2'), isFalse);
    });

    test(
        'compte cash (kind=cash) et compte titres avec ancrage cash coexistent '
        'sans double comptage', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: 'w-cl3', name: 'Test'));

      final cashAccount = Account(
        id: 'acc-cl3-cash',
        walletId: 'w-cl3',
        name: 'Livret',
        kind: AccountKind.cash,
        cashBalance: 300.0,
      );
      await storage.saveAccount(cashAccount);

      final securitiesAccount = Account(
        id: 'acc-cl3-cto',
        walletId: 'w-cl3',
        name: 'CTO',
        kind: AccountKind.autre,
      );
      await storage.saveAccount(securitiesAccount);

      final ledger = LedgerService(database: db);
      await ledger.emitCashOpeningBalance(
        accountId: 'acc-cl3-cto',
        amount: '400',
        currency: 'EUR',
        date: DateTime(2025, 1, 1),
      );

      final controller = _makeController(db: db);
      await controller.loadAllData();

      expect(controller.accountValues['acc-cl3-cash'], closeTo(300.0, 1e-9));
      expect(controller.accountValues['acc-cl3-cto'], closeTo(400.0, 1e-9));
      // Total = 300 (cash) + 400 (titres, cash dérivé) — chacun compté UNE fois.
      expect(controller.totalPatrimoine, closeTo(700.0, 1e-9));
      expect(controller.cashBalances['acc-cl3-cash'], closeTo(300.0, 1e-9));
      expect(controller.cashBalances['acc-cl3-cto'], closeTo(400.0, 1e-9));
    });
  });

  // =========================================================================
  // Correctif B1 — notifyListeners après dispose
  // =========================================================================

  group('WalletController – dispose avant continuation (B1)', () {
    test('dispose() pendant loadAllData() en cours : aucune exception levée', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w-b1',
        walletName: 'Test B1',
        accountId: 'acc-b1',
        accountName: 'PEA',
        symbol: 'B1SYM',
        quantity: '2',
      );

      // Completer bloqué : la Future historique ne se résoudra qu'après dispose.
      final histCompleter = Completer<AssetHistoricalData?>();

      final fakeMarket = _DelayedMarketDataService(
        historyCompleter: histCompleter,
        quotesBySymbol: {
          'B1SYM': AssetQuoteData(symbol: 'B1SYM', price: 50.0, currency: 'EUR'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);

      // Lance loadAllData() SANS await : la continuation reste en attente
      // sur _loadHistory (qui attend histCompleter).
      final loadFuture = controller.loadAllData();

      // Dépile la vue : dispose le contrôleur avant que la Future se termine.
      controller.dispose();

      // Débloque la Future historique → les _safeNotify() post-await
      // ne doivent PAS lever d'exception.
      histCompleter.complete(null);

      // Aucune exception ne doit remonter.
      await expectLater(loadFuture, completes);
    });
  });

  // =========================================================================
  // CRUD wallet (motif « account switcher »)
  // =========================================================================

  group('WalletController – createWallet', () {
    test('crée un wallet, le persiste et l\'ajoute à la liste', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.wallets.length, 1); // wallet par défaut

      final created = await controller.createWallet('  Nouveau patrimoine  ');

      // Le nom est trim() (cf. Wallet créé par createWallet).
      expect(created.name, 'Nouveau patrimoine');
      expect(controller.wallets.length, 2);
      expect(controller.wallets.any((w) => w.id == created.id), true);

      // Persisté réellement en base : un rechargement le retrouve.
      final reloaded = await AccountStorage(database: db).getAllWallets();
      expect(reloaded.any((w) => w.id == created.id), true);
    });

    test('ne sélectionne PAS automatiquement le wallet créé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final controller = _makeController(db: db);
      await controller.loadAllData();
      final activeBefore = controller.activeWallet?.id;

      await controller.createWallet('Autre patrimoine');

      // L'appelant enchaîne explicitement selectWallet : createWallet seul ne
      // change pas l'actif.
      expect(controller.activeWallet?.id, activeBefore);
    });
  });

  group('WalletController – renameWallet', () {
    test('renomme, persiste et patch en mémoire SANS reload destructif',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithInvestment(
        db: db,
        walletId: 'w-rename',
        walletName: 'Ancien nom',
        accountId: 'acc-rename',
        accountName: 'PEA',
        symbol: 'RENA',
        quantity: '1',
      );

      final fakeMarket = _FakeMarketDataService(
        quotesBySymbol: {
          'RENA': AssetQuoteData(symbol: 'RENA', price: 42.0, currency: 'EUR'),
        },
      );
      final controller = _makeController(db: db, marketService: fakeMarket);
      await controller.loadAllData();

      final wallet = controller.wallets.first;
      final accountsBefore = controller.accounts;

      await controller.renameWallet(wallet, 'Nouveau nom');

      expect(controller.wallets.first.name, 'Nouveau nom');
      expect(controller.activeWallet?.name, 'Nouveau nom');
      // Pas de loadAllData déclenché : la même liste de comptes (identité de
      // référence) reste en place, preuve qu'aucun rechargement n'a eu lieu.
      expect(identical(controller.accounts, accountsBefore), true);

      final reloaded = await AccountStorage(database: db).getAllWallets();
      expect(reloaded.first.name, 'Nouveau nom');
      // createdAt préservé (pas régénéré au renommage).
      expect(reloaded.first.createdAt, wallet.createdAt);
    });

    test('renomme un wallet NON actif : activeWallet inchangé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-ren-a', name: 'Wallet A');
      final walletB = Wallet(id: 'w-ren-b', name: 'Wallet B');
      await storage.saveWallet(walletA);
      await storage.saveWallet(walletB);

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.activeWallet?.id, 'w-ren-a');

      await controller.renameWallet(walletB, 'Wallet B renommé');

      expect(controller.activeWallet?.id, 'w-ren-a');
      expect(controller.activeWallet?.name, 'Wallet A');
      expect(
        controller.wallets.firstWhere((w) => w.id == 'w-ren-b').name,
        'Wallet B renommé',
      );
    });
  });

  group('WalletController – hideWallet/restoreWallet/commitDeleteWallet', () {
    test('hideWallet retire de la liste visible sans toucher au stockage',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-hide-a', name: 'A');
      final walletB = Wallet(id: 'w-hide-b', name: 'B');
      await storage.saveWallet(walletA);
      await storage.saveWallet(walletB);

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.wallets.length, 2);

      final hidden = controller.hideWallet('w-hide-b');
      expect(hidden?.id, 'w-hide-b');
      expect(controller.wallets.length, 1);
      expect(controller.wallets.any((w) => w.id == 'w-hide-b'), false);

      // Toujours présent en base tant que la suppression n'est pas validée.
      final stillStored = await storage.getAllWallets();
      expect(stillStored.any((w) => w.id == 'w-hide-b'), true);
    });

    test('hideWallet refuse de masquer le dernier wallet visible', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      await setupSingleWalletWithCash(
        db: db,
        walletId: 'w-only',
        accountId: 'acc-only',
        cashBalance: 100.0,
      );

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.wallets.length, 1);

      final hidden = controller.hideWallet('w-only');
      expect(hidden, isNull);
      expect(controller.wallets.length, 1);
    });

    test('restoreWallet ré-affiche le wallet masqué', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-rest-a', name: 'A');
      final walletB = Wallet(id: 'w-rest-b', name: 'B');
      await storage.saveWallet(walletA);
      await storage.saveWallet(walletB);

      final controller = _makeController(db: db);
      await controller.loadAllData();

      final hidden = controller.hideWallet('w-rest-b')!;
      expect(controller.wallets.length, 1);

      controller.restoreWallet(hidden);
      expect(controller.wallets.length, 2);
      expect(controller.wallets.any((w) => w.id == 'w-rest-b'), true);
    });

    test('restoreWallet est idempotent (aucun doublon si déjà présent)',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-idem-a', name: 'A');
      await storage.saveWallet(walletA);

      final controller = _makeController(db: db);
      await controller.loadAllData();

      // Wallet jamais masqué : restoreWallet ne doit rien dupliquer.
      controller.restoreWallet(walletA);
      expect(controller.wallets.length, 1);
    });

    test('commitDeleteWallet supprime réellement le wallet masqué du stockage',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-commit-a', name: 'A');
      final walletB = Wallet(id: 'w-commit-b', name: 'B');
      await storage.saveWallet(walletA);
      await storage.saveWallet(walletB);

      final controller = _makeController(db: db);
      await controller.loadAllData();

      final hidden = controller.hideWallet('w-commit-b')!;
      await controller.commitDeleteWallet(hidden);

      final stored = await storage.getAllWallets();
      expect(stored.any((w) => w.id == 'w-commit-b'), false);
      expect(controller.wallets.any((w) => w.id == 'w-commit-b'), false);
    });

    test(
        'commitDeleteWallet du wallet ACTIF : loadAllData bascule l\'actif sur '
        'le premier restant', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-active-a', name: 'A');
      final walletB = Wallet(id: 'w-active-b', name: 'B');
      await storage.saveWallet(walletA);
      await storage.saveWallet(walletB);

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.activeWallet?.id, 'w-active-a');

      final hidden = controller.hideWallet('w-active-a')!;
      await controller.commitDeleteWallet(hidden);

      expect(controller.activeWallet?.id, 'w-active-b');
      expect(controller.wallets.length, 1);
    });

    test('commitDeleteWallet est idempotent (sans effet si non masqué)',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-noop-a', name: 'A');
      final walletB = Wallet(id: 'w-noop-b', name: 'B');
      await storage.saveWallet(walletA);
      await storage.saveWallet(walletB);

      final controller = _makeController(db: db);
      await controller.loadAllData();

      // Jamais masqué : commitDeleteWallet doit être un no-op (garde
      // d'idempotence), le wallet reste en base et dans la liste.
      await controller.commitDeleteWallet(walletB);

      final stored = await storage.getAllWallets();
      expect(stored.any((w) => w.id == 'w-noop-b'), true);
      expect(controller.wallets.any((w) => w.id == 'w-noop-b'), true);
    });

    test(
        'commit après restauration (Annuler) : le wallet restauré n\'est PAS '
        'supprimé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      final walletA = Wallet(id: 'w-undo-a', name: 'A');
      final walletB = Wallet(id: 'w-undo-b', name: 'B');
      await storage.saveWallet(walletA);
      await storage.saveWallet(walletB);

      final controller = _makeController(db: db);
      await controller.loadAllData();

      final hidden = controller.hideWallet('w-undo-b')!;
      // L'utilisateur annule avant la fermeture du snackbar.
      controller.restoreWallet(hidden);
      // Le commit différé arrive quand même (fermeture du snackbar) : la
      // garde d'idempotence doit l'empêcher de supprimer un wallet restauré.
      await controller.commitDeleteWallet(hidden);

      final stored = await storage.getAllWallets();
      expect(stored.any((w) => w.id == 'w-undo-b'), true);
      expect(controller.wallets.any((w) => w.id == 'w-undo-b'), true);
    });

    // =======================================================================
    // Correctif M-1 — perte silencieuse de données pendant la fenêtre
    // d'annulation d'une suppression de wallet actif
    // =======================================================================

    test(
        'M-1 : masquer le wallet ACTIF ferme la fenêtre d\'écriture — un '
        'createAccount vise le nouvel actif et SURVIT au commit', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: 'w-m1-a', name: 'A'));
      await storage.saveWallet(Wallet(id: 'w-m1-b', name: 'B'));
      // Un compte cash sous chaque wallet : _accounts est non vide → le reload
      // déclenché par hideWallet passe en mode non destructif (isRefreshing).
      await storage.saveAccount(Account(
        id: 'acc-m1-a', walletId: 'w-m1-a', name: 'Cpt A',
        kind: AccountKind.cash, cashBalance: 100.0,
      ));
      await storage.saveAccount(Account(
        id: 'acc-m1-b', walletId: 'w-m1-b', name: 'Cpt B',
        kind: AccountKind.cash, cashBalance: 200.0,
      ));

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.activeWallet?.id, 'w-m1-a');

      // Suppression différée du wallet ACTIF (A).
      final hidden = controller.hideWallet('w-m1-a')!;
      // Bascule SYNCHRONE : l'actif n'est déjà plus A (fenêtre d'écriture
      // fermée avant toute saisie).
      expect(controller.activeWallet?.id, 'w-m1-b');

      // Pendant la fenêtre d'annulation, l'utilisateur crée un compte. Il DOIT
      // viser le nouvel actif (B), jamais le wallet en cours de suppression (A).
      final created = await controller.createAccount(
        name: 'Saisi pendant la fenêtre',
        kind: AccountKind.cash,
        cashBalance: 500.0,
      );
      expect(created.walletId, 'w-m1-b',
          reason: 'createAccount doit écrire sous le nouvel actif B, pas A');

      // La fenêtre expire SANS annulation → suppression réelle de A (cascade).
      await controller.commitDeleteWallet(hidden);

      // A est bien supprimé…
      final storedWallets = await storage.getAllWallets();
      expect(storedWallets.any((w) => w.id == 'w-m1-a'), false);
      // …mais le compte saisi pendant la fenêtre a SURVÉCU (rattaché à B, hors
      // du périmètre de la cascade). C'est le cœur du correctif M-1 : sans la
      // bascule, ce compte aurait été créé sous A et détruit par la cascade.
      final bAccounts = await storage.getAccountsByWallet('w-m1-b');
      expect(bAccounts.any((a) => a.id == created.id), true,
          reason: 'le compte saisi dans la fenêtre ne doit pas être détruit '
              'par la cascade de suppression de A');
      expect(controller.activeWallet?.id, 'w-m1-b');
    });

    test(
        'M-1 symétrie : annuler la suppression du wallet actif rebascule '
        'l\'actif sur ce wallet', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: 'w-m1r-a', name: 'A'));
      await storage.saveWallet(Wallet(id: 'w-m1r-b', name: 'B'));
      await storage.saveAccount(Account(
        id: 'acc-m1r-a', walletId: 'w-m1r-a', name: 'CA',
        kind: AccountKind.cash, cashBalance: 10.0,
      ));
      await storage.saveAccount(Account(
        id: 'acc-m1r-b', walletId: 'w-m1r-b', name: 'CB',
        kind: AccountKind.cash, cashBalance: 20.0,
      ));

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.activeWallet?.id, 'w-m1r-a');

      // Masque l'actif A → bascule synchrone vers B.
      final hidden = controller.hideWallet('w-m1r-a')!;
      expect(controller.activeWallet?.id, 'w-m1r-b');

      // L'utilisateur annule : l'actif redevient A (état perçu au moment de la
      // suppression), de façon SYNCHRONE.
      controller.restoreWallet(hidden);
      expect(controller.activeWallet?.id, 'w-m1r-a');
      expect(controller.wallets.any((w) => w.id == 'w-m1r-a'), true);
      expect(controller.wallets.length, 2);
    });

    test(
        'M-1 : masquer un wallet NON actif ne déplace PAS l\'actif', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: 'w-m1n-a', name: 'A'));
      await storage.saveWallet(Wallet(id: 'w-m1n-b', name: 'B'));

      final controller = _makeController(db: db);
      await controller.loadAllData();
      expect(controller.activeWallet?.id, 'w-m1n-a');

      // Masque B (NON actif) : l'actif A doit rester inchangé.
      final hidden = controller.hideWallet('w-m1n-b')!;
      expect(controller.activeWallet?.id, 'w-m1n-a');

      // Annuler ne doit pas non plus toucher l'actif.
      controller.restoreWallet(hidden);
      expect(controller.activeWallet?.id, 'w-m1n-a');
    });
  });

  // =========================================================================
  // Correctif I2 — snapshot sous le mauvais wallet
  // =========================================================================

  group('WalletController – snapshot sous bon wallet (I2)', () {
    test(
        'changement de wallet pendant _loadHistory : snapshot non écrit sous le nouveau wallet',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);

      final storage = AccountStorage(database: db);

      final wallet1 = Wallet(id: 'w-i2-a', name: 'Wallet I2-A');
      final wallet2 = Wallet(id: 'w-i2-b', name: 'Wallet I2-B');
      await storage.saveWallet(wallet1);
      await storage.saveWallet(wallet2);

      final account1 = Account(
        id: 'acc-i2-a', walletId: 'w-i2-a', name: 'PEA A', kind: AccountKind.autre,
      );
      final account2 = Account(
        id: 'acc-i2-b', walletId: 'w-i2-b', name: 'PEA B', kind: AccountKind.autre,
      );
      await storage.saveAccount(account1);
      await storage.saveAccount(account2);

      final asset1 = Asset(symbol: 'I2SYM', currency: 'EUR');
      final pos1 = Position(accountId: 'acc-i2-a', asset: asset1, quantity: '3');
      final asset2 = Asset(symbol: 'I2SYM2', currency: 'EUR');
      final pos2 = Position(accountId: 'acc-i2-b', asset: asset2, quantity: '1');
      await storage.savePosition('acc-i2-a', pos1);
      await storage.savePosition('acc-i2-b', pos2);

      // Completer qui bloque sur l'historique du wallet1.
      final histCompleter = Completer<AssetHistoricalData?>();

      final fakeMarket = _DelayedMarketDataService(
        historyCompleter: histCompleter,
        quotesBySymbol: {
          'I2SYM': AssetQuoteData(symbol: 'I2SYM', price: 100.0, currency: 'EUR'),
          'I2SYM2': AssetQuoteData(symbol: 'I2SYM2', price: 200.0, currency: 'EUR'),
        },
      );
      final fakeSnap = _FakeSnapshotStorage();

      final controller = _makeController(
        db: db,
        marketService: fakeMarket,
        snapshotStorage: fakeSnap,
      );

      // Chargement initial (wallet1 actif) — restera bloqué sur _loadHistory.
      final loadFuture = controller.loadAllData();

      // Pendant le délai, l'utilisateur bascule sur wallet2.
      // selectWallet appelle loadAllData() en interne, qui sera bloqué aussi.
      final selectFuture = controller.selectWallet(wallet2);

      // Débloque les deux loadAllData() en attente.
      histCompleter.complete(null);

      await Future.wait([loadFuture, selectFuture]);

      expect(controller.activeWallet?.id, 'w-i2-b');

      // Vérification principale : aucun snapshot du wallet1 ne doit être
      // écrit sous l'id wallet2.
      final snapsW2 = fakeSnap._store['w-i2-b'] ?? [];
      final snapsW1 = fakeSnap._store['w-i2-a'] ?? [];
      // S'il y a un snapshot sous w-i2-b, il ne doit pas avoir été produit
      // par le chargement du wallet1 (valeur = 3×100 = 300 EUR).
      for (final snap in snapsW2) {
        expect(snap.totalValue, isNot(closeTo(300.0, 1e-6)),
            reason:
                'Le total du wallet1 (300 EUR) ne doit pas être persisté sous wallet2');
      }
      // Et aucun snapshot du wallet2 ne doit être stocké sous wallet1.
      for (final snap in snapsW1) {
        expect(snap.totalValue, isNot(closeTo(200.0, 1e-6)),
            reason:
                'Le total du wallet2 (200 EUR) ne doit pas être persisté sous wallet1');
      }
    });
  });
}

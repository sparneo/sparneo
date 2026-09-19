// test/widgets/wallet_view_test.dart
//
// Test bout-en-bout (R4, contre-revue architecte du lot suppression de
// compte) : création d'un compte titres via le flux normal de WalletView,
// PUIS suppression depuis la page ouverte (corbeille ⋮ d'AccountView) —
// c'est la non-régression du bug RÉELLEMENT vécu par l'auteur (un
// Navigator.push nu, sans regarder le résultat de la page ouverte, avalait
// silencieusement une suppression confirmée depuis AccountView). Sans ce
// test, un futur retour à cette forme rouvrirait le bug sans qu'aucune suite
// ne le détecte.
//
// Navigation RÉELLE entre WalletView et AccountView (pas de mock de la
// route) : nécessite que les DEUX contrôleurs pointent la MÊME base — via
// les seams [WalletView.debugController] et
// [WalletView.debugAccountViewBuilder] (celui-ci construit un
// [AccountView] avec son propre [AccountController], `debugAutoInit: true`,
// car l'id du compte créé n'est connu qu'au moment de l'ouverture, pendant
// le test lui-même — impossible à précharger comme le fait
// account_view_test.dart).
//
// Point technique clé : ouvrir/interagir avec une base SQLite réelle À
// L'INTÉRIEUR d'un testWidgets (zone à horloge factice) est connu pour
// bloquer indéfiniment avec la factory ffi ISOLÉE (databaseFactoryFfi,
// dart:isolate/_RawReceivePort — cf. account_view_test.dart,
// statement_import_page_test.dart). On l'évite ENTIÈREMENT ici en utilisant
// [databaseFactoryFfiNoIsolate] (pas de messagerie d'isolat, FFI synchrone
// in-process) : les interactions pilotées par tap+pump peuvent donc déclencher
// de VRAIS accès disque (en mémoire) sans risque de blocage, contrairement à
// la convention habituelle de ce projet qui préfère des fakes en mémoire pour
// les tests interactifs.
//
// Pas d'appel réseau : services de marché/change fakes.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/controllers/chart_mode_controller.dart';
import 'package:portfolio_tracker/controllers/wallet_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/allocation_target_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/widgets/account_view.dart';
import 'package:portfolio_tracker/widgets/wallet_view.dart';

// ---------------------------------------------------------------------------
// Fakes (pas d'appels réseau) — mêmes motifs que wallet_controller_test.dart
// / account_view_test.dart.
// ---------------------------------------------------------------------------

class _FakeExchangeRateService extends ExchangeRateService {
  _FakeExchangeRateService() : super.forTesting();

  @override
  Future<double> getUsdToEurRate() async => 0.92;

  @override
  Future<double> getRateToEur(String currency) async {
    if (currency.toUpperCase() == 'EUR') return 1.0;
    return 0.92;
  }
}

class _FakeMarketDataService extends MarketDataService {
  _FakeMarketDataService(super.exchange) : super.forTesting();

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async => null;

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(
    Asset asset, {
    int days = 30,
  }) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalData(
    String symbol, {
    int days = 30,
  }) async => null;
}

// ---------------------------------------------------------------------------
// Base de test SANS isolat (R4) — DISTINCTE de test/helpers/test_database.dart
// (databaseFactoryFfi, isolée), qui reste inchangée pour tous les autres
// tests. Locale à ce fichier : le risque de blocage propre à la factory
// isolée sous testWidgets ne concerne QUE les tests qui, comme celui-ci,
// interagissent réellement (tap+pump) pendant que la base est sollicitée.
// ---------------------------------------------------------------------------

Future<AppDatabase> _openNoIsolateTestDatabase() async {
  sqfliteFfiInit();
  final db = AppDatabase(
    factory: databaseFactoryFfiNoIsolate,
    path: inMemoryDatabasePath,
  );
  await db.database;
  return db;
}

const _walletId = 'wallet-1';
const _existingAccountId = 'account-existing';

/// Peuple la base avec UN wallet et UN compte préexistant — nécessaire pour
/// que la garde « dernier compte » (delete_account_dialog.dart,
/// `totalAccountCount <= 1`) n'intercepte pas la suppression du compte créé
/// pendant le test (2 comptes au moment de la suppression, pas 1).
Future<void> _seedWalletWithOneAccount(AppDatabase db) async {
  final storage = AccountStorage(database: db);
  await storage.saveWallet(Wallet(id: _walletId, name: 'Mon Patrimoine'));
  await storage.saveAccount(
    Account(
      id: _existingAccountId,
      walletId: _walletId,
      name: 'Compte existant',
      kind: AccountKind.cto,
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChartModeController.resetSharedForTest();
  });

  testWidgets(
    'création puis suppression d\'un compte titres depuis la corbeille ⋮ '
    'd\'AccountView (filet D1/R4) : le compte quitte la liste ET le stockage',
    (tester) async {
      final db = await _openNoIsolateTestDatabase();
      addTearDown(db.close);
      await _seedWalletWithOneAccount(db);

      final exchange = _FakeExchangeRateService();
      final market = _FakeMarketDataService(exchange);

      final walletCtrl = WalletController(
        storage: AccountStorage(database: db),
        allocationTargetStorage: AllocationTargetStorage(database: db),
        marketService: market,
        exchangeService: exchange,
        transactionStorage: TransactionStorage(database: db),
        ledgerService: LedgerService(database: db),
      );

      final app = MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('fr'),
        home: WalletView(
          debugController: walletCtrl,
          // R4 : remplace la construction normale d'AccountView (qui viserait
          // AppDatabase.shared(), le stockage de PRODUCTION) par un contrôleur
          // fraîchement construit sur la MÊME base de test, auto-initialisé
          // (l'id n'est connu qu'à l'ouverture, ici, pendant le test).
          debugAccountViewBuilder: (accountId) => AccountView(
            debugController: AccountController(
              initialAccountId: accountId,
              storage: AccountStorage(database: db),
              ledgerService: LedgerService(database: db),
              marketService: market,
              exchangeService: exchange,
              transactionStorage: TransactionStorage(database: db),
              initialUsdToEurRate: 0.92,
            ),
            debugAutoInit: true,
          ),
        ),
      );

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      // --- Étape 1 : création d'un compte titres via le flux normal -------
      await tester.tap(find.byTooltip('Ajouter un compte'));
      await tester.pumpAndSettle();

      expect(find.text('Nouveau compte'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Compte titres E2E');
      // Nature par défaut (AccountKind.autre) → AccountType.investment : déjà
      // un compte NON cash, aucune interaction avec le menu déroulant requise.
      await tester.tap(find.widgetWithText(ElevatedButton, 'Créer'));
      await tester.pumpAndSettle();

      // La création a navigué vers AccountView (nature non-cash) : son
      // AppBar affiche le nom du compte fraîchement créé.
      expect(find.text('Compte titres E2E'), findsOneWidget);

      final createdAccount = walletCtrl.accounts.firstWhere(
        (a) => a.name == 'Compte titres E2E',
      );

      // --- Étape 2 : suppression depuis la corbeille ⋮ d'AccountView ------
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Supprimer le compte'), findsOneWidget);
      await tester.tap(find.text('Supprimer le compte'));
      await tester.pumpAndSettle();

      // Dialogue de confirmation (delete_account_dialog.dart).
      expect(
        find.textContaining('Compte titres E2E'),
        findsWidgets,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
      await tester.pumpAndSettle();

      // Retour sur WalletView : le compte est immédiatement masqué de la
      // liste affichée (suppression différée, fenêtre « Annuler »), mais PAS
      // encore supprimé du stockage.
      expect(
        walletCtrl.accounts.any((a) => a.id == createdAccount.id),
        isFalse,
        reason:
            'le compte doit quitter la liste affichée dès la confirmation, '
            'sans attendre la fin de la fenêtre d\'annulation',
      );
      final stillStored = await AccountStorage(
        database: db,
      ).getAccount(createdAccount.id);
      expect(
        stillStored,
        isNotNull,
        reason:
            'la suppression réelle en base doit attendre la fin de la '
            'fenêtre d\'annulation (snackbar), pas être immédiate',
      );

      // --- Étape 3 : passé la fenêtre d'annulation (4 s), le commit a lieu -
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      final deleted = await AccountStorage(
        database: db,
      ).getAccount(createdAccount.id);
      expect(
        deleted,
        isNull,
        reason:
            'le compte doit avoir quitté le STOCKAGE après la fenêtre '
            'd\'annulation — c\'est le bug vécu par l\'auteur (une '
            'suppression confirmée depuis AccountView, avalée par un '
            'Navigator.push nu qui n\'inspectait jamais le résultat)',
      );
      expect(walletCtrl.accounts.any((a) => a.id == createdAccount.id), isFalse);
    },
  );
}

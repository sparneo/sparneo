// test/widgets/account_view_test.dart
//
// Tests WIDGET du repli « compte cash » d'AccountView (B8 lot 3, doc 19 §4.5,
// §7 Lot 3) : un compte cash (livret, compte courant) ouvre désormais la MÊME
// page qu'un compte titres, mais avec « Mes positions » masquée et le solde
// espèces promu comme valeur mise en avant du compte.
//
// Pas d'appel réseau : fakes en mémoire pour MarketDataService, taux de
// change injecté directement (initialUsdToEurRate). Persistance via une base
// SQLite in-memory isolée (mêmes fakes que account_controller_test.dart).
//
// AccountView ouvre normalement une base réelle dans initState()
// (AccountController.initAccounts()) : ouvrir une base réelle À L'INTÉRIEUR
// d'un testWidgets est connu pour bloquer indéfiniment (dart:isolate,
// _RawReceivePort._handleMessage — cf. statement_import_page_test.dart). On
// contourne via [AccountView.debugController] (réservé aux tests) : le
// contrôleur est construit et entièrement chargé via [tester.runAsync] (zone
// asynchrone réelle, hors du pompage à horloge factice) — TOUT accès disque
// (ouverture ET fermeture de la base) reste à l'intérieur de ce
// [tester.runAsync], y compris au teardown — PUIS le contrôleur déjà prêt est
// injecté : la vue ne déclenche alors plus aucun accès disque lors du
// pumpWidget.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/widgets/account_view.dart';
import 'package:portfolio_tracker/widgets/charts/period_selector.dart';

import '../helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Fake MarketDataService (sans réseau) — même motif que
// test/controllers/account_controller_test.dart.
// ---------------------------------------------------------------------------

class _FakeMarketDataService extends MarketDataService {
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
// Helpers de construction
// ---------------------------------------------------------------------------

const _walletId = 'wallet-1';
const _accountId = 'account-1';

/// Peuple la base in-memory avec un wallet et un compte de la nature donnée.
Future<void> _seedAccount(
  AppDatabase db, {
  required AccountKind kind,
  double? cashBalance,
}) async {
  final storage = AccountStorage(database: db);
  await storage.saveWallet(Wallet(id: _walletId, name: 'Test Wallet'));
  await storage.saveAccount(
    Account(
      id: _accountId,
      walletId: _walletId,
      name: 'Compte test',
      kind: kind,
      cashBalance: cashBalance,
    ),
  );
}

Widget _host(AccountController ctrl) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('fr'),
  home: AccountView(debugController: ctrl),
);

/// Construit et charge ENTIÈREMENT un [AccountController] sur la base
/// [db] (fakes, aucun réseau).
Future<AccountController> _loadedCtrl(AppDatabase db) async {
  final ctrl = AccountController(
    initialAccountId: _accountId,
    initialUsdToEurRate: 0.92,
    storage: AccountStorage(database: db),
    ledgerService: LedgerService(database: db),
    transactionStorage: TransactionStorage(database: db),
    marketService: _FakeMarketDataService(),
  );
  await ctrl.initAccounts();
  return ctrl;
}

/// Ouvre la base, la peuple via [seed], charge le contrôleur et enregistre la
/// fermeture en teardown — le TOUT à l'intérieur de [tester.runAsync] (zone
/// asynchrone réelle), à l'ouverture COMME à la fermeture (cf. commentaire
/// d'en-tête : ouvrir/fermer une base réelle dans la zone à horloge factice
/// d'un testWidgets bloque indéfiniment).
Future<AccountController> _setUpAccount(
  WidgetTester tester, {
  required Future<void> Function(AppDatabase db) seed,
}) async {
  late AppDatabase db;
  late AccountController ctrl;
  await tester.runAsync(() async {
    db = await openTestDatabase();
    await seed(db);
    ctrl = await _loadedCtrl(db);
  });
  addTearDown(() => tester.runAsync(db.close));
  return ctrl;
}

void main() {
  group('AccountView — repli compte cash (B8 lot 3)', () {
    testWidgets(
      'masque « Mes positions » et son bouton d\'ajout sur un compte cash',
      (tester) async {
        final ctrl = await _setUpAccount(
          tester,
          seed: (db) =>
              _seedAccount(db, kind: AccountKind.cash, cashBalance: 500),
        );

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.myPositions), findsNothing);
        expect(find.text(l10n.addPositionTooltip), findsNothing);
        expect(find.text(l10n.emptyPositionsTitle), findsNothing);
      },
    );

    testWidgets(
      'un compte TITRES (non-cash) continue d\'afficher « Mes positions » '
      '(non-régression)',
      (tester) async {
        final ctrl = await _setUpAccount(
          tester,
          seed: (db) async {
            await _seedAccount(db, kind: AccountKind.cto);
            final storage = AccountStorage(database: db);
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(symbol: 'AAA', name: 'Asset AAA', currency: 'EUR'),
                quantity: '10',
              ),
            );
          },
        );

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.myPositions), findsOneWidget);
      },
    );

    testWidgets('le bouton journal est présent sur un compte cash', (
      tester,
    ) async {
      final ctrl = await _setUpAccount(
        tester,
        seed: (db) =>
            _seedAccount(db, kind: AccountKind.cash, cashBalance: 100),
      );

      await tester.pumpWidget(_host(ctrl));
      await tester.pumpAndSettle();

      // Bouton journal : icône « receipt_long » de la barre d'app (déjà
      // inconditionnel avant B8, doc 19 §4.5). La navigation réelle vers
      // AccountJournalPage n'est PAS exercée ici : cette page ouvre elle
      // aussi sa propre base par défaut dans son initState, ce qui
      // reproduirait le blocage documenté ci-dessus si on la pumpait. Les 4
      // kinds espèces qu'elle propose (deposit/withdrawal/interest/charge,
      // sans buy/sell) sont vérifiés par lecture de code (account_journal_
      // page.dart:213, allowedKinds — aucune condition sur account.kind/type
      // dans tout le fichier, confirmé par grep) : ce lot ne les modifie pas.
      expect(find.byIcon(Icons.receipt_long), findsOneWidget);
    });

    testWidgets('compte cash NON ancré : action « Définir le solde initial… » '
        'proposée, pas « Ajuster… » — et la valeur legacy (cash_balance) est '
        'affichée', (tester) async {
      final ctrl = await _setUpAccount(
        tester,
        seed: (db) =>
            _seedAccount(db, kind: AccountKind.cash, cashBalance: 500),
      );

      expect(ctrl.hasCashAnchor, isFalse);

      await tester.pumpWidget(_host(ctrl));
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
      expect(find.text(l10n.setInitialCashBalanceAction), findsOneWidget);
      expect(find.text(l10n.adjustCashBalanceAction), findsNothing);

      // Régime legacy : TotalValueCard reflète `cash_balance` (500 €), la
      // seule source de vérité tant qu'aucun ancrage n'existe (doc 19 §3).
      expect(find.textContaining(RegExp(r'500,00\s€')), findsWidgets);
    });

    testWidgets(
      'compte cash ANCRÉ : action « Ajuster… » proposée, pas « Définir le '
      'solde initial… » — et la valeur dérivée du journal est affichée',
      (tester) async {
        final ctrl = await _setUpAccount(
          tester,
          seed: (db) async {
            await _seedAccount(db, kind: AccountKind.cash);
            final ledger = LedgerService(database: db);
            await ledger.emitCashOpeningBalance(
              accountId: _accountId,
              amount: '1000',
              currency: 'EUR',
              date: DateTime.now().subtract(const Duration(days: 60)),
            );
          },
        );

        expect(ctrl.hasCashAnchor, isTrue);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.adjustCashBalanceAction), findsOneWidget);
        expect(find.text(l10n.setInitialCashBalanceAction), findsNothing);

        // Régime journalisé : TotalValueCard reflète le cash DÉRIVÉ (1 000 €),
        // pas `cash_balance` (resté null ici).
        expect(find.textContaining(RegExp(r'1\s000,00\s€')), findsWidgets);

        // Bonus (fix de gating dans ce lot) : la section graphique du compte
        // s'affiche désormais pour un compte cash ancré (grille synthétique du
        // journal, B8 doc 19 §4.3/4.4) — auparavant gatée sur positionsData
        // (toujours vide pour un compte cash), donc jamais visible.
        expect(find.byType(PeriodSelector), findsOneWidget);

        // Le sélecteur Performance/Évolution réelle est MASQUÉ sur un compte
        // cash : le mode « Performance » y est TOUJOURS une droite plate au
        // solde actuel (aucune position à faire varier), donc un choix dont
        // une branche est tautologiquement inutile — le mode réel est forcé
        // sans qu'il y ait de bascule à proposer (retour manuel du 28/07).
        expect(ctrl.hasRealCurve, isTrue);
        expect(find.byType(SegmentedButton<bool>), findsNothing);
        expect(find.text(l10n.chartModePerformance), findsNothing);
        expect(find.text(l10n.chartModeRealEvolution), findsNothing);
      },
    );
  });
}

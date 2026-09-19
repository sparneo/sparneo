// test/widgets/account_view_test.dart
//
// Tests WIDGET du repli « compte cash » d'AccountView (B8 lot 3, conception
// interne Lot 3) : un compte cash (livret, compte courant) ouvre désormais la
// MÊME page qu'un compte titres, mais avec « Mes positions » masquée et le solde
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

import 'package:shared_preferences/shared_preferences.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/controllers/chart_mode_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/widgets/charts/inline_links_caption.dart';
import 'package:portfolio_tracker/widgets/initial_position_dialog.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/account_view.dart';
import 'package:portfolio_tracker/widgets/charts/period_selector.dart';
import 'package:portfolio_tracker/widgets/position_detail_page.dart';
import 'package:portfolio_tracker/widgets/total_value_card.dart';

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

/// Fake fournissant un historique de cours pour UN symbole donné (les autres
/// méthodes restent des no-op réseau, comme [_FakeMarketDataService]) —
/// nécessaire pour peupler `chartDates`/`hasRealCurve` (cf. [_seedNoBasis
/// Position] : sans historique, [AccountController._computeAccountRealCurve]
/// s'arrête tôt sur `_chartDates.isEmpty`, et `realNoBasisSymbols` ne serait
/// jamais calculé).
class _FakeMarketDataServiceWithHistory extends MarketDataService {
  final String symbol;
  final List<DateTime> dates;
  final List<num> prices;

  /// Cotations COURANTES par symbole, pour les tests qui ont besoin d'une
  /// valeur de compte non nulle (couverture de la courbe réelle : sans
  /// cotation, `currentTotalValueEur` vaut 0 et le ratio est `null`). Vide
  /// par défaut : les tests antérieurs gardent leur comportement.
  final Map<String, double> quotePrices;

  _FakeMarketDataServiceWithHistory({
    required this.symbol,
    required this.dates,
    required this.prices,
    this.quotePrices = const {},
  });

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async {
    final price = quotePrices[asset.symbol];
    if (price == null) return null;
    return AssetQuoteData(
      symbol: asset.symbol,
      name: asset.symbol,
      price: price,
      change: 0,
      changePercent: 0,
      currency: asset.currency,
    );
  }

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(
    Asset asset, {
    int days = 30,
  }) async {
    if (asset.symbol != symbol) return null;
    return AssetHistoricalData(symbol: symbol, dates: dates, prices: prices);
  }

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
/// [db] (fakes, aucun réseau). [marketService] injectable (défaut : aucune
/// donnée, cf. [_FakeMarketDataService]) — utilisé par les tests qui ont
/// besoin d'un historique de cours réel (mode 2, cf.
/// [_FakeMarketDataServiceWithHistory]).
Future<AccountController> _loadedCtrl(
  AppDatabase db, {
  MarketDataService? marketService,
}) async {
  final ctrl = AccountController(
    initialAccountId: _accountId,
    initialUsdToEurRate: 0.92,
    storage: AccountStorage(database: db),
    ledgerService: LedgerService(database: db),
    transactionStorage: TransactionStorage(database: db),
    marketService: marketService ?? _FakeMarketDataService(),
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
  MarketDataService? marketService,
}) async {
  late AppDatabase db;
  late AccountController ctrl;
  await tester.runAsync(() async {
    db = await openTestDatabase();
    await seed(db);
    ctrl = await _loadedCtrl(db, marketService: marketService);
  });
  addTearDown(() => tester.runAsync(db.close));
  return ctrl;
}

void main() {
  // Le mode de courbe est désormais une PRÉFÉRENCE D'APPAREIL persistée dans
  // un singleton de PROCESS ([ChartModeController]) : sans cette remise à zéro
  // entre chaque test, le premier qui bascule le sélecteur (« la puce reste
  // visible en mode Vos positions… ») imposerait son choix à TOUS les suivants
  // du fichier — constaté : la caption d'exclusion disparaissait trois tests
  // plus loin, faute d'être encore en mode réel. Le mock SharedPreferences est
  // posé en même temps : sans lui, la persistance déclenchée par un tap sur le
  // sélecteur partirait sur le vrai plugin (absent en test).
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChartModeController.resetSharedForTest();
  });

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

    testWidgets(
      'compte TITRES (non-cash) : « Valeur totale » inclut le cash dérivé du '
      'journal, pas seulement les positions (régression — le cash était '
      'silencieusement omis, désynchronisant le header de la ligne '
      '« Espèces » et de la courbe Évolution réelle)',
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
            final ledger = LedgerService(database: db);
            await ledger.emitCashOpeningBalance(
              accountId: _accountId,
              amount: '250',
              currency: 'EUR',
              date: DateTime.now().subtract(const Duration(days: 30)),
            );
          },
        );

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        // _FakeMarketDataService ne fournit aucune cotation : les positions
        // valent 0 dans ce test, donc la « Valeur totale » attendue est
        // EXACTEMENT le cash dérivé (250 €) — avant le fix, ce cash était
        // omis et le header affichait 0.
        expect(find.textContaining(RegExp(r'250,00\s€')), findsWidgets);
      },
    );

    testWidgets(
      'compte TITRES NON ancré (buy seuls) : « Valeur totale » = somme des '
      'positions, le cash dérivé NÉGATIF FICTIF est exclu (régression — il '
      'était retranché silencieusement, sans rien à l\'écran pour '
      'l\'expliquer, la ligne « dont espèces » étant elle-même muette faute '
      'd\'ancrage)',
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
            // Aucun mouvement d'espèces au journal : l'achat seul projette un
            // cash de −900, purement mécanique (invariant « faux négatif
            // interdit », design cash-ledger §6.7).
            final ledger = LedgerService(database: db);
            await ledger.recordTransaction(
              AssetTransaction(
                id: 'tx-buy-noanchor',
                accountId: _accountId,
                symbol: 'AAA',
                kind: TransactionKind.buy,
                quantity: '10',
                unitPrice: '90',
                amount: '-900',
                currency: 'EUR',
                date: DateTime(2025, 1, 10),
              ),
            );
          },
        );

        expect(ctrl.hasCashAnchor, isFalse);
        // Le cache `accounts.derived_cash` est renseigné MÊME sans ancrage :
        // c'est bien la garde, et non la nullité du champ, qui protège.
        expect(double.parse(ctrl.derivedCash!), closeTo(-900.0, 1e-9));

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        // _FakeMarketDataService ne fournit aucune cotation : les positions
        // valent 0, donc la « Valeur totale » attendue est EXACTEMENT 0.
        // Avant le fix, le header affichait −900,00 €.
        expect(find.textContaining(RegExp(r'-900,00\s€')), findsNothing);
        expect(find.textContaining(RegExp(r'0,00\s€')), findsWidgets);
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

      // Bouton journal : icône « receipt_long » de la barre d'app (déjà inconditionnel
      // avant B8, conception interne). La navigation réelle vers AccountJournalPage
      // n'est PAS exercée ici : cette page ouvre elle aussi sa propre base par défaut
      // dans son initState, ce qui reproduirait le blocage documenté ci-dessus si on
      // la pumpait. Les 4 kinds espèces qu'elle propose
      // (deposit/withdrawal/interest/charge, sans buy/sell) sont vérifiés par lecture
      // de code (account_journal_ page.dart:213, allowedKinds — aucune condition sur
      // account.kind/type dans tout le fichier, confirmé par grep) : ce lot ne les
      // modifie pas.
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

      // Régime legacy : TotalValueCard reflète `cash_balance` (500 €), la seule
      // source de vérité tant qu'aucun ancrage n'existe (conception interne).
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

        // Bonus (fix de gating dans ce lot) : la section graphique du compte s'affiche
        // désormais pour un compte cash ancré (grille synthétique du journal, B8
        // conception interne/4.4) — auparavant gatée sur positionsData (toujours vide
        // pour un compte cash), donc jamais visible.
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

  // ===========================================================================
  // Correctif d'honnêteté d'affichage — puce « partiel » du gain total
  // (revue UX) : la réserve « base de coût inconnue » qualifie
  // [AccountController.realTotalGain] (affiché en PERMANENCE dans
  // TotalValueCard), pas la courbe. Elle doit donc rester visible quel que
  // soit le mode de courbe sélectionné — c'est la régression exacte que ce
  // lot corrige (avant, l'avertissement vivait sous le graphe, gaté par
  // useRealCurve, et disparaissait en mode « Vos positions » alors que le
  // gain partiel, lui, restait affiché sans réserve).
  // ===========================================================================
  group('AccountView — puce « partiel » du gain total', () {
    /// Compte titres avec UNE position dont le PRU est volontairement
    /// inconnu : `openingBalance` SANS `unitPrice` (cf. doc de
    /// [HistoryAggregator.computeRealTotalGain]/[noBasisSymbols] — « y
    /// compris un openingBalance TITRE sans unitPrice »). `storage.
    /// savePosition` d'abord : `reprojectSymbolWithin` ne CRÉE jamais de
    /// ligne, il ne fait qu'un UPDATE ciblé (même motif que
    /// wallet_controller_test.dart).
    Future<void> seedNoBasisPosition(AppDatabase db) async {
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
      final ledger = LedgerService(database: db);
      await ledger.emitOpeningBalance(
        accountId: _accountId,
        symbol: 'AAA',
        quantity: '10',
        currency: 'EUR',
        date: DateTime.now().subtract(const Duration(days: 30)),
      );
    }

    MarketDataService historyFakeForAAA() => _FakeMarketDataServiceWithHistory(
          symbol: 'AAA',
          dates: [
            DateTime.now().subtract(const Duration(days: 30)),
            DateTime.now(),
          ],
          prices: const [100, 110],
        );

    testWidgets(
      'régression : la puce reste visible en mode « Vos positions » ET en '
      'mode « Évolution réelle » (avant ce lot, l\'avertissement ne vivait '
      'que sous le graphe en mode réel et disparaissait en mode « Vos '
      'positions » alors que le gain total, amputé, restait affiché sans '
      'réserve)',
      (tester) async {
        final ctrl = await _setUpAccount(
          tester,
          seed: seedNoBasisPosition,
          marketService: historyFakeForAAA(),
        );

        // Prérequis du scénario : le mode 2 a bien abouti (sinon le test ne
        // prouverait rien) et la position sans PRU est bien exclue.
        expect(ctrl.hasRealCurve, isTrue);
        expect(ctrl.realNoBasisSymbols, contains('AAA'));

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));

        // Mode par défaut : « Évolution réelle » (_showRealCurve = true).
        expect(find.text(l10n.chartPartialGainBadgeLabel), findsOneWidget);
        expect(
          tester
              .widget<TotalValueCard>(find.byType(TotalValueCard))
              .gainExcludedCount,
          1,
        );

        // Bascule vers « Vos positions » (mode 1) — LA régression exacte.
        await tester.tap(find.text(l10n.chartModePerformance));
        await tester.pumpAndSettle();

        expect(find.text(l10n.chartPartialGainBadgeLabel), findsOneWidget);
        expect(
          tester
              .widget<TotalValueCard>(find.byType(TotalValueCard))
              .gainExcludedCount,
          1,
        );
      },
    );

    testWidgets(
      'realNoBasisSymbols vide : aucune puce « partiel » (non-régression — '
      'compte cash ancré sans position, même fixture que le test « compte '
      'cash ANCRÉ » ci-dessus)',
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

        expect(ctrl.hasRealCurve, isTrue);
        expect(ctrl.realNoBasisSymbols, isEmpty);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.chartPartialGainBadgeLabel), findsNothing);
        expect(
          tester
              .widget<TotalValueCard>(find.byType(TotalValueCard))
              .gainExcludedCount,
          0,
        );
      },
    );
  });

  // ===========================================================================
  // Correctif d'honnêteté d'affichage — compteur de l'état vide du graphe
  // (revue UX) : `noHistoricalDataForPositions` doit compter ce que
  // l'utilisateur VOIT (positions détenues, `isHeldPosition`), pas la
  // totalité de `positionsData` qui inclut aussi les positions soldées et
  // résidus non cotés sans valeur — masqués de la liste juste en dessous.
  // ===========================================================================
  group('AccountView — compteur de l\'état vide du graphe (correction B)', () {
    testWidgets(
      'ne compte que les positions détenues (isHeldPosition), pas toutes '
      'les positions du compte',
      (tester) async {
        final ctrl = await _setUpAccount(
          tester,
          seed: (db) async {
            await _seedAccount(db, kind: AccountKind.cto);
            final storage = AccountStorage(database: db);
            // Détenue (comptée).
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(
                  symbol: 'AAA',
                  name: 'Asset AAA',
                  currency: 'EUR',
                ),
                quantity: '10',
              ),
            );
            // SOLDÉE (quantité nette ~0) : masquée de la liste par
            // isHeldPosition, ne doit donc PAS être comptée ici non plus.
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(
                  symbol: 'BBB',
                  name: 'Asset BBB',
                  currency: 'EUR',
                ),
                quantity: '0',
              ),
            );
          },
        );

        // _FakeMarketDataService (défaut, sans historique) : chartValues
        // reste vide, l'état vide du graphe s'affiche bien.
        expect(ctrl.positionsData.length, 2);
        expect(ctrl.chartValues, isEmpty);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        // AVANT le fix : "...pour 2 position(s)" (compte la soldée).
        // APRÈS : "...pour 1 position(s)" (seule AAA est détenue/affichée).
        expect(
          find.text(l10n.noHistoricalDataForPositions(1)),
          findsOneWidget,
        );
        expect(
          find.text(l10n.noHistoricalDataForPositions(2)),
          findsNothing,
        );
      },
    );
  });

  // ===========================================================================
  // Épuration UI (revue UX, 29/07) — avertissement de positions EXCLUES de la
  // courbe réelle (saisies sans historique) : désormais CONDITIONNEL (absent
  // quand rien n'est exclu) ET CHIFFRÉ (nombre de positions concernées),
  // remplace l'ancienne phrase inconditionnelle « Les positions saisies sans
  // historique n'y figurent pas » qui s'affichait même quand rien n'était
  // exclu — notamment sur tout compte cash, qui n'a par construction aucune
  // position (cf. AccountController.realExcludedLegacyCount).
  // ===========================================================================
  group('AccountView — avertissement de positions exclues (épuration UI)', () {
    MarketDataService historyFakeForAAA() => _FakeMarketDataServiceWithHistory(
          symbol: 'AAA',
          dates: [
            DateTime.now().subtract(const Duration(days: 30)),
            DateTime.now(),
          ],
          prices: const [100, 110],
        );

    testWidgets(
      'aucune position exclue (toutes journalisées) : aucune caption '
      'd\'exclusion',
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
            final ledger = LedgerService(database: db);
            await ledger.emitOpeningBalance(
              accountId: _accountId,
              symbol: 'AAA',
              quantity: '10',
              currency: 'EUR',
              date: DateTime.now().subtract(const Duration(days: 30)),
            );
          },
          marketService: historyFakeForAAA(),
        );

        expect(ctrl.hasRealCurve, isTrue);
        expect(ctrl.realExcludedLegacyCount, 0);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(
          find.text(l10n.chartRealExcludedLegacyCaption(1)),
          findsNothing,
        );
        expect(find.textContaining('sans historique'), findsNothing);
      },
    );

    testWidgets(
      'une position détenue SANS aucun mouvement journalisé (legacy, saisie '
      'à la main) à côté d\'une position journalisée : caption présente et '
      'chiffrée à 1',
      (tester) async {
        final ctrl = await _setUpAccount(
          tester,
          seed: (db) async {
            await _seedAccount(db, kind: AccountKind.cto);
            final storage = AccountStorage(database: db);
            // Journalisée : compte pour la courbe réelle (hasRealCurve).
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(symbol: 'AAA', name: 'Asset AAA', currency: 'EUR'),
                quantity: '10',
              ),
            );
            final ledger = LedgerService(database: db);
            await ledger.emitOpeningBalance(
              accountId: _accountId,
              symbol: 'AAA',
              quantity: '10',
              currency: 'EUR',
              date: DateTime.now().subtract(const Duration(days: 30)),
            );
            // LEGACY : détenue mais AUCUN mouvement journalisé — exclue de la
            // reconstruction (currentPositions dont le symbole n'est pas clé
            // de txsBySymbol, cf. AccountController._computeAccountRealCurve).
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(symbol: 'BBB', name: 'Asset BBB', currency: 'EUR'),
                quantity: '5',
              ),
            );
          },
          marketService: historyFakeForAAA(),
        );

        expect(ctrl.hasRealCurve, isTrue);
        expect(ctrl.realExcludedLegacyCount, 1);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        // La caption n'est plus seulement CHIFFRÉE : elle NOMME le titre
        // exclu et le rend cliquable (l'ancienne « Une position saisie sans
        // historique… » ne disait ni laquelle, ni quoi en faire).
        final caption = tester.widget<InlineLinksCaption>(
          find.byType(InlineLinksCaption),
        );
        expect(caption.prefix, l10n.chartRealExcludedLegacyNamedPrefix(1));
        expect(caption.links.map((l) => l.label), ['BBB']);
        expect(caption.suffix, l10n.chartRealExcludedLegacyDeclareHint);
      },
    );

    testWidgets(
      'toucher le symbole hérité ouvre la position initiale PRÉREMPLIE de la '
      'quantité détenue et du PRU connu',
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
            await LedgerService(database: db).emitOpeningBalance(
              accountId: _accountId,
              symbol: 'AAA',
              quantity: '10',
              currency: 'EUR',
              date: DateTime.now().subtract(const Duration(days: 30)),
            );
            // HÉRITÉE, avec un PRU déjà saisi à la main : c'est lui qu'il ne
            // faut PAS perdre en déclarant l'opération d'origine (le mouvement
            // déclaré devient la seule source du PRU projeté).
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(symbol: 'BBB', name: 'Asset BBB', currency: 'EUR'),
                quantity: '5',
                averageBuyPrice: 42.0,
              ),
            );
          },
          marketService: historyFakeForAAA(),
        );

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        expect(ctrl.realExcludedLegacySymbols, ['BBB']);

        // Le lien vit DANS un Text.rich : on ne peut pas le taper par
        // `find.text('BBB')` (le span n'est pas un widget). On déclenche donc
        // le recognizer via le callback exposé par la caption — c'est
        // exactement ce que fait le tap, et ça reste un test de CÂBLAGE.
        final caption = tester.widget<InlineLinksCaption>(
          find.byType(InlineLinksCaption),
        );
        caption.links.single.onTap();
        await tester.pumpAndSettle();

        final dialog = find.byType(InitialPositionDialog);
        expect(dialog, findsOneWidget);
        // Quantité DÉTENUE et PRU CONNU préremplis : déclarer l'opération
        // d'origine, c'est reproduire l'état courant, pas le retaper.
        expect(
          find.descendant(of: dialog, matching: find.text('5')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('42.0')),
          findsOneWidget,
        );
        // Le symbole est dans le titre : on sait quelle ligne on déclare.
        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(
          find.descendant(
            of: dialog,
            matching: find.text(l10n.setInitialPositionTitleFor('BBB')),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'compte 100 % hérité (aucun titre journalisé) : pas de sélecteur de '
      'mode, la liste des positions héritées reste affichée avec le préfixe '
      '« pas d\'évolution réelle à reconstruire », et le tap ouvre la '
      'déclaration de position initiale (bug constaté à l\'écran)',
      (tester) async {
        final ctrl = await _setUpAccount(
          tester,
          seed: (db) async {
            await _seedAccount(db, kind: AccountKind.cto);
            final storage = AccountStorage(database: db);
            // AUCUN mouvement de journal pour cette position : compte 100 %
            // hérité — exactement le cas rapporté (plus rien de journalisé,
            // toutes les positions étant héritées).
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(symbol: 'BBB', name: 'Asset BBB', currency: 'EUR'),
                quantity: '5',
              ),
            );
          },
          marketService: _FakeMarketDataServiceWithHistory(
            symbol: 'BBB',
            dates: [
              DateTime.now().subtract(const Duration(days: 30)),
              DateTime.now(),
            ],
            prices: const [100, 110],
            quotePrices: {'BBB': 110},
          ),
        );

        // Aucune courbe réelle (rien à reconstruire), mais le mode 1 reste
        // intact et la liste héritée reste renseignée (cf.
        // AccountController._computeAccountRealCurve).
        expect(ctrl.hasRealCurve, isFalse);
        expect(ctrl.chartValues, isNotEmpty);
        expect(ctrl.realExcludedLegacySymbols, ['BBB']);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        // Pas de sélecteur : aucune courbe réelle à proposer (mode 1 seul).
        expect(find.byType(SegmentedButton<bool>), findsNothing);

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        // La liste NOMMÉE est bien affichée malgré l'absence de courbe
        // réelle — avec le préfixe DÉDIÉ à ce cas (« … ne figure pas dans
        // cette courbe » serait faux : il n'y a pas de courbe du tout).
        final caption = tester.widget<InlineLinksCaption>(
          find.byType(InlineLinksCaption),
        );
        expect(caption.prefix, l10n.chartRealExcludedLegacyNoCurvePrefix(1));
        expect(caption.links.map((l) => l.label), ['BBB']);
        expect(caption.suffix, l10n.chartRealExcludedLegacyDeclareHint);

        // Le tap ouvre bien la déclaration de position initiale, comme en
        // mode réel (même câblage, cf. test ci-dessus).
        caption.links.single.onTap();
        await tester.pumpAndSettle();
        expect(find.byType(InitialPositionDialog), findsOneWidget);
      },
    );

    testWidgets(
      'compte cash ancré (aucune position par construction) : jamais de '
      'caption d\'exclusion, même en mode réel forcé',
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

        expect(ctrl.hasRealCurve, isTrue);
        expect(ctrl.realExcludedLegacyCount, 0);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        expect(find.textContaining('sans historique'), findsNothing);
      },
    );
  });

  // ===========================================================================
  // Épuration UI (lot 3) : la ligne « Espèces » d'un compte-titres fusionne
  // dans TotalValueCard (« dont espèces ») et son action rejoint le menu ⋮.
  // Le régime compte cash (émphasé) reste, lui, INCHANGÉ — non-régression
  // déjà largement couverte par le groupe « repli compte cash » ci-dessus ;
  // ce groupe n'y ajoute qu'une vérification que le menu ⋮ ne le duplique pas.
  // ===========================================================================
  group(
    'AccountView — ligne « dont espèces » et action ⋮ (épuration UI, lot 3)',
    () {
      testWidgets(
        'compte-titres ANCRÉ : « dont espèces » chiffrée dans la carte de '
        'valeur, plus aucune ligne accessoire ni bouton inline dans le '
        'contenu',
        (tester) async {
          final ctrl = await _setUpAccount(
            tester,
            seed: (db) async {
              await _seedAccount(db, kind: AccountKind.cto);
              final ledger = LedgerService(database: db);
              await ledger.emitCashOpeningBalance(
                accountId: _accountId,
                amount: '300',
                currency: 'EUR',
                date: DateTime.now().subtract(const Duration(days: 10)),
              );
            },
          );

          expect(ctrl.hasCashAnchor, isTrue);

          await tester.pumpWidget(_host(ctrl));
          await tester.pumpAndSettle();

          final l10n = await AppLocalizations.delegate.load(
            const Locale('fr'),
          );
          expect(
            find.text(
              l10n.accountCashLine(Formatters.formatMoney(300, 'EUR')),
            ),
            findsOneWidget,
          );
          // L'ancienne ligne dédiée (icône + libellé « Espèces : … » +
          // bouton inline) a disparu du contenu — son action a rejoint le
          // menu ⋮ (vérifié plus bas).
          expect(find.byIcon(Icons.payments_outlined), findsNothing);
          expect(
            find.text(
              l10n.cashDerivedLabel(Formatters.formatMoney(300, 'EUR')),
            ),
            findsNothing,
          );
          expect(find.text(l10n.adjustCashBalanceAction), findsNothing);
        },
      );

      testWidgets(
        'compte-titres NON ancré : ni « dont espèces » ni « Espèces non '
        'suivies » — le cas normal et majoritaire n\'affiche RIEN (cf. lot 2)',
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
                  asset: Asset(
                    symbol: 'AAA',
                    name: 'Asset AAA',
                    currency: 'EUR',
                  ),
                  quantity: '10',
                ),
              );
            },
          );

          expect(ctrl.hasCashAnchor, isFalse);

          await tester.pumpWidget(_host(ctrl));
          await tester.pumpAndSettle();

          final l10n = await AppLocalizations.delegate.load(
            const Locale('fr'),
          );
          expect(find.textContaining('dont espèces'), findsNothing);
          expect(find.text(l10n.cashNotTrackedLabel), findsNothing);
          expect(find.byIcon(Icons.payments_outlined), findsNothing);
        },
      );

      testWidgets(
        'garde-fou devises (§8.5) : la note d\'exclusion des mouvements en '
        'devise étrangère reste visible dans le contenu d\'un compte-titres, '
        'même SANS ancrage cash (elle qualifie foreignCashMovementCount, pas '
        'hasCashAnchor — pas de ligne « dont espèces » à côté d\'elle ici)',
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
                  asset: Asset(
                    symbol: 'AAPL',
                    name: 'Apple',
                    currency: 'USD',
                  ),
                  quantity: '10',
                ),
              );
              final ledger = LedgerService(database: db);
              // Achat coté ET réglé USD (settlementCurrency null) sur un
              // compte EUR : alimente un bucket USD ≠ devise du compte (même
              // scénario que account_controller_test.dart, groupe
              // foreignCashMovementCount).
              await ledger.recordTransaction(
                AssetTransaction(
                  id: 'tx-usd',
                  accountId: _accountId,
                  symbol: 'AAPL',
                  kind: TransactionKind.buy,
                  quantity: '10',
                  unitPrice: '175',
                  amount: '-1750',
                  currency: 'USD',
                  date: DateTime(2025, 1, 1),
                ),
              );
            },
          );

          expect(ctrl.hasCashAnchor, isFalse);
          expect(ctrl.foreignCashMovementCount, 1);

          await tester.pumpWidget(_host(ctrl));
          await tester.pumpAndSettle();

          final l10n = await AppLocalizations.delegate.load(
            const Locale('fr'),
          );
          expect(find.text(l10n.cashForeignExcludedNote(1)), findsOneWidget);
        },
      );

      testWidgets(
        'compte-titres NON ancré : le menu ⋮ propose « Définir le solde '
        'initial… », pas « Ajuster le solde espèces… »',
        (tester) async {
          final ctrl = await _setUpAccount(
            tester,
            seed: (db) => _seedAccount(db, kind: AccountKind.cto),
          );

          expect(ctrl.hasCashAnchor, isFalse);

          await tester.pumpWidget(_host(ctrl));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();

          final l10n = await AppLocalizations.delegate.load(
            const Locale('fr'),
          );
          expect(find.text(l10n.setInitialCashBalanceAction), findsOneWidget);
          expect(find.text(l10n.adjustCashBalanceAction), findsNothing);
        },
      );

      testWidgets(
        'compte-titres ANCRÉ : le menu ⋮ propose « Ajuster le solde '
        'espèces… », pas « Définir le solde initial… »',
        (tester) async {
          final ctrl = await _setUpAccount(
            tester,
            seed: (db) async {
              await _seedAccount(db, kind: AccountKind.cto);
              final ledger = LedgerService(database: db);
              await ledger.emitCashOpeningBalance(
                accountId: _accountId,
                amount: '300',
                currency: 'EUR',
                date: DateTime.now().subtract(const Duration(days: 10)),
              );
            },
          );

          expect(ctrl.hasCashAnchor, isTrue);

          await tester.pumpWidget(_host(ctrl));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();

          final l10n = await AppLocalizations.delegate.load(
            const Locale('fr'),
          );
          expect(find.text(l10n.adjustCashBalanceAction), findsOneWidget);
          expect(find.text(l10n.setInitialCashBalanceAction), findsNothing);
        },
      );

      testWidgets(
        'compte cash : le menu ⋮ ne duplique PAS l\'action espèces (régime '
        'émphasé inchangé — l\'action reste inline, cf. groupe « repli '
        'compte cash »)',
        (tester) async {
          final ctrl = await _setUpAccount(
            tester,
            seed: (db) =>
                _seedAccount(db, kind: AccountKind.cash, cashBalance: 500),
          );

          await tester.pumpWidget(_host(ctrl));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();

          final l10n = await AppLocalizations.delegate.load(
            const Locale('fr'),
          );
          // Un seul exemplaire (le bouton inline) : le menu ⋮ n'en ajoute pas
          // un second pour un compte cash.
          expect(find.text(l10n.setInitialCashBalanceAction), findsOneWidget);
        },
      );
    },
  );

  // -------------------------------------------------------------------------
  // Garde de qualité du mode par défaut (couverture de la courbe réelle)
  // -------------------------------------------------------------------------

  group('AccountView — mode par défaut sous garde de couverture', () {
    /// Compte CTO avec UNE position journalisée (AAA, 10 × 105 = 1050) et UNE
    /// position HÉRITÉE sans aucun mouvement (BBB, 5 × 100 = 500) : la courbe
    /// réelle ne représente que 1050/1550 ≈ 68 % de la valeur du compte, sous
    /// le seuil de la politique.
    Future<AccountController> setUpLowCoverage(WidgetTester tester) =>
        _setUpAccount(
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
            await storage.savePosition(
              _accountId,
              Position(
                accountId: _accountId,
                asset: Asset(symbol: 'BBB', name: 'Asset BBB', currency: 'EUR'),
                quantity: '5',
              ),
            );
            final ledger = LedgerService(database: db);
            await ledger.emitOpeningBalance(
              accountId: _accountId,
              symbol: 'AAA',
              quantity: '10',
              currency: 'EUR',
              date: DateTime.now().subtract(const Duration(days: 30)),
            );
          },
          marketService: _FakeMarketDataServiceWithHistory(
            symbol: 'AAA',
            dates: [
              DateTime.now().subtract(const Duration(days: 30)),
              DateTime.now(),
            ],
            prices: const [100, 105],
            quotePrices: const {'AAA': 105.0, 'BBB': 100.0},
          ),
        );

    testWidgets(
      'couverture basse et AUCUN choix persisté : le sélecteur s\'ouvre sur '
      '« Vos positions », avec la note chiffrée qui l\'explique',
      (tester) async {
        final ctrl = await setUpLowCoverage(tester);

        expect(ctrl.hasRealCurve, isTrue);
        expect(ctrl.realExcludedLegacyCount, 1);
        expect(ctrl.realCurveCoverage, closeTo(1050.0 / 1550.0, 1e-9));

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final selector = tester.widget<SegmentedButton<bool>>(
          find.byType(SegmentedButton<bool>),
        );
        expect(selector.selected, {false});

        // La bascule automatique est NOMMÉE, jamais silencieuse.
        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(
          find.text(l10n.chartRealCoverageFallbackCaption(68)),
          findsOneWidget,
        );
        // Et la LISTE NOMMÉE est rendue en mode 1 aussi : c'est justement
        // quand la courbe réelle a été écartée que savoir QUOI compléter
        // compte le plus. Elle précède la note de bascule.
        final caption = tester.widget<InlineLinksCaption>(
          find.byType(InlineLinksCaption),
        );
        expect(caption.links.map((l) => l.label), ['BBB']);
        // Courbe réelle DISPONIBLE (hasRealCurve) mais mode 1 affiché (repli
        // automatique) : « … ne figure pas dans cette courbe » désignerait à
        // tort la courbe à l'écran, qui INCLUT justement BBB. Le préfixe doit
        // nommer l'évolution réelle, la seule dont BBB soit effectivement
        // absente.
        expect(caption.prefix, l10n.chartRealExcludedLegacyOtherModePrefix(1));
      },
    );

    testWidgets(
      'même couverture basse, mais choix « évolution réelle » persisté : le '
      'choix de l\'utilisateur prime (avertissement chiffré à la place)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'chart_mode_real_account': true,
        });
        ChartModeController.resetSharedForTest();
        await ChartModeController.shared().load();

        final ctrl = await setUpLowCoverage(tester);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final selector = tester.widget<SegmentedButton<bool>>(
          find.byType(SegmentedButton<bool>),
        );
        expect(selector.selected, {true});

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        // Mode réel affiché : avertissement chiffré, pas la note de repli.
        //
        // VARIANTE COURTE : la liste nommée juste au-dessus a déjà dit CE QUI
        // manque (« BBB »). L'avertissement n'en garde que le chiffre — la
        // formulation longue y répéterait « il y manque des positions sans
        // historique » sous l'énumération de ces mêmes positions.
        expect(find.text(l10n.chartRealCoverageWarningShort(68)), findsOneWidget);
        expect(find.text(l10n.chartRealCoverageWarning(68)), findsNothing);
        expect(
          find.text(l10n.chartRealCoverageFallbackCaption(68)),
          findsNothing,
        );
      },
    );

    testWidgets(
      'basculer le sélecteur persiste le choix pour la portée « compte »',
      (tester) async {
        final ctrl = await setUpLowCoverage(tester);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        await tester.tap(find.text(l10n.chartModeRealEvolution));
        await tester.pumpAndSettle();

        expect(
          ChartModeController.shared().choiceFor(ChartModeScope.account),
          isTrue,
        );
        // Les autres portées restent vierges.
        expect(
          ChartModeController.shared().choiceFor(ChartModeScope.wallet),
          isNull,
        );
        final selector = tester.widget<SegmentedButton<bool>>(
          find.byType(SegmentedButton<bool>),
        );
        expect(selector.selected, {true});
      },
    );
  });

  // ===========================================================================
  // Correctifs suppression de compte (diagnostic architecte) — D4/D5
  // ===========================================================================

  group('AccountView — sentinelles de suppression distinctes (D4)', () {
    test(
        'AccountView.resultDeleted et PositionDetailPage.resultDeleted ne '
        'partagent plus la même valeur — un pop mal ciblé sur la pile de '
        'navigation ne peut plus faire prendre une suppression de position '
        'pour une suppression de compte (ou réciproquement)', () {
      expect(
        AccountView.resultDeleted,
        isNot(equals(PositionDetailPage.resultDeleted)),
      );
      // Non-régression du contrat de valeur (WalletView/AccountView lisent
      // ces littéraux au retour de Navigator.push<String>).
      expect(AccountView.resultDeleted, 'account-deleted');
      expect(PositionDetailPage.resultDeleted, 'position-deleted');
    });
  });

  group('AccountView — compte introuvable (D5)', () {
    testWidgets(
      'initialAccountId introuvable : écran « ce compte n\'existe plus », '
      'jamais le contenu normal (qui suppose activeAccount non-null)',
      (tester) async {
        late AppDatabase db;
        late AccountController ctrl;
        await tester.runAsync(() async {
          db = await openTestDatabase();
          // Un AUTRE compte, bien réel, existe dans le même wallet — preuve
          // qu'il n'est PAS choisi comme repli silencieux à la place de l'id
          // demandé (c'était exactement le bug : bascule muette sur un
          // compte quelconque, voire cash, section positions masquée).
          await _seedAccount(db, kind: AccountKind.cash, cashBalance: 42);
          ctrl = AccountController(
            initialAccountId: 'id-qui-n-existe-pas',
            initialUsdToEurRate: 0.92,
            storage: AccountStorage(database: db),
            ledgerService: LedgerService(database: db),
            transactionStorage: TransactionStorage(database: db),
            marketService: _FakeMarketDataService(),
          );
          await ctrl.initAccounts();
        });
        addTearDown(() => tester.runAsync(db.close));

        expect(ctrl.accountNotFound, isTrue);
        expect(ctrl.activeAccount, isNull);

        await tester.pumpWidget(_host(ctrl));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.accountNotFoundTitle), findsOneWidget);
        // Le nom du compte « Compte test » (l'AUTRE compte réel du wallet)
        // ne doit JAMAIS apparaître : ce serait la preuve d'un repli
        // silencieux sur lui.
        expect(find.text('Compte test'), findsNothing);
      },
    );
  });
}

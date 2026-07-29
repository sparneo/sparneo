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

  _FakeMarketDataServiceWithHistory({
    required this.symbol,
    required this.dates,
    required this.prices,
  });

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async => null;

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
        expect(
          find.text(l10n.chartRealExcludedLegacyCaption(1)),
          findsOneWidget,
        );
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
}

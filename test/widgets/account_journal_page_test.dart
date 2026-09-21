// test/widgets/account_journal_page_test.dart
//
// Tests WIDGET de l'édition/suppression des mouvements dans le journal de
// COMPTE. Avant ce lot, `_buildTile` n'avait strictement aucune interaction
// (ni onTap ni bouton) : ce fichier couvre l'ajout du tap → édition et du
// bouton supprimer, calqués sur position_detail_page.dart, AVEC le gating
// `!TransactionKind.isSystemGenerated` qui doit exclure openingBalance /
// adjustment / transferOut (mouvements fabriqués par l'app, affichés en
// lecture seule — cf. asset_transaction.dart).
//
// AUCUNE base SQLite réelle : AccountJournalPage expose (réservés aux tests)
// debugTransactionStorage / debugAccountStorage / debugLedgerService, qui
// permettent d'injecter des fakes en mémoire. Ouvrir une base réelle DANS un
// testWidgets est connu pour bloquer indéfiniment (dart:isolate,
// _RawReceivePort._handleMessage — cf. account_view_test.dart,
// statement_import_page_test.dart) : on l'évite entièrement plutôt que de la
// contourner via tester.runAsync. Zéro appel réseau.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;

import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/logic/position_projection.dart'
    show journalHasCashAnchor;
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/account_journal_page.dart';

const _accountId = 'account-1';

// ---------------------------------------------------------------------------
// Fakes en mémoire (aucune base SQLite) — même motif que le constructeur
// `TransactionStorage.forTesting()` déjà prévu en production pour ça.
// ---------------------------------------------------------------------------

class _FakeAccountStorage extends AccountStorage {
  final Account account;
  _FakeAccountStorage(this.account);

  @override
  Future<Account?> getAccount(String id) async => account;

  // Aucune position en mémoire : taper une ligne TITRE emprunte donc la branche
  // « titre soldé » de _openPositionForSymbol (popup d'explication), qui ne
  // navigue pas — la navigation vers PositionDetailPage ouvrirait une vraie base
  // SQLite, ce que ces tests widget ne peuvent pas (cf. entête de fichier).
  @override
  Future<List<Position>> getPositions(String accountId) async => const [];
}

class _FakeTransactionStorage extends TransactionStorage {
  final List<AssetTransaction> txs;
  _FakeTransactionStorage(this.txs) : super.forTesting();

  @override
  Future<List<AssetTransaction>> getByAccount(
    String accountId, {
    DatabaseExecutor? executor,
  }) async => List.unmodifiable(txs);
}

/// Espionne les mutations SANS toucher de base réelle. [txs] est LA MÊME
/// instance de liste que celle passée à [_FakeTransactionStorage] : un
/// enregistrement/suppression via ce ledger est donc immédiatement visible au
/// rechargement suivant du journal (`_load()` relit `txs`).
class _FakeLedgerService extends LedgerService {
  final List<AssetTransaction> txs;
  final List<AssetTransaction> recorded = [];
  final List<String> deletedIds = [];

  _FakeLedgerService(this.txs);

  @override
  Future<void> recordTransaction(AssetTransaction tx) async {
    recorded.add(tx);
    txs.removeWhere((t) => t.id == tx.id);
    txs.add(tx);
  }

  @override
  Future<void> deleteTransaction(String id) async {
    deletedIds.add(id);
    txs.removeWhere((t) => t.id == id);
  }
}

// ---------------------------------------------------------------------------
// Helpers de construction
// ---------------------------------------------------------------------------

Account _account({AccountKind kind = AccountKind.cto}) => Account(
      id: _accountId,
      walletId: 'wallet-1',
      name: 'Compte test',
      kind: kind,
      currency: 'EUR',
    );

Widget _host({
  required List<AssetTransaction> txs,
  required _FakeLedgerService ledger,
  AccountKind accountKind = AccountKind.cto,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('fr'),
    home: AccountJournalPage(
      accountId: _accountId,
      accountName: 'Compte test',
      debugTransactionStorage: _FakeTransactionStorage(txs),
      debugAccountStorage: _FakeAccountStorage(_account(kind: accountKind)),
      debugLedgerService: ledger,
    ),
  );
}

AssetTransaction _cashTx({
  required String id,
  required TransactionKind kind,
  required DateTime date,
  String? amount,
  String? symbol,
  String? quantity,
}) =>
    AssetTransaction(
      id: id,
      accountId: _accountId,
      symbol: symbol,
      kind: kind,
      quantity: quantity,
      amount: amount,
      currency: 'EUR',
      date: date,
    );

String _fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// [InkWell] de la tuile affichant [dateText] (date formatée, unique dans les
/// corpus de test ci-dessous) — le plus proche ancêtre InkWell du texte de
/// date, cf. `_buildTile` (un seul InkWell englobe toute la ligne).
InkWell _tileInkWell(WidgetTester tester, String dateText) {
  return tester.widget<InkWell>(
    find
        .ancestor(of: find.text(dateText), matching: find.byType(InkWell))
        .first,
  );
}

/// Bouton supprimer (s'il existe) de la tuile affichant [dateText].
Finder _tileDeleteButton(String dateText) {
  return find.descendant(
    of: find
        .ancestor(of: find.text(dateText), matching: find.byType(InkWell))
        .first,
    matching: find.byIcon(Icons.delete_outline),
  );
}

void main() {
  group('AccountJournalPage — gating éditable / lecture seule', () {
    testWidgets(
      'deposit / withdrawal / interest / charge : tuile tapable + bouton '
      'supprimer',
      (tester) async {
        final editableKinds = <TransactionKind, String>{
          TransactionKind.deposit: '100',
          TransactionKind.withdrawal: '-50',
          TransactionKind.interest: '5',
          TransactionKind.charge: '-10',
        };

        var day = 1;
        final txs = editableKinds.entries
            .map(
              (e) => _cashTx(
                id: 'tx-${e.key.wire}',
                kind: e.key,
                date: DateTime(2024, 1, day++),
                amount: e.value,
              ),
            )
            .toList();

        final ledger = _FakeLedgerService(txs);
        await tester.pumpWidget(_host(txs: List.of(txs), ledger: ledger));
        await tester.pumpAndSettle();

        for (final tx in txs) {
          final dateText = _fmtDate(tx.date);
          final inkWell = _tileInkWell(tester, dateText);
          expect(
            inkWell.onTap,
            isNotNull,
            reason: '${tx.kind.wire} doit être tapable',
          );
          expect(
            _tileDeleteButton(dateText),
            findsOneWidget,
            reason: '${tx.kind.wire} doit afficher un bouton supprimer',
          );
        }
      },
    );

    testWidgets(
      // B18/conception interne : SEUL l'openingBalance ESPÈCES est devenu éditable
      // (cf. groupe « édition du solde espèces initial » plus bas) — adjustment
      // ESPÈCES reste, lui, verrouillé en lecture seule (non- régression).
      // openingBalance a donc quitté ce test.
      'adjustment ESPÈCES (système restant) : tap → popup '
      '« Mouvement automatique », JAMAIS le dialogue d\'édition, aucun '
      'bouton supprimer',
      (tester) async {
        final txs = [
          _cashTx(
            id: 'tx-adjustment',
            kind: TransactionKind.adjustment,
            date: DateTime(2024, 2, 2),
            amount: '20',
          ),
        ];

        final ledger = _FakeLedgerService(txs);

        for (final tx in txs) {
          await tester.pumpWidget(_host(txs: List.of(txs), ledger: ledger));
          await tester.pumpAndSettle();

          final dateText = _fmtDate(tx.date);
          // La tuile RÉAGIT (plus de tap mort — le défaut corrigé), mais
          // n'édite pas : jamais de bouton supprimer.
          expect(_tileInkWell(tester, dateText).onTap, isNotNull);
          expect(
            _tileDeleteButton(dateText),
            findsNothing,
            reason: '${tx.kind.wire} ne doit PAS afficher de bouton supprimer',
          );

          await tester.tap(find.text(dateText));
          await tester.pumpAndSettle();

          // Popup d'explication, PAS le dialogue d'édition cash.
          expect(find.text('Mouvement automatique'), findsOneWidget);
          expect(ledger.recorded, isEmpty,
              reason: 'aucune écriture ne doit partir d\'un tap système');
          // Referme la popup avant l'itération suivante.
          await tester.tap(find.text('Fermer'));
          await tester.pumpAndSettle();
        }
      },
    );

    testWidgets(
      'ligne TITRE (buy/transferOut, symbol non-null) : tap → fiche position '
      '(ici titre soldé ⇒ popup), JAMAIS le dialogue cash ; aucun bouton '
      'supprimer',
      (tester) async {
        // transferOut (sortie de titres) et buy portent un `symbol` : ils
        // remontent dans CE journal de compte (getByAccount ne filtre pas par
        // symbole). Sans routage, taper une ligne buy l'aurait ré-émise avec
        // symbol: null et lui aurait fait perdre son rattachement au titre.
        final txs = [
          _cashTx(
            id: 'tx-transferout',
            kind: TransactionKind.transferOut,
            date: DateTime(2024, 2, 3),
            symbol: 'AAPL',
            quantity: '-5',
          ),
          _cashTx(
            id: 'tx-buy',
            kind: TransactionKind.buy,
            date: DateTime(2024, 2, 4),
            symbol: 'AAPL',
            quantity: '10',
            amount: '-1500',
          ),
        ];

        final ledger = _FakeLedgerService(txs);

        for (final tx in txs) {
          await tester.pumpWidget(_host(txs: List.of(txs), ledger: ledger));
          await tester.pumpAndSettle();

          final dateText = _fmtDate(tx.date);
          expect(_tileInkWell(tester, dateText).onTap, isNotNull);
          expect(_tileDeleteButton(dateText), findsNothing);

          await tester.tap(find.text(dateText));
          await tester.pumpAndSettle();

          // _FakeAccountStorage.getPositions renvoie [] → branche « titre
          // soldé » : popup dédiée, jamais le dialogue d'édition cash.
          expect(find.text('Mouvement sur titre'), findsOneWidget);
          expect(ledger.recorded, isEmpty);
          await tester.tap(find.text('Fermer'));
          await tester.pumpAndSettle();
        }
      },
    );
  });

  group('AccountJournalPage — édition d\'un mouvement cash', () {
    testWidgets(
      'taper sur un deposit ouvre le dialogue d\'édition ; Enregistrer passe '
      'par _ledger.recordTransaction (jamais d\'insert direct)',
      (tester) async {
        final tx = _cashTx(
          id: 'tx-deposit',
          kind: TransactionKind.deposit,
          date: DateTime(2024, 3, 1),
          amount: '250',
        );
        final txs = [tx];
        final ledger = _FakeLedgerService(txs);

        await tester.pumpWidget(_host(txs: txs, ledger: ledger));
        await tester.pumpAndSettle();

        await tester.tap(find.text(_fmtDate(tx.date)));
        await tester.pumpAndSettle();

        // Le dialogue d'édition est ouvert (pré-rempli avec le montant
        // existant, cf. TransactionEditDialog._rawAmountCtrl).
        expect(find.text('Enregistrer'), findsOneWidget);

        await tester.tap(find.text('Enregistrer'));
        await tester.pumpAndSettle();

        expect(ledger.recorded, hasLength(1));
        expect(ledger.recorded.single.id, 'tx-deposit');
        expect(ledger.deletedIds, isEmpty);
      },
    );
  });

  // ===========================================================================
  // B18/conception interne : le solde espèces initial (openingBalance espèces) est
  // devenu la QUATRIÈME famille éditable du journal (dialogue dédié
  // CashOpeningBalanceDialog), seule exception aux mouvements système verrouillés —
  // cf. commentaire de _openEditCashOpeningBalance.
  // ===========================================================================
  group(
      'AccountJournalPage — édition du solde espèces initial (openingBalance '
      'espèces)', () {
    testWidgets(
      'tap sur la ligne openingBalance espèces ouvre le dialogue dédié '
      '(titre « Modifier… »), pas de bouton supprimer',
      (tester) async {
        final tx = _cashTx(
          id: 'tx-opening',
          kind: TransactionKind.openingBalance,
          date: DateTime(2024, 6, 10),
          amount: '1000',
        );
        final txs = [tx];
        final ledger = _FakeLedgerService(txs);

        await tester.pumpWidget(_host(txs: txs, ledger: ledger));
        await tester.pumpAndSettle();

        final dateText = _fmtDate(tx.date);
        expect(_tileInkWell(tester, dateText).onTap, isNotNull);
        expect(_tileDeleteButton(dateText), findsNothing,
            reason: 'un solde initial ne se SUPPRIME pas (seul ancrage cash)');

        await tester.tap(find.text(dateText));
        await tester.pumpAndSettle();

        expect(find.text('Modifier le solde espèces initial'), findsOneWidget);
        // PAS le dialogue générique deposit/withdrawal/... (bouton « Enregistrer »).
        expect(find.text('Enregistrer'), findsNothing);
      },
    );

    testWidgets(
      'valider une nouvelle date persiste, via recordTransaction, une '
      'transaction de MÊME id/kind/symbol null — seule la date change ; '
      'l\'ancrage cash (journalHasCashAnchor) survit à l\'édition',
      (tester) async {
        final tx = _cashTx(
          id: 'tx-opening',
          kind: TransactionKind.openingBalance,
          date: DateTime(2024, 6, 10),
          amount: '1000',
        );
        final txs = [tx];
        final ledger = _FakeLedgerService(txs);

        await tester.pumpWidget(_host(txs: txs, ledger: ledger));
        await tester.pumpAndSettle();

        await tester.tap(find.text(_fmtDate(tx.date)));
        await tester.pumpAndSettle();

        // Ouvre le sélecteur de date (InkWell portant le libellé « Date »)
        // puis choisit un autre jour DU MÊME MOIS (aucune navigation requise).
        await tester.tap(find.text(_fmtDate(tx.date)).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('15'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Valider'));
        await tester.pumpAndSettle();

        expect(ledger.recorded, hasLength(1));
        final edited = ledger.recorded.single;
        expect(edited.id, 'tx-opening');
        expect(edited.kind, TransactionKind.openingBalance);
        expect(edited.symbol, isNull);
        expect(edited.amount, '1000', reason: 'montant inchangé');
        expect(edited.date, DateTime(2024, 6, 15));

        // Ancrage préservé (le discriminant dépend du KIND seul).
        expect(journalHasCashAnchor(ledger.txs), isTrue);
      },
    );
  });

  group('AccountJournalPage — suppression d\'un mouvement cash', () {
    testWidgets(
      'supprimer + confirmer passe par _ledger.deleteTransaction',
      (tester) async {
        final tx = _cashTx(
          id: 'tx-withdrawal',
          kind: TransactionKind.withdrawal,
          date: DateTime(2024, 4, 1),
          amount: '-75',
        );
        final txs = [tx];
        final ledger = _FakeLedgerService(txs);

        await tester.pumpWidget(_host(txs: txs, ledger: ledger));
        await tester.pumpAndSettle();

        await tester.tap(_tileDeleteButton(_fmtDate(tx.date)));
        await tester.pumpAndSettle();

        // Confirmation demandée avant toute suppression.
        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.deleteTransactionConfirm), findsOneWidget);

        await tester.tap(find.text(l10n.delete));
        await tester.pumpAndSettle();

        expect(ledger.deletedIds, ['tx-withdrawal']);
        expect(ledger.recorded, isEmpty);
        // La tuile a disparu du journal rechargé (_load() relit `txs`).
        expect(find.text(_fmtDate(tx.date)), findsNothing);
      },
    );

    testWidgets(
      'annuler la confirmation ne supprime rien',
      (tester) async {
        final tx = _cashTx(
          id: 'tx-charge',
          kind: TransactionKind.charge,
          date: DateTime(2024, 5, 1),
          amount: '-15',
        );
        final txs = [tx];
        final ledger = _FakeLedgerService(txs);

        await tester.pumpWidget(_host(txs: txs, ledger: ledger));
        await tester.pumpAndSettle();

        await tester.tap(_tileDeleteButton(_fmtDate(tx.date)));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        await tester.tap(find.text(l10n.cancel));
        await tester.pumpAndSettle();

        expect(ledger.deletedIds, isEmpty);
        expect(ledger.recorded, isEmpty);
        // La tuile est toujours présente.
        expect(find.text(_fmtDate(tx.date)), findsOneWidget);
      },
    );
  });

  group('AccountJournalPage — filtres', () {
    testWidgets(
      'sur 360 dp, TOUS les types de filtre tiennent à l\'écran (aucun tronqué '
      'au bord : c\'était le défaut du défilement horizontal sans affordance)',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final ledger = _FakeLedgerService([]);
        await tester.pumpWidget(_host(txs: [], ledger: ledger));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        final labels = <String>[
          l10n.filterAllKinds,
          l10n.transactionKindBuy,
          l10n.transactionKindSell,
          l10n.transactionKindDividend,
          l10n.transactionKindDeposit,
          l10n.transactionKindWithdrawal,
          l10n.transactionKindInterest,
          l10n.transactionKindCharge,
          l10n.periodAll,
          l10n.period30Days,
          l10n.period90Days,
          l10n.period1Year,
        ];

        for (final label in labels) {
          final finder = find.text(label);
          expect(finder, findsOneWidget, reason: 'filtre « $label » absent');
          final rect = tester.getRect(finder);
          expect(
            rect.right,
            lessThanOrEqualTo(360.0),
            reason: '« $label » dépasse le bord droit (tronqué)',
          );
          expect(
            rect.left,
            greaterThanOrEqualTo(0.0),
            reason: '« $label » dépasse le bord gauche',
          );
        }
      },
    );

    testWidgets(
      'sur un compte crypto, la rangée à NEUF puces (dont « Récompenses ») '
      'tient aussi à l\'écran sur 360 dp',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final ledger = _FakeLedgerService([]);
        await tester.pumpWidget(
          _host(txs: [], ledger: ledger, accountKind: AccountKind.crypto),
        );
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        final labels = <String>[
          l10n.filterAllKinds,
          l10n.transactionKindBuy,
          l10n.transactionKindSell,
          l10n.transactionKindDividend,
          l10n.transactionKindDeposit,
          l10n.transactionKindWithdrawal,
          l10n.transactionKindInterest,
          l10n.transactionKindCharge,
          l10n.filterRewards,
        ];

        for (final label in labels) {
          final finder = find.text(label);
          expect(finder, findsOneWidget, reason: 'filtre « $label » absent');
          final rect = tester.getRect(finder);
          expect(
            rect.right,
            lessThanOrEqualTo(360.0),
            reason: '« $label » dépasse le bord droit (tronqué)',
          );
          expect(
            rect.left,
            greaterThanOrEqualTo(0.0),
            reason: '« $label » dépasse le bord gauche',
          );
        }
        // Aucune exception de rendu (débordement Flutter) déclenchée par la
        // neuvième puce.
        expect(tester.takeException(), isNull);
      },
    );

    // Deux `testWidgets` distincts (et NON deux `pumpWidget` successifs sur le
    // même tester) : `AccountJournalPage` n'a pas de `key` et occupe la même
    // position dans l'arbre → un second `pumpWidget` réutiliserait le MÊME
    // State (initState non ré-exécuté, donc `_accountKind` jamais rechargé),
    // masquant tout changement de nature de compte.
    testWidgets(
      'la puce « Récompenses » est visible sur un compte crypto',
      (tester) async {
        final ledger = _FakeLedgerService([]);
        await tester.pumpWidget(
          _host(txs: [], ledger: ledger, accountKind: AccountKind.crypto),
        );
        await tester.pumpAndSettle();
        expect(find.text('Récompenses'), findsOneWidget);
      },
    );

    testWidgets(
      'la puce « Récompenses » est absente sur un compte titres (CTO)',
      (tester) async {
        final ledger = _FakeLedgerService([]);
        await tester.pumpWidget(
          _host(txs: [], ledger: ledger, accountKind: AccountKind.cto),
        );
        await tester.pumpAndSettle();
        expect(find.text('Récompenses'), findsNothing);
      },
    );

    testWidgets(
      'sélectionner « Récompenses » ne montre que les adjustments '
      'stakingReward — ni un adjustment nu, ni un openingBalance',
      (tester) async {
        final reward = AssetTransaction(
          id: 'tx-reward',
          accountId: _accountId,
          kind: TransactionKind.adjustment,
          quantity: '3.1',
          currency: 'EUR',
          date: DateTime(2024, 7, 1),
          meta: const {'corporateAction': 'stakingReward'},
        );
        // Adjustment NU (sans corporateAction) : ne doit PAS apparaître sous
        // « Récompenses » (cf. filterJournal, cas spécial rewardsOnly).
        final plainAdjustment = _cashTx(
          id: 'tx-plain-adjustment',
          kind: TransactionKind.adjustment,
          date: DateTime(2024, 7, 2),
          amount: '20',
        );
        // openingBalance : autre kind système, ne doit pas non plus fuiter.
        final opening = _cashTx(
          id: 'tx-opening',
          kind: TransactionKind.openingBalance,
          date: DateTime(2024, 7, 3),
          amount: '1000',
        );
        final txs = [reward, plainAdjustment, opening];
        final ledger = _FakeLedgerService(txs);

        await tester.pumpWidget(
          _host(txs: txs, ledger: ledger, accountKind: AccountKind.crypto),
        );
        await tester.pumpAndSettle();

        // Les trois lignes sont visibles sous « Tous ».
        expect(find.text(_fmtDate(reward.date)), findsOneWidget);
        expect(find.text(_fmtDate(plainAdjustment.date)), findsOneWidget);
        expect(find.text(_fmtDate(opening.date)), findsOneWidget);

        await tester.tap(find.text('Récompenses'));
        await tester.pumpAndSettle();

        expect(find.text(_fmtDate(reward.date)), findsOneWidget);
        expect(find.text(_fmtDate(plainAdjustment.date)), findsNothing);
        expect(find.text(_fmtDate(opening.date)), findsNothing);
      },
    );
  });

  group('AccountJournalPage — libellé crypto (chantier B16, lot 1)', () {
    testWidgets(
      'une récompense de staking affiche « Récompense de staking · <qté> », '
      'pas le libellé générique « Ajustement » ni « qté × prix » (coût nul, '
      'unitPrice absent), et JAMAIS d\'équivalent EUR (décision auteur '
      'explicite, symétrique de position_detail_page, commit 1eb77b1)',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-reward',
          accountId: _accountId,
          symbol: 'ADA-EUR',
          kind: TransactionKind.adjustment,
          quantity: '12.4',
          currency: 'EUR',
          date: DateTime(2024, 3, 31),
          meta: const {'corporateAction': 'stakingReward'},
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        expect(find.text('Récompense de staking · 12.4'), findsOneWidget);
        expect(find.text('Ajustement'), findsNothing);
        // Sous-titre : quantité brute (pas de troncature) — pas de « × »
        // (pas de prix, ce n'est pas un « qté × prix ») ni de « € » (pas
        // d'équivalent EUR sur une récompense).
        expect(find.textContaining('×'), findsNothing);
        expect(find.textContaining('€'), findsNothing);
      },
    );

    testWidgets(
      'un agrégat mensuel de récompenses (meta[\'aggregatedRows\']) affiche '
      'la quantité DU MOUVEMENT (déjà le total du mois) — rien à recalculer',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-reward-agg',
          accountId: _accountId,
          symbol: 'SOL-EUR',
          kind: TransactionKind.adjustment,
          quantity: '3.087654321',
          currency: 'EUR',
          date: DateTime(2024, 5, 1),
          meta: const {
            'corporateAction': 'stakingReward',
            'aggregation': 'monthly',
            'replaceable': true,
            'aggregatedMonth': '2024-05',
            'aggregatedRows': 27,
            'aggregatedFrom': '2024-05-01',
            'aggregatedTo': '2024-05-31',
          },
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        expect(
          find.text('Récompense de staking · 3.087654321'),
          findsOneWidget,
        );
        expect(find.textContaining('€'), findsNothing);
      },
    );

    testWidgets(
      'un ajustement NU (sans meta[\'corporateAction\']), même avec une '
      'quantité, garde son rendu inchangé — pas de fuite du rendu récompense',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-plain-adjustment',
          accountId: _accountId,
          symbol: 'AAPL',
          kind: TransactionKind.adjustment,
          quantity: '5',
          currency: 'EUR',
          date: DateTime(2024, 6, 1),
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        expect(find.text('Ajustement'), findsOneWidget);
        expect(find.textContaining('Récompense'), findsNothing);
      },
    );

    // ------------------------------------------------------------------- Demande
    // auteur, drive B16 (« voir la quantité de crypto retirée et l'équivalent en
    // cash ») : tuile d'un transferOut EN NATURE.
    // -------------------------------------------------------------------

    testWidgets(
      'transferOut avec meta[\'valueEur\'] : quantité ET « ≈ X € » affichés',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-transferout-eur',
          accountId: _accountId,
          symbol: 'BTC-EUR',
          kind: TransactionKind.transferOut,
          quantity: '0.015',
          currency: 'EUR',
          date: DateTime(2024, 4, 1),
          meta: const {
            'valuationUsd': '900',
            'valueEur': '810',
            'fxRate': '0.9',
            'fxDate': '2024-04-01',
          },
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        final eurLabel = Formatters.formatEur(810);
        expect(find.text('0.015 (≈ $eurLabel)'), findsOneWidget);
      },
    );

    testWidgets(
      'transferOut SANS meta[\'valueEur\'] (FX indisponible ou jambe USD '
      'illisible) : quantité SEULE, pas de « ≈ »',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-transferout-noeur',
          accountId: _accountId,
          symbol: 'BTC-EUR',
          kind: TransactionKind.transferOut,
          quantity: '0.02',
          currency: 'EUR',
          date: DateTime(2024, 4, 2),
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        expect(find.text('0.02'), findsOneWidget);
        expect(find.textContaining('≈'), findsNothing);
      },
    );

    testWidgets(
      'transferOut avec meta[\'valueEur\'] minuscule (poussière) : '
      '« < 0,01 € » plutôt que « ≈ 0,00 € » (se lirait comme une valeur '
      'manquante)',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-transferout-dust',
          accountId: _accountId,
          symbol: 'SHIB-EUR',
          kind: TransactionKind.transferOut,
          quantity: '0.0000000001',
          currency: 'EUR',
          date: DateTime(2024, 4, 5),
          meta: const {
            'valuationUsd': '0.0000001',
            'valueEur': '0.00000009',
            'fxRate': '0.9',
            'fxDate': '2024-04-05',
          },
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        expect(find.text('0.0000000001 (< 0,01 €)'), findsOneWidget);
        expect(find.textContaining('0,00 €'), findsNothing);
      },
    );

    // ------------------------------------------------------------------- Demande
    // auteur, drive B16 (« sur les dépôts en crypto, est-ce possible d'avoir
    // l'équivalent cash ? ») : tuile d'un dépôt en nature (adjustment
    // inKindDeposit) — la puce « Dépôt » le remonte déjà (cas spécial
    // filterJournal, non-régression couverte plus bas), la tuile affiche désormais
    // quantité + équivalent EUR comme un retrait.
    // -------------------------------------------------------------------

    testWidgets(
      'dépôt en nature (coût EUR) : quantité + « ≈ X € » remplacent le '
      '« qty × prix » brut ; filtre « Dépôt » le remonte toujours',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-inkind-deposit',
          accountId: _accountId,
          symbol: 'BTC-EUR',
          kind: TransactionKind.adjustment,
          quantity: '0.5',
          unitPrice: '45000',
          currency: 'EUR',
          date: DateTime(2024, 4, 3),
          meta: const {'inKindDeposit': true, 'valuationSource': 'statement'},
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        final eurLabel = Formatters.formatEur(22500);
        expect(find.text('0.5 (≈ $eurLabel)'), findsOneWidget);
        expect(find.text('0.5 × 45000 EUR'), findsNothing);

        // Filtre « Dépôt » : la tuile reste visible (cas spécial filterJournal).
        await tester.tap(find.text('Dépôt'));
        await tester.pumpAndSettle();
        expect(find.text('0.5 (≈ $eurLabel)'), findsOneWidget);
      },
    );

    testWidgets(
      'dépôt en nature (coût USD + meta[\'fxRate\']) : converti en EUR — '
      'ne reste JAMAIS affiché en dollars',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-inkind-deposit-usd',
          accountId: _accountId,
          symbol: 'XRP-USD',
          kind: TransactionKind.adjustment,
          quantity: '4.67848',
          unitPrice: '1.709957080077',
          currency: 'USD',
          date: DateTime(2024, 4, 4),
          meta: const {
            'inKindDeposit': true,
            'valuationSource': 'statement',
            'valuationUsd': '8.0000',
            'fxRate': '0.9',
            'fxDate': '2024-04-04',
          },
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        // 4.67848 × 1.709957080077 × 0.9 ≈ 7,20 €.
        final eurLabel = Formatters.formatEur(4.67848 * 1.709957080077 * 0.9);
        expect(find.text('4.67848 (≈ $eurLabel)'), findsOneWidget);
        // Le sous-titre brut « qty × prix USD » n'apparaît plus (seul le
        // symbole « XRP-USD » du titre mentionne encore le dollar).
        expect(
          find.textContaining('1.709957080077 USD'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Problème 2 (drive B16 : dépôt en nature valorisé À LA MAIN '
      '(meta[\'valueEur\'] posée par finalizeCryptoExchanges, currency '
      '\'USD\' réécrite en aval par la cascade ticker, AUCUN fxRate) → '
      '« quantité (≈ X €) », JAMAIS le brut « qty × prix USD »',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-inkind-deposit-usd-manual',
          accountId: _accountId,
          symbol: 'STRK22691-USD',
          kind: TransactionKind.adjustment,
          quantity: '4.67848',
          unitPrice: '1.709957080077',
          currency: 'USD',
          date: DateTime(2024, 4, 6),
          meta: const {
            'inKindDeposit': true,
            'valuationSource': 'manual',
            'valueEur': '8',
          },
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        final eurLabel = Formatters.formatEur(8);
        expect(find.text('4.67848 (≈ $eurLabel)'), findsOneWidget);
        expect(find.textContaining('1.709957080077 USD'), findsNothing);
      },
    );

    testWidgets(
      'dépôt en nature (coût USD SANS meta[\'fxRate\'] NI meta[\'valueEur\'], '
      'mouvement importé AVANT le correctif Problème 2) : repli sur '
      '« qty × prix USD » brut, JAMAIS de conversion inventée',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-inkind-deposit-usd-nofx',
          accountId: _accountId,
          symbol: 'XRP-USD',
          kind: TransactionKind.adjustment,
          quantity: '4.67848',
          unitPrice: '1.709957080077',
          currency: 'USD',
          date: DateTime(2024, 4, 6),
          meta: const {
            'inKindDeposit': true,
            'valuationSource': 'manual',
          },
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        expect(
          find.text('4.67848 × 1.709957080077 USD'),
          findsOneWidget,
        );
        expect(find.textContaining('≈'), findsNothing);
      },
    );

    testWidgets(
      'dépôt en nature (poussière, coût EUR quasi nul) : « < 0,01 € » '
      'plutôt que « ≈ 0,00 € »',
      (tester) async {
        final tx = AssetTransaction(
          id: 'tx-inkind-deposit-dust',
          accountId: _accountId,
          symbol: 'SHIB-EUR',
          kind: TransactionKind.adjustment,
          quantity: '0.0000000001',
          unitPrice: '92396.9158',
          currency: 'EUR',
          date: DateTime(2024, 4, 7),
          meta: const {'inKindDeposit': true, 'valuationSource': 'statement'},
        );
        final ledger = _FakeLedgerService([tx]);
        await tester.pumpWidget(_host(txs: [tx], ledger: ledger));
        await tester.pumpAndSettle();

        expect(find.text('0.0000000001 (< 0,01 €)'), findsOneWidget);
        expect(find.textContaining('0,00 €'), findsNothing);
      },
    );
  });
}

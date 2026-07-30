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
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
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

Account _account() => Account(
      id: _accountId,
      walletId: 'wallet-1',
      name: 'Compte test',
      kind: AccountKind.cto,
      currency: 'EUR',
    );

Widget _host({
  required List<AssetTransaction> txs,
  required _FakeLedgerService ledger,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('fr'),
    home: AccountJournalPage(
      accountId: _accountId,
      accountName: 'Compte test',
      debugTransactionStorage: _FakeTransactionStorage(txs),
      debugAccountStorage: _FakeAccountStorage(_account()),
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
      'openingBalance / adjustment ESPÈCES (système) : tap → popup '
      '« Mouvement automatique », JAMAIS le dialogue d\'édition, aucun '
      'bouton supprimer',
      (tester) async {
        final txs = [
          _cashTx(
            id: 'tx-opening',
            kind: TransactionKind.openingBalance,
            date: DateTime(2024, 2, 1),
            amount: '1000',
          ),
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
}

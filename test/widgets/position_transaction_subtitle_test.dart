// test/widgets/position_transaction_subtitle_test.dart
//
// Rendu de la liste « Mouvements » de la fiche position
// (`position_detail_page.dart`) pour un `adjustment` porteur du marqueur
// `meta['corporateAction'] == 'stakingReward'` (récompense de staking crypto,
// coût 0 — cf. `CryptoLedgerNormalizer._emitRewardIndividual` et
// l'agrégation mensuelle). Avant ce correctif, ces mouvements affichaient le
// libellé générique « Ajustement » SANS la quantité reçue (`unitPrice` est
// TOUJOURS null sur ces lignes, donc la branche historique « qty × prix »
// n'était jamais atteinte, ni aucune autre branche dédiée).
//
// Cible [positionTransactionSubtitle] (fonction PURE, extraite du corps de
// `_PositionDetailPageState._buildTransactionTile` pour rester testable) :
// c'est un WIDGET test (pompage réel via `AppLocalizations.of(context)!`,
// pas une instanciation manuelle d'`AppLocalizationsFr`/`AppLocalizationsEn`)
// mais SANS jamais construire `PositionDetailPage` lui-même — cette page pose
// `MarketDataService.shared`/`ExchangeRateService()`/`AccountStorage()` en
// dur dans ses champs d'état (aucun paramètre de constructeur injectable, à
// la différence d'`AccountJournalPage`), donc la pomper réellement
// exigerait du réseau et une base SQLite. Zéro appel réseau ici.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/position_detail_page.dart';

AssetTransaction _tx({
  TransactionKind kind = TransactionKind.adjustment,
  String? quantity,
  String? unitPrice,
  Map<String, dynamic>? meta,
}) {
  return AssetTransaction(
    id: 'tx-1',
    accountId: 'a1',
    symbol: 'SOL',
    kind: kind,
    quantity: quantity,
    unitPrice: unitPrice,
    currency: 'EUR',
    date: DateTime(2026, 3, 1),
    meta: meta,
  );
}

/// Pompe UNIQUEMENT la fonction pure ciblée, à travers la VRAIE chaîne de
/// délégués de localisation (comme le ferait `_buildTransactionTile`) —
/// aucune dépendance à `PositionDetailPage`.
Widget _subtitleHost(AssetTransaction tx, {Locale locale = const Locale('fr')}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: locale,
    home: Builder(
      builder: (context) {
        final l10n = AppLocalizations.of(context)!;
        return Text(positionTransactionSubtitle(l10n, tx));
      },
    ),
  );
}

void main() {
  group('positionTransactionSubtitle — récompense de staking', () {
    testWidgets(
      'adjustment marqué stakingReward → « Récompense · <quantité> » (FR)',
      (tester) async {
        final tx = _tx(
          quantity: '12.5',
          meta: const {'corporateAction': 'stakingReward'},
        );
        await tester.pumpWidget(_subtitleHost(tx));

        expect(find.text('Récompense · 12.5'), findsOneWidget);
        // Jamais d'équivalent EUR sur une récompense — ni cours du jour, ni
        // cours actuel (décision auteur explicite, hors périmètre de ce
        // correctif d'affichage).
        expect(find.textContaining('€'), findsNothing);
      },
    );

    testWidgets(
      'adjustment marqué stakingReward → « Reward · <quantity> » (EN)',
      (tester) async {
        final tx = _tx(
          quantity: '0.003125',
          meta: const {'corporateAction': 'stakingReward'},
        );
        await tester.pumpWidget(_subtitleHost(tx, locale: const Locale('en')));

        expect(find.text('Reward · 0.003125'), findsOneWidget);
      },
    );

    testWidgets(
      'quantité de précision fine préservée telle quelle (pas de troncature)',
      (tester) async {
        final tx = _tx(
          quantity: '0.00000001',
          meta: const {'corporateAction': 'stakingReward'},
        );
        await tester.pumpWidget(_subtitleHost(tx));

        expect(find.text('Récompense · 0.00000001'), findsOneWidget);
      },
    );
  });

  group('positionTransactionSubtitle — écart d\'import enregistré', () {
    testWidgets(
      'adjustment marqué internalTransferResidual → '
      '« Écart d\'import enregistré · <quantité> » (FR)',
      (tester) async {
        final tx = _tx(
          quantity: '7.5',
          meta: const {'internalTransferResidual': true, 'replaceable': true},
        );
        await tester.pumpWidget(_subtitleHost(tx));

        expect(
          find.text('Écart d\'import enregistré · 7.5'),
          findsOneWidget,
        );
        // Jamais d'équivalent EUR — même décision auteur que la récompense.
        expect(find.textContaining('€'), findsNothing);
      },
    );

    testWidgets(
      'adjustment marqué internalTransferResidual → '
      '« Recorded import discrepancy · <quantity> » (EN)',
      (tester) async {
        final tx = _tx(
          quantity: '0.168',
          meta: const {'internalTransferResidual': true},
        );
        await tester.pumpWidget(_subtitleHost(tx, locale: const Locale('en')));

        expect(
          find.text('Recorded import discrepancy · 0.168'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'quantité SIGNÉE négative préservée telle quelle (un écart peut '
      'retirer)',
      (tester) async {
        final tx = _tx(
          quantity: '-0.036427675',
          meta: const {'internalTransferResidual': true},
        );
        await tester.pumpWidget(_subtitleHost(tx));

        expect(
          find.text('Écart d\'import enregistré · -0.036427675'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'stakingReward prime sur internalTransferResidual si (hypothétiquement) '
      'les deux marqueurs coexistaient',
      (tester) async {
        final tx = _tx(
          quantity: '1',
          meta: const {
            'corporateAction': 'stakingReward',
            'internalTransferResidual': true,
          },
        );
        await tester.pumpWidget(_subtitleHost(tx));

        expect(find.text('Récompense · 1'), findsOneWidget);
      },
    );
  });

  group('positionTransactionSubtitle — non-régression', () {
    testWidgets(
      'adjustment nu (sans meta) → « Ajustement », rendu inchangé',
      (tester) async {
        final tx = _tx();
        await tester.pumpWidget(_subtitleHost(tx));

        expect(find.text('Ajustement'), findsOneWidget);
      },
    );

    testWidgets(
      'adjustment avec quantité mais SANS marqueur stakingReward → '
      '« Ajustement » (pas de fuite du nouveau rendu)',
      (tester) async {
        final tx = _tx(quantity: '5');
        await tester.pumpWidget(_subtitleHost(tx));

        expect(find.text('Ajustement'), findsOneWidget);
      },
    );

    testWidgets(
      'adjustment classique quantité × prix (recomptage manuel) → '
      'branche générique inchangée, pas « Récompense »',
      (tester) async {
        final tx = _tx(quantity: '3', unitPrice: '150');
        await tester.pumpWidget(_subtitleHost(tx));

        expect(find.text('3 × 150 EUR'), findsOneWidget);
        expect(find.textContaining('Récompense'), findsNothing);
      },
    );

    testWidgets(
      'un dépôt en nature (inKindDeposit) garde la priorité sur '
      'stakingReward si (hypothétiquement) les deux marqueurs coexistaient',
      (tester) async {
        final tx = _tx(
          quantity: '2',
          meta: const {
            'inKindDeposit': true,
            'valueEur': '40.0',
          },
        );
        await tester.pumpWidget(_subtitleHost(tx));

        final eurLabel = Formatters.formatEur(40.0);
        expect(find.text('2 (≈ $eurLabel)'), findsOneWidget);
      },
    );
  });
}

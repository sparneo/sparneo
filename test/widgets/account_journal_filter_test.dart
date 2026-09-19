// test/widgets/account_journal_filter_test.dart
//
// Tests UNITAIRES de la fonction pure filterJournal.
//
// Stratégie :
//   - Zéro dépendance Flutter / réseau : uniquement le modèle AssetTransaction
//     et la fonction filterJournal extraite dans account_journal_page.dart.
//   - Couvre : aucun filtre, filtre par kind, filtre par période (borne incluse,
//     borne exclue), combinaison kind+période, liste vide, ordre préservé.

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/widgets/account_journal_page.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AssetTransaction _tx({
  required String id,
  required TransactionKind kind,
  required DateTime date,
  String? symbol,
  Map<String, dynamic>? meta,
}) {
  return AssetTransaction(
    id: id,
    accountId: 'acc1',
    symbol: symbol,
    kind: kind,
    currency: 'EUR',
    date: date,
    meta: meta,
  );
}

void main() {
  // Dates de référence
  final now = DateTime(2026, 7, 6, 12, 0);
  final d10ago = now.subtract(const Duration(days: 10));
  final d30ago = now.subtract(const Duration(days: 30));
  final d60ago = now.subtract(const Duration(days: 60));
  final d400ago = now.subtract(const Duration(days: 400));

  // Corpus de base (ordre intentionnellement DATE DESC pour coller au tri DB)
  final buy1 = _tx(id: 'b1', kind: TransactionKind.buy, date: d10ago, symbol: 'AAPL');
  final sell1 = _tx(id: 's1', kind: TransactionKind.sell, date: d30ago, symbol: 'AAPL');
  final dividend1 = _tx(id: 'dv1', kind: TransactionKind.dividend, date: d60ago, symbol: 'MSFT');
  final deposit1 = _tx(id: 'dp1', kind: TransactionKind.deposit, date: d400ago);
  final withdrawal1 = _tx(id: 'w1', kind: TransactionKind.withdrawal, date: d60ago);
  // Retrait ON-CHAIN VRAI (import crypto B16, restreint : journalisé en NATURE,
  // donc en transferOut, jamais en withdrawal — porte meta['inKindWithdrawal']
  // == true (ligne source de type BRUT `withdrawal`) — cf. cas spécial RESTREINT
  // dans filterJournal.
  final transferOut1 = _tx(
    id: 'to1',
    kind: TransactionKind.transferOut,
    date: d60ago,
    symbol: 'BTC-EUR',
    meta: const {'inKindWithdrawal': true, 'importKey': 'ref:acc1:RIW1'},
  );
  // Poussière de délistage (import crypto B16, retour auteur, symétrique EXACT
  // du Problème 1 côté dépôt, commit 78198a4) : même kind transferOut, IMPORTÉE
  // (meta['importKey'] présente) mais SANS le flag dédié — écriture INTERNE de
  // plateforme, ne doit PLUS fuiter sous « Retrait ».
  final transferOutDelisting1 = _tx(
    id: 'tod1',
    kind: TransactionKind.transferOut,
    date: d60ago,
    symbol: 'ETH-EUR',
    meta: const {'importKey': 'ref:acc1:RIW2'},
  );
  // Sortie en nature SAISIE À LA MAIN (formulaire du journal, jamais un
  // import) : aucune meta['importKey'] — matche quand même la puce
  // « Retrait » (discriminant manuel/importé retenu).
  final transferOutManual1 = _tx(
    id: 'tom1',
    kind: TransactionKind.transferOut,
    date: d60ago,
    symbol: 'SOL-EUR',
  );
  // Dépôt ON-CHAIN (import crypto B16, demande auteur : journalisé en NATURE,
  // donc en adjustment VALORISÉ (meta['inKindDeposit'] == true), jamais en
  // deposit (réservé au cash) — cf. cas spécial symétrique.
  final inKindDeposit1 = _tx(
    id: 'ikd1',
    kind: TransactionKind.adjustment,
    date: d60ago,
    symbol: 'BTC-EUR',
    meta: const {'inKindDeposit': true, 'valuationSource': 'statement'},
  );
  // Autres `adjustment` du même import crypto — ne doivent JAMAIS fuiter sous
  // « Dépôt » : agrégat mensuel de récompenses (kind adjustment SANS la clé
  // dédiée) et résidu de transfert interne (meta distincte,
  // `internalTransferResidual`).
  final rewardAggregate1 = _tx(
    id: 'agg1',
    kind: TransactionKind.adjustment,
    date: d60ago,
    meta: const {
      'corporateAction': 'stakingReward',
      'aggregation': 'monthly',
    },
  );
  final internalResidual1 = _tx(
    id: 'res1',
    kind: TransactionKind.adjustment,
    date: d60ago,
    symbol: 'ETH-EUR',
    meta: const {'internalTransferResidual': true, 'replaceable': true},
  );
  // `adjustment` sans meta du tout (mouvement saisi/importé AVANT que cette
  // clé existe) — cas défensif, ne doit pas non plus fuiter.
  final plainAdjustment1 =
      _tx(id: 'padj1', kind: TransactionKind.adjustment, date: d60ago);
  // Position initiale déclarative — kind SYSTÈME différent d'adjustment, sert
  // à vérifier que le filtre « Récompenses » n'élargit pas au-delà
  // d'adjustment/stakingReward (décision auteur.
  final openingBalance1 =
      _tx(id: 'ob1', kind: TransactionKind.openingBalance, date: d60ago);

  final allTxs = [buy1, sell1, dividend1, deposit1, withdrawal1];
  final allTxsWithTransferOut = [
    ...allTxs,
    transferOut1,
    transferOutDelisting1,
    transferOutManual1,
  ];
  final allTxsWithInKindDeposit = [
    ...allTxs,
    inKindDeposit1,
    rewardAggregate1,
    internalResidual1,
    plainAdjustment1,
  ];

  // -------------------------------------------------------------------------
  group('filterJournal — aucun filtre', () {
    test('retourne toutes les transactions', () {
      final result = filterJournal(allTxs);
      expect(result, hasLength(allTxs.length));
      expect(result, containsAll(allTxs));
    });

    test('liste vide en entrée → liste vide en sortie', () {
      expect(filterJournal([]), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('filterJournal — filtre par kind', () {
    test('garde uniquement les buy', () {
      final result = filterJournal(allTxs, kind: TransactionKind.buy);
      expect(result, [buy1]);
    });

    test('garde uniquement les sell', () {
      final result = filterJournal(allTxs, kind: TransactionKind.sell);
      expect(result, [sell1]);
    });

    test('garde uniquement les dividend', () {
      final result = filterJournal(allTxs, kind: TransactionKind.dividend);
      expect(result, [dividend1]);
    });

    test('garde uniquement les deposit', () {
      final result = filterJournal(allTxs, kind: TransactionKind.deposit);
      expect(result, [deposit1]);
    });

    test('garde uniquement les withdrawal', () {
      final result = filterJournal(allTxs, kind: TransactionKind.withdrawal);
      expect(result, [withdrawal1]);
    });

    test('kind sans correspondance → liste vide', () {
      final onlyBuy = [buy1];
      final result = filterJournal(onlyBuy, kind: TransactionKind.sell);
      expect(result, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Décision auteur, drive B16, RESTREINTE (retour auteur, symétrique EXACT du
  // Problème 1 côté dépôt, commit 78198a4) : la puce « Retrait » matche un
  // transferOut SEULEMENT s'il est un VRAI retrait (meta['inKindWithdrawal'] ==
  // true) ou SAISI À LA MAIN (pas de meta['importKey']) — les poussières de
  // délistage importées SANS le flag (transferOutDelisting1) en sortent.
  group('filterJournal — cas spécial withdrawal/transferOut (import crypto B16, restreint)', () {
    test(
      'kind: withdrawal remonte le withdrawal espèces, le VRAI retrait '
      'transferOut flagué ET le transferOut manuel — mais PAS la poussière '
      'de délistage importée sans le flag',
      () {
        final result = filterJournal(
          allTxsWithTransferOut,
          kind: TransactionKind.withdrawal,
        );
        expect(
          result,
          containsAll([withdrawal1, transferOut1, transferOutManual1]),
        );
        expect(result, isNot(contains(transferOutDelisting1)));
        expect(result, hasLength(3));
      },
    );

    test(
      'un autre kind (buy) ne fait PAS fuiter les transferOut : le cas '
      'spécial est strictement réservé à withdrawal',
      () {
        final result = filterJournal(
          allTxsWithTransferOut,
          kind: TransactionKind.buy,
        );
        expect(result, [buy1]);
        expect(result, isNot(contains(transferOut1)));
      },
    );
  });

  // -------------------------------------------------------------------------
  // Décision auteur, drive B16 : la puce « Dépôt » matche AUSSI l'adjustment
  // `inKindDeposit` (dépôt on-chain journalisé en nature à l'import crypto) — cas
  // spécial SYMÉTRIQUE de withdrawal/transferOut, mais SANS fuite des autres
  // adjustments (agrégats de récompenses, résidus de transferts internes,
  // adjustment sans meta).
  group('filterJournal — cas spécial deposit/inKindDeposit (import crypto B16)', () {
    test(
      'kind: deposit remonte le deposit espèces ET l\'adjustment '
      'inKindDeposit, aucun autre adjustment',
      () {
        final result = filterJournal(
          allTxsWithInKindDeposit,
          kind: TransactionKind.deposit,
        );
        expect(result, containsAll([deposit1, inKindDeposit1]));
        expect(result, hasLength(2));
      },
    );

    test(
      'les autres adjustments (agrégat de récompenses, résidu de transfert '
      'interne, adjustment sans meta) ne fuitent JAMAIS sous « Dépôt »',
      () {
        final result = filterJournal(
          allTxsWithInKindDeposit,
          kind: TransactionKind.deposit,
        );
        expect(result, isNot(contains(rewardAggregate1)));
        expect(result, isNot(contains(internalResidual1)));
        expect(result, isNot(contains(plainAdjustment1)));
      },
    );

    test(
      'un autre kind (buy) ne fait PAS fuiter l\'inKindDeposit : le cas '
      'spécial est strictement réservé à deposit',
      () {
        final result = filterJournal(
          allTxsWithInKindDeposit,
          kind: TransactionKind.buy,
        );
        expect(result, [buy1]);
        expect(result, isNot(contains(inKindDeposit1)));
      },
    );

    test('kind: withdrawal reste inchangé (non-régression) — n\'inclut aucun adjustment', () {
      final result = filterJournal(
        allTxsWithInKindDeposit,
        kind: TransactionKind.withdrawal,
      );
      expect(result, [withdrawal1]);
    });
  });

  // -------------------------------------------------------------------------
  // Décision auteur (« Récompenses », puce dédiée réservée aux comptes crypto) :
  // rewardsOnly matche UNIQUEMENT un adjustment portant meta['corporateAction'] ==
  // 'stakingReward' — jamais un adjustment nu, ni un dépôt en nature
  // (inKindDeposit), ni un openingBalance.
  group('filterJournal — cas spécial rewardsOnly (puce Récompenses)', () {
    final corpus = [
      ...allTxsWithInKindDeposit,
      openingBalance1,
    ];

    test('remonte uniquement l\'agrégat de récompenses stakingReward', () {
      final result = filterJournal(corpus, rewardsOnly: true);
      expect(result, [rewardAggregate1]);
    });

    test(
      'exclut un adjustment nu (sans meta), un dépôt en nature '
      '(inKindDeposit), un résidu de transfert interne et un openingBalance',
      () {
        final result = filterJournal(corpus, rewardsOnly: true);
        expect(result, isNot(contains(plainAdjustment1)));
        expect(result, isNot(contains(inKindDeposit1)));
        expect(result, isNot(contains(internalResidual1)));
        expect(result, isNot(contains(openingBalance1)));
      },
    );

    test('rewardsOnly ignore kind s\'il est fourni en même temps', () {
      // rewardsOnly est un filtre à part entière (cf. doc filterJournal) :
      // un `kind` fourni en parallèle n'a aucun effet.
      final result = filterJournal(
        corpus,
        kind: TransactionKind.buy,
        rewardsOnly: true,
      );
      expect(result, [rewardAggregate1]);
    });

    test('sans rewardsOnly (comportement par défaut), aucun changement — '
        'l\'agrégat de récompenses reste hors du filtre deposit '
        '(non-régression)', () {
      final result = filterJournal(corpus, kind: TransactionKind.deposit);
      expect(result, isNot(contains(rewardAggregate1)));
    });
  });

  // -------------------------------------------------------------------------
  group('filterJournal — filtre par période', () {
    test('notBefore = d30ago exclut les transactions antérieures strictement', () {
      // buy1 (d10ago) et sell1 (exactement d30ago) doivent passer ;
      // dividend1 (d60ago), deposit1 (d400ago), withdrawal1 (d60ago) exclus.
      final result = filterJournal(allTxs, notBefore: d30ago);
      expect(result, containsAll([buy1, sell1]));
      expect(result, isNot(contains(dividend1)));
      expect(result, isNot(contains(deposit1)));
      expect(result, isNot(contains(withdrawal1)));
    });

    test('borne incluse : tx exactement à la date cutoff est gardée', () {
      // sell1.date == d30ago exactement
      final result = filterJournal([sell1], notBefore: d30ago);
      expect(result, [sell1]);
    });

    test('borne exclut une tx une seconde avant le cutoff', () {
      final cutoff = d30ago;
      final justBefore = cutoff.subtract(const Duration(seconds: 1));
      final txJustBefore = _tx(id: 'jb', kind: TransactionKind.buy, date: justBefore);
      final result = filterJournal([txJustBefore], notBefore: cutoff);
      expect(result, isEmpty);
    });

    test('notBefore null → pas de borne basse', () {
      final result = filterJournal(allTxs, notBefore: null);
      expect(result, hasLength(allTxs.length));
    });
  });

  // -------------------------------------------------------------------------
  group('filterJournal — combinaison kind + période', () {
    test('buy dans les 60 derniers jours', () {
      // buy1 (d10ago, buy) passe ; sell1 (d30ago, sell) : mauvais kind ;
      // dividend1 (d60ago) : hors période (d60ago == cutoff) et mauvais kind ;
      // deposit1 (d400ago) : hors période et mauvais kind.
      final result = filterJournal(
        allTxs,
        kind: TransactionKind.buy,
        notBefore: d60ago,
      );
      expect(result, [buy1]);
    });

    test('dividend dans les 30 derniers jours → vide', () {
      // dividend1 est à d60ago, hors de la fenêtre 30 jours
      final result = filterJournal(
        allTxs,
        kind: TransactionKind.dividend,
        notBefore: d30ago,
      );
      expect(result, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  group('filterJournal — ordre préservé', () {
    test('l\'ordre d\'entrée est conservé après filtrage', () {
      // On construit une liste triée date DESC (comme la DB)
      final ordered = [buy1, sell1, dividend1, withdrawal1, deposit1];
      final result = filterJournal(ordered); // aucun filtre
      expect(result, ordered);
    });

    test('filtre par kind préserve l\'ordre relatif', () {
      final txA = _tx(id: 'a', kind: TransactionKind.buy, date: d10ago);
      final txB = _tx(id: 'b', kind: TransactionKind.sell, date: d30ago);
      final txC = _tx(id: 'c', kind: TransactionKind.buy, date: d60ago);
      final result = filterJournal([txA, txB, txC], kind: TransactionKind.buy);
      expect(result, [txA, txC]);
    });
  });
}

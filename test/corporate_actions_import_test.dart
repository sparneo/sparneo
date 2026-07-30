// test/corporate_actions_import_test.dart
//
// Traitement des OPÉRATIONS SUR TITRES (corporate actions) Bourse Direct :
// mapping code → effet modèle (transferOut / attribution gratuite / rompus /
// changement de place / à revoir / régularisation espèces), projection B* du
// nouveau kind `transferOut`, et masquage des résidus non cotés sans valeur.
//
// FIXTURES 100 % SYNTHÉTIQUES : codes/quantités/prix/ISIN inventés. On alimente
// `normalize` directement avec des lignes déjà « parsées » (List<List<String>>)
// — aucun fichier disque, aucune donnée réelle.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

const _isin = 'FR0000000001'; // ISIN factice

// Colonnes du profil Bourse Direct, dans l'ordre attendu par le mapping byName.
const _header = <String>[
  'DateOperation',
  'CodeOperation',
  'libelleMouvement',
  'isin',
  'Quantite',
  'cours',
  'Courtage',
  'Net',
  'SensEsp', // sens ESPÈCES fiable (D=sortie, C=entrée)
];

/// Une ligne de données : [date(YYYYMMDD), code, libellé, isin, qté, cours,
/// courtage, net, sensEsp]. Prépend l'en-tête pour former l'entrée de
/// `normalize` (le mapping se fait par NOM ; les cellules manquantes en fin de
/// ligne sont tolérées → colonne absente).
List<List<String>> _rows(List<List<String>> data) => [_header, ...data];

List<ImportedMovement> _normalize(List<List<String>> data) =>
    StatementImportService.normalize(
      _rows(data),
      BrokerProfile.bourseDirect(),
      accountCurrency: 'EUR',
    );

ImportedMovement _one(List<String> row) => _normalize([row]).single;

void main() {
  group('normalize — mapping des corporate actions', () {
    test('RTFIS → transferOut (sortie de titres, aucun cash)', () {
      final m = _one(
        ['20200115', 'RTFIS', 'Retrait Titres', _isin, '5', '42', '', ''],
      );
      expect(m.isRejected, isFalse);
      final tx = m.transaction!;
      expect(tx.kind, TransactionKind.transferOut);
      expect(Decimal.parse(tx.quantity!), Decimal.parse('5'));
      // Sortie de titres : AUCUN effet cash, unitPrice non pertinent.
      expect(tx.amount, isNull);
      expect(tx.unitPrice, isNull);
      expect(m.isin, _isin);
    });

    test('VRSOR → transferOut (non-régression : ne ponctionne PLUS le cash)',
        () {
      final m = _one(
        ['20200116', 'VRSOR', 'Virement Titres', _isin, '3', '10', '', ''],
      );
      final tx = m.transaction!;
      // Ancien bug : VRSOR → withdrawal (retrait d'espèces). Désormais sortie
      // de TITRES : jamais withdrawal, jamais d'amount cash.
      expect(tx.kind, TransactionKind.transferOut);
      expect(tx.kind, isNot(TransactionKind.withdrawal));
      expect(tx.amount, isNull);
      expect(Decimal.parse(tx.quantity!), Decimal.parse('3'));
    });

    test('ATTRI → adjustment titre à coût 0 (unitPrice/amount null)', () {
      final m = _one(
        ['20200117', 'ATTRI', 'Attribution', _isin, '2', '15', '', ''],
      );
      final tx = m.transaction!;
      expect(tx.kind, TransactionKind.adjustment);
      expect(Decimal.parse(tx.quantity!), Decimal.parse('2'));
      expect(tx.unitPrice, isNull); // coût 0 forcé → PRU en baisse
      expect(tx.amount, isNull);
    });

    test('ODRMP → sell (rompus rachetés : réduit la qté, crédite le Net)', () {
      final m = _one(
        ['20200118', 'ODRMP', 'Rompus', _isin, '0.4', '12', '', '4.8'],
      );
      final tx = m.transaction!;
      expect(tx.kind, TransactionKind.sell);
      expect(Decimal.parse(tx.quantity!), Decimal.parse('0.4'));
      expect(Decimal.parse(tx.unitPrice!), Decimal.parse('12'));
      // Net crédité en cash, forcé positif (entrée).
      expect(Decimal.parse(tx.amount!), Decimal.parse('4.8'));
    });

    test('CHGPL → adjustment quantité 0 (quantité-neutre, aucun cash)', () {
      final m = _one(
        ['20200119', 'CHGPL', 'Changement place', _isin, '7', '20', '', ''],
      );
      final tx = m.transaction!;
      expect(tx.kind, TransactionKind.adjustment);
      expect(Decimal.parse(tx.quantity!), Decimal.zero); // no-op
      expect(tx.amount, isNull);
    });

    test(
        'la NATURE de l\'opération est conservée dans meta (affichage du '
        'journal : « Ajustement » seul est indéchiffrable)', () {
      // Trois lignes produisant le MÊME kind `adjustment` pour trois opérations
      // sans rapport — c'est précisément ce qui a alarmé l'auteur sur un import
      // pourtant sain. `meta['corporateAction']` porte le nom de l'enum, stable
      // et traduisible côté UI ; jamais le libellé brut du relevé.
      expect(
        _one(['20200117', 'ATTRI', 'Attribution', _isin, '2', '15', '', ''])
            .transaction!
            .meta?['corporateAction'],
        'freeAttribution',
      );
      expect(
        _one(['20200119', 'CHGPL', 'Changement place', _isin, '7', '20', '', ''])
            .transaction!
            .meta?['corporateAction'],
        'placeChange',
      );
      expect(
        _one(['20200118', 'ODRMP', 'Rompus', _isin, '0.4', '12', '', '4.8'])
            .transaction!
            .meta?['corporateAction'],
        'fractionalRedemption',
      );
      // La clé de dédup n'est PAS affectée par l'ajout de cette clé meta
      // (elle est calculée sur le CONTENU de la ligne, pas sur meta) : un
      // ré-import d'un relevé déjà importé doit rester un doublon.
      final again =
          _one(['20200117', 'ATTRI', 'Attribution', _isin, '2', '15', '', '']);
      expect(again.importKey, isNotNull);
    });

    test('DS → rejet motivé (à revoir manuellement)', () {
      final m = _one(
        ['20200120', 'DS', 'Détachement droit', _isin, '1', '', '', ''],
      );
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, 'corporateActionReview');
    });

    test('PEAMI AVEC ISIN, SensEsp=C → crédité au cash (PLUS de rejet, +)', () {
      // L'ISIN n'est qu'une référence (titre indemnisé) : mouvement de cash pur.
      final m = _one(
        ['20200121', 'PEAMI', 'Régul PEA', _isin, '', '', '', '3.25', 'C'],
      );
      expect(m.isRejected, isFalse); // non-régression du bug d'écart de cash
      final tx = m.transaction!;
      expect(tx.kind, TransactionKind.adjustment);
      expect(tx.symbol, isNull); // position jamais touchée
      // Net NON signé (3.25) + SensEsp=C → crédit → +3.25.
      expect(Decimal.parse(tx.amount!), Decimal.parse('3.25'));
    });

    test('PEAMI SensEsp=D → débité (Net non signé, signe via SensEsp)', () {
      final m = _one(
        ['20200122', 'PEAMI', 'Régul PEA', '', '', '', '', '3.25', 'D'],
      );
      // Même magnitude, mais D (débit/sortie) → négatif.
      expect(Decimal.parse(m.transaction!.amount!), Decimal.parse('-3.25'));
    });

    test('ODOST → cash SORTANT (SensEsp=D), JAMAIS un dividende entrant', () {
      // « Espèces sur OST / souscription irréductible » : paiement (cash out),
      // les titres arrivant via une ligne SOUSC distincte.
      final m = _one(
        ['20200123', 'ODOST', 'Espèces sur OST', _isin, '', '', '', '100', 'D'],
      );
      final tx = m.transaction!;
      expect(tx.kind, TransactionKind.adjustment);
      expect(tx.kind, isNot(TransactionKind.dividend)); // n'est plus un dividende
      expect(tx.symbol, isNull);
      // Cash SORTANT : négatif (l'ancien mapping dividend l'aurait mis positif).
      expect(Decimal.parse(tx.amount!), Decimal.parse('-100'));
    });
  });

  group('normalize — droit de souscription (SOUSC reclassé en sortie)', () {
    const rightsIsin = 'FR0014000IK6'; // ISIN factice « DRONE VOLT DS 20 »

    test('DRONE VOLT : DS rejeté, SOUSC → transferOut, droit soldé à 0', () {
      // Les 3 jambes de QUANTITÉ du droit, sur le MÊME ISIN :
      //   DS    +3568 (réception des droits)   → rejeté (manualReview)
      //   SOUSC  3560 (exercice, droits SORTENT) → reclassé transferOut (−3560)
      //   RTFIS     8 (retrait du reliquat)      → transferOut (−8)
      // Réel : 3568 − 3560 − 8 = 0. Le droit se solde à ≤ 0.
      final movements = _normalize([
        ['20200601', 'DS', 'DRONE VOLT DS', rightsIsin, '3568', '', '', ''],
        // cours présent (0.5) : SANS le reclassement, SOUSC→buy réussirait et
        // ajouterait +3560 (position fantôme). Net VIDE : le cash du buy aurait
        // été un PHANTOM dérivé de quantité×cours.
        ['20200602', 'SOUSC', 'DRONE VOLT DS', rightsIsin, '3560', '0.5', '', ''],
        ['20200603', 'RTFIS', 'DRONE VOLT DS', rightsIsin, '8', '', '', ''],
      ]);

      // DS reste rejeté (à revoir) — jamais journalisé.
      expect(movements[0].isRejected, isTrue);
      expect(movements[0].rejectReason, 'corporateActionReview');

      // SOUSC est désormais une SORTIE de titres, pas un achat.
      final sousc = movements[1].transaction!;
      expect(sousc.kind, TransactionKind.transferOut);
      expect(Decimal.parse(sousc.quantity!), Decimal.parse('3560'));
      expect(sousc.amount, isNull); // aucun cash (phantom du buy supprimé)
      expect(sousc.unitPrice, isNull); // cours ignoré (sortie de titres)

      // RTFIS reste transferOut (inchangé).
      final rtfis = movements[2].transaction!;
      expect(rtfis.kind, TransactionKind.transferOut);
      expect(Decimal.parse(rtfis.quantity!), Decimal.parse('8'));

      // Contribution QUANTITÉ nette du droit ≤ 0 (mécanisme « soldée »).
      final soldee = projectPosition([sousc, rtfis]);
      expect(soldee.quantity, Decimal.zero);

      // Cycle COMPLET (droits reçus puis intégralement sortis) = 0, PAS +3552 :
      // SOUSC est bien compté NÉGATIVEMENT.
      final full = projectPosition([
        AssetTransaction(
          id: 'ob',
          accountId: 'a',
          symbol: 'X',
          kind: TransactionKind.openingBalance,
          quantity: '3568',
          currency: 'EUR',
          date: DateTime(2020, 5, 31),
        ),
        sousc.copyWith(symbol: 'X'),
        rtfis.copyWith(symbol: 'X'),
      ]);
      expect(full.quantity, Decimal.zero);
    });

    test('non-régression : SOUSC sur un ISIN SANS DS reste un ACHAT', () {
      // Souscription réelle d'un titre (pas de ligne DS pour cet ISIN) : le
      // gate ne s'applique PAS → achat normal, quantité positive, cash négatif.
      final m = _one(
        ['20200601', 'SOUSC', 'Vraie souscription', _isin, '10', '25', '', '250'],
      );
      final tx = m.transaction!;
      expect(tx.kind, TransactionKind.buy);
      expect(Decimal.parse(tx.quantity!), Decimal.parse('10'));
      expect(Decimal.parse(tx.unitPrice!), Decimal.parse('25'));
      // Net non signé (250) forcé négatif car achat.
      expect(Decimal.parse(tx.amount!), Decimal.parse('-250'));
    });

    test('cas RUBIS (DS + RTFIS, sans SOUSC) : DS rejeté, RTFIS transferOut', () {
      // Contrôle : un droit SANS ligne SOUSC (déjà soldé par le seul RTFIS)
      // n'est pas affecté par le reclassement — comportement inchangé.
      final movements = _normalize([
        ['20200601', 'DS', 'RUBIS DS', rightsIsin, '100', '', '', ''],
        ['20200602', 'RTFIS', 'RUBIS DS', rightsIsin, '100', '', '', ''],
      ]);
      expect(movements[0].isRejected, isTrue);
      expect(movements[1].transaction!.kind, TransactionKind.transferOut);
      expect(Decimal.parse(movements[1].transaction!.quantity!),
          Decimal.parse('100'));
    });
  });

  group('projection B* — kind transferOut', () {
    AssetTransaction tx(
      TransactionKind kind, {
      String? qty,
      String? price,
      String? amount,
      required DateTime date,
    }) =>
        AssetTransaction(
          id: date.microsecondsSinceEpoch.toString(),
          accountId: 'a',
          symbol: 'X',
          kind: kind,
          quantity: qty,
          unitPrice: price,
          amount: amount,
          currency: 'EUR',
          date: date,
        );

    test('sortie INTÉGRALE : quantité 0, aucune PV, cash inchangé', () {
      final r = replayLedger([
        tx(TransactionKind.buy,
            qty: '10', price: '100', amount: '-1000', date: DateTime(2024, 1, 1)),
        tx(TransactionKind.transferOut,
            qty: '10', date: DateTime(2024, 2, 1)),
      ]);
      expect(r.quantity, Decimal.zero);
      expect(r.realizedGain, 0.0); // transfert ≠ cession
      // Le cash ne reflète QUE le buy (-1000) : transferOut n'a aucun amount.
      expect(r.cashByCurrency['EUR'], Decimal.parse('-1000'));
    });

    test('sortie PARTIELLE : PRU des titres restants INCHANGÉ, aucune PV', () {
      final r = replayLedger([
        tx(TransactionKind.buy,
            qty: '10', price: '100', amount: '-1000', date: DateTime(2024, 1, 1)),
        tx(TransactionKind.transferOut,
            qty: '4', date: DateTime(2024, 2, 1)),
      ]);
      expect(r.quantity, Decimal.parse('6'));
      // Base de coût retirée AU PRORATA (400) → coût restant 600 sur 6 titres →
      // PRU toujours 100 (inchangé).
      expect(r.averagePrice, closeTo(100.0, 1e-9));
      expect(r.realizedGain, 0.0);
    });

    test('attribution gratuite (adjustment coût 0) fait BAISSER le PRU', () {
      final r = replayLedger([
        tx(TransactionKind.buy,
            qty: '10', price: '100', amount: '-1000', date: DateTime(2024, 1, 1)),
        tx(TransactionKind.adjustment,
            qty: '10', date: DateTime(2024, 2, 1)), // unitPrice null → coût 0
      ]);
      expect(r.quantity, Decimal.parse('20'));
      expect(r.averagePrice, closeTo(50.0, 1e-9)); // 1000 / 20
    });
  });

  group('backup round-trip — transaction transferOut', () {
    test('toJson/fromJson préserve kind, quantité et amount null', () {
      final original = AssetTransaction(
        id: 'tx-1',
        accountId: 'a',
        symbol: 'X',
        kind: TransactionKind.transferOut,
        quantity: '5',
        currency: 'EUR',
        date: DateTime(2024, 3, 1),
      );
      final round = AssetTransaction.fromJson(original.toJson());
      expect(round.kind, TransactionKind.transferOut);
      expect(round.quantity, '5');
      expect(round.amount, isNull);
      expect(round.symbol, 'X');
      expect(round.date, original.date);
    });
  });

  group('masquage — résidus non cotés sans valeur (isHeldPosition)', () {
    test('position soldée (quantité 0) → masquée', () {
      expect(
        isHeldPosition(quantity: '0', quotable: true, currentPrice: 12),
        isFalse,
      );
    });

    test('résidu NON coté à valeur nulle → masqué', () {
      expect(
        isHeldPosition(quantity: '3', quotable: false, currentPrice: null),
        isFalse,
      );
      expect(
        isHeldPosition(quantity: '3', quotable: false, currentPrice: 0),
        isFalse,
      );
    });

    test('titre COTÉ de faible valeur (25 €) → affiché', () {
      expect(
        isHeldPosition(quantity: '1', quotable: true, currentPrice: 25),
        isTrue,
      );
    });

    test('résidu non coté MAIS valorisé par un dernier cours (>0) → affiché', () {
      expect(
        isHeldPosition(quantity: '2', quotable: false, currentPrice: 3),
        isTrue,
      );
    });
  });
}

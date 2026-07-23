// test/intraday_ordering_test.dart
//
// Départage INTRADAY du rejeu du journal : les mouvements de MÊME DATE sont
// ordonnés par la séquence de fichier `meta['seq']` (ordre réel du relevé),
// PAS par l'`id` (aléatoire à l'import). Sans cela, une vente ordonnée avant
// son achat du même jour déclenchait le clamp anti-survente et faisait
// disparaître des titres (résidu fantôme sur les allers-retours intraday).
//
// FIXTURES 100 % SYNTHÉTIQUES : quantités/prix/ISIN inventés.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

final _d = DateTime(2020, 6, 15); // même jour pour tout le lot intraday

AssetTransaction _tx(
  TransactionKind kind, {
  required String id,
  required String qty,
  required String price,
  int? seq,
  DateTime? date,
}) =>
    AssetTransaction(
      id: id,
      accountId: 'a',
      symbol: 'X',
      kind: kind,
      quantity: qty,
      unitPrice: price,
      currency: 'EUR',
      date: date ?? _d,
      meta: seq == null ? null : {'seq': seq},
    );

void main() {
  group('replayLedger — départage intraday par meta[seq]', () {
    test('achat(N) + vente(N) même date, id trie vente AVANT achat mais '
        'seq(achat) < seq(vente) → net 0, aucun clamp', () {
      // id : la vente ('001') trierait AVANT l'achat ('999') → survente + clamp.
      // seq : l'achat (0) précède la vente (1) → ordre réel préservé.
      final r = replayLedger([
        _tx(TransactionKind.sell, id: '001', qty: '11', price: '110', seq: 1),
        _tx(TransactionKind.buy, id: '999', qty: '11', price: '100', seq: 0),
      ]);
      expect(r.quantity, Decimal.zero); // pas de résidu fantôme
      // PV = produit 11×110 − coût 11×100 = 110 (WAC dans le bon ordre).
      expect(r.realizedGain, closeTo(110.0, 1e-9));
    });

    test('aller-retour intraday achat100/vente100/achat50/vente50 même date '
        '→ net 0, aucun clamp', () {
      final r = replayLedger([
        _tx(TransactionKind.buy, id: 'b1', qty: '100', price: '10', seq: 0),
        _tx(TransactionKind.sell, id: 's1', qty: '100', price: '12', seq: 1),
        _tx(TransactionKind.buy, id: 'b2', qty: '50', price: '11', seq: 2),
        _tx(TransactionKind.sell, id: 's2', qty: '50', price: '13', seq: 3),
      ]..shuffle(), // l'ordre d'ENTRÉE ne doit rien changer : seq fait foi
      );
      expect(r.quantity, Decimal.zero);
    });

    test('Air Liquide-like : fichier liste VENTE avant ACHAT même date, flat → '
        'net 0, PV exacte, aucun clamp (rang entrées-d\'abord)', () {
      // Le relevé place la vente en premier (seq 0) et l'achat ensuite (seq 1) :
      // seq reproduit fidèlement ce MAUVAIS ordre. Le rang entrée/sortie remet
      // l'achat d'abord → net 0, PV = (110−100)×11 = 110, aucun clamp.
      final withSeq = replayLedger([
        _tx(TransactionKind.sell, id: 's', qty: '11', price: '110', seq: 0),
        _tx(TransactionKind.buy, id: 'b', qty: '11', price: '100', seq: 1),
      ]);
      expect(withSeq.quantity, Decimal.zero);
      expect(withSeq.realizedGain, closeTo(110.0, 1e-9));

      // Même SANS seq (saisies manuelles) : le rang suffit — plus de survente.
      final noSeq = replayLedger([
        _tx(TransactionKind.sell, id: 'a', qty: '11', price: '110'),
        _tx(TransactionKind.buy, id: 'z', qty: '11', price: '100'),
      ]);
      expect(noSeq.quantity, Decimal.zero);
      expect(noSeq.realizedGain, closeTo(110.0, 1e-9));
    });

    test('Fermentalg-like : allers-retours même date commençant par une vente, '
        'flat → net final 0, aucun clamp', () {
      // seq reproduit l'ordre fichier (vente d'abord) ; le rang neutralise.
      final r = replayLedger([
        _tx(TransactionKind.sell, id: 's1', qty: '53', price: '2.5', seq: 0),
        _tx(TransactionKind.buy, id: 'b1', qty: '566', price: '2.0', seq: 1),
        _tx(TransactionKind.sell, id: 's2', qty: '513', price: '2.6', seq: 2),
      ]);
      // Achat 566 traité en premier (rang 0), puis ventes 53+513=566 → net 0.
      expect(r.quantity, Decimal.zero);
    });

    test('détention préalable : hold 100 (date antérieure), même date '
        '[buy 30, sell 40] → net 90, aucun clamp', () {
      final r = replayLedger([
        _tx(TransactionKind.openingBalance,
            id: 'o', qty: '100', price: '10', date: DateTime(2020, 1, 1)),
        _tx(TransactionKind.sell, id: 's', qty: '40', price: '15', seq: 1),
        _tx(TransactionKind.buy, id: 'b', qty: '30', price: '12', seq: 0),
      ]);
      // 100 + 30 (entrée d'abord) − 40 = 90 ; jamais de négatif transitoire.
      expect(r.quantity, Decimal.parse('90'));
    });

    test('transactions manuelles sans seq : ordre par id INCHANGÉ '
        '(non-régression)', () {
      // buy id '1' avant sell id '2' → net 0 (ordre id naturel).
      final r = replayLedger([
        _tx(TransactionKind.sell, id: '2', qty: '5', price: '20'),
        _tx(TransactionKind.buy, id: '1', qty: '5', price: '10'),
      ]);
      expect(r.quantity, Decimal.zero);
      expect(r.realizedGain, closeTo(50.0, 1e-9));
    });

    test('edge manuel(sans seq) + importé(avec seq) même date : repli id '
        '(l\'un sans seq)', () {
      // Un mouvement porte seq, l'autre non → le comparateur retombe sur id
      // (pas de tri par seq quand l\'un des deux en manque). Déterministe.
      final r = replayLedger([
        _tx(TransactionKind.buy, id: 'm', qty: '4', price: '10'), // manuel
        _tx(TransactionKind.buy, id: 'i', qty: '6', price: '20', seq: 0), // import
      ]);
      // Quel que soit l'ordre retenu, deux achats ne se clampent pas : net 10.
      expect(r.quantity, Decimal.parse('10'));
    });
  });

  group('normalize — meta[seq] posée dans l\'ordre chronologique du fichier', () {
    // En-tête minimal du profil Bourse Direct (mapping byName).
    const header = <String>[
      'DateOperation',
      'CodeOperation',
      'libelleMouvement',
      'isin',
      'Quantite',
      'cours',
      'Courtage',
      'Net',
    ];

    test('lot ascendant : seq croît avec les lignes, monotone', () {
      final rows = <List<String>>[
        header,
        // Trois opérations le MÊME jour, ordre du fichier = ordre réel.
        ['20200615', 'AC', 'Titre', 'FR0000000001', '10', '100', '0', '1000'],
        ['20200615', 'VCPT', 'Titre', 'FR0000000001', '4', '110', '0', '440'],
        ['20200615', 'AC', 'Titre', 'FR0000000001', '2', '105', '0', '210'],
      ];
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      final seqs = movements.map((m) => m.transaction!.importSeq).toList();
      // Toutes portent une seq, strictement croissante dans l'ordre du fichier.
      expect(seqs, everyElement(isNotNull));
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i]! > seqs[i - 1]!, isTrue,
            reason: 'seq non monotone : $seqs');
      }
    });
  });
}

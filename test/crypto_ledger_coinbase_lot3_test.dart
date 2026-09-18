// test/crypto_ledger_coinbase_lot3_test.dart
//
// Tests du LOT 3 du chantier B16 (profil Coinbase, conception interne) : le
// moteur PUR (`CryptoLedgerNormalizer.planCryptoImport` via
// `StatementImportService`) sur le profil `BrokerProfile.coinbase()`.
//
// Fixtures 100 % SYNTHÉTIQUES (aucune donnée réelle — hook anti-fuite sur le
// dépôt) : tickers fictifs (PAxx/RBxx…), noms/UUID inventés pour le test des
// lignes parasites, dates arbitraires. Le seul appariement RÉEL exercé (motif
// `counterpartyPattern` embarqué dans `BrokerProfile.coinbase()`) reste testé
// via un texte de note fabriqué de toutes pièces.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

// ---------------------------------------------------------------------------
// Fixture — colonnes du profil Coinbase (§5.3.0), dans l'ordre déclaré par
// `BrokerProfile.coinbase()` (résolues par NOM, l'ORDRE des colonnes du
// fichier synthétique ci-dessous est donc arbitraire mais fixé une fois pour
// toutes pour la lisibilité des lignes).
// ---------------------------------------------------------------------------

const _header = [
  'Timestamp', 'Transaction Type', 'Asset', 'Quantity Transacted',
  'Fees and/or Spread', 'Subtotal', 'Total (inclusive of fees and/or spread)',
  'Price Currency', 'ID', 'Notes', 'Sender Address', //
];

List<String> _row({
  required String timestamp,
  required String type,
  required String asset,
  required String qty,
  String fee = '',
  String subtotal = '',
  // Colonne RÉELLEMENT consultée par `MovementField.amount` (B-1, revue
  // adversariale — cf. `BrokerProfile.coinbase()`) : `Total (inclusive of
  // fees and/or spread)`, JAMAIS `Subtotal` (qui reste réservée à
  // `valuationAmountColumn`, `leg.valuationUsd`). Vide par défaut : sans
  // effet sur les lignes qui n'emprûntent jamais `leg.amount` (Convert,
  // Receive, Send).
  String total = '',
  String priceCurrency = '',
  required String id,
  String notes = '',
  String senderAddress = '',
}) => [
      timestamp, type, asset, qty, fee, subtotal, total, priceCurrency, id,
      notes, senderAddress, //
    ];

Uint8List _bytesFor(List<List<String>> dataRows, {List<List<String>> preHeaderLines = const []}) {
  final all = [...preHeaderLines, _header, ...dataRows];
  final text = all.map((r) => r.join(',')).join('\n');
  return Uint8List.fromList(utf8.encode(text));
}

CryptoImportPlan _plan(
  Uint8List bytes, {
  String accountId = 'acc1',
  String accountCurrency = 'EUR',
}) {
  final profile = BrokerProfile.coinbase();
  final parsed = StatementImportService.parseWithLineNumbers(bytes, profile);
  return StatementImportService.planCryptoImport(
    parsed.rows,
    profile,
    accountCurrency: accountCurrency,
    accountId: accountId,
    sourceLines: parsed.sourceLines,
  );
}

/// Une "paire" Convert appariable : jambe sortante (négative, avec Notes) +
/// jambe entrante (positive, même actif/quantité que le Notes cite).
List<List<String>> _healthyPair({
  required String idPrefix,
  required String time, // 'AAAA-MM-JJ HH:MM:SS'
  required String timeSecondLeg,
  required String paidAsset,
  required String paidQty,
  required String receivedAsset,
  required String receivedQty,
}) {
  return [
    _row(
      timestamp: time,
      type: 'Convert',
      asset: paidAsset,
      qty: '-$paidQty',
      id: '${idPrefix}NEG',
      notes: 'Converted $paidQty $paidAsset to $receivedQty $receivedAsset',
    ),
    _row(
      timestamp: timeSecondLeg,
      type: 'Convert',
      asset: receivedAsset,
      qty: receivedQty,
      id: '${idPrefix}POS',
    ),
  ];
}

void main() {
  // -------------------------------------------------------------------------
  // PORTE — 19 conversions appariées 19/19 + une 20ᵉ VOLONTAIREMENT ambiguë
  // (conception interne) : deux candidates à même quantité dans la fenêtre.
  // -------------------------------------------------------------------------
  group('Porte lot 3 — appariement Convert 19/19 + 20ᵉ ambiguë', () {
    test('19 paires appariées sans reste, la 20ᵉ rejetée proprement (aucun '
        'repli heuristique)', () {
      final rows = <List<String>>[];
      for (var i = 1; i <= 19; i++) {
        final mm = i.toString().padLeft(2, '0');
        rows.addAll(_healthyPair(
          idPrefix: 'P$mm',
          time: '2024-06-01 10:$mm:00',
          timeSecondLeg: '2024-06-01 10:$mm:05',
          paidAsset: 'PA$mm',
          paidQty: '10.5',
          receivedAsset: 'RB$mm',
          receivedQty: '20.25',
        ));
      }
      // 20ᵉ conversion : AMBIGUË — la sortante trouve DEUX candidates de
      // même actif/quantité dans la fenêtre.
      rows.add(_row(
        timestamp: '2024-06-01 10:20:00',
        type: 'Convert',
        asset: 'PA20',
        qty: '-3.5',
        id: 'P20NEG',
        notes: 'Converted 3.5 PA20 to 5.0 RB20',
      ));
      rows.add(_row(
        timestamp: '2024-06-01 10:20:03',
        type: 'Convert',
        asset: 'RB20',
        qty: '5.0',
        id: 'P20POSA',
      ));
      rows.add(_row(
        timestamp: '2024-06-01 10:20:07',
        type: 'Convert',
        asset: 'RB20',
        qty: '5.0',
        id: 'P20POSB',
      ));

      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, hasLength(19));
      for (var i = 1; i <= 19; i++) {
        final mm = i.toString().padLeft(2, '0');
        final u = plan.unvaluedExchanges
            .firstWhere((e) => e.importKey == 'ref:acc1:P${mm}NEG');
        expect(u.kind, equals('exchange'));
        expect(u.codePaid, equals('PA$mm'));
        expect(u.quantityPaid, equals('10.5'));
        expect(u.codeReceived, equals('RB$mm'));
        expect(u.quantityReceived, equals('20.25'));
        expect(u.sourceLines, hasLength(2));
      }

      // La 20ᵉ : REJETÉE proprement, aucune trace dans unvaluedExchanges —
      // les trois lignes impliquées restent inchangées (rejets motivés).
      expect(
        plan.unvaluedExchanges.any((e) => e.importKey.contains('P20')),
        isFalse,
      );
      expect(plan.movements, hasLength(3));
      expect(plan.movements.every((m) => m.isRejected), isTrue);
      final byId = <String, ImportedMovement>{
        for (final m in plan.movements) m.sourceRow[8]: m,
      };
      expect(byId['P20NEG']!.rejectReason, equals('convertAmbiguousMatch'));
      // M-1 (revue adversariale, CORRECTIF) : ces deux entrantes ont
      // CONCOURU pour la même sortante ambiguë (P20NEG) et perdu à égalité —
      // `convertAmbiguousMatch`, jamais `convertNoMatch` (qui suggérerait à
      // tort qu'elles n'ont trouvé AUCUNE candidate).
      expect(byId['P20POSA']!.rejectReason, equals('convertAmbiguousMatch'));
      expect(byId['P20POSB']!.rejectReason, equals('convertAmbiguousMatch'));
    });
  });

  // -------------------------------------------------------------------------
  // Contraintes d'appariement ISOLÉES (§2) — chacune sa propre fixture,
  // toujours accompagnée d'une paire SAINE de contrôle (sinon le refus
  // GLOBAL « langue non reconnue » masquerait le rejet ligne à ligne testé).
  // -------------------------------------------------------------------------
  group('Contraintes d\'appariement Convert — isolées', () {
    test('motif imparsable sur la sortante → convertNotesUnparsed (jamais '
        'de tentative d\'appariement)', () {
      final rows = <List<String>>[
        ..._healthyPair(
          idPrefix: 'OK',
          time: '2024-06-01 09:00:00',
          timeSecondLeg: '2024-06-01 09:00:02',
          paidAsset: 'CC1',
          paidQty: '1',
          receivedAsset: 'DD1',
          receivedQty: '2',
        ),
        _row(
          timestamp: '2024-06-01 09:05:00',
          type: 'Convert',
          asset: 'CC2',
          qty: '-4',
          id: 'BADNEG',
          notes: 'texte sans rapport, aucun motif "to QTY ASSET"',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, hasLength(1)); // la paire de contrôle.
      final bad = plan.movements.singleWhere((m) => m.sourceRow[8] == 'BADNEG');
      expect(bad.rejectReason, equals('convertNotesUnparsed'));
    });

    test('quantité proche mais NON EXACTE → non apparié (convertNoMatch)', () {
      final rows = <List<String>>[
        ..._healthyPair(
          idPrefix: 'OK',
          time: '2024-06-01 09:00:00',
          timeSecondLeg: '2024-06-01 09:00:02',
          paidAsset: 'CC3',
          paidQty: '1',
          receivedAsset: 'DD3',
          receivedQty: '2',
        ),
        _row(
          timestamp: '2024-06-01 09:10:00',
          type: 'Convert',
          asset: 'EE1',
          qty: '-2',
          id: 'NEARNEG',
          notes: 'Converted 2 EE1 to 5.00 FF1',
        ),
        _row(
          timestamp: '2024-06-01 09:10:03',
          type: 'Convert',
          asset: 'FF1',
          qty: '5.01', // décimale EXACT requise : 5.01 ≠ 5.00
          id: 'NEARPOS',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, hasLength(1));
      final byId = {for (final m in plan.movements) m.sourceRow[8]: m};
      expect(byId['NEARNEG']!.rejectReason, equals('convertNoMatch'));
      expect(byId['NEARPOS']!.rejectReason, equals('convertNoMatch'));
    });

    test('hors fenêtre ±10 s → non apparié (convertNoMatch)', () {
      final rows = <List<String>>[
        ..._healthyPair(
          idPrefix: 'OK',
          time: '2024-06-01 09:00:00',
          timeSecondLeg: '2024-06-01 09:00:02',
          paidAsset: 'CC4',
          paidQty: '1',
          receivedAsset: 'DD4',
          receivedQty: '2',
        ),
        _row(
          timestamp: '2024-06-01 09:20:00',
          type: 'Convert',
          asset: 'GG1',
          qty: '-2',
          id: 'FARNEG',
          notes: 'Converted 2 GG1 to 5 HH1',
        ),
        _row(
          // + 15 s : hors de la fenêtre de 10 s déclarée par le profil.
          timestamp: '2024-06-01 09:20:15',
          type: 'Convert',
          asset: 'HH1',
          qty: '5',
          id: 'FARPOS',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, hasLength(1));
      final byId = {for (final m in plan.movements) m.sourceRow[8]: m};
      expect(byId['FARNEG']!.rejectReason, equals('convertNoMatch'));
      expect(byId['FARPOS']!.rejectReason, equals('convertNoMatch'));
    });

    test('pluralité CÔTÉ SORTANTE (une négative, deux candidates identiques) '
        '→ abandon des deux côtés (convertAmbiguousMatch)', () {
      final rows = <List<String>>[
        ..._healthyPair(
          idPrefix: 'OK',
          time: '2024-06-01 09:00:00',
          timeSecondLeg: '2024-06-01 09:00:02',
          paidAsset: 'CC5',
          paidQty: '1',
          receivedAsset: 'DD5',
          receivedQty: '2',
        ),
        _row(
          timestamp: '2024-06-01 09:30:00',
          type: 'Convert',
          asset: 'II1',
          qty: '-1',
          id: 'DUPNEG',
          notes: 'Converted 1 II1 to 9 JJ1',
        ),
        _row(
          timestamp: '2024-06-01 09:30:02',
          type: 'Convert',
          asset: 'JJ1',
          qty: '9',
          id: 'DUPPOSA',
        ),
        _row(
          timestamp: '2024-06-01 09:30:04',
          type: 'Convert',
          asset: 'JJ1',
          qty: '9',
          id: 'DUPPOSB',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, hasLength(1));
      final byId = {for (final m in plan.movements) m.sourceRow[8]: m};
      expect(byId['DUPNEG']!.rejectReason, equals('convertAmbiguousMatch'));
      // M-1 (revue adversariale, CORRECTIF) — même raisonnement que la
      // porte ci-dessus : ces deux entrantes ont concouru à égalité pour la
      // même sortante ambiguë, jamais `convertNoMatch`.
      expect(byId['DUPPOSA']!.rejectReason, equals('convertAmbiguousMatch'));
      expect(byId['DUPPOSB']!.rejectReason, equals('convertAmbiguousMatch'));
    });

    test('pluralité CÔTÉ ENTRANTE (deux négatives revendiquant la même '
        'entrante) → abandon des trois lignes (convertAmbiguousMatch)', () {
      final rows = <List<String>>[
        ..._healthyPair(
          idPrefix: 'OK',
          time: '2024-06-01 09:00:00',
          timeSecondLeg: '2024-06-01 09:00:02',
          paidAsset: 'CC6',
          paidQty: '1',
          receivedAsset: 'DD6',
          receivedQty: '2',
        ),
        _row(
          timestamp: '2024-06-01 09:40:00',
          type: 'Convert',
          asset: 'KK1',
          qty: '-1',
          id: 'CLAIMNEGA',
          notes: 'Converted 1 KK1 to 7 LL1',
        ),
        _row(
          timestamp: '2024-06-01 09:40:01',
          type: 'Convert',
          asset: 'KK2',
          qty: '-1',
          id: 'CLAIMNEGB',
          notes: 'Converted 1 KK2 to 7 LL1',
        ),
        _row(
          timestamp: '2024-06-01 09:40:03',
          type: 'Convert',
          asset: 'LL1',
          qty: '7',
          id: 'CLAIMPOS',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, hasLength(1));
      final byId = {for (final m in plan.movements) m.sourceRow[8]: m};
      expect(byId['CLAIMNEGA']!.rejectReason, equals('convertAmbiguousMatch'));
      expect(byId['CLAIMNEGB']!.rejectReason, equals('convertAmbiguousMatch'));
      expect(byId['CLAIMPOS']!.rejectReason, equals('convertAmbiguousMatch'));
    });
  });

  // -------------------------------------------------------------------------
  // Langue non reconnue (§2) — le motif ne matche AUCUNE ligne Convert du
  // fichier → refus GLOBAL motivé, jamais des rejets muets ligne à ligne.
  // -------------------------------------------------------------------------
  group('Langue du relevé non reconnue', () {
    test('AU MOINS 2 sortantes non matchées (seuil M-3) → refus global '
        'cryptoConvertNotesLanguageUnrecognized', () {
      final rows = [
        _row(
          timestamp: '2024-06-01 09:00:00',
          type: 'Convert',
          asset: 'MM1',
          qty: '-1',
          id: 'ONLYNEG',
          notes: 'Ceci ne contient aucun motif reconnu',
        ),
        _row(
          timestamp: '2024-06-01 09:05:00',
          type: 'Convert',
          asset: 'MM2',
          qty: '-1',
          id: 'ONLYNEG2',
          notes: 'Ceci non plus ne contient aucun motif reconnu',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason,
          equals('cryptoConvertNotesLanguageUnrecognized'));
      expect(plan.movements, isEmpty);
      expect(plan.unvaluedExchanges, isEmpty);
    });

    test('M-3 (revue adversariale, CORRECTIF) : UNE SEULE sortante non '
        'matchée (SOUS le seuil de 2) → rejet ligne à ligne motivé, PAS de '
        'refus global disproportionné', () {
      final rows = [
        _row(
          timestamp: '2024-06-01 09:00:00',
          type: 'Convert',
          asset: 'MM3',
          qty: '-1',
          id: 'ONLYNEG3',
          notes: 'Ceci ne contient aucun motif reconnu',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      final m = plan.movements.singleWhere((m) => m.sourceRow[8] == 'ONLYNEG3');
      expect(m.rejectReason, equals('convertNotesUnparsed'));
    });

    test('M-3 (revue adversariale, CORRECTIF) : colonne "Notes" ABSENTE de '
        'l\'en-tête → refus global DÉDIÉ cryptoConvertNotesColumnMissing '
        '(distinct de « langue non reconnue »)', () {
      const headerWithoutNotes = [
        'Timestamp', 'Transaction Type', 'Asset', 'Quantity Transacted',
        'Fees and/or Spread', 'Subtotal',
        'Total (inclusive of fees and/or spread)', 'Price Currency', 'ID',
        'Sender Address', //
      ];
      final dataRow = [
        '2024-06-01 09:00:00', 'Send', 'NN9', '-1', '', '', '', '', 'SEND9',
        '', //
      ];
      final text =
          [headerWithoutNotes, dataRow].map((r) => r.join(',')).join('\n');
      final bytes = Uint8List.fromList(utf8.encode(text));
      final plan = _plan(bytes);

      expect(plan.globalRejectReason,
          equals('cryptoConvertNotesColumnMissing'));
    });
  });

  // -------------------------------------------------------------------------
  // Lignes parasites (headerDetectionColumn 'Transaction Type') — aucune
  // fuite de la ligne d'identité utilisateur (nom + UUID SYNTHÉTIQUES).
  // -------------------------------------------------------------------------
  group('Lignes parasites avant l\'en-tête', () {
    const realNameFixture = 'Jean Fixture';
    const accountUuidFixture = 'uuid-0000';

    test('la ligne d\'identité (nom réel + UUID) n\'apparaît dans AUCUN '
        'sourceRow/rejet/meta', () {
      final bytes = _bytesFor(
        [
          _row(
            timestamp: '2024-06-01 09:00:00',
            type: 'Send',
            asset: 'NN1',
            qty: '-1.5',
            id: 'SEND1',
          ),
        ],
        preHeaderLines: [
          [''], // ligne vide
          ['Transactions'], // titre seul
          ['User', realNameFixture, accountUuidFixture], // identité
        ],
      );
      final plan = _plan(bytes);

      expect(plan.globalRejectReason, isNull);
      expect(plan.movements, hasLength(1));
      final m = plan.movements.single;
      expect(m.isRejected, isFalse);
      expect(m.sourceRow, isNot(contains(realNameFixture)));
      expect(m.sourceRow, isNot(contains(accountUuidFixture)));
      final metaString = m.transaction!.meta.toString();
      expect(metaString, isNot(contains(realNameFixture)));
      expect(metaString, isNot(contains(accountUuidFixture)));
    });
  });

  // -------------------------------------------------------------------------
  // Bout en bout profil Coinbase — suffixe ' UTC', tolérance '$', ordre
  // décroissant (mécanismes génériques déjà testés isolément ailleurs :
  // vérifie seulement leur combinaison SOUS ce profil précis).
  // -------------------------------------------------------------------------
  group('Bout en bout — profil Coinbase', () {
    test('suffixe " UTC", "\$" ancré, fichier en ordre DÉCROISSANT → '
        'normalisé correctement', () {
      // Fichier fourni en ordre CHRONOLOGIQUE DÉCROISSANT (la ligne la plus
      // récente en tête) — `_chronologicalOrder` doit le détecter et
      // journaliser dans le bon ordre malgré tout.
      final rows = [
        _row(
          timestamp: '2024-07-02 10:00:00 UTC',
          type: 'Send',
          asset: 'OO1',
          qty: '-3',
          fee: '\$0.50',
          id: 'SEND2',
        ),
        _row(
          timestamp: '2024-07-01 10:00:00 UTC',
          type: 'Receive',
          asset: 'OO1',
          qty: '10',
          subtotal: '\$450.00',
          priceCurrency: 'USD',
          id: 'RECV2',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      // Le retrait (Send) est un mouvement direct (`transferOut`) ; le
      // dépôt en nature (Receive) attend encore une valorisation — il
      // reste un `UnvaluedExchange`, pas un `ImportedMovement` (lot 2).
      expect(plan.movements, hasLength(1));
      expect(plan.movements.every((m) => !m.isRejected), isTrue);
      expect(plan.unvaluedExchanges, hasLength(1));

      // Le dépôt en nature (Receive) doit être daté AVANT le retrait (Send)
      // dans la séquence rejouée, malgré l'ordre décroissant du fichier —
      // `seq` croissant reflète l'ordre chronologique final.
      final recv = plan.unvaluedExchanges.singleWhere((e) => e.sourceKindLabel == 'Receive');
      final sendMovement =
          plan.movements.singleWhere((m) => m.transaction!.kind == TransactionKind.transferOut);
      expect(recv.seq, lessThan(sendMovement.transaction!.meta!['seq'] as int));

      // Frais "\$0.50" correctement dépouillé de son symbole PUIS IGNORÉ
      // (B-1, revue adversariale, CORRECTIF) : `Fees and/or Spread` n'est
      // JAMAIS mappé sur `MovementField.fee` pour ce profil (cf. `Broker
      // Profile.coinbase()`) — la quantité sortie reste la quantité BRUTE
      // de `Quantity Transacted`, jamais `quantity − fee` (qui aurait
      // soustrait un montant FIAT à une quantité de crypto).
      expect(sendMovement.transaction!.quantity, equals('3'));
    });
  });

  // -------------------------------------------------------------------------
  // B-1 (revue adversariale, BLOQUANT) — `Fees and/or Spread` n'est PAS un
  // frais en nature déductible sur ce format : (a) c'est le plus souvent un
  // montant FIAT, jamais une quantité de crypto ; (b) sur une jambe Convert
  // ENTRANTE, le frais en nature est déjà EXCLU de `Quantity Transacted` par
  // Coinbase lui-même — le déduire une seconde fois compterait double.
  // -------------------------------------------------------------------------
  group('B-1 — Fees and/or Spread n\'est jamais un frais déductible', () {
    test('Send avec "Fees and/or Spread" renseigné → frais IGNORÉ, quantité '
        'BRUTE inchangée (jamais quantity − fee)', () {
      final rows = [
        _row(
          timestamp: '2024-10-01 09:00:00',
          type: 'Send',
          asset: 'UU1',
          qty: '-5',
          fee: '2.75', // frais FIAT plausible — jamais soustrait à la crypto.
          id: 'SEND10',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      final m = plan.movements.single;
      expect(m.isRejected, isFalse);
      expect(m.transaction!.quantity, equals('5')); // PAS 7.75.
    });

    test('Convert ENTRANTE avec "Fees and/or Spread" renseigné (frais en '
        'nature déjà exclu de Quantity Transacted par Coinbase) → '
        'quantityReceived == Quantity Transacted BRUT, jamais de double '
        'comptage', () {
      final rows = [
        _row(
          timestamp: '2024-10-02 09:00:00',
          type: 'Convert',
          asset: 'VV1',
          qty: '-10',
          id: 'CONV10NEG',
          notes: 'Converted 10 VV1 to 3 WW1',
        ),
        _row(
          timestamp: '2024-10-02 09:00:02',
          type: 'Convert',
          asset: 'WW1',
          qty: '3',
          fee: '0.05', // frais en nature déjà exclu de "3" par Coinbase.
          id: 'CONV10POS',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      final u = plan.unvaluedExchanges.single;
      // Toujours "3" : le frais n'est PAS déduit une seconde fois (aurait
      // donné "2.95", −1,67 % de quantité falsifiée).
      expect(u.quantityReceived, equals('3'));
    });
  });

  // -------------------------------------------------------------------------
  // Garde « Price Currency » (§4/§5.3.4, revue adversariale OBLIGATOIRE).
  // -------------------------------------------------------------------------
  group('Garde Price Currency (Buy/Sell)', () {
    test('compte EUR + fichier USD → cascade de valorisation (PAS le '
        'chemin fiat direct)', () {
      final rows = [
        _row(
          timestamp: '2024-08-01 10:00:00',
          type: 'Buy',
          asset: 'PP1',
          qty: '2',
          subtotal: '1000',
          total: '1000', // sans frais ici : Total == Subtotal.
          priceCurrency: 'USD',
          id: 'BUY1',
        ),
      ];
      final plan = _plan(_bytesFor(rows), accountCurrency: 'EUR');

      expect(plan.globalRejectReason, isNull);
      expect(plan.movements, isEmpty); // jamais de chemin fiat direct ici.
      expect(plan.unvaluedExchanges, hasLength(1));
      final u = plan.unvaluedExchanges.single;
      expect(u.kind, equals('exchange'));
      expect(u.codePaid, equals('USD'));
      expect(u.codePaidIsFiat, isTrue);
      expect(u.quantityPaid, equals('1000'));
      expect(u.codeReceived, equals('PP1'));
      expect(u.codeReceivedIsFiat, isFalse);
      expect(u.quantityReceived, equals('2'));
    });

    test('compte USD + fichier USD → chemin fiat DIRECT (cash pris tel '
        'quel, aucun UnvaluedExchange)', () {
      final rows = [
        _row(
          timestamp: '2024-08-01 10:00:00',
          type: 'Buy',
          asset: 'PP2',
          qty: '2',
          subtotal: '1000',
          total: '1000',
          priceCurrency: 'USD',
          id: 'BUY2',
        ),
        _row(
          timestamp: '2024-08-02 10:00:00',
          type: 'Sell',
          asset: 'PP3',
          qty: '4',
          subtotal: '800',
          total: '800',
          priceCurrency: 'USD',
          id: 'SELL2',
        ),
      ];
      final plan = _plan(_bytesFor(rows), accountCurrency: 'USD');

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, isEmpty);
      expect(plan.movements, hasLength(2));

      final buy = plan.movements
          .singleWhere((m) => m.transaction!.kind == TransactionKind.buy);
      expect(buy.transaction!.quantity, equals('2'));
      expect(buy.transaction!.amount, equals('-1000')); // cash SORTANT.
      expect(buy.transaction!.currency, equals('USD'));
      expect(buy.ledgerCode, equals('PP2'));

      final sell = plan.movements
          .singleWhere((m) => m.transaction!.kind == TransactionKind.sell);
      expect(sell.transaction!.quantity, equals('4'));
      expect(sell.transaction!.amount, equals('800')); // cash ENTRANT.
      expect(sell.ledgerCode, equals('PP3'));
    });

    test('M-4 (revue adversariale) : "Price Currency" en casse DIFFÉRENTE '
        '("usd") mais équivalente à la devise du compte → chemin fiat '
        'DIRECT, devise émise NORMALISÉE ("USD"), jamais la casse brute de '
        'la cellule', () {
      final rows = [
        _row(
          timestamp: '2024-08-03 10:00:00',
          type: 'Buy',
          asset: 'PP4',
          qty: '1',
          subtotal: '500',
          total: '500',
          priceCurrency: 'usd', // casse volontairement DIFFÉRENTE.
          id: 'BUY4',
        ),
      ];
      final plan = _plan(_bytesFor(rows), accountCurrency: 'USD');

      expect(plan.globalRejectReason, isNull);
      expect(plan.unvaluedExchanges, isEmpty); // chemin DIRECT malgré tout.
      final buy = plan.movements.single;
      expect(buy.transaction!.currency, equals('USD')); // PAS "usd".
    });
  });

  // -------------------------------------------------------------------------
  // Garde « Price Currency » (B-2, revue adversariale, BLOQUANT) — le trou
  // laissé par la garde Buy/Sell ci-dessus : Convert/Receive/Send valorisent
  // TOUJOURS via `leg.valuationUsd` (colonne `valuationAmountColumn`,
  // documentée en `CryptoLedgerSpec.valuationCurrency`), qui peut être dans
  // une AUTRE devise que celle déclarée par `valuationCurrency` si `Price
  // Currency` diffère sur CETTE ligne — sans garde, un `Subtotal` EUR serait
  // traité comme du USD (falsification silencieuse à la conversion).
  // -------------------------------------------------------------------------
  group('Garde Price Currency — cascade de valorisation (B-2)', () {
    test('Price Currency EUR (≠ valuationCurrency USD) sur un Receive en '
        'nature → valorisation USD ABSENTE, jamais assimilée à du USD', () {
      final rows = [
        _row(
          timestamp: '2024-08-10 09:00:00',
          type: 'Receive',
          asset: 'XX1',
          qty: '5',
          subtotal: '200', // en RÉALITÉ des euros, jamais des dollars.
          priceCurrency: 'EUR',
          id: 'RECVEUR',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      final u = plan.unvaluedExchanges.single;
      expect(u.kind, equals('depositInKind'));
      expect(u.usdReceived, isNull); // JAMAIS "200" pris pour du USD.
    });

    test('Price Currency USD (== valuationCurrency) sur la même ligne → '
        'valorisation USD NORMALE, inchangée (non-régression)', () {
      final rows = [
        _row(
          timestamp: '2024-08-10 09:00:00',
          type: 'Receive',
          asset: 'XX2',
          qty: '5',
          subtotal: '200',
          priceCurrency: 'USD',
          id: 'RECVUSD',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      final u = plan.unvaluedExchanges.single;
      expect(u.kind, equals('depositInKind'));
      expect(u.usdReceived, equals('200'));
    });
  });

  // -------------------------------------------------------------------------
  // I-3 (revue adversariale) — le groupage `counterpartyNote` doit
  // ACCUMULER par clé, jamais ÉCRASER (deux lignes NON-Convert partageant
  // par accident le même `ID` ne doivent jamais faire disparaître l'une des
  // deux en silence).
  // -------------------------------------------------------------------------
  group('I-3 — Groupage counterpartyNote : accumulation, jamais écrasement',
      () {
    test('deux lignes non-Convert partageant le même ID survivent TOUTES '
        'les deux (aucune ne disparaît silencieusement)', () {
      final rows = [
        _row(
          timestamp: '2024-08-15 09:00:00',
          type: 'Send',
          asset: 'YY1',
          qty: '-1',
          id: 'DUPID',
        ),
        _row(
          timestamp: '2024-08-15 09:00:01',
          type: 'Send',
          asset: 'YY2',
          qty: '-2',
          id: 'DUPID',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.movements, hasLength(2));
      expect(plan.movements.every((m) => !m.isRejected), isTrue);
      final ledgerCodes = plan.movements.map((m) => m.ledgerCode).toSet();
      expect(ledgerCodes, equals({'YY1', 'YY2'}));
    });
  });

  // -------------------------------------------------------------------------
  // Table de mapping (§3) — Receive Earn / Receive on-chain / Send.
  // -------------------------------------------------------------------------
  group('Table de mapping — Receive/Send', () {
    test('Reward Income + Receive « Coinbase Earn » (même mois) → UN SEUL '
        'agrégat mensuel, coût 0', () {
      final rows = [
        _row(
          timestamp: '2024-09-05 09:00:00',
          type: 'Reward Income',
          asset: 'QQ1',
          qty: '0.1',
          subtotal: '5',
          priceCurrency: 'USD',
          id: 'RWD1',
        ),
        _row(
          timestamp: '2024-09-20 09:00:00',
          type: 'Receive',
          asset: 'QQ1',
          qty: '0.2',
          subtotal: '10',
          priceCurrency: 'USD',
          id: 'RWD2',
          senderAddress: 'Coinbase Earn',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.aggregatedRewardSourceRows, equals(2));
      expect(plan.movements, hasLength(1));
      final agg = plan.movements.single;
      expect(agg.isRejected, isFalse);
      expect(agg.transaction!.kind, equals(TransactionKind.adjustment));
      expect(agg.transaction!.quantity, equals('0.3'));
      expect(agg.transaction!.meta!['corporateAction'], equals('stakingReward'));
      expect(agg.ledgerCode, equals('QQ1'));
      expect(agg.transaction!.meta!['aggregatedValuationUsd'], equals('15'));
    });

    test('Receive on-chain (sans Sender Address « Coinbase Earn ») → '
        'dépôt en nature (depositInKind), PAS un agrégat de récompense', () {
      final rows = [
        _row(
          timestamp: '2024-09-05 09:00:00',
          type: 'Receive',
          asset: 'RR1',
          qty: '1.25',
          id: 'ONCHAIN1',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.movements, isEmpty);
      expect(plan.unvaluedExchanges, hasLength(1));
      final u = plan.unvaluedExchanges.single;
      expect(u.kind, equals('depositInKind'));
      expect(u.codeReceived, equals('RR1'));
      expect(u.quantityReceived, equals('1.25'));
      expect(u.sourceKindLabel, equals('Receive'));
      expect(u.codeReceivedIsFiat, isFalse);
    });

    test('Send → transferOut flagué inKindWithdrawal (retrait externe '
        'RÉEL)', () {
      final rows = [
        _row(
          timestamp: '2024-09-06 09:00:00',
          type: 'Send',
          asset: 'SS1',
          qty: '-3.5',
          id: 'SEND3',
        ),
      ];
      final plan = _plan(_bytesFor(rows));

      expect(plan.globalRejectReason, isNull);
      expect(plan.movements, hasLength(1));
      final m = plan.movements.single;
      expect(m.isRejected, isFalse);
      expect(m.transaction!.kind, equals(TransactionKind.transferOut));
      expect(m.transaction!.quantity, equals('3.5'));
      expect(m.transaction!.meta!['inKindWithdrawal'], isTrue);
      expect(m.ledgerCode, equals('SS1'));
    });
  });
}

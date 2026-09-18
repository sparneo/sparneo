// test/crypto_ledger_lot0_timezone_invariance_test.dart
//
// GARDE DE NON-RÉGRESSION — invariant UTC/fuseau du parsing de date (chantier
// B16, conception interne) : `StatementImportService._parseDate` ne convertit
// RIEN, il retient le jour TEL QU'ÉCRIT dans le relevé. Un mouvement horodaté «
// 2024-03-31 23:30:00 » doit rester daté du 31 mars, ET produire le même
// `importKey`, QUEL QUE SOIT LE FUSEAU DE L'APPAREIL — toute conversion UTC→local
// romprait l'idempotence de la déduplication (le même fichier importé depuis
// Paris puis depuis Nouméa créerait des doublons) et ferait glisser les buckets
// d'agrégation mensuelle (lot 1).
//
// CE FICHIER DOIT PASSER SOUS N'IMPORTE QUEL FUSEAU SYSTÈME. À exécuter
// explicitement sous les deux extrêmes du calendrier (UTC+14 et UTC−11), et
// sous une zone à minuit INEXISTANT certains jours (`America/Santiago` :
// l'heure d'été chilienne saute directement de 23:59 à 01:00 — le fuseau
// change d'offset, mais ce test n'appelle jamais `DateTime.now()`/`.toLocal()`
// donc ces sauts n'ont AUCUN effet ici ; documenté pour mémoire, pas parce
// qu'un échec y est attendu) :
//
//   TZ=Pacific/Kiritimati flutter test test/crypto_ledger_lot0_timezone_invariance_test.dart
//   TZ=Pacific/Pago_Pago flutter test test/crypto_ledger_lot0_timezone_invariance_test.dart
//   TZ=America/Santiago flutter test test/crypto_ledger_lot0_timezone_invariance_test.dart
//
// Les TROIS exécutions doivent être vertes, avec les MÊMES littéraux
// (dates ET importKey) — c'est le seul garde-fou contre un futur
// `.toLocal()`/`.toUtc()` « bien intentionné » qui casserait l'invariant.
//
// GROUPE « fenêtre de groupage Convert » (M-2, revue adversariale, chantier
// B16 lot 3) — mêmes garanties, mais pour `CryptoLedgerNormalizer._Leg.
// preciseDate` (fenêtre `CryptoLedgerSpec.groupingWindow`, granularité
// SECONDE) plutôt que `date` (granularité JOUR). AVANT le correctif,
// `_parseCryptoTimeOfDay` construisait cette valeur via le constructeur
// `DateTime` LOCAL — sous `Europe/Paris`, le repli d'heure d'hiver (heure-mur
// RÉPÉTÉE) aurait pu faire paraître deux jambes RÉELLEMENT distantes de
// quelques secondes tantôt hors fenêtre, tantôt décalées d'une heure
// fantôme. À exécuter EN PLUS sous ce fuseau :
//
//   TZ=Europe/Paris flutter test test/crypto_ledger_lot0_timezone_invariance_test.dart
//
// Fixture 100 % SYNTHÉTIQUE (aucune donnée réelle).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

// ---------------------------------------------------------------------------
// Fixture Coinbase MINIMALE (colonnes du profil `BrokerProfile.coinbase()`),
// dupliquée à dessein depuis `crypto_ledger_coinbase_lot3_test.dart` (même
// politique de duplication que le reste du dépôt, cf. doc de tête de
// `crypto_ledger_normalizer.dart`) — réservée à M-2 ci-dessous, qui a besoin
// de la fenêtre de groupage `preciseDate` (SECONDE près), absente du profil
// générique testé plus haut dans ce fichier (granularité JOUR).
// ---------------------------------------------------------------------------
const _coinbaseHeader = [
  'Timestamp', 'Transaction Type', 'Asset', 'Quantity Transacted',
  'Fees and/or Spread', 'Subtotal', 'Total (inclusive of fees and/or spread)',
  'Price Currency', 'ID', 'Notes', 'Sender Address', //
];

List<String> _coinbaseRow({
  required String timestamp,
  required String type,
  required String asset,
  required String qty,
  required String id,
  String notes = '',
}) =>
    [timestamp, type, asset, qty, '', '', '', '', id, notes, ''];

BrokerProfile _profile() => BrokerProfile.genericManual(
      delimiter: ';',
      encoding: utf8,
      hasHeaderRow: false,
      // Format « année d'abord » + heure accolée, comme les trois relevés crypto
      // (conception interne) : c'est le cas d'usage réel de l'invariant.
      dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
      decimalSeparator: DecimalSeparator.dot,
      columns: const ColumnMapping(byIndex: {
        MovementField.date: 0,
        MovementField.kindLabel: 1,
        MovementField.amount: 2,
      }),
      kindLexicon: const {
        'Ajustement': TransactionKind.adjustment,
      },
    );

ImportedMovement _normalizeOne(String row) {
  final profile = _profile();
  final rows = StatementImportService.parse(
    Uint8List.fromList(utf8.encode(row)),
    profile,
  );
  final movements = StatementImportService.normalize(
    rows,
    profile,
    accountCurrency: 'EUR',
  );
  expect(movements, hasLength(1));
  return movements.first;
}

void main() {
  group('Invariant UTC — date/importKey indépendants du fuseau système', () {
    test('« 2024-03-31 23:30:00 » (borne de fin de mois/fin de journée UTC) '
        '→ date et importKey FIXES, quel que soit TZ', () {
      final m = _normalizeOne('2024-03-31 23:30:00;Ajustement;10');
      expect(m.isRejected, isFalse);

      // Date : toujours le 31 mars, jamais le 1er avril (glissement TZ+) ni
      // le 30 mars (glissement TZ−).
      expect(m.transaction!.date, equals(DateTime(2024, 3, 31)));

      // importKey : littéral figé — capturé une fois sous TZ système par
      // défaut, doit rester identique sous TZ=Pacific/Kiritimati (UTC+14) et
      // TZ=Pacific/Pago_Pago (UTC−11).
      expect(m.importKey, equals('hash:2b0974ca4c98bce'));
    });

    test('« 2024-01-01 00:15:00 » (borne de DÉBUT de journée UTC) → date et '
        'importKey FIXES', () {
      final m = _normalizeOne('2024-01-01 00:15:00;Ajustement;20');
      expect(m.isRejected, isFalse);
      expect(m.transaction!.date, equals(DateTime(2024, 1, 1)));
      expect(m.importKey, equals('hash:feac4cd174be6e4'));
    });
  });

  group('Invariant UTC — fenêtre de groupage Convert (preciseDate, M-2, '
      'revue adversariale)', () {
    test('deux jambes Convert à 5 s d\'écart (heure-mur UTC) restent '
        'appariées QUEL QUE SOIT LE FUSEAU SYSTÈME — AVANT le correctif, '
        'un `DateTime` LOCAL aurait fait dépendre `preciseDate.difference` '
        'du fuseau d\'exécution (ex. repli d\'heure d\'hiver Europe/Paris)',
        () {
      final rows = [
        _coinbaseRow(
          timestamp: '2024-03-31 23:30:00',
          type: 'Convert',
          asset: 'ZZ1',
          qty: '-10',
          id: 'TZCONVNEG',
          notes: 'Converted 10 ZZ1 to 4 ZZ2',
        ),
        _coinbaseRow(
          // + 5 s SEULEMENT : bien À L'INTÉRIEUR de la fenêtre ±10 s
          // déclarée par `BrokerProfile.coinbase()`, quel que soit le
          // fuseau système — c'est CE calcul que M-2 corrige (`DateTime.utc`
          // plutôt que le constructeur LOCAL).
          timestamp: '2024-03-31 23:30:05',
          type: 'Convert',
          asset: 'ZZ2',
          qty: '4',
          id: 'TZCONVPOS',
        ),
      ];
      final text =
          [_coinbaseHeader, ...rows].map((r) => r.join(',')).join('\n');
      final bytes = Uint8List.fromList(utf8.encode(text));

      final profile = BrokerProfile.coinbase();
      final parsed = StatementImportService.parseWithLineNumbers(bytes, profile);
      final plan = StatementImportService.planCryptoImport(
        parsed.rows,
        profile,
        accountCurrency: 'EUR',
        accountId: 'acc-tz',
        sourceLines: parsed.sourceLines,
      );

      expect(plan.globalRejectReason, isNull);
      // Appariées avec succès : littéral figé — capturé une fois sous TZ
      // système par défaut, DOIT rester identique sous TZ=Pacific/Kiritimati
      // (UTC+14) et TZ=Pacific/Pago_Pago (UTC−11), cf. doc de tête de
      // fichier.
      expect(plan.unvaluedExchanges, hasLength(1));
      final u = plan.unvaluedExchanges.single;
      expect(u.importKey, equals('ref:acc-tz:TZCONVNEG'));
      expect(u.codePaid, equals('ZZ1'));
      expect(u.codeReceived, equals('ZZ2'));
      expect(plan.movements, isEmpty); // aucun rejet des deux côtés.
    });

    test('M-r1 (contre-revue, CORRECTIF) : fichier MIXTE — une jambe avec '
        'heure, l\'autre SANS (repli) — les deux référentiels doivent '
        'rester UTC, sinon la fenêtre se décale de l\'offset local entier '
        '(mesuré : 2 h 00 min 05 s au lieu de 5 s sous Europe/Paris)', () {
      final rows = [
        _coinbaseRow(
          // Heure PRÉSENTE : `_parseCryptoTimeOfDay` produit un
          // `DateTime.utc` direct.
          timestamp: '2024-06-15 00:00:00',
          type: 'Convert',
          asset: 'AB1',
          qty: '-10',
          id: 'MIXNEG',
          notes: 'Converted 10 AB1 to 4 AB2',
        ),
        _coinbaseRow(
          // Heure ABSENTE (repli) : AVANT le correctif, retombait sur
          // `date` LOCAL — sous un fuseau décalé, l'instant réel diffère de
          // minuit UTC du même jour, décalant `preciseDate.difference` de
          // l'offset local entier.
          timestamp: '2024-06-15',
          type: 'Convert',
          asset: 'AB2',
          qty: '4',
          id: 'MIXPOS',
        ),
      ];
      final text =
          [_coinbaseHeader, ...rows].map((r) => r.join(',')).join('\n');
      final bytes = Uint8List.fromList(utf8.encode(text));

      final profile = BrokerProfile.coinbase();
      final parsed = StatementImportService.parseWithLineNumbers(bytes, profile);
      final plan = StatementImportService.planCryptoImport(
        parsed.rows,
        profile,
        accountCurrency: 'EUR',
        accountId: 'acc-tz-mixed',
        sourceLines: parsed.sourceLines,
      );

      expect(plan.globalRejectReason, isNull);
      // Les deux jambes visent le MÊME instant UTC (minuit du 15 juin) :
      // diff = 0 s, largement dans la fenêtre ±10 s, QUEL QUE SOIT LE
      // FUSEAU — un repli en référentiel LOCAL aurait introduit ici un
      // écart artificiel égal à l'offset local (jusqu'à plusieurs heures).
      expect(plan.unvaluedExchanges, hasLength(1));
      final u = plan.unvaluedExchanges.single;
      expect(u.importKey, equals('ref:acc-tz-mixed:MIXNEG'));
      expect(plan.movements, isEmpty);
    });
  });
}

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
// Fixture 100 % SYNTHÉTIQUE (aucune donnée réelle).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

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
}

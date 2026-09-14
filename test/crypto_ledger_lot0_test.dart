// test/crypto_ledger_lot0_test.dart
//
// Tests unitaires du LOT 0 du chantier B16 (socle commun de l'import crypto,
// conception interne) : extensions dormantes de `StatementImportService` et
// `BrokerProfile`, exercées à travers l'API PUBLIQUE (`parse`/`normalize`) —
// les méthodes concernées (`_parseDate`, `_timeSuffix`, `_parseCsv`,
// `_parseAmount`) restent privées. Fixtures 100 % SYNTHÉTIQUES, aucune donnée
// réelle.

import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

// ---------------------------------------------------------------------------
// Helpers — profil CSV minimal (Date;Operation;Montant), délimiteur `;`
// (jamais de conflit avec une décimale à virgule dans les fixtures).
// ---------------------------------------------------------------------------

BrokerProfile _byIndexProfile({
  required DateFormatSpec dateFormat,
  DecimalSeparator decimalSeparator = DecimalSeparator.dot,
}) =>
    BrokerProfile.genericManual(
      delimiter: ';',
      encoding: utf8,
      hasHeaderRow: false,
      dateFormat: dateFormat,
      decimalSeparator: decimalSeparator,
      columns: const ColumnMapping(byIndex: {
        MovementField.date: 0,
        MovementField.kindLabel: 1,
        MovementField.amount: 2,
      }),
      kindLexicon: const {
        'Ajustement': TransactionKind.adjustment,
      },
    );

Uint8List _utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));

ImportedMovement _normalizeOne(String row, BrokerProfile profile) {
  final rows = StatementImportService.parse(_utf8Bytes(row), profile);
  final movements = StatementImportService.normalize(
    rows,
    profile,
    accountCurrency: 'EUR',
  );
  expect(movements, hasLength(1));
  return movements.first;
}

void main() {
  group('DateFormatSpec.yearFirst', () {
    test('AAAA-MM-JJ (yearFirst) : "2024-03-12" → 12 mars 2024', () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
      );
      final r = _normalizeOne('2024-03-12;Ajustement;10', profile);
      expect(r.isRejected, isFalse);
      expect(r.transaction!.date, equals(DateTime(2024, 3, 12)));
    });

    test('profil dayFirst existant (défaut) INCHANGÉ : "12/03/2024" → 12 mars 2024',
        () {
      final profile = _byIndexProfile(dateFormat: const DateFormatSpec());
      final r = _normalizeOne('12/03/2024;Ajustement;10', profile);
      expect(r.isRejected, isFalse);
      expect(r.transaction!.date, equals(DateTime(2024, 3, 12)));
    });

    test('profil dayFirst existant : "03/12/2024" reste JJ/MM (3 décembre, '
        'pas 12 mars) — non-régression', () {
      final profile = _byIndexProfile(dateFormat: const DateFormatSpec());
      final r = _normalizeOne('03/12/2024;Ajustement;10', profile);
      expect(r.isRejected, isFalse);
      expect(r.transaction!.date, equals(DateTime(2024, 12, 3)));
    });

    test('yearFirst : "24-03-12" (année à 2 chiffres) → rejet, JAMAIS l\'an '
        '24 (fichier illisible/mal profilé, pas une date fantaisiste)', () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
      );
      final r = _normalizeOne('24-03-12;Ajustement;10', profile);
      expect(r.isRejected, isTrue);
      expect(r.rejectReason, equals('invalidDate'));
    });
  });

  group('_timeSuffix — suffixes UTC/GMT (export Coinbase)', () {
    BrokerProfile profile() => _byIndexProfile(
          dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        );

    test('"2024-03-12 10:15:30 UTC" → date correctement isolée (12 mars 2024)',
        () {
      final r = _normalizeOne('2024-03-12 10:15:30 UTC;Ajustement;10', profile());
      expect(r.isRejected, isFalse);
      expect(r.transaction!.date, equals(DateTime(2024, 3, 12)));
    });

    test('"2024-03-12 10:15:30 GMT" → date correctement isolée (12 mars 2024)',
        () {
      final r = _normalizeOne('2024-03-12 10:15:30 GMT;Ajustement;10', profile());
      expect(r.isRejected, isFalse);
      expect(r.transaction!.date, equals(DateTime(2024, 3, 12)));
    });

    test('"2024-03-12 10:15:30 utc" (casse minuscule) → date correctement '
        'isolée (12 mars 2024)', () {
      final r = _normalizeOne('2024-03-12 10:15:30 utc;Ajustement;10', profile());
      expect(r.isRejected, isFalse);
      expect(r.transaction!.date, equals(DateTime(2024, 3, 12)));
    });

    test('"2024-03-12 UTC" SANS heure devant → PAS amputé → rejet motivé '
        '(jamais de troncature silencieuse)', () {
      final r = _normalizeOne('2024-03-12 UTC;Ajustement;10', profile());
      expect(r.isRejected, isTrue);
    });
  });

  group('_parseCsv — strip BOM inconditionnel (export Binance)', () {
    test('BOM en tête de fichier : mapping PAR NOM fonctionne malgré le BOM',
        () {
      final profile = BrokerProfile.genericManual(
        delimiter: ';',
        encoding: utf8,
        hasHeaderRow: true,
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.dot,
        columns: const ColumnMapping(byName: {
          MovementField.date: 'Date',
          MovementField.kindLabel: 'Operation',
          MovementField.amount: 'Montant',
        }),
        kindLexicon: const {'Ajustement': TransactionKind.adjustment},
      );

      // BOM UTF-8 littéral (U+FEFF) devant la ligne d'en-tête.
      final bytes = Uint8List.fromList([
        0xEF, 0xBB, 0xBF, // BOM
        ...utf8.encode('Date;Operation;Montant\n2024-03-12;Ajustement;10'),
      ]);

      final rows = StatementImportService.parse(bytes, profile);
      // Le BOM ne doit PLUS coller au premier nom de colonne.
      expect(rows.first.first, equals('Date'));
      expect(rows.first.first, isNot(contains('﻿')));

      final movements = StatementImportService.normalize(
        rows,
        profile,
        accountCurrency: 'EUR',
      );
      expect(movements, hasLength(1));
      expect(movements.first.isRejected, isFalse);
      expect(movements.first.transaction!.date, equals(DateTime(2024, 3, 12)));
    });
  });

  group('_parseAmount — tolérance aux symboles monétaires (\$/€, export Coinbase)',
      () {
    test('"-\$1234.56" (décimale point) → -1234.56', () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.dot,
      );
      final r = _normalizeOne(r'2024-03-12;Ajustement;-$1234.56', profile);
      expect(r.isRejected, isFalse);
      expect(Decimal.parse(r.transaction!.amount!), equals(Decimal.parse('-1234.56')));
    });

    test('"12,34 €" (décimale virgule, symbole en QUEUE avec espace) → 12.34',
        () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.comma,
      );
      final r = _normalizeOne('2024-03-12;Ajustement;12,34 €', profile);
      expect(r.isRejected, isFalse);
      expect(Decimal.parse(r.transaction!.amount!), equals(Decimal.parse('12.34')));
    });

    test('montant SANS symbole reste inchangé (non-régression)', () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.dot,
      );
      final r = _normalizeOne('2024-03-12;Ajustement;42.50', profile);
      expect(r.isRejected, isFalse);
      expect(Decimal.parse(r.transaction!.amount!), equals(Decimal.parse('42.50')));
    });

    test(r'"$-1234.56" (symbole AVANT le signe, valeur synthétique) → -1234.56',
        () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.dot,
      );
      final r = _normalizeOne(r'2024-03-12;Ajustement;$-1234.56', profile);
      expect(r.isRejected, isFalse);
      expect(Decimal.parse(r.transaction!.amount!), equals(Decimal.parse('-1234.56')));
    });

    test('"12,34€" (symbole en QUEUE SANS espace) → 12.34', () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.comma,
      );
      final r = _normalizeOne('2024-03-12;Ajustement;12,34€', profile);
      expect(r.isRejected, isFalse);
      expect(Decimal.parse(r.transaction!.amount!), equals(Decimal.parse('12.34')));
    });

    test('"12€50" (symbole au MILIEU, jamais ancré) → rejet invalidAmount, '
        'JAMAIS accepté en silence (facteur 100 évité — revue adversariale)',
        () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.dot,
      );
      final r = _normalizeOne('2024-03-12;Ajustement;12€50', profile);
      expect(r.isRejected, isTrue);
      expect(r.rejectReason, equals('invalidAmount'));
    });

    test('"12\$34" (symbole au MILIEU, jamais ancré) → rejet invalidAmount',
        () {
      final profile = _byIndexProfile(
        dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
        decimalSeparator: DecimalSeparator.dot,
      );
      final r = _normalizeOne(r'2024-03-12;Ajustement;12$34', profile);
      expect(r.isRejected, isTrue);
      expect(r.rejectReason, equals('invalidAmount'));
    });
  });
}

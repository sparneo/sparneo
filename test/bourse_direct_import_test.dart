// test/bourse_direct_import_test.dart
//
// Tests du profil courtier « Bourse Direct » (lecture `.xlsx` + mapping
// pré-rempli). Le classeur xlsx est FABRIQUÉ EN MÉMOIRE ici (quelques lignes
// synthétiques reproduisant la structure réelle de l'export « Extraction de
// compte » — titre, en-têtes, une ligne par nature d'opération mappée + un
// code inconnu) : AUCUNE donnée réelle, aucun fichier disque n'est lu.
//
// Structure du classeur produit : `xl/worksheets/sheet1.xml` (une ligne de
// titre, puis la ligne d'en-têtes contenant `CodeOperation`, puis les lignes
// de données) + `xl/sharedStrings.xml` pour les cellules texte — la forme
// minimale qu'un lecteur `.xlsx` conforme doit savoir lire, construite à la
// main via `package:archive` (ZIP) + `package:xml` pour ne dépendre d'aucun
// package tiers de lecture xlsx (cf. rapport de livraison : les packages
// dédiés ciblent encore des versions d'archive/xml antérieures à celles déjà
// résolues dans ce projet).

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

// ---------------------------------------------------------------------------
// Fabrique un classeur .xlsx minimal à partir d'une grille de valeurs.
// ---------------------------------------------------------------------------

/// Une cellule de la grille synthétique : soit un nombre (rendu tel quel dans
/// le XML, comme le ferait Excel pour une valeur numérique — donc SANS
/// guillemets ni séparateur), soit un texte (passé par la table de chaînes
/// partagées, comme le fait Excel pour toute cellule non numérique).
sealed class _Cell {
  const _Cell();
}

class _Num extends _Cell {
  final num value;
  const _Num(this.value);
}

class _Txt extends _Cell {
  final String value;
  const _Txt(this.value);
}

String _colLetter(int index) {
  var i = index;
  var s = '';
  do {
    s = String.fromCharCode(65 + (i % 26)) + s;
    i = i ~/ 26 - 1;
  } while (i >= 0);
  return s;
}

/// Construit les bytes d'un classeur `.xlsx` à une seule feuille contenant
/// [rows] (une ligne = une liste de [_Cell]).
Uint8List _buildXlsx(List<List<_Cell>> rows) {
  final sharedStrings = <String>[];
  int internString(String s) {
    final existing = sharedStrings.indexOf(s);
    if (existing != -1) return existing;
    sharedStrings.add(s);
    return sharedStrings.length - 1;
  }

  final sheetXmlBuffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write(
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">',
    )
    ..write('<sheetData>');

  for (var r = 0; r < rows.length; r++) {
    sheetXmlBuffer.write('<row r="${r + 1}">');
    final row = rows[r];
    for (var c = 0; c < row.length; c++) {
      final ref = '${_colLetter(c)}${r + 1}';
      final cell = row[c];
      switch (cell) {
        case _Num n:
          sheetXmlBuffer.write('<c r="$ref"><v>${n.value}</v></c>');
        case _Txt t:
          final idx = internString(t.value);
          sheetXmlBuffer.write('<c r="$ref" t="s"><v>$idx</v></c>');
      }
    }
    sheetXmlBuffer.write('</row>');
  }
  sheetXmlBuffer.write('</sheetData></worksheet>');

  final sharedStringsXml = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write(
      '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'count="${sharedStrings.length}" uniqueCount="${sharedStrings.length}">',
    );
  for (final s in sharedStrings) {
    sharedStringsXml.write('<si><t>${_xmlEscape(s)}</t></si>');
  }
  sharedStringsXml.write('</sst>');

  final archive = Archive()
    ..addFile(_textFile('xl/worksheets/sheet1.xml', sheetXmlBuffer.toString()))
    ..addFile(_textFile('xl/sharedStrings.xml', sharedStringsXml.toString()));

  final bytes = ZipEncoder().encodeBytes(archive);
  return Uint8List.fromList(bytes);
}

ArchiveFile _textFile(String name, String content) {
  final data = utf8.encode(content);
  return ArchiveFile(name, data.length, data);
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

// ---------------------------------------------------------------------------
// Grille synthétique reproduisant la structure Bourse Direct : une ligne de
// titre (pas un en-tête), la ligne d'en-têtes (contient CodeOperation/isin),
// puis une ligne par nature d'opération mappée + un code inconnu.
// ---------------------------------------------------------------------------

const _isinTest = 'FR0000031122'; // ISIN factice, aucune donnée réelle

Uint8List _sampleWorkbookBytes() {
  return _buildXlsx([
    // Ligne de titre (au-dessus des en-têtes) — doit être ignorée.
    [const _Txt('Extraction de compte - Relevé synthétique de test')],
    // Ligne d'en-têtes réelle.
    [
      const _Txt('DateOperation'),
      const _Txt('CodeOperation'),
      const _Txt('isin'),
      const _Txt('Quantite'),
      const _Txt('cours'),
      const _Txt('Courtage'),
      const _Txt('Net'),
    ],
    // AC (buy) — date stockée comme NOMBRE, ex. 20150127.
    [
      const _Num(20150127),
      const _Txt('AC'),
      const _Txt(_isinTest),
      const _Num(10),
      const _Num(100.5),
      const _Num(5),
      const _Num(1010),
    ],
    // VCPT (sell).
    [
      const _Num(20150202),
      const _Txt('VCPT'),
      const _Txt(_isinTest),
      const _Num(4),
      const _Num(110.25),
      const _Num(3),
      const _Num(438),
    ],
    // CO (dividend), pas de quantité/cours.
    [
      const _Num(20150210),
      const _Txt('CO'),
      const _Txt(_isinTest),
      const _Txt(''),
      const _Txt(''),
      const _Txt(''),
      const _Num(15.5),
    ],
    // PEAIE (deposit), mouvement espèces pur.
    [
      const _Num(20150301),
      const _Txt('PEAIE'),
      const _Txt(''),
      const _Txt(''),
      const _Txt(''),
      const _Txt(''),
      const _Num(500),
    ],
    // ODTTF (charge), mouvement espèces pur.
    [
      const _Num(20150315),
      const _Txt('ODTTF'),
      const _Txt(''),
      const _Txt(''),
      const _Txt(''),
      const _Txt(''),
      const _Num(9.9),
    ],
    // Code inconnu (ex. attribution de titres) — doit être rejeté.
    [
      const _Num(20150320),
      const _Txt('ATTRI'),
      const _Txt(_isinTest),
      const _Num(1),
      const _Txt(''),
      const _Txt(''),
      const _Txt(''),
    ],
  ]);
}

void main() {
  group('StatementImportService._parseXlsx (via parse) — lecture brute', () {
    test('lit un classeur xlsx en lignes, en ignorant la ligne de titre '
        'grâce à headerDetectionColumn', () {
      final profile = BrokerProfile.bourseDirect();
      final rows = StatementImportService.parse(_sampleWorkbookBytes(), profile);

      // La ligne de titre a été éliminée : la ligne 0 est bien l'en-tête.
      expect(rows.first, contains('CodeOperation'));
      expect(rows.first, contains('isin'));

      // Une date stockée comme NOMBRE ressort en texte canonique sans point
      // ni séparateur de milliers : "20150127", pas "20150127.0".
      final firstDataRow = rows[1];
      final dateColIndex = rows.first.indexOf('DateOperation');
      expect(firstDataRow[dateColIndex], equals('20150127'));
    });
  });

  group('BrokerProfile.bourseDirect + normalize — kinds et signes', () {
    late List<List<String>> rows;

    setUp(() {
      rows = StatementImportService.parse(
        _sampleWorkbookBytes(),
        BrokerProfile.bourseDirect(),
      );
    });

    test('AC → buy, amount négatif, ISIN/quantité/prix repris', () {
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      final m = movements.firstWhere((m) => !m.isRejected && m.transaction!.kind == TransactionKind.buy);
      final tx = m.transaction!;
      expect(m.isin, equals(_isinTest));
      expect(Decimal.parse(tx.quantity!), equals(Decimal.parse('10')));
      expect(Decimal.parse(tx.unitPrice!), equals(Decimal.parse('100.5')));
      expect(Decimal.parse(tx.fee!), equals(Decimal.parse('5')));
      // Net fourni non signé (1010) → forcé négatif car AC = achat.
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('-1010')));
      expect(tx.date, equals(DateTime(2015, 1, 27)));
    });

    test('VCPT → sell, amount positif', () {
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      final tx = movements
          .firstWhere((m) => !m.isRejected && m.transaction!.kind == TransactionKind.sell)
          .transaction!;
      expect(Decimal.parse(tx.quantity!), equals(Decimal.parse('4')));
      expect(Decimal.parse(tx.unitPrice!), equals(Decimal.parse('110.25')));
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('438')));
      expect(tx.date, equals(DateTime(2015, 2, 2)));
    });

    test('CO → dividend, amount positif', () {
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      final tx = movements
          .firstWhere((m) => !m.isRejected && m.transaction!.kind == TransactionKind.dividend)
          .transaction!;
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('15.5')));
    });

    test('PEAIE → deposit, amount positif, sans identité d\'actif', () {
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      final m = movements.firstWhere((m) => !m.isRejected && m.transaction!.kind == TransactionKind.deposit);
      expect(Decimal.parse(m.transaction!.amount!), equals(Decimal.parse('500')));
      expect(m.transaction!.symbol, isNull);
    });

    test('ODTTF → charge, amount négatif', () {
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      final tx = movements
          .firstWhere((m) => !m.isRejected && m.transaction!.kind == TransactionKind.charge)
          .transaction!;
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('-9.9')));
    });

    test('ATTRI → attribution gratuite (adjustment titre, coût 0)', () {
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      final m = movements.firstWhere(
        (m) => !m.isRejected && m.transaction!.kind == TransactionKind.adjustment,
      );
      final tx = m.transaction!;
      // +quantité, COÛT 0 (unitPrice null → PRU en baisse), aucun cash.
      expect(Decimal.parse(tx.quantity!), equals(Decimal.parse('1')));
      expect(tx.unitPrice, isNull);
      expect(tx.amount, isNull);
      expect(m.isin, equals(_isinTest));
    });

    test('6 lignes de données → 6 mouvements valides, aucun rejet '
        '(ATTRI désormais traité)', () {
      final movements = StatementImportService.normalize(
        rows,
        BrokerProfile.bourseDirect(),
        accountCurrency: 'EUR',
      );
      expect(movements, hasLength(6));
      expect(movements.where((m) => m.isRejected), isEmpty);
      expect(movements.where((m) => !m.isRejected), hasLength(6));
    });
  });
}

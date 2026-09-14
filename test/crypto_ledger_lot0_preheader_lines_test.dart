// test/crypto_ledger_lot0_preheader_lines_test.dart
//
// Lot 0 du chantier B16 (import crypto, conception interne) : vérifie que
// `headerDetectionColumn` SUFFIT à traiter la structure Coinbase (3 lignes
// AVANT l'en-tête réelle : une ligne VIDE, un titre seul, une ligne d'IDENTITÉ
// utilisateur — nom réel + identifiant de compte) SANS aucun code spécifique
// crypto — extension déjà en place pour Bourse Direct (`headerDetectionColumn:
// 'CodeOperation'`), simplement réutilisée ici.
//
// Deux garanties couvertes :
//  1. Confidentialité : AUCUNE cellule des lignes 1–3 (dont le nom réel et
//     l'UUID de compte de la ligne 3) ne doit jamais ressortir dans un
//     mouvement, un rejet ou un `meta` — ces lignes sont éliminées AVANT
//     normalisation.
//  2. Numéros de ligne PHYSIQUES EXACTS (revue adversariale, corrige un
//     comportement antérieur APPROCHÉ) : `Csv.decode` élimine par défaut les lignes
//     vides, ce qui décale TOUS les n° de ligne cités à l'utilisateur (« Ligne N »
//     à l'écran de rejet/aperçu) — piège documenté en conception interne, déjà
//     coûteux (deux bugs de repérage). `_parseCsv` désactive désormais
//     `skipEmptyLines` du décodeur et applique LUI-MÊME le même prédicat (ligne
//     écartée ssi tous ses champs sont vides) SUR LES LIGNES DÉCODÉES AVEC LEUR
//     INDEX D'ORIGINE, pour que `sourceLines` porte le n° physique EXACT de chaque
//     ligne conservée — y compris après une ligne vide, en tête de fichier ou au
//     milieu.
//
// Fixture 100 % SYNTHÉTIQUE (aucune donnée réelle) : « Jean Fixture » / «
// uuid-0000 » sont inventés, structure calquée sur conception interne

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

const _realNameFixture = 'Jean Fixture';
const _accountUuidFixture = 'uuid-0000';
const _titleLine = 'Transactions';

BrokerProfile _profile() => const BrokerProfile(
      id: 'coinbase-like-test',
      label: 'Coinbase-like (test)',
      delimiter: ',',
      encoding: utf8,
      hasHeaderRow: true,
      // Élimine tout ce qui précède la ligne contenant cette cellule — même
      // mécanisme que Bourse Direct (`CodeOperation`), conception interne : aucun
      // code spécifique crypto n'est nécessaire pour ce piège.
      headerDetectionColumn: 'Transaction Type',
      dateFormat: DateFormatSpec(separator: '-', yearFirst: true),
      decimalSeparator: DecimalSeparator.dot,
      columns: ColumnMapping(byName: {
        MovementField.date: 'Timestamp',
        MovementField.kindLabel: 'Transaction Type',
        MovementField.symbol: 'Asset',
        MovementField.quantity: 'Quantity',
      }),
      kindLexicon: {'Ajustement': TransactionKind.adjustment},
    );

Uint8List _fixtureBytes() {
  final text = [
    '', // ligne 1 : VIDE
    _titleLine, // ligne 2 : titre seul
    'User,$_realNameFixture,$_accountUuidFixture', // ligne 3 : identité
    'Timestamp,Transaction Type,Asset,Quantity', // ligne 4 : en-tête réelle
    '2024-03-12 10:00:00,Ajustement,BTC,1.5', // ligne 5 : donnée
  ].join('\n');
  return Uint8List.fromList(utf8.encode(text));
}

/// Variante avec une SECONDE ligne vide, cette fois au MILIEU du fichier
/// (après l'en-tête, entre deux lignes de données) — vérifie que le
/// décalage ne se limite pas au cas « ligne vide en tête » : les numéros
/// des lignes qui SUIVENT une ligne vide interne restent eux aussi
/// physiquement exacts.
Uint8List _fixtureBytesWithMidFileBlankLine() {
  final text = [
    '', // ligne 1 : VIDE
    _titleLine, // ligne 2 : titre seul
    'User,$_realNameFixture,$_accountUuidFixture', // ligne 3 : identité
    'Timestamp,Transaction Type,Asset,Quantity', // ligne 4 : en-tête réelle
    '2024-03-12 10:00:00,Ajustement,BTC,1.5', // ligne 5 : donnée 1
    '', // ligne 6 : VIDE (au milieu)
    '2024-03-13 11:00:00,Ajustement,ETH,2.0', // ligne 7 : donnée 2
  ].join('\n');
  return Uint8List.fromList(utf8.encode(text));
}

void main() {
  group('Lignes pré-en-tête Coinbase (ligne vide + titre + identité)', () {
    test('sourceLines PHYSIQUES EXACTES malgré la ligne vide en tête de '
        'fichier (skipEmptyLines désactivé côté décodeur, filtrage manuel '
        'AVANT calcul du n° de ligne)', () {
      final parsed = StatementImportService.parseWithLineNumbers(
        _fixtureBytes(),
        _profile(),
      );

      // 2 lignes survivent à la détection d'en-tête (en-tête + donnée).
      expect(parsed.rows, hasLength(2));
      expect(parsed.rows.first, contains('Transaction Type'));

      // Numéros PHYSIQUES réels du fichier : en-tête = ligne 4, donnée =
      // ligne 5 (la ligne 1 vide ne décale plus rien).
      expect(parsed.sourceLines, equals([4, 5]));
    });

    test('ligne vide au MILIEU du fichier : les numéros qui suivent restent '
        'eux aussi physiques (pas seulement le cas « tête de fichier »)', () {
      final parsed = StatementImportService.parseWithLineNumbers(
        _fixtureBytesWithMidFileBlankLine(),
        _profile(),
      );

      // en-tête (L4) + donnée 1 (L5) + donnée 2 (L7) — la ligne vide L6 a
      // disparu de `rows` SANS décaler le numéro de la ligne suivante.
      expect(parsed.rows, hasLength(3));
      expect(parsed.sourceLines, equals([4, 5, 7]));

      final movements = StatementImportService.normalize(
        parsed.rows,
        _profile(),
        accountCurrency: 'EUR',
        sourceLines: parsed.sourceLines,
      );
      expect(movements, hasLength(2));
      expect(movements.every((m) => !m.isRejected), isTrue);
      expect(movements[0].sourceRowIndex, equals(5));
      expect(movements[1].sourceRowIndex, equals(7));
    });

    test('AUCUNE cellule des lignes 1–3 (dont le nom réel et l\'UUID de '
        'compte) ne ressort dans les mouvements/rejets/meta', () {
      final parsed = StatementImportService.parseWithLineNumbers(
        _fixtureBytes(),
        _profile(),
      );
      final movements = StatementImportService.normalize(
        parsed.rows,
        _profile(),
        accountCurrency: 'EUR',
        sourceLines: parsed.sourceLines,
      );

      expect(movements, hasLength(1));
      final m = movements.single;
      expect(m.isRejected, isFalse);

      // Ni la ligne vide, ni le titre, ni l'identité utilisateur ne doivent
      // apparaître dans la ligne source conservée par le mouvement.
      expect(m.sourceRow, isNot(contains(_realNameFixture)));
      expect(m.sourceRow, isNot(contains(_accountUuidFixture)));
      expect(m.sourceRow, isNot(contains(_titleLine)));
      expect(m.sourceRow, equals(['2024-03-12 10:00:00', 'Ajustement', 'BTC', '1.5']));
      // Numéro de ligne physique EXACT désormais (ligne 5 réelle du fichier).
      expect(m.sourceRowIndex, equals(5));

      // Le `meta` du mouvement (primitives JSON round-trippées en backup) ne
      // porte aucune trace de ces lignes non plus.
      final metaString = m.transaction!.meta.toString();
      expect(metaString, isNot(contains(_realNameFixture)));
      expect(metaString, isNot(contains(_accountUuidFixture)));

      // Et plus largement : ces valeurs n'apparaissent NULLE PART dans les
      // lignes retenues après détection d'en-tête (garantie structurelle,
      // pas seulement sur ce mouvement précis).
      for (final row in parsed.rows) {
        expect(row, isNot(contains(_realNameFixture)));
        expect(row, isNot(contains(_accountUuidFixture)));
        expect(row, isNot(contains(_titleLine)));
      }
    });
  });
}

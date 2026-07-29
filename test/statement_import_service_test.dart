// test/statement_import_service_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Colonnes du relevé de test : Date;Operation;ISIN;Libelle;Quantite;Cours;Frais;Montant
const _colDate = 0;
const _colOp = 1;
const _colIsin = 2;
const _colLabel = 3;
const _colQty = 4;
const _colPrice = 5;
const _colFee = 6;
const _colAmount = 7;

BrokerProfile _profile() => BrokerProfile.genericManual(
      delimiter: ';',
      encoding: latin1,
      hasHeaderRow: true,
      dateFormat: const DateFormatSpec(), // JJ/MM/AAAA, défaut FR
      decimalSeparator: DecimalSeparator.comma,
      columns: const ColumnMapping(byIndex: {
        MovementField.date: _colDate,
        MovementField.kindLabel: _colOp,
        MovementField.isin: _colIsin,
        MovementField.label: _colLabel,
        MovementField.quantity: _colQty,
        MovementField.unitPrice: _colPrice,
        MovementField.fee: _colFee,
        MovementField.amount: _colAmount,
      }),
      kindLexicon: const {
        'Achat': TransactionKind.buy,
        'Vente': TransactionKind.sell,
        'Dividende': TransactionKind.dividend,
        'Versement': TransactionKind.deposit,
        'Retrait': TransactionKind.withdrawal,
        'Intérêts': TransactionKind.interest,
        'Frais': TransactionKind.charge,
      },
    );

Uint8List _latin1Bytes(String text) => Uint8List.fromList(latin1.encode(text));

const _header = 'Date;Operation;ISIN;Libelle;Quantite;Cours;Frais;Montant';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  test('normalize ignore une ligne INTÉGRALEMENT VIDE (aucun rejet)', () {
    // Reproduit une ligne vide présente dans le fichier (ex. séparateur xlsx) :
    // elle ne doit produire NI candidat NI rejet — juste être sautée.
    final rows = <List<String>>[
      _header.split(';'),
      '15/01/2024;Achat;FR0000120073;Air Liquide;10;150;5;-1505'.split(';'),
      <String>[], // ligne vide (aucune cellule — cas xlsx sans <c>)
      ['', '', '', '', '', '', '', ''], // ligne vide (cellules blanches)
      '   ;;;;;;;'.split(';'), // cellules blanches (espaces)
    ];
    final movements = StatementImportService.normalize(
      rows,
      _profile(),
      accountCurrency: 'EUR',
    );
    expect(movements.where((m) => m.isRejected), isEmpty,
        reason: 'aucune ligne vide ne doit être rejetée');
    expect(movements.length, 1, reason: 'seul le vrai mouvement subsiste');
  });

  group('StatementImportService.parse', () {
    test('décode Latin-1 + délimiteur ; + libellés accentués', () {
      final text = '$_header\r\n'
          '05/01/2024;Achat;FR0000031122;AIRBUS;10;100,50;5,00;-1010,00\r\n'
          '10/01/2024;Intérêts;;Livret espèces;;;;12,34\r\n';
      final bytes = _latin1Bytes(text);

      final rows = StatementImportService.parse(bytes, _profile());

      expect(rows.length, equals(3)); // en-tête + 2 lignes
      expect(rows[0][_colOp], equals('Operation'));
      expect(rows[1][_colLabel], equals('AIRBUS'));
      // Caractères accentués Latin-1 correctement décodés (pas de mojibake).
      expect(rows[2][_colOp], equals('Intérêts'));
      expect(rows[2][_colLabel], equals('Livret espèces'));
      // Décimale française conservée telle quelle par parse() (non convertie
      // ici — c'est le rôle de normalize()).
      expect(rows[1][_colAmount], equals('-1010,00'));
    });

    test('fichier vide → liste vide', () {
      expect(StatementImportService.parse(Uint8List(0), _profile()), isEmpty);
    });
  });

  group('StatementImportService.normalize — kinds et signes', () {
    test('Achat (buy) → amount négatif, quantity/unitPrice/fee renseignés',
        () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '05/01/2024;Achat;FR0000031122;AIRBUS;10;100,50;5,00;-1010,00\r\n'),
        _profile(),
      );
      final movements = StatementImportService.normalize(
        rows,
        _profile(),
        accountCurrency: 'EUR',
      );

      expect(movements, hasLength(1));
      final m = movements.single;
      expect(m.isRejected, isFalse);
      final tx = m.transaction!;
      expect(tx.kind, equals(TransactionKind.buy));
      expect(Decimal.parse(tx.quantity!), equals(Decimal.parse('10')));
      expect(Decimal.parse(tx.unitPrice!), equals(Decimal.parse('100.50')));
      expect(Decimal.parse(tx.fee!), equals(Decimal.parse('5.00')));
      // Signe forcé négatif quel que soit le signe déjà présent dans le fichier.
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('-1010.00')));
      expect(tx.settlementCurrency, equals('EUR'));
    });

    test('Vente (sell) → amount positif', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '15/01/2024;Vente;FR0000031122;AIRBUS;5;110,25;3,00;548,25\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.kind, equals(TransactionKind.sell));
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('548.25')));
    });

    test('Achat sans colonne Montant → amount dérivé de quantity×prix+frais',
        () {
      final profile = _profile();
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '06/01/2024;Achat;FR0000031122;AIRBUS;2;50,00;1,00;\r\n'),
        profile,
      );
      final tx = StatementImportService.normalize(rows, profile,
              accountCurrency: 'EUR')
          .single
          .transaction!;
      // -(2*50 + 1) = -101
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('-101')));
    });

    test('Dividende → amount positif (net)', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '10/01/2024;Dividende;FR0000031122;AIRBUS;;;;15,50\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.kind, equals(TransactionKind.dividend));
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('15.50')));
    });

    test('Versement (deposit) → amount positif', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '20/01/2024;Versement;;;;;;500,00\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.kind, equals(TransactionKind.deposit));
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('500.00')));
      expect(tx.symbol, isNull);
    });

    test('Retrait (withdrawal) → amount négatif même si fourni positif', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '21/01/2024;Retrait;;;;;;200,00\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.kind, equals(TransactionKind.withdrawal));
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('-200.00')));
    });

    test('Intérêts (interest) → amount positif', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '22/01/2024;Intérêts;;;;;;3,21\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.kind, equals(TransactionKind.interest));
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('3.21')));
    });

    test('Frais (charge) → amount négatif', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '23/01/2024;Frais;;;;;;9,90\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.kind, equals(TransactionKind.charge));
      expect(Decimal.parse(tx.amount!), equals(Decimal.parse('-9.90')));
    });
  });

  group('StatementImportService.normalize — rejets', () {
    test('libellé de nature d\'opération non mappé → rejet, jamais coercé en buy',
        () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '05/01/2024;OperationInconnue;FR0000031122;AIRBUS;10;100,50;5,00;-1010,00\r\n'),
        _profile(),
      );
      final movements =
          StatementImportService.normalize(rows, _profile(), accountCurrency: 'EUR');

      expect(movements, hasLength(1));
      final m = movements.single;
      expect(m.isRejected, isTrue);
      expect(m.transaction, isNull);
      expect(m.rejectReason, equals('unknownKind'));
      // La ligne source brute est conservée pour le diagnostic.
      expect(m.sourceRow[_colOp], equals('OperationInconnue'));
    });

    test('date invalide → rejet motivé', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '31/02/2024;Achat;FR0000031122;AIRBUS;10;100,50;5,00;-1010,00\r\n'),
        _profile(),
      );
      final m = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('invalidDate'));
    });

    test('Achat sans aucune identité d\'actif (ni ISIN ni libellé) → rejet',
        () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '05/01/2024;Achat;;;10;100,50;5,00;-1010,00\r\n'),
        _profile(),
      );
      final m = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('missingAssetIdentity'));
    });
  });

  group('StatementImportService.normalize — dates JJ/MM/AAAA', () {
    test('parse en local, sans dérive de jour, ni conversion UTC', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '31/12/2024;Achat;FR0000031122;AIRBUS;1;10,00;0,00;-10,00\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.date.year, equals(2024));
      expect(tx.date.month, equals(12));
      expect(tx.date.day, equals(31));
      expect(tx.date.isUtc, isFalse);
    });

    test('01/03/2024 (JJ/MM) n\'est PAS confondu avec MM/JJ (1 mars, pas '
        'le 3 janvier)', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '01/03/2024;Achat;FR0000031122;AIRBUS;1;10,00;0,00;-10,00\r\n'),
        _profile(),
      );
      final tx = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single
          .transaction!;
      expect(tx.date.month, equals(3));
      expect(tx.date.day, equals(1));
    });

    test('heure accolée à la date (export Fortuneo « 29/06/2026 00:00 ») : '
        'partie horaire ignorée, aucun rejet', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '29/06/2026 00:00;Vente;LU1190417599;LYXACTSMARTXPAR;30;109,36;0,00;3274,24\r\n'),
        _profile(),
      );
      final m = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single;
      expect(m.isRejected, isFalse, reason: m.rejectReason);
      final tx = m.transaction!;
      expect(tx.date.year, equals(2026));
      expect(tx.date.month, equals(6));
      expect(tx.date.day, equals(29));
      // Date à la JOURNÉE, jamais l'heure du relevé (l'ordre intraday vient de
      // `meta.seq`) — et toujours en local.
      expect(tx.date.hour, equals(0));
      expect(tx.date.isUtc, isFalse);
    });

    test('variantes d\'heure accolée (secondes, ISO T, minuit 00:00:00) '
        'toutes acceptées', () {
      for (final raw in const [
        '29/06/2026 09:30',
        '29/06/2026 09:30:15',
        '29/06/2026T09:30:15',
        '29/06/2026 09:30:15,123',
      ]) {
        final rows = StatementImportService.parse(
          _latin1Bytes('$_header\r\n'
              '$raw;Achat;FR0000031122;AIRBUS;1;10,00;0,00;-10,00\r\n'),
          _profile(),
        );
        final m = StatementImportService.normalize(rows, _profile(),
                accountCurrency: 'EUR')
            .single;
        expect(m.isRejected, isFalse, reason: '$raw → ${m.rejectReason}');
        expect(m.transaction!.date, equals(DateTime(2026, 6, 29)),
            reason: raw);
      }
    });

    test('une date SANS heure reconnaissable derrière reste rejetée (jamais '
        'tronquée en silence)', () {
      final rows = StatementImportService.parse(
        _latin1Bytes('$_header\r\n'
            '29/06/2026 blabla;Achat;FR0000031122;AIRBUS;1;10,00;0,00;-10,00\r\n'),
        _profile(),
      );
      final m = StatementImportService.normalize(rows, _profile(),
              accountCurrency: 'EUR')
          .single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('invalidDate'));
    });
  });

  group('StatementImportService.normalize — déduplication', () {
    test('ré-import du même relevé ⇒ mêmes importKey (mêmes ordinaux)', () {
      final text = '$_header\r\n'
          '05/01/2024;Achat;FR0000031122;AIRBUS;10;100,50;5,00;-1010,00\r\n'
          '10/01/2024;Dividende;FR0000031122;AIRBUS;;;;15,50\r\n'
          '15/01/2024;Vente;FR0000031122;AIRBUS;5;110,25;3,00;548,25\r\n';
      final rows = StatementImportService.parse(_latin1Bytes(text), _profile());

      final first = StatementImportService.normalize(rows, _profile(),
          accountCurrency: 'EUR', accountId: 'acc1');
      final second = StatementImportService.normalize(rows, _profile(),
          accountCurrency: 'EUR', accountId: 'acc1');

      expect(first.map((m) => m.importKey).toList(),
          equals(second.map((m) => m.importKey).toList()));
      // Aucun null (aucun rejet dans ce relevé).
      expect(first.every((m) => m.importKey != null), isTrue);
    });

    test('deux lignes de contenu réellement identique ⇒ ordinaux distincts '
        '(importKey différents)', () {
      final text = '$_header\r\n'
          '05/01/2024;Achat;FR0000031122;AIRBUS;1;100,00;0,00;-100,00\r\n'
          '05/01/2024;Achat;FR0000031122;AIRBUS;1;100,00;0,00;-100,00\r\n';
      final rows = StatementImportService.parse(_latin1Bytes(text), _profile());
      final movements = StatementImportService.normalize(rows, _profile(),
          accountCurrency: 'EUR', accountId: 'acc1');

      expect(movements, hasLength(2));
      expect(movements[0].importKey, isNot(equals(movements[1].importKey)));
    });

    test('référence d\'opération courtier fournie → utilisée comme clé de '
        'dédup (prioritaire sur le hash de contenu)', () {
      final profile = _profile().copyWith(
        columns: const ColumnMapping(byIndex: {
          MovementField.date: _colDate,
          MovementField.kindLabel: _colOp,
          MovementField.isin: _colIsin,
          MovementField.label: _colLabel,
          MovementField.quantity: _colQty,
          MovementField.unitPrice: _colPrice,
          MovementField.fee: _colFee,
          MovementField.amount: _colAmount,
          MovementField.operationReference: _colAmount + 1,
        }),
      );
      final text = '$_header;Ref\r\n'
          '05/01/2024;Achat;FR0000031122;AIRBUS;1;100,00;0,00;-100,00;OP123\r\n';
      final rows = StatementImportService.parse(_latin1Bytes(text), profile);
      final m = StatementImportService.normalize(rows, profile,
              accountCurrency: 'EUR', accountId: 'acc1')
          .single;
      expect(m.importKey, equals('ref:acc1:OP123'));
    });
  });

  group('StatementImportService.normalize — ordre chronologique des id', () {
    test('relevé anti-chronologique (plus récent en tête) est rejoué à '
        'l\'envers pour générer des id croissants avec la date', () {
      // Ordre du fichier : 20/01 puis 05/01 (anti-chronologique).
      final text = '$_header\r\n'
          '20/01/2024;Achat;FR0000031122;AIRBUS;1;10,00;0,00;-10,00\r\n'
          '05/01/2024;Achat;FR0000031122;AIRBUS;1;10,00;0,00;-10,00\r\n';
      final rows = StatementImportService.parse(_latin1Bytes(text), _profile());
      final movements = StatementImportService.normalize(rows, _profile(),
          accountCurrency: 'EUR');

      expect(movements, hasLength(2));
      // Les mouvements sont renvoyés en ordre chronologique croissant (05/01
      // avant 20/01), quel que soit l'ordre du fichier source.
      expect(movements[0].transaction!.date.day, equals(5));
      expect(movements[1].transaction!.date.day, equals(20));
      // Le mouvement le plus ancien a un id lexicalement inférieur (généré en
      // premier) — départage correct des ex-æquo de date par le rejeu.
      expect(movements[0].transaction!.id.compareTo(movements[1].transaction!.id),
          lessThan(0));
    });
  });
}

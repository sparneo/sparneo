// test/model/asset_transaction_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AssetTransaction _buyFull() => AssetTransaction(
      id: 'test_buy_001',
      accountId: 'acc_1',
      symbol: 'AAPL',
      kind: TransactionKind.buy,
      quantity: '10',
      unitPrice: '175.50',
      amount: '-1755.00',
      currency: 'USD',
      date: DateTime.utc(2024, 3, 15, 10, 30),
      fee: '1.99',
      note: 'Achat mensuel',
      meta: {'broker_id': 'ord_12345', 'tag': 'dca'},
    );

AssetTransaction _depositCash() => AssetTransaction(
      id: 'test_deposit_001',
      accountId: 'acc_1',
      symbol: null,
      kind: TransactionKind.deposit,
      quantity: null,
      unitPrice: null,
      amount: '5000.00',
      currency: 'EUR',
      date: DateTime.utc(2024, 1, 5),
      fee: null,
      note: null,
      meta: null,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // 1. Round-trip toJson → fromJson (chaque kind)
  // -------------------------------------------------------------------------

  group('AssetTransaction — round-trip JSON', () {
    test('buy complet (tous champs renseignés)', () {
      final original = _buyFull();
      final restored = AssetTransaction.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.accountId, original.accountId);
      expect(restored.symbol, original.symbol);
      expect(restored.kind, TransactionKind.buy);
      expect(restored.quantity, original.quantity);
      expect(restored.unitPrice, original.unitPrice);
      expect(restored.amount, original.amount);
      expect(restored.currency, original.currency);
      expect(restored.date.toIso8601String(), original.date.toIso8601String());
      expect(restored.fee, original.fee);
      expect(restored.note, original.note);
      expect(restored.meta, original.meta);
    });

    test('deposit cash pur (symbol/quantity/unitPrice/fee/note/meta tous null)', () {
      final original = _depositCash();
      final restored = AssetTransaction.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.kind, TransactionKind.deposit);
      expect(restored.symbol, isNull);
      expect(restored.quantity, isNull);
      expect(restored.unitPrice, isNull);
      expect(restored.fee, isNull);
      expect(restored.note, isNull);
      expect(restored.meta, isNull);
      expect(restored.amount, original.amount);
    });

    test('sell — round-trip fidèle', () {
      final original = AssetTransaction(
        id: 'tx_sell',
        accountId: 'acc_2',
        symbol: 'MSFT',
        kind: TransactionKind.sell,
        quantity: '5',
        unitPrice: '420.00',
        amount: '2100.00',
        currency: 'USD',
        date: DateTime.utc(2024, 6, 1),
      );
      final restored = AssetTransaction.fromJson(original.toJson());
      expect(restored.kind, TransactionKind.sell);
      expect(restored.amount, '2100.00');
    });

    test('dividend — round-trip fidèle', () {
      final original = AssetTransaction(
        id: 'tx_div',
        accountId: 'acc_2',
        symbol: 'VT',
        kind: TransactionKind.dividend,
        quantity: null,
        unitPrice: null,
        amount: '12.50',
        currency: 'USD',
        date: DateTime.utc(2024, 9, 15),
      );
      final restored = AssetTransaction.fromJson(original.toJson());
      expect(restored.kind, TransactionKind.dividend);
      expect(restored.symbol, 'VT');
      expect(restored.quantity, isNull);
    });

    test('withdrawal — round-trip fidèle', () {
      final original = AssetTransaction(
        id: 'tx_wd',
        accountId: 'acc_3',
        symbol: null,
        kind: TransactionKind.withdrawal,
        quantity: null,
        unitPrice: null,
        amount: '-2000.00',
        currency: 'EUR',
        date: DateTime.utc(2024, 12, 31),
      );
      final restored = AssetTransaction.fromJson(original.toJson());
      expect(restored.kind, TransactionKind.withdrawal);
      expect(restored.amount, '-2000.00');
    });

    test('interest (nouveau kind) — round-trip fidèle, cash pur positif', () {
      final original = AssetTransaction(
        id: 'tx_int',
        accountId: 'acc_4',
        symbol: null,
        kind: TransactionKind.interest,
        quantity: null,
        unitPrice: null,
        amount: '3.14',
        currency: 'EUR',
        date: DateTime.utc(2024, 7, 1),
      );
      final restored = AssetTransaction.fromJson(original.toJson());
      expect(restored.kind, TransactionKind.interest);
      expect(restored.symbol, isNull);
      expect(restored.amount, '3.14');
      // Le wire persisté est bien 'interest'.
      expect(original.toJson()['kind'], 'interest');
    });

    test('charge (nouveau kind) — round-trip fidèle, montant signé négatif', () {
      final original = AssetTransaction(
        id: 'tx_charge',
        accountId: 'acc_4',
        symbol: null,
        kind: TransactionKind.charge,
        quantity: null,
        unitPrice: null,
        amount: '-12.00',
        // Invariant : sur une ligne charge, le montant est porté par amount ;
        // fee reste null.
        fee: null,
        currency: 'EUR',
        date: DateTime.utc(2024, 8, 1),
      );
      final restored = AssetTransaction.fromJson(original.toJson());
      expect(restored.kind, TransactionKind.charge);
      expect(restored.amount, '-12.00');
      expect(restored.fee, isNull);
      // Le wire persisté est 'charge' (et NON 'fee' — pas de collision).
      expect(original.toJson()['kind'], 'charge');
      expect(TransactionKind.charge.wire, 'charge');
    });

    test('charge rebate (montant positif) — le signe est préservé', () {
      final original = AssetTransaction(
        id: 'tx_rebate',
        accountId: 'acc_4',
        symbol: null,
        kind: TransactionKind.charge,
        amount: '5.00',
        currency: 'EUR',
        date: DateTime.utc(2024, 8, 2),
      );
      final restored = AssetTransaction.fromJson(original.toJson());
      expect(restored.kind, TransactionKind.charge);
      expect(restored.amount, '5.00');
    });

    // ---- settlementCurrency (v7 — devise de règlement, design §8) ----

    test('settlementCurrency présent (titre USD réglé en EUR) → round-trip', () {
      final original = AssetTransaction(
        id: 'tx_cross',
        accountId: 'cto_eur',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '175.50', // cotation USD
        amount: '-1620.00', // net réglé EUR (fait figé)
        currency: 'USD',
        settlementCurrency: 'EUR',
        date: DateTime.utc(2024, 3, 15),
        fee: '1.99',
      );
      final json = original.toJson();
      // La clé est émise car non-null.
      expect(json['settlementCurrency'], 'EUR');
      final restored = AssetTransaction.fromJson(json);
      expect(restored.settlementCurrency, 'EUR');
      expect(restored.currency, 'USD');
      expect(restored.amount, '-1620.00');
    });

    test('settlementCurrency null → clé ABSENTE du JSON (backup non pollué)', () {
      final original = _buyFull(); // settlementCurrency non fourni → null
      expect(original.settlementCurrency, isNull);
      final json = original.toJson();
      expect(json.containsKey('settlementCurrency'), isFalse,
          reason: 'une ligne mono-devise ne doit PAS émettre la clé');
      final restored = AssetTransaction.fromJson(json);
      expect(restored.settlementCurrency, isNull);
    });

    test('fromJson tolérant : clé absente → null (rétro-compat pré-v7)', () {
      final json = <String, dynamic>{
        'id': 'legacy_1',
        'accountId': 'acc',
        'kind': 'buy',
        'currency': 'USD',
        'amount': '-100.00',
        'date': '2023-01-01T00:00:00.000Z',
      };
      final tx = AssetTransaction.fromJson(json);
      expect(tx.settlementCurrency, isNull);
    });

    test('fromJson tolérant : clé présente mais vide → null', () {
      final json = <String, dynamic>{
        'id': 'legacy_2',
        'accountId': 'acc',
        'kind': 'buy',
        'currency': 'USD',
        'amount': '-100.00',
        'settlementCurrency': '',
        'date': '2023-01-01T00:00:00.000Z',
      };
      final tx = AssetTransaction.fromJson(json);
      expect(tx.settlementCurrency, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 2. fromJson tolérant — JSON minimal / champs manquants
  // -------------------------------------------------------------------------

  group('AssetTransaction.fromJson — tolérance', () {
    test('JSON minimal (id/kind/currency/date) → objet valide, champs absents à null', () {
      final json = <String, dynamic>{
        'id': 'min_001',
        'kind': 'buy',
        'currency': 'EUR',
        'date': '2024-01-01T00:00:00.000Z',
      };
      final tx = AssetTransaction.fromJson(json);
      expect(tx.id, 'min_001');
      expect(tx.kind, TransactionKind.buy);
      expect(tx.currency, 'EUR');
      expect(tx.symbol, isNull);
      expect(tx.quantity, isNull);
      expect(tx.unitPrice, isNull);
      expect(tx.amount, isNull);
      expect(tx.fee, isNull);
      expect(tx.note, isNull);
      expect(tx.meta, isNull);
    });

    test('accountId absent → fallbackAccountId utilisé', () {
      final json = <String, dynamic>{
        'id': 'tx_fb',
        'kind': 'deposit',
        'currency': 'EUR',
        'date': '2024-02-01T00:00:00.000Z',
      };
      final tx = AssetTransaction.fromJson(json, fallbackAccountId: 'acc_fallback');
      expect(tx.accountId, 'acc_fallback');
    });

    test('accountId absent ET pas de fallback → chaîne vide (ne crash pas)', () {
      final json = <String, dynamic>{
        'id': 'tx_no_acc',
        'kind': 'buy',
        'currency': 'USD',
        'date': '2024-03-01T00:00:00.000Z',
      };
      // Ne doit pas lancer d'exception
      expect(() => AssetTransaction.fromJson(json), returnsNormally);
      final tx = AssetTransaction.fromJson(json);
      expect(tx.accountId, '');
    });

    test('meta présent → décodé comme Map', () {
      final json = <String, dynamic>{
        'id': 'tx_meta',
        'kind': 'buy',
        'currency': 'USD',
        'date': '2024-04-01T00:00:00.000Z',
        'meta': {'source': 'import_csv', 'ref': '42'},
      };
      final tx = AssetTransaction.fromJson(json);
      expect(tx.meta, isNotNull);
      expect(tx.meta!['source'], 'import_csv');
    });
  });

  // -------------------------------------------------------------------------
  // 3. TransactionKind.fromWire
  // -------------------------------------------------------------------------

  group('TransactionKind.fromWire', () {
    test('chaque valeur connue est correctement parsée', () {
      expect(TransactionKind.fromWire('buy'), TransactionKind.buy);
      expect(TransactionKind.fromWire('sell'), TransactionKind.sell);
      expect(TransactionKind.fromWire('dividend'), TransactionKind.dividend);
      expect(TransactionKind.fromWire('deposit'), TransactionKind.deposit);
      expect(TransactionKind.fromWire('withdrawal'), TransactionKind.withdrawal);
      expect(TransactionKind.fromWire('openingBalance'),
          TransactionKind.openingBalance);
      expect(TransactionKind.fromWire('adjustment'),
          TransactionKind.adjustment);
      expect(TransactionKind.fromWire('interest'), TransactionKind.interest);
      expect(TransactionKind.fromWire('charge'), TransactionKind.charge);
    });

    test('les 9 kinds ont un wire distinct et round-trippent', () {
      final wires = TransactionKind.values.map((k) => k.wire).toList();
      expect(wires.toSet().length, wires.length,
          reason: 'aucune collision de wire (charge != fee, etc.)');
      for (final k in TransactionKind.values) {
        expect(TransactionKind.fromWire(k.wire), k);
      }
      // 'fee' n'est PAS un wire (le champ fee ne doit pas être confondu avec
      // le kind charge).
      expect(TransactionKind.tryFromWire('fee'), isNull);
    });

    test('valeur inconnue → FormatException (plus de coercition silencieuse)',
        () {
      expect(() => TransactionKind.fromWire('unknown_future_kind'),
          throwsFormatException);
      expect(() => TransactionKind.fromWire(''), throwsFormatException);
      // Sensible à la casse : 'BUY' n'est pas un wire connu → lève.
      expect(() => TransactionKind.fromWire('BUY'), throwsFormatException);
    });
  });

  group('TransactionKind.tryFromWire', () {
    test('valeur connue → kind, y compris les nouveaux kinds', () {
      expect(TransactionKind.tryFromWire('buy'), TransactionKind.buy);
      expect(TransactionKind.tryFromWire('openingBalance'),
          TransactionKind.openingBalance);
      expect(TransactionKind.tryFromWire('adjustment'),
          TransactionKind.adjustment);
    });

    test('valeur inconnue → null (aucune coercition, aucune levée)', () {
      expect(TransactionKind.tryFromWire('unknown_future_kind'), isNull);
      expect(TransactionKind.tryFromWire(''), isNull);
      expect(TransactionKind.tryFromWire('BUY'), isNull); // sensible à la casse
    });
  });

  // -------------------------------------------------------------------------
  // 4. La valeur persistée est le wire anglais (R8 — pas un label i18n)
  // -------------------------------------------------------------------------

  group('AssetTransaction — valeur persistée = wire', () {
    test('toJson()[kind] contient le wire anglais, pas un label', () {
      for (final kind in TransactionKind.values) {
        final tx = AssetTransaction(
          id: 'wire_test_${kind.wire}',
          accountId: 'acc',
          kind: kind,
          currency: 'EUR',
          date: DateTime.utc(2024, 1, 1),
        );
        expect(tx.toJson()['kind'], kind.wire,
            reason: 'kind ${kind.name} doit être persisté comme "${kind.wire}"');
      }
    });

    test('wire de buy vaut "buy" (stable)', () => expect(TransactionKind.buy.wire, 'buy'));
    test('wire de sell vaut "sell"', () => expect(TransactionKind.sell.wire, 'sell'));
    test('wire de dividend vaut "dividend"', () => expect(TransactionKind.dividend.wire, 'dividend'));
    test('wire de deposit vaut "deposit"', () => expect(TransactionKind.deposit.wire, 'deposit'));
    test('wire de withdrawal vaut "withdrawal"', () => expect(TransactionKind.withdrawal.wire, 'withdrawal'));
  });

  // -------------------------------------------------------------------------
  // 5. copyWith
  // -------------------------------------------------------------------------

  group('AssetTransaction.copyWith', () {
    test('(a) modifie un champ non-nullable', () {
      final original = _buyFull();
      final copy = original.copyWith(currency: 'EUR');
      expect(copy.currency, 'EUR');
      expect(copy.id, original.id);
      expect(copy.kind, original.kind);
    });

    test('(a) modifie un champ nullable non-null vers une autre valeur', () {
      final original = _buyFull();
      final copy = original.copyWith(fee: '2.50');
      expect(copy.fee, '2.50');
      expect(copy.note, original.note); // inchangé
    });

    test('(b) efface symbol à null via la sentinelle', () {
      final original = _buyFull();
      expect(original.symbol, isNotNull);
      final copy = original.copyWith(symbol: null);
      expect(copy.symbol, isNull);
    });

    test('(b) efface quantity à null via la sentinelle', () {
      final original = _buyFull();
      final copy = original.copyWith(quantity: null);
      expect(copy.quantity, isNull);
    });

    test('(b) efface unitPrice à null via la sentinelle', () {
      final original = _buyFull();
      final copy = original.copyWith(unitPrice: null);
      expect(copy.unitPrice, isNull);
    });

    test('(b) efface amount à null via la sentinelle', () {
      final original = _buyFull();
      final copy = original.copyWith(amount: null);
      expect(copy.amount, isNull);
    });

    test('(b) efface fee à null via la sentinelle', () {
      final original = _buyFull();
      final copy = original.copyWith(fee: null);
      expect(copy.fee, isNull);
    });

    test('(b) efface note à null via la sentinelle', () {
      final original = _buyFull();
      final copy = original.copyWith(note: null);
      expect(copy.note, isNull);
    });

    test('(b) efface meta à null via la sentinelle', () {
      final original = _buyFull();
      expect(original.meta, isNotNull);
      final copy = original.copyWith(meta: null);
      expect(copy.meta, isNull);
    });

    test('(a) définit settlementCurrency puis (b) l\'efface via la sentinelle',
        () {
      final original = _buyFull();
      expect(original.settlementCurrency, isNull);
      final withSettle = original.copyWith(settlementCurrency: 'EUR');
      expect(withSettle.settlementCurrency, 'EUR');
      expect(withSettle.currency, original.currency); // inchangé
      final cleared = withSettle.copyWith(settlementCurrency: null);
      expect(cleared.settlementCurrency, isNull);
    });

    test('(c) sans argument → objet équivalent (tous champs identiques)', () {
      final original = _buyFull();
      final copy = original.copyWith();
      expect(copy.id, original.id);
      expect(copy.accountId, original.accountId);
      expect(copy.symbol, original.symbol);
      expect(copy.kind, original.kind);
      expect(copy.quantity, original.quantity);
      expect(copy.unitPrice, original.unitPrice);
      expect(copy.amount, original.amount);
      expect(copy.currency, original.currency);
      expect(copy.date, original.date);
      expect(copy.fee, original.fee);
      expect(copy.note, original.note);
      expect(copy.meta, original.meta);
    });

    test('copyWith sans arg sur un objet cash pur conserve les nulls', () {
      final original = _depositCash();
      final copy = original.copyWith();
      expect(copy.symbol, isNull);
      expect(copy.quantity, isNull);
      expect(copy.unitPrice, isNull);
      expect(copy.fee, isNull);
      expect(copy.meta, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 6. generateId
  // -------------------------------------------------------------------------

  group('AssetTransaction.generateId', () {
    test('deux appels successifs produisent des id distincts', () {
      final id1 = AssetTransaction.generateId();
      final id2 = AssetTransaction.generateId();
      expect(id1, isNot(equals(id2)));
    });

    test("l'id contient un séparateur '_'", () {
      final id = AssetTransaction.generateId();
      expect(id.contains('_'), isTrue);
    });

    test("la partie avant '_' est un entier (microsecondes)", () {
      final id = AssetTransaction.generateId();
      final parts = id.split('_');
      expect(parts.length, greaterThanOrEqualTo(2));
      expect(int.tryParse(parts.first), isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // 7. Égalité / hashCode sur l'id
  // -------------------------------------------------------------------------

  group('AssetTransaction — égalité', () {
    test('deux instances avec le même id sont égales', () {
      final a = AssetTransaction(
        id: 'same_id',
        accountId: 'acc',
        kind: TransactionKind.buy,
        currency: 'EUR',
        date: DateTime.utc(2024, 1, 1),
      );
      final b = AssetTransaction(
        id: 'same_id',
        accountId: 'acc_different',
        kind: TransactionKind.sell,
        currency: 'USD',
        date: DateTime.utc(2025, 6, 6),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('deux instances avec des id différents ne sont pas égales', () {
      final a = AssetTransaction(
        id: 'id_a',
        accountId: 'acc',
        kind: TransactionKind.buy,
        currency: 'EUR',
        date: DateTime.utc(2024, 1, 1),
      );
      final b = a.copyWith(id: 'id_b');
      expect(a, isNot(equals(b)));
    });
  });
}

// test/transaction_storage_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import 'helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Helpers d'insertion de parents (FK wallet → account → transaction)
// ---------------------------------------------------------------------------

/// Insère un wallet parent dans [db] pour satisfaire la FK
/// `accounts.wallet_id → wallets.id ON DELETE CASCADE`.
Future<void> _insertWallet(AppDatabase db, String walletId) async {
  final database = await db.database;
  await database.insert(
    'wallets',
    {
      'id': walletId,
      'name': 'Wallet $walletId',
      'created_at': '2024-01-01T00:00:00.000',
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}

/// Insère un compte parent dans [db] pour satisfaire la FK
/// `transactions.account_id → accounts.id ON DELETE CASCADE`.
///
/// Insère aussi le wallet [walletId] si [insertWallet] est true (défaut).
Future<void> _insertAccount(
  AppDatabase db,
  String accountId, {
  String walletId = 'w1',
  bool insertWallet = true,
}) async {
  if (insertWallet) await _insertWallet(db, walletId);
  final database = await db.database;
  await database.insert(
    'accounts',
    {
      'id': accountId,
      'wallet_id': walletId,
      'name': 'Account $accountId',
      'type': 'general',
      'currency': 'EUR',
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}

/// Construit une [AssetTransaction] de test avec des valeurs par défaut
/// raisonnables. Les paramètres nommés permettent de surcharger sélectivement.
AssetTransaction _tx({
  String id = 'tx_001',
  String accountId = 'acc1',
  String? symbol = 'AAPL',
  TransactionKind kind = TransactionKind.buy,
  String? quantity = '10',
  String? unitPrice = '150.00',
  String? amount = '-1500.00',
  String currency = 'USD',
  DateTime? date,
  String? fee = '1.50',
  String? note = 'Test note',
  Map<String, dynamic>? meta,
}) =>
    AssetTransaction(
      id: id,
      accountId: accountId,
      symbol: symbol,
      kind: kind,
      quantity: quantity,
      unitPrice: unitPrice,
      amount: amount,
      currency: currency,
      date: date ?? DateTime(2024, 6, 15, 10, 30, 0),
      fee: fee,
      note: note,
      meta: meta,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // (a) Round-trip upsert → getById : tous les champs préservés
  // -------------------------------------------------------------------------

  group('TransactionStorage — round-trip upsert/getById', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('upsert puis getById conserve tous les champs (y compris meta et amount signé)', () async {
      final original = _tx(
        id: 'tx_round_trip',
        meta: {'source': 'broker', 'tax': 12.5},
      );

      await storage.upsert(original);
      final restored = await storage.getById('tx_round_trip');

      expect(restored, isNotNull);
      expect(restored!.id, original.id);
      expect(restored.accountId, original.accountId);
      expect(restored.symbol, original.symbol);
      expect(restored.kind, original.kind);
      expect(restored.quantity, original.quantity);
      expect(restored.unitPrice, original.unitPrice);
      expect(restored.amount, original.amount);
      expect(restored.currency, original.currency);
      expect(restored.date, original.date);
      expect(restored.fee, original.fee);
      expect(restored.note, original.note);
      expect(restored.meta, original.meta);
    });

    test('settlementCurrency (v7) round-trip : présent puis relu', () async {
      final tx = _tx(
        id: 'tx_settle',
        currency: 'USD',
        amount: '-1620.00',
      ).copyWith(settlementCurrency: 'EUR');
      await storage.upsert(tx);
      final restored = await storage.getById('tx_settle');
      expect(restored!.settlementCurrency, 'EUR');
      expect(restored.currency, 'USD');
    });

    test('settlementCurrency null : round-trip conserve null', () async {
      final tx = _tx(id: 'tx_settle_null'); // settlementCurrency non fourni
      expect(tx.settlementCurrency, isNull);
      await storage.upsert(tx);
      final restored = await storage.getById('tx_settle_null');
      expect(restored!.settlementCurrency, isNull);
    });

    test('rétro-compat : ligne SANS settlement_currency (colonne omise) → null',
        () async {
      // Simule une ligne legacy écrite avant v7 : on insère en SQL brut sans la
      // colonne settlement_currency (NULLABLE) → la lecture doit retomber sur null.
      final database = await db.database;
      await database.insert('transactions', {
        'id': 'tx_legacy',
        'account_id': 'acc1',
        'symbol': 'AAPL',
        'kind': 'buy',
        'quantity': '1',
        'unit_price': '100',
        'amount': '-100',
        'currency': 'USD',
        'date': DateTime(2023, 1, 1).toIso8601String(),
        // settlement_currency volontairement ABSENT (colonne nullable).
      });
      final restored = await storage.getById('tx_legacy');
      expect(restored!.settlementCurrency, isNull);
    });

    test('amount signé négatif (buy) est conservé tel quel', () async {
      final tx = _tx(
        id: 'tx_negative_amount',
        kind: TransactionKind.buy,
        amount: '-3750.50',
      );
      await storage.upsert(tx);
      final restored = await storage.getById('tx_negative_amount');
      expect(restored!.amount, '-3750.50');
    });

    test('amount signé positif (sell) est conservé tel quel', () async {
      final tx = _tx(
        id: 'tx_positive_amount',
        kind: TransactionKind.sell,
        amount: '+2000.00',
      );
      await storage.upsert(tx);
      final restored = await storage.getById('tx_positive_amount');
      expect(restored!.amount, '+2000.00');
    });

    test('transaction cash (symbol null) est préservée', () async {
      final tx = _tx(
        id: 'tx_cash',
        symbol: null,
        kind: TransactionKind.deposit,
        quantity: null,
        unitPrice: null,
        amount: '500.00',
      );
      await storage.upsert(tx);
      final restored = await storage.getById('tx_cash');
      expect(restored!.symbol, isNull);
      expect(restored.quantity, isNull);
      expect(restored.unitPrice, isNull);
      expect(restored.kind, TransactionKind.deposit);
    });

    test('getById retourne null si id absent', () async {
      final result = await storage.getById('id_inexistant');
      expect(result, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // (b) Upsert idempotent : ré-upsert du même id écrase, pas de doublon
  // -------------------------------------------------------------------------

  group('TransactionStorage — upsert idempotent', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('ré-upsert du même id écrase les données (pas de doublon)', () async {
      final tx1 = _tx(id: 'tx_idem', amount: '-100.00', note: 'première version');
      final tx2 = _tx(id: 'tx_idem', amount: '-200.00', note: 'seconde version');

      await storage.upsert(tx1);
      await storage.upsert(tx2);

      final all = await storage.getByAccount('acc1');
      // Un seul enregistrement après deux upserts du même id
      expect(all.where((t) => t.id == 'tx_idem').length, 1);

      final restored = await storage.getById('tx_idem');
      expect(restored!.amount, '-200.00');
      expect(restored.note, 'seconde version');
    });
  });

  // -------------------------------------------------------------------------
  // (c) Tri déterministe : date DESC, id DESC — cas des ex-æquo de date
  // -------------------------------------------------------------------------

  group('TransactionStorage — tri déterministe getByAccount', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('3 transactions dont 2 à la même date exacte → date DESC, id DESC stable', () async {
      // txA et txB partagent la même date ISO-8601 exacte.
      // txC est plus ancienne.
      // Ordre attendu après date DESC, id DESC : txB (même date, id > txA), txA, txC.
      const sameDate = '2024-06-15T10:30:00.000';
      const olderDate = '2024-06-10T08:00:00.000';

      final txA = AssetTransaction(
        id: 'id_aaaaa',
        accountId: 'acc1',
        kind: TransactionKind.buy,
        currency: 'EUR',
        date: DateTime.parse(sameDate),
        symbol: 'MSFT',
        quantity: '1',
        unitPrice: '300.00',
        amount: '-300.00',
      );
      final txB = AssetTransaction(
        id: 'id_bbbbb',
        accountId: 'acc1',
        kind: TransactionKind.sell,
        currency: 'EUR',
        date: DateTime.parse(sameDate),
        symbol: 'MSFT',
        quantity: '2',
        unitPrice: '310.00',
        amount: '620.00',
      );
      final txC = AssetTransaction(
        id: 'id_ccccc',
        accountId: 'acc1',
        kind: TransactionKind.buy,
        currency: 'EUR',
        date: DateTime.parse(olderDate),
        symbol: 'MSFT',
        quantity: '5',
        unitPrice: '290.00',
        amount: '-1450.00',
      );

      // Insertion dans l'ordre C, A, B (volontairement désordonnée)
      await storage.upsert(txC);
      await storage.upsert(txA);
      await storage.upsert(txB);

      final result = await storage.getByAccount('acc1');
      expect(result, hasLength(3));

      // date DESC : txB et txA (même date) avant txC
      // id DESC pour départager txB vs txA : 'id_bbbbb' > 'id_aaaaa'
      expect(result[0].id, 'id_bbbbb');
      expect(result[1].id, 'id_aaaaa');
      expect(result[2].id, 'id_ccccc');
    });
  });

  // -------------------------------------------------------------------------
  // (d) getBySymbol : filtre par symbole ; cash (null) n'apparaît pas
  // -------------------------------------------------------------------------

  group('TransactionStorage — getBySymbol', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('filtre bien par symbole ; une transaction cash (symbol null) n\'apparaît pas', () async {
      await storage.upsert(_tx(id: 'tx_aapl_1', symbol: 'AAPL'));
      await storage.upsert(_tx(id: 'tx_msft_1', symbol: 'MSFT'));
      await storage.upsert(_tx(
        id: 'tx_cash_1',
        symbol: null,
        kind: TransactionKind.deposit,
        quantity: null,
        unitPrice: null,
        amount: '1000.00',
      ));

      final result = await storage.getBySymbol('acc1', 'AAPL');
      expect(result, hasLength(1));
      expect(result.first.id, 'tx_aapl_1');
    });

    test('retourne uniquement les transactions du compte ET du symbole demandés', () async {
      await _insertAccount(db, 'acc2', walletId: 'w1', insertWallet: false);

      await storage.upsert(_tx(id: 'tx_acc1_aapl', accountId: 'acc1', symbol: 'AAPL'));
      await storage.upsert(_tx(id: 'tx_acc2_aapl', accountId: 'acc2', symbol: 'AAPL'));

      final result = await storage.getBySymbol('acc1', 'AAPL');
      expect(result, hasLength(1));
      expect(result.first.id, 'tx_acc1_aapl');
    });

    test('getBySymbol avec symbol inconnu retourne une liste vide', () async {
      await storage.upsert(_tx(id: 'tx_aapl', symbol: 'AAPL'));
      final result = await storage.getBySymbol('acc1', 'UNKN');
      expect(result, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // (e) getByPeriod : bornes incluses, hors bornes exclues
  // -------------------------------------------------------------------------

  group('TransactionStorage — getByPeriod', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('borne basse incluse, borne haute incluse, hors bornes exclues', () async {
      final before = DateTime(2024, 6, 1, 0, 0, 0);
      final from   = DateTime(2024, 6, 10, 0, 0, 0);
      final inside = DateTime(2024, 6, 15, 12, 0, 0);
      final to     = DateTime(2024, 6, 20, 23, 59, 59);
      final after  = DateTime(2024, 6, 25, 0, 0, 0);

      await storage.upsert(_tx(id: 'tx_before', date: before));
      await storage.upsert(_tx(id: 'tx_from',   date: from));
      await storage.upsert(_tx(id: 'tx_inside', date: inside));
      await storage.upsert(_tx(id: 'tx_to',     date: to));
      await storage.upsert(_tx(id: 'tx_after',  date: after));

      final result = await storage.getByPeriod('acc1', from, to);
      final ids = result.map((t) => t.id).toSet();

      expect(ids.contains('tx_before'), isFalse, reason: 'avant la borne basse');
      expect(ids.contains('tx_from'),   isTrue,  reason: 'borne basse incluse');
      expect(ids.contains('tx_inside'), isTrue,  reason: 'dans la période');
      expect(ids.contains('tx_to'),     isTrue,  reason: 'borne haute incluse');
      expect(ids.contains('tx_after'),  isFalse, reason: 'après la borne haute');
    });
  });

  // -------------------------------------------------------------------------
  // (f) deleteById / deleteForAccount (idempotence)
  // -------------------------------------------------------------------------

  group('TransactionStorage — suppression', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('deleteById supprime la transaction ciblée', () async {
      await storage.upsert(_tx(id: 'tx_del_1'));
      await storage.upsert(_tx(id: 'tx_del_2'));

      await storage.deleteById('tx_del_1');

      expect(await storage.getById('tx_del_1'), isNull);
      expect(await storage.getById('tx_del_2'), isNotNull);
    });

    test('deleteById est idempotent (pas d\'exception si id absent)', () async {
      await expectLater(storage.deleteById('id_inexistant'), completes);
    });

    test('deleteForAccount supprime toutes les transactions du compte', () async {
      await storage.upsert(_tx(id: 'tx_a1'));
      await storage.upsert(_tx(id: 'tx_a2'));

      await storage.deleteForAccount('acc1');

      expect(await storage.getByAccount('acc1'), isEmpty);
    });

    test('deleteForAccount est idempotent (pas d\'exception si compte vide)', () async {
      await expectLater(storage.deleteForAccount('acc_inexistant'), completes);
    });

    test('deleteForAccount n\'affecte pas les transactions d\'un autre compte', () async {
      await _insertAccount(db, 'acc2', walletId: 'w1', insertWallet: false);
      await storage.upsert(_tx(id: 'tx_acc1', accountId: 'acc1'));
      await storage.upsert(_tx(id: 'tx_acc2', accountId: 'acc2'));

      await storage.deleteForAccount('acc1');

      expect(await storage.getByAccount('acc1'), isEmpty);
      expect(await storage.getByAccount('acc2'), hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // (g) Cascade FK : supprimer le compte parent purge ses transactions
  // -------------------------------------------------------------------------

  group('TransactionStorage — cascade FK (suppression compte parent)', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('supprimer le compte parent en SQL cascade-supprime ses transactions', () async {
      await storage.upsert(_tx(id: 'tx_cascade_1'));
      await storage.upsert(_tx(id: 'tx_cascade_2'));

      // Vérification préalable
      expect(await storage.getByAccount('acc1'), hasLength(2));

      // Suppression du compte par SQL direct (foreign_keys = ON → cascade)
      final database = await db.database;
      await database.delete('accounts', where: 'id = ?', whereArgs: ['acc1']);

      // Les transactions doivent avoir disparu (cascade)
      expect(await storage.getByAccount('acc1'), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // (h) FK : upsert avec account_id inexistant → lève une exception
  // -------------------------------------------------------------------------

  group('TransactionStorage — FK violation', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      // Aucun compte inséré → toute tentative d'upsert doit échouer
    });

    tearDown(() async => db.close());

    test('upsert avec account_id inexistant lève une exception (FK violation)', () async {
      final tx = _tx(id: 'tx_fk_fail', accountId: 'compte_inexistant');
      await expectLater(storage.upsert(tx), throwsException);
    });
  });

  // -------------------------------------------------------------------------
  // (i) Mapping meta : round-trip non-null ; meta_json corrompu → meta null
  // -------------------------------------------------------------------------

  group('TransactionStorage — mapping meta_json', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    test('meta non-null round-trip préserve la structure complète', () async {
      final meta = {
        'source': 'broker_api',
        'tax': 15.0,
        'tags': ['dividend', 'us'],
        'nested': {'key': 'value'},
      };
      await storage.upsert(_tx(id: 'tx_meta', meta: meta));
      final restored = await storage.getById('tx_meta');
      expect(restored!.meta, meta);
    });

    test('meta null est préservé (pas de meta_json en base)', () async {
      await storage.upsert(_tx(id: 'tx_no_meta', meta: null));
      final restored = await storage.getById('tx_no_meta');
      expect(restored!.meta, isNull);
    });

    test('meta_json corrompu en base → getById retourne meta null sans crash', () async {
      // Insertion directe d'un meta_json invalide, sans passer par upsert
      // (le compte parent doit exister pour satisfaire la FK)
      final database = await db.database;
      await database.rawInsert(
        '''
        INSERT INTO transactions(id, account_id, symbol, kind, currency, date, meta_json)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          'tx_corrupt_meta',
          'acc1',
          'AAPL',
          'buy',
          'EUR',
          '2024-06-15T00:00:00.000000',
          'invalid{{json',
        ],
      );

      final restored = await storage.getById('tx_corrupt_meta');
      expect(restored, isNotNull);
      expect(restored!.meta, isNull);
    });

    test('meta_json JSON scalaire (non-Map) → meta null sans crash', () async {
      final database = await db.database;
      await database.rawInsert(
        '''
        INSERT INTO transactions(id, account_id, symbol, kind, currency, date, meta_json)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          'tx_scalar_meta',
          'acc1',
          'AAPL',
          'buy',
          'EUR',
          '2024-06-15T00:00:00.000000',
          '"just_a_string"',
        ],
      );

      final restored = await storage.getById('tx_scalar_meta');
      expect(restored, isNotNull);
      expect(restored!.meta, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // (j) tous les TransactionKind — round-trip de la valeur wire
  // -------------------------------------------------------------------------

  group('TransactionStorage — round-trip de tous les TransactionKind', () {
    late AppDatabase db;
    late TransactionStorage storage;

    setUp(() async {
      db = await openTestDatabase();
      storage = TransactionStorage(database: db);
      await _insertAccount(db, 'acc1');
    });

    tearDown(() async => db.close());

    for (final kind in TransactionKind.values) {
      test('kind ${kind.wire} est préservé en base', () async {
        final tx = _tx(id: 'tx_kind_${kind.wire}', kind: kind);
        await storage.upsert(tx);
        final restored = await storage.getById('tx_kind_${kind.wire}');
        expect(restored!.kind, kind);
      });
    }
  });
}

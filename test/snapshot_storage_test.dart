// test/snapshot_storage_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/model/valuation_snapshot.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/snapshot_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ValuationSnapshot _snap({
  String date = '2024-06-15',
  double totalValue = 10000.0,
  String currency = 'EUR',
  int capturedAt = 1718400000000,
  int accountCount = 3,
  int schemaVersion = 1,
}) =>
    ValuationSnapshot(
      date: date,
      totalValue: totalValue,
      currency: currency,
      capturedAt: capturedAt,
      accountCount: accountCount,
      schemaVersion: schemaVersion,
    );

/// Insère un wallet parent dans [db] pour satisfaire la contrainte FK
/// `snapshots.wallet_id → wallets.id ON DELETE CASCADE`.
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // (a) Round-trip JSON stable — pas de dépendance DB, groupe isolé
  // -------------------------------------------------------------------------

  group('ValuationSnapshot — round-trip JSON', () {
    test('toJson → fromJson conserve tous les champs', () {
      final original = _snap();
      final restored = ValuationSnapshot.fromJson(original.toJson());

      expect(restored.date, original.date);
      expect(restored.totalValue, original.totalValue);
      expect(restored.currency, original.currency);
      expect(restored.capturedAt, original.capturedAt);
      expect(restored.accountCount, original.accountCount);
      expect(restored.schemaVersion, original.schemaVersion);
    });
  });

  // -------------------------------------------------------------------------
  // (b) fromJson tolérant aux champs manquants — pas de dépendance DB
  // -------------------------------------------------------------------------

  group('ValuationSnapshot.fromJson — tolérance aux champs manquants', () {
    test('JSON vide applique les valeurs par défaut', () {
      final snap = ValuationSnapshot.fromJson({});

      expect(snap.date, '');
      expect(snap.totalValue, 0.0);
      expect(snap.currency, 'EUR');
      expect(snap.capturedAt, 0);
      expect(snap.accountCount, 0);
      expect(snap.schemaVersion, 1);
    });

    test('JSON partiel (date + totalValue seulement) complète le reste', () {
      final snap = ValuationSnapshot.fromJson({
        'date': '2024-01-01',
        'totalValue': 5000.0,
      });

      expect(snap.date, '2024-01-01');
      expect(snap.totalValue, 5000.0);
      expect(snap.currency, 'EUR');
      expect(snap.schemaVersion, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Groupes utilisant SQLite in-memory
  // -------------------------------------------------------------------------

  group('SnapshotStorage SQLite', () {
    late AppDatabase db;
    late SnapshotStorage storage;

    setUp(() async {
      // Chaque test obtient une base in-memory isolée (openTestDatabase crée
      // une instance distincte à chaque appel — voir test_database.dart).
      db = await openTestDatabase();
      storage = SnapshotStorage(database: db);

      // Wallet parent obligatoire : la FK wallet_id → wallets.id ON DELETE
      // CASCADE est active (PRAGMA foreign_keys = ON) ; sans ce wallet, les
      // INSERT INTO snapshots seraient rejetés avec une erreur FK.
      await _insertWallet(db, 'w1');
    });

    tearDown(() async {
      await db.close();
    });

    // -----------------------------------------------------------------------
    // (c) Upsert idempotent : deux fois la même date → 1 seule entrée
    // -----------------------------------------------------------------------

    group('upsertSnapshot — idempotence', () {
      test('upsert deux fois la même date ne conserve que la dernière valeur', () async {
        const walletId = 'w1';

        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-15', totalValue: 10000.0));
        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-15', totalValue: 12500.0));

        final snapshots = await storage.getSnapshots(walletId);

        expect(snapshots.length, 1);
        expect(snapshots.first.totalValue, 12500.0);
      });
    });

    // -----------------------------------------------------------------------
    // (d) Tri par date croissante
    // -----------------------------------------------------------------------

    group('getSnapshots — tri par date croissante', () {
      test("les snapshots sont retournés par date croissante quelle que soit l'ordre d'insertion", () async {
        const walletId = 'w1';

        // Insertion volontairement désordonnée
        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-20', totalValue: 3.0));
        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-10', totalValue: 1.0));
        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-15', totalValue: 2.0));

        final snapshots = await storage.getSnapshots(walletId);

        expect(snapshots.length, 3);
        expect(snapshots[0].date, '2024-06-10');
        expect(snapshots[1].date, '2024-06-15');
        expect(snapshots[2].date, '2024-06-20');
      });
    });

    // -----------------------------------------------------------------------
    // (e) Rétention : entrée > 5 ans est purgée lors d'un upsert
    // -----------------------------------------------------------------------

    group('upsertSnapshot — rétention', () {
      test('une entrée vieille de plus de 1826 jours est purgée lors de l\'upsert suivant', () async {
        const walletId = 'w1';

        // Snapshot récent de référence : 2024-06-15
        // Snapshot ancien : 2024-06-15 − 1827 jours = hors rétention
        final reference = DateTime(2024, 6, 15);
        final tooOld = reference.subtract(const Duration(days: 1827));
        final justOk = reference.subtract(const Duration(days: 1826));

        final tooOldKey = ValuationSnapshot.dateKeyFor(tooOld);
        final justOkKey = ValuationSnapshot.dateKeyFor(justOk);

        // Pré-peuple les anciennes entrées directement via des upserts préalables
        await storage.upsertSnapshot(walletId, _snap(date: tooOldKey, totalValue: 999.0));
        await storage.upsertSnapshot(walletId, _snap(date: justOkKey, totalValue: 888.0));

        // Upsert du snapshot récent : déclenche la purge
        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-15', totalValue: 10000.0));

        final snapshots = await storage.getSnapshots(walletId);
        final dates = snapshots.map((s) => s.date).toList();

        // L'entrée trop ancienne doit avoir été supprimée
        expect(dates.contains(tooOldKey), isFalse);
        // L'entrée juste dans la rétention doit être conservée
        expect(dates.contains(justOkKey), isTrue);
        expect(dates.contains('2024-06-15'), isTrue);
      });
    });

    // -----------------------------------------------------------------------
    // (f) deleteSnapshotsForWallet vide la liste
    // -----------------------------------------------------------------------

    group('deleteSnapshotsForWallet', () {
      test('supprime tous les snapshots du wallet', () async {
        const walletId = 'w1';

        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-10'));
        await storage.upsertSnapshot(walletId, _snap(date: '2024-06-11'));

        await storage.deleteSnapshotsForWallet(walletId);

        final snapshots = await storage.getSnapshots(walletId);
        expect(snapshots, isEmpty);
      });
    });

    // -----------------------------------------------------------------------
    // (g) Isolation entre deux walletIds différents
    // -----------------------------------------------------------------------

    group('isolation entre wallets', () {
      setUp(() async {
        // wallet supplémentaire pour les tests d'isolation
        await _insertWallet(db, 'walletA');
        await _insertWallet(db, 'walletB');
      });

      test('les snapshots de deux wallets distincts ne se mélangent pas', () async {
        await storage.upsertSnapshot('walletA', _snap(date: '2024-06-15', totalValue: 1000.0));
        await storage.upsertSnapshot('walletB', _snap(date: '2024-06-15', totalValue: 9999.0));

        final snapsA = await storage.getSnapshots('walletA');
        final snapsB = await storage.getSnapshots('walletB');

        expect(snapsA.length, 1);
        expect(snapsA.first.totalValue, 1000.0);

        expect(snapsB.length, 1);
        expect(snapsB.first.totalValue, 9999.0);
      });

      test('deleteSnapshotsForWallet ne supprime que le wallet ciblé', () async {
        await storage.upsertSnapshot('walletA', _snap(date: '2024-06-15', totalValue: 1000.0));
        await storage.upsertSnapshot('walletB', _snap(date: '2024-06-15', totalValue: 9999.0));

        await storage.deleteSnapshotsForWallet('walletA');

        expect(await storage.getSnapshots('walletA'), isEmpty);
        expect(await storage.getSnapshots('walletB'), hasLength(1));
      });
    });

    // -----------------------------------------------------------------------
    // (h) NOUVEAU : deleteSnapshotsForWallet(w1) ne touche pas w2
    //     (two-wallet explicit isolation test)
    // -----------------------------------------------------------------------

    group('deleteSnapshotsForWallet — isolation 2 wallets', () {
      test('insertion dans 2 wallets : delete w1 laisse w2 intact', () async {
        // w1 est déjà inséré dans setUp ; on ajoute w2
        await _insertWallet(db, 'w2');

        await storage.upsertSnapshot('w1', _snap(date: '2024-03-01', totalValue: 5000.0));
        await storage.upsertSnapshot('w1', _snap(date: '2024-03-02', totalValue: 5100.0));
        await storage.upsertSnapshot('w2', _snap(date: '2024-03-01', totalValue: 8000.0));

        await storage.deleteSnapshotsForWallet('w1');

        // w1 : vidé
        expect(await storage.getSnapshots('w1'), isEmpty);
        // w2 : intact
        final snapsW2 = await storage.getSnapshots('w2');
        expect(snapsW2, hasLength(1));
        expect(snapsW2.first.totalValue, 8000.0);
      });
    });
  });

  // -------------------------------------------------------------------------
  // Bonus : helper dateKeyFor — pas de dépendance DB
  // -------------------------------------------------------------------------

  group('ValuationSnapshot.dateKeyFor', () {
    test('formate correctement avec padding zéros', () {
      expect(ValuationSnapshot.dateKeyFor(DateTime(2024, 1, 5)), '2024-01-05');
      expect(ValuationSnapshot.dateKeyFor(DateTime(2024, 12, 31)), '2024-12-31');
      expect(ValuationSnapshot.dateKeyFor(DateTime(2000, 6, 15)), '2000-06-15');
    });
  });
}

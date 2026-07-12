// test/allocation_target_storage_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/services/allocation_target_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';

import 'helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late AllocationTargetStorage storage;

  setUp(() async {
    db = await openTestDatabase();
    storage = AllocationTargetStorage(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  // Helpers ----------------------------------------------------------------

  /// Insère un wallet parent pour satisfaire la FK wallet_id → wallets.id.
  Future<void> insertWallet(String walletId) async {
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

  // -------------------------------------------------------------------------
  // (a) Défaut : empty si aucune cible enregistrée
  // -------------------------------------------------------------------------

  group('AllocationTargetStorage.getTarget — défaut', () {
    test('retourne AllocationTarget.empty() si aucune cible enregistrée', () async {
      // Aucune ligne dans allocation_targets → doit retourner empty
      final target = await storage.getTarget('wallet1');
      expect(target.isEmpty, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // (b) Round-trip saveTarget → getTarget
  // -------------------------------------------------------------------------

  group('AllocationTargetStorage — round-trip', () {
    test('saveTarget puis getTarget retourne la même cible', () async {
      await insertWallet('w1');

      final original = AllocationTarget(targets: {
        AssetType.etf.name: 60.0,
        AssetType.crypto.name: 20.0,
      });

      await storage.saveTarget('w1', original);
      final restored = await storage.getTarget('w1');

      expect(restored.targets, hasLength(2));
      expect(restored.targetFor(AssetType.etf), 60.0);
      expect(restored.targetFor(AssetType.crypto), 20.0);
    });

    test('saveTarget écrase la cible précédente', () async {
      await insertWallet('w1');

      await storage.saveTarget('w1', AllocationTarget(targets: {AssetType.etf.name: 50.0}));
      await storage.saveTarget('w1', AllocationTarget(targets: {AssetType.bond.name: 30.0}));

      final target = await storage.getTarget('w1');
      expect(target.targetFor(AssetType.etf), isNull);
      expect(target.targetFor(AssetType.bond), 30.0);
    });
  });

  // -------------------------------------------------------------------------
  // (c) JSON corrompu → empty (pas de crash)
  // -------------------------------------------------------------------------

  group('AllocationTargetStorage — JSON corrompu', () {
    test('JSON corrompu retourne AllocationTarget.empty() sans exception', () async {
      // Insertion directe d'une ligne avec target_json invalide.
      // Le wallet parent doit exister pour satisfaire la FK.
      await insertWallet('w1');
      final database = await db.database;
      await database.rawInsert(
        "INSERT INTO allocation_targets(wallet_id, target_json) VALUES(?, ?)",
        ['w1', 'not_valid_json{{'],
      );

      final target = await storage.getTarget('w1');
      expect(target.isEmpty, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // (d) deleteTargetForWallet
  // -------------------------------------------------------------------------

  group('AllocationTargetStorage.deleteTargetForWallet', () {
    test('supprime la cible du wallet ciblé', () async {
      await insertWallet('w1');
      await storage.saveTarget('w1', AllocationTarget(targets: {AssetType.etf.name: 50.0}));

      await storage.deleteTargetForWallet('w1');

      final target = await storage.getTarget('w1');
      expect(target.isEmpty, isTrue);
    });

    test('delete est idempotent (pas d\'exception si clé absente)', () async {
      // Aucune cible n'existe : deleteTargetForWallet ne doit pas lever
      await expectLater(storage.deleteTargetForWallet('nonexistent'), completes);
    });
  });

  // -------------------------------------------------------------------------
  // (e) Isolation entre walletIds distincts
  // -------------------------------------------------------------------------

  group('AllocationTargetStorage — isolation entre wallets', () {
    test('les cibles de deux wallets distincts ne se mélangent pas', () async {
      await insertWallet('wA');
      await insertWallet('wB');

      await storage.saveTarget('wA', AllocationTarget(targets: {AssetType.etf.name: 70.0}));
      await storage.saveTarget('wB', AllocationTarget(targets: {AssetType.crypto.name: 15.0}));

      final targetA = await storage.getTarget('wA');
      final targetB = await storage.getTarget('wB');

      expect(targetA.targetFor(AssetType.etf), 70.0);
      expect(targetA.targetFor(AssetType.crypto), isNull);

      expect(targetB.targetFor(AssetType.crypto), 15.0);
      expect(targetB.targetFor(AssetType.etf), isNull);
    });

    test('deleteTargetForWallet ne supprime que le wallet ciblé', () async {
      await insertWallet('wA');
      await insertWallet('wB');

      await storage.saveTarget('wA', AllocationTarget(targets: {AssetType.etf.name: 60.0}));
      await storage.saveTarget('wB', AllocationTarget(targets: {AssetType.stock.name: 40.0}));

      await storage.deleteTargetForWallet('wA');

      expect((await storage.getTarget('wA')).isEmpty, isTrue);
      expect((await storage.getTarget('wB')).isEmpty, isFalse);
    });
  });
}

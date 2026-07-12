// lib/services/allocation_target_storage.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/services/app_database.dart';

/// Persistance des cibles d'allocation par wallet via SQLite.
/// Table : `allocation_targets(wallet_id PK, target_json TEXT)`.
///
/// Pattern identique à [SnapshotStorage] : injection [AppDatabase] optionnelle,
/// fallback `AppDatabase()` par défaut (singleton runtime effectif).
class AllocationTargetStorage {
  final AppDatabase? _database;

  /// Constructeur de production : utilise l'instance [AppDatabase] injectée
  /// ou crée un [AppDatabase()] par défaut.
  AllocationTargetStorage({AppDatabase? database}) : _database = database;

  /// Constructeur réservé aux tests : permet de sous-classer [AllocationTargetStorage]
  /// dans les fakes sans ouvrir de base de données réelle.
  ///
  /// Le champ [_database] reste null et n'est jamais accédé si les méthodes
  /// sont toutes surchargées.
  @visibleForTesting
  AllocationTargetStorage.forTesting() : _database = null;

  /// Retourne l'instance [AppDatabase] effective.
  /// En production (aucune injection) : le singleton partagé (R6).
  AppDatabase get _db => _database ?? AppDatabase.shared();

  // --- Lecture ---

  /// Retourne les cibles du wallet [walletId].
  /// Si aucune ligne n'existe : retourne [AllocationTarget.empty()].
  /// Si le JSON stocké est corrompu : retourne [AllocationTarget.empty()]
  /// sans lever d'exception.
  Future<AllocationTarget> getTarget(String walletId) async {
    final db = await _db.database;
    final rows = await db.query(
      'allocation_targets',
      where: 'wallet_id = ?',
      whereArgs: [walletId],
      limit: 1,
    );
    if (rows.isEmpty) return const AllocationTarget.empty();

    final raw = rows.first['target_json'] as String;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AllocationTarget.fromJson(json);
    } catch (_) {
      // JSON corrompu : on retourne une cible vide plutôt que de crasher.
      return const AllocationTarget.empty();
    }
  }

  // --- Écriture ---

  /// Persiste les cibles du wallet [walletId] via INSERT OR REPLACE.
  ///
  /// ATTENTION FK : la ligne wallet correspondante doit exister dans `wallets`
  /// (PRAGMA foreign_keys = ON, ON DELETE CASCADE). En production cela est
  /// toujours le cas ; en test, insérer le wallet parent avant d'appeler
  /// saveTarget.
  Future<void> saveTarget(String walletId, AllocationTarget target) async {
    final db = await _db.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO allocation_targets(wallet_id, target_json) VALUES(?, ?)',
      [walletId, jsonEncode(target.toJson())],
    );
  }

  // --- Suppression ---

  /// Supprime les cibles associées à [walletId].
  /// Idempotent : aucune exception si la ligne est absente.
  Future<void> deleteTargetForWallet(String walletId) async {
    final db = await _db.database;
    await db.delete(
      'allocation_targets',
      where: 'wallet_id = ?',
      whereArgs: [walletId],
    );
  }
}

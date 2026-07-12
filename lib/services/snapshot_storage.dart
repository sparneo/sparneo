// lib/services/snapshot_storage.dart
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/model/valuation_snapshot.dart';
import 'package:portfolio_tracker/services/app_database.dart';

/// Persistance des snapshots de valorisation journaliers via SQLite.
///
/// Table cible : `snapshots(wallet_id, date, total_value, currency,
///   captured_at, account_count, schema_version, PK(wallet_id,date))`.
///
/// Rétention : [_retentionDays] jours (~5 ans) à partir de la date du
/// snapshot inséré — identique à l'ancienne implémentation SharedPreferences.
class SnapshotStorage {
  /// Nombre de jours de rétention (~5 ans).
  static const int _retentionDays = 1826;

  final AppDatabase? _database;

  /// Constructeur de production : utilise l'instance [AppDatabase] injectée
  /// ou crée un [AppDatabase()] par défaut (singleton runtime effectif).
  SnapshotStorage({AppDatabase? database}) : _database = database;

  /// Constructeur réservé aux tests : permet de sous-classer [SnapshotStorage]
  /// dans les fakes sans ouvrir de base de données réelle.
  ///
  /// Les sous-classes (_FakeSnapshotStorage) surchargent [getSnapshots] et
  /// [upsertSnapshot] — le champ [_database] reste null et n'est jamais
  /// accédé.
  @visibleForTesting
  SnapshotStorage.forTesting() : _database = null;

  /// Retourne l'instance [AppDatabase] effective.
  /// En production (aucune injection) : le singleton partagé (R6).
  AppDatabase get _db => _database ?? AppDatabase.shared();

  // --- Lecture ---

  /// Retourne la liste des snapshots du wallet, triés par date croissante.
  Future<List<ValuationSnapshot>> getSnapshots(String walletId) async {
    final db = await _db.database;
    final rows = await db.query(
      'snapshots',
      where: 'wallet_id = ?',
      whereArgs: [walletId],
      orderBy: 'date ASC',
    );
    return rows.map(_rowToSnapshot).toList();
  }

  // --- Écriture ---

  /// Insère ou remplace le snapshot du jour [snapshot.date] pour [walletId].
  ///
  /// La PK composite (wallet_id, date) garantit l'idempotence par jour via
  /// `INSERT OR REPLACE` : la dernière valeur du jour fait foi.
  ///
  /// Après l'insertion, une purge supprime les entrées antérieures au cutoff
  /// calculé comme : date du snapshot − [_retentionDays] jours (comparaison
  /// lexicographique sur 'YYYY-MM-DD', identique à l'ancienne implémentation).
  Future<void> upsertSnapshot(String walletId, ValuationSnapshot snapshot) async {
    final db = await _db.database;

    await db.rawInsert(
      '''
      INSERT OR REPLACE INTO snapshots
        (wallet_id, date, total_value, currency, captured_at,
         account_count, schema_version)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        walletId,
        snapshot.date,
        snapshot.totalValue,
        snapshot.currency,
        snapshot.capturedAt,
        snapshot.accountCount,
        snapshot.schemaVersion,
      ],
    );

    // Purge des entrées trop anciennes (même règle que l'implémentation SP)
    final cutoff = DateTime.parse(snapshot.date).subtract(
      const Duration(days: _retentionDays),
    );
    final cutoffKey = ValuationSnapshot.dateKeyFor(cutoff);

    await db.delete(
      'snapshots',
      where: 'wallet_id = ? AND date < ?',
      whereArgs: [walletId, cutoffKey],
    );
  }

  // --- Suppression ---

  /// Supprime tous les snapshots associés à [walletId].
  Future<void> deleteSnapshotsForWallet(String walletId) async {
    final db = await _db.database;
    await db.delete(
      'snapshots',
      where: 'wallet_id = ?',
      whereArgs: [walletId],
    );
  }

  // --- Helpers ---

  /// Convertit une row SQLite en [ValuationSnapshot].
  static ValuationSnapshot _rowToSnapshot(Map<String, dynamic> row) {
    return ValuationSnapshot(
      date: row['date'] as String,
      totalValue: (row['total_value'] as num).toDouble(),
      currency: row['currency'] as String,
      capturedAt: (row['captured_at'] as num).toInt(),
      accountCount: (row['account_count'] as num?)?.toInt() ?? 0,
      schemaVersion: (row['schema_version'] as num?)?.toInt() ?? 1,
    );
  }
}

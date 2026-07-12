// lib/services/transaction_storage.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/services/app_database.dart';

/// Persistance du journal de transactions par compte via SQLite.
///
/// Table cible : `transactions(id PK, account_id, symbol, kind, quantity,
///   unit_price, amount, currency, date, fee, note, meta_json ;
///   FK account_id→accounts CASCADE)`.
///
/// Les montants (quantity, unit_price, amount, fee) sont en TEXT : décision de
/// précision assumée (cohérence avec positions.quantity — risque R8 du design).
/// Ne PAS convertir en REAL : cela briserait la précision du ledger.
///
/// Ordre d'affichage canonique : `date DESC, id DESC`.
/// — `date` ISO-8601 complet : tri lexicographique = tri chronologique.
/// — `id` (microseconde + suffixe) : départage stable des ex-æquo de date.
class TransactionStorage {
  final AppDatabase? _database;

  /// Constructeur de production : utilise l'instance [AppDatabase] injectée
  /// ou retourne le singleton partagé [AppDatabase.shared()] par défaut.
  TransactionStorage({AppDatabase? database}) : _database = database;

  /// Constructeur réservé aux tests : permet de sous-classer [TransactionStorage]
  /// dans les fakes sans ouvrir de base de données réelle.
  ///
  /// Le champ [_database] reste null et n'est jamais accédé si les méthodes
  /// sont toutes surchargées.
  @visibleForTesting
  TransactionStorage.forTesting() : _database = null;

  /// Retourne l'instance [AppDatabase] effective.
  /// En production (aucune injection) : le singleton partagé (R6).
  AppDatabase get _db => _database ?? AppDatabase.shared();

  // --- Lecture ---

  /// Retourne toutes les transactions du compte [accountId], triées par
  /// date décroissante puis id décroissant (ordre d'affichage canonique).
  ///
  /// [executor] permet de lire DANS une transaction SQL en cours (projecteur
  /// atomique du ledger : reprojection du solde espèces dérivé sur tout le
  /// journal du compte). Par défaut : la connexion partagée (comportement
  /// inchangé pour les appelants existants).
  Future<List<AssetTransaction>> getByAccount(
    String accountId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await _db.database;
    final rows = await db.query(
      'transactions',
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'date DESC, id DESC',
    );
    return rows.map(_rowToTx).toList();
  }

  /// Retourne les transactions du compte [accountId] portant sur [symbol],
  /// triées par date décroissante puis id décroissant.
  ///
  /// Les transactions cash (symbol null) n'apparaissent pas ici.
  ///
  /// [executor] permet de lire DANS une transaction SQL en cours (projecteur
  /// atomique du ledger). Par défaut : la connexion partagée (comportement
  /// inchangé pour les appelants existants).
  Future<List<AssetTransaction>> getBySymbol(
    String accountId,
    String symbol, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await _db.database;
    final rows = await db.query(
      'transactions',
      where: 'account_id = ? AND symbol = ?',
      whereArgs: [accountId, symbol],
      orderBy: 'date DESC, id DESC',
    );
    return rows.map(_rowToTx).toList();
  }

  /// Retourne les transactions du compte [accountId] dont la date est comprise
  /// entre [from] (inclus) et [to] (inclus), triées par date décroissante
  /// puis id décroissant.
  ///
  /// La comparaison est lexicographique sur la représentation ISO-8601 stockée
  /// en base — cohérent avec le stockage `toIso8601String()`.
  Future<List<AssetTransaction>> getByPeriod(
    String accountId,
    DateTime from,
    DateTime to,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'transactions',
      where: 'account_id = ? AND date >= ? AND date <= ?',
      whereArgs: [accountId, from.toIso8601String(), to.toIso8601String()],
      orderBy: 'date DESC, id DESC',
    );
    return rows.map(_rowToTx).toList();
  }

  /// Retourne la transaction d'identifiant [id], ou null si absente.
  ///
  /// [executor] : lecture dans une transaction SQL en cours (projecteur
  /// atomique). Par défaut, la connexion partagée (comportement inchangé).
  Future<AssetTransaction?> getById(String id, {DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    final rows = await db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToTx(rows.first);
  }

  // --- Écriture ---

  /// Insère ou remplace la transaction [tx] (idempotent par id via
  /// `INSERT OR REPLACE`).
  ///
  /// ATTENTION FK : la ligne `accounts(account_id)` DOIT exister
  /// (PRAGMA foreign_keys = ON). Sinon une exception est levée — c'est le
  /// comportement voulu (cohérence du ledger).
  ///
  /// [executor] : écriture dans une transaction SQL en cours (projecteur
  /// atomique mouvement + reprojection). Par défaut, la connexion partagée.
  Future<void> upsert(AssetTransaction tx, {DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    await db.rawInsert(
      '''
      INSERT OR REPLACE INTO transactions
        (id, account_id, symbol, kind, quantity, unit_price, amount,
         currency, date, fee, note, meta_json, settlement_currency)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      _txToRow(tx),
    );
  }

  /// Supprime la transaction d'identifiant [id].
  /// Idempotent : aucune exception si la transaction est absente.
  ///
  /// [executor] : suppression dans une transaction SQL en cours (projecteur
  /// atomique suppression + reprojection). Par défaut, la connexion partagée.
  Future<void> deleteById(String id, {DatabaseExecutor? executor}) async {
    final db = executor ?? await _db.database;
    await db.delete(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Supprime toutes les transactions du compte [accountId].
  /// Idempotent : aucune exception si aucune transaction n'existe.
  ///
  /// Note : la FK `ON DELETE CASCADE` purge automatiquement les transactions
  /// lorsqu'un compte est supprimé VIA SQL. Cette méthode reste utile pour
  /// une purge explicite (ex. contrôleur, avant que la cascade SQLite soit
  /// effective — risque R2 du design).
  Future<void> deleteForAccount(String accountId) async {
    final db = await _db.database;
    await db.delete(
      'transactions',
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }

  // --- Helpers ---

  /// Convertit une row SQLite en [AssetTransaction].
  ///
  /// meta_json : si la valeur stockée est non-null mais corrompue (JSON invalide
  /// ou non-Map), `meta` est mis à null sans lever d'exception (tolérance
  /// ascendante).
  static AssetTransaction _rowToTx(Map<String, dynamic> row) {
    Map<String, dynamic>? meta;
    final metaRaw = row['meta_json'] as String?;
    if (metaRaw != null) {
      try {
        final decoded = jsonDecode(metaRaw);
        if (decoded is Map) {
          meta = Map<String, dynamic>.from(decoded);
        }
        // Si decoded n'est pas un Map (ex. JSON scalaire), meta reste null.
      } catch (_) {
        // JSON invalide : meta reste null (pas de crash).
      }
    }

    return AssetTransaction(
      id: row['id'] as String,
      accountId: row['account_id'] as String,
      symbol: row['symbol'] as String?,
      // Lecture DB TOLÉRANTE : cette ligne a été validée à l'écriture (seuls
      // des wires connus sont insérés). Un wire inconnu ici traduirait une
      // corruption/altération manuelle de la base locale — on tolère (repli
      // `buy`) pour ne pas bloquer l'affichage, plutôt que de lever. La porte
      // STRICTE (rejet) vaut pour les données EXTERNES (import de backup), pas
      // pour nos propres lignes déjà validées. Ne PAS remplacer par `fromWire`
      // (qui lève désormais). Cf. asset_transaction.dart.
      kind: TransactionKind.tryFromWire(row['kind'] as String) ??
          TransactionKind.buy,
      quantity: row['quantity'] as String?,
      unitPrice: row['unit_price'] as String?,
      amount: row['amount'] as String?,
      currency: row['currency'] as String,
      // Devise de règlement (v7) : absente/NULL sur les lignes legacy → null
      // (règlement identique à la cotation). Colonne ajoutée en additif ; une
      // base antérieure à v7 n'a simplement pas la clé (rétro-compat).
      settlementCurrency: row['settlement_currency'] as String?,
      date: DateTime.parse(row['date'] as String),
      fee: row['fee'] as String?,
      note: row['note'] as String?,
      meta: meta,
    );
  }

  /// Convertit un [AssetTransaction] en liste de valeurs pour `INSERT OR REPLACE`.
  ///
  /// L'ordre correspond exactement aux colonnes de la requête `upsert` :
  /// id, account_id, symbol, kind, quantity, unit_price, amount, currency,
  /// date, fee, note, meta_json, settlement_currency.
  static List<Object?> _txToRow(AssetTransaction tx) {
    return [
      tx.id,
      tx.accountId,
      tx.symbol,
      tx.kind.wire,
      tx.quantity,
      tx.unitPrice,
      tx.amount,
      tx.currency,
      tx.date.toIso8601String(),
      tx.fee,
      tx.note,
      tx.meta != null ? jsonEncode(tx.meta) : null,
      // Devise de règlement (v7) : NULL si identique à la cotation (legacy).
      tx.settlementCurrency,
    ];
  }
}

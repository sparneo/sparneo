// lib/services/last_price_storage.dart
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/app_database.dart';

/// Persistance du cache « dernier cours connu » via SQLite (LOT 2).
///
/// Table cible : `last_known_quotes(symbol PK, name, price, change,
///   change_percent, previous_close, currency, exchange, cached_at)`.
///
/// Clé de cache : le `symbol` brut transmis au [MarketDataProvider] (le
/// `quoteSymbol` de l'actif, ex. `GC=F` pour un métal). Montants stockés en
/// TEXT (round-trip exact, cf. app_database.dart). `INSERT OR REPLACE` :
/// la dernière cotation réussie écrase toujours la précédente (pas de TTL,
/// pas d'éviction — cf. design LOT 2).
class LastPriceStorage {
  final AppDatabase? _database;

  /// Constructeur de production : utilise l'instance [AppDatabase] injectée
  /// ou crée un [AppDatabase()] par défaut (singleton runtime effectif).
  LastPriceStorage({AppDatabase? database}) : _database = database;

  /// Constructeur réservé aux tests : permet de sous-classer
  /// [LastPriceStorage] dans les fakes sans ouvrir de base de données réelle.
  @visibleForTesting
  LastPriceStorage.forTesting() : _database = null;

  /// Retourne l'instance [AppDatabase] effective.
  /// En production (aucune injection) : le singleton partagé (R6).
  AppDatabase get _db => _database ?? AppDatabase.shared();

  /// Insère ou remplace le dernier cours connu de [symbol] à partir de la
  /// quote [q] (devise native, non convertie). [at] devient `cached_at`.
  Future<void> upsertQuote(String symbol, AssetQuoteData q, {required DateTime at}) async {
    final db = await _db.database;
    await db.rawInsert(
      '''
      INSERT OR REPLACE INTO last_known_quotes
        (symbol, name, price, change, change_percent, previous_close,
         currency, exchange, cached_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        symbol,
        q.name,
        q.price?.toString(),
        q.change?.toString(),
        q.changePercent?.toString(),
        q.previousClose?.toString(),
        q.currency,
        q.exchange,
        at.millisecondsSinceEpoch,
      ],
    );
  }

  /// Retourne le dernier cours connu de [symbol], ou `null` si absent.
  /// L'[AssetQuoteData] reconstruit porte `asOf` = l'horodatage `cached_at`
  /// (signale que la donnée est servie depuis le cache, pas en live).
  Future<AssetQuoteData?> getQuote(String symbol) async {
    final db = await _db.database;
    final rows = await db.query(
      'last_known_quotes',
      where: 'symbol = ?',
      whereArgs: [symbol],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    return AssetQuoteData(
      symbol: symbol,
      name: row['name'] as String?,
      price: num.tryParse(row['price'] as String? ?? ''),
      change: num.tryParse(row['change'] as String? ?? ''),
      changePercent: num.tryParse(row['change_percent'] as String? ?? ''),
      previousClose: num.tryParse(row['previous_close'] as String? ?? ''),
      currency: row['currency'] as String?,
      exchange: row['exchange'] as String?,
      asOf: DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int),
    );
  }
}

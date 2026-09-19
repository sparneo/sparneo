// lib/services/caching_market_data_provider.dart
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';
import 'package:portfolio_tracker/services/last_price_storage.dart';
import 'package:portfolio_tracker/services/market_data_provider.dart';

/// Décorateur de [MarketDataProvider] : sert le « dernier cours connu »
/// (persisté via [LastPriceStorage]) quand le délégué (ex. Yahoo Finance)
/// échoue, au lieu de propager `null` (LOT 2 — dégradation douce).
///
/// [getHistoricalData] porte EN PLUS un cache MÉMOIRE (pas de persistance,
/// vidé au redémarrage de l'app) des séries historiques, keyé par
/// `(symbol, days)` — voir le champ [_historyCache]. Objectif : qu'un
/// aller-retour entre périodes de graphique (même fenêtre déjà demandée) ne
/// redéclenche pas toute la rafale réseau vers Yahoo. Cache DISTINCT de celui
/// de [getQuoteWithMetadata] (LastPriceStorage, persisté, sert de repli en
/// cas de panne) : celui-ci ne sert jamais de repli sur erreur, il sert
/// uniquement à éviter un aller-retour réseau redondant sur une donnée
/// récente.
///
/// NB limite assumée sur la cotation instantanée : le délégué aplatit toute
/// erreur en `null` (404 symbole invalide inclus). Le cache LastPriceStorage
/// est donc aussi servi sur 404 — on peut resservir le dernier cours d'un
/// symbole devenu invalide. Acceptable pour une dégradation douce (mieux que
/// zéro) ; `asOf` signale l'ancienneté de la donnée resservie. Pas de
/// sur-ingénierie de cette distinction pour ce lot.
class CachingMarketDataProvider implements MarketDataProvider {
  final MarketDataProvider _delegate;
  final LastPriceStorage _cache;
  final DateTime Function() _now;
  final Duration _historyTtl;

  /// Cache mémoire des séries historiques, clé `"symbol|days"` → entrée
  /// horodatée. Ne mémorise QUE les réponses non-null (une réponse null =
  /// échec/introuvable : la mémoriser figerait un symbole en panne
  /// temporaire comme durablement introuvable pendant tout le TTL, alors
  /// qu'un simple prochain essai suffirait). TTL COURT ([_historyTtl],
  /// 15 min par défaut) : voir [invalidateHistory] pour le traitement du cas
  /// « rafraîchissement manuel », qui ne peut pas se contenter d'attendre le
  /// TTL.
  final Map<String, _HistoryCacheEntry> _historyCache = {};

  /// [clock] et [historyTtl] sont des points d'injection réservés aux tests
  /// (horloge déterministe / TTL raccourci) — en usage normal, l'horloge
  /// système et le TTL par défaut s'appliquent.
  CachingMarketDataProvider(
    this._delegate,
    this._cache, {
    DateTime Function()? clock,
    Duration? historyTtl,
  })  : _now = clock ?? DateTime.now,
        _historyTtl = historyTtl ?? const Duration(minutes: 15);

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async {
    final q = await _delegate.getQuoteWithMetadata(symbol);
    if (q != null && q.price != null) {
      // Succès : on rafraîchit le cache pour la prochaine panne éventuelle,
      // et on retourne la donnée live telle quelle (asOf == null).
      await _cache.upsertQuote(symbol, q, at: DateTime.now());
      return q;
    }

    // Échec (délégué en panne ou quote sans prix) : on sert le dernier cours
    // connu s'il existe (asOf posé par le storage), sinon null (comportement
    // inchangé d'avant LOT 2).
    return _cache.getQuote(symbol);
  }

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30}) async {
    final key = _historyCacheKey(symbol, days);
    final cached = _historyCache[key];
    if (cached != null && _now().isBefore(cached.fetchedAt.add(_historyTtl))) {
      return cached.data;
    }

    final data = await _delegate.getHistoricalData(symbol, days: days);
    if (data != null) {
      _historyCache[key] = _HistoryCacheEntry(data, _now());
    }
    return data;
  }

  String _historyCacheKey(String symbol, int days) => '$symbol|$days';

  /// Vide le cache mémoire des séries historiques — à appeler explicitement
  /// sur les chemins de RAFRAÎCHISSEMENT MANUEL (pull-to-refresh), qui ne
  /// peuvent pas se contenter d'attendre l'expiration du TTL : l'utilisateur
  /// qui déclenche explicitement un refresh attend une vraie ronde réseau,
  /// pas une réponse resservie.
  ///
  /// Les reloads « structurels » (post-import, CRUD compte/position) ne
  /// l'appellent volontairement PAS : la série de prix d'un symbole
  /// ([symbol], [days]) est une donnée de MARCHÉ indépendante du journal
  /// local de l'utilisateur — l'ajout/la modification de transactions ne la
  /// rend jamais périmée. Voir [MarketDataService.invalidateHistoryCache]
  /// pour le point d'entrée exposé aux contrôleurs (qui ne connaissent que
  /// [MarketDataProvider]/[MarketDataService], pas ce décorateur concret).
  void invalidateHistory() {
    _historyCache.clear();
  }

  // Recherche par ISIN : pure délégation, sans cache. La recherche n'est
  // exercée qu'à l'import (rare, à la demande) et resservir un vieux résultat
  // n'apporterait rien de plus qu'une passe réseau ponctuelle — on évite donc
  // une couche de péremption superflue (contrairement à getHistoricalData,
  // rejoué en rafale à chaque switch de période).
  @override
  Future<List<IsinSearchHit>> searchByIsin(String isin, {int quotesCount = 8}) =>
      _delegate.searchByIsin(isin, quotesCount: quotesCount);

  // Vérification d'existence de symbole (import crypto B16, conception
  // interne) : pure délégation, PAS de cache au lot 0 (passthrough — la
  // volumétrie d'un assistant d'import reste faible, contrairement aux séries
  // historiques rejouées à chaque switch de période).
  @override
  Future<bool?> symbolExists(String symbol) => _delegate.symbolExists(symbol);

  /// Cache mémoire des plages historiques ([getHistoricalRange]), clé
  /// `"symbol|joursFrom|joursTo"` — DISTINCT de [_historyCache]
  /// ([getHistoricalData]) : bornes explicites plutôt qu'un nombre de jours
  /// glissant. Import crypto B16 lot 4 (conception interne) : l'étage 2 de la
  /// cascade de valorisation appelle cette méthode UNE FOIS PAR ACTIF résolu
  /// (fenêtre englobant TOUTES ses opérations non valorisées, même esprit que la
  /// fenêtre FX unique de l'étage 1) — ce cache protège seulement contre un RAPPEL
  /// de la même fenêtre pour le même symbole (ex. un second aperçu après
  /// correction manuelle d'AUTRES lignes), pas contre un appel par opération (déjà
  /// évité en amont par le groupage par symbole côté appelant).
  ///
  /// SANS TTL, contrairement à [_historyCache] : une barre JOURNALIÈRE passée ne
  /// change jamais rétroactivement (même doctrine que le cache FX journalier de
  /// `ExchangeRateService.getDailyRatesToEur`, conception interne) — portée = la
  /// durée de vie de CETTE instance, jamais de persistance disque. Ne mémorise
  /// QUE les réponses non-null, même raisonnement que [_historyCache] (un
  /// échec/panne ne doit jamais rester figé « introuvable » pour tout le reste de
  /// la session).
  final Map<String, AssetHistoricalData> _rangeCache = {};

  @override
  Future<AssetHistoricalData?> getHistoricalRange(
    String symbol,
    DateTime from,
    DateTime to, {
    int maxAttempts = 3,
  }) async {
    final key = _rangeCacheKey(symbol, from, to);
    final cached = _rangeCache[key];
    if (cached != null) return cached;

    final data = await _delegate.getHistoricalRange(
      symbol,
      from,
      to,
      maxAttempts: maxAttempts,
    );
    if (data != null) {
      _rangeCache[key] = data;
    }
    return data;
  }

  String _rangeCacheKey(String symbol, DateTime from, DateTime to) =>
      '$symbol|${_dayKey(from)}|${_dayKey(to)}';

  String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Entrée du cache mémoire des séries historiques ([CachingMarketDataProvider._historyCache]).
class _HistoryCacheEntry {
  final AssetHistoricalData data;
  final DateTime fetchedAt;

  _HistoryCacheEntry(this.data, this.fetchedAt);
}

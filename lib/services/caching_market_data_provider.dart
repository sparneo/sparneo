// lib/services/caching_market_data_provider.dart
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/last_price_storage.dart';
import 'package:portfolio_tracker/services/market_data_provider.dart';

/// Décorateur de [MarketDataProvider] : sert le « dernier cours connu »
/// (persisté via [LastPriceStorage]) quand le délégué (ex. Yahoo Finance)
/// échoue, au lieu de propager `null` (LOT 2 — dégradation douce).
///
/// Périmètre volontairement limité à la cotation instantanée :
/// [getHistoricalData] est une pure délégation, sans cache (cf. design).
///
/// NB limite assumée : le délégué aplatit toute erreur en `null` (404 symbole
/// invalide inclus). Le cache est donc aussi servi sur 404 — on peut resservir
/// le dernier cours d'un symbole devenu invalide. Acceptable pour une
/// dégradation douce (mieux que zéro) ; `asOf` signale l'ancienneté de la
/// donnée resservie. Pas de sur-ingénierie de cette distinction pour ce lot.
class CachingMarketDataProvider implements MarketDataProvider {
  final MarketDataProvider _delegate;
  final LastPriceStorage _cache;

  CachingMarketDataProvider(this._delegate, this._cache);

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
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30}) =>
      _delegate.getHistoricalData(symbol, days: days);
}

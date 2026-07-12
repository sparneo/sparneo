// services/market_data_service.dart
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/caching_market_data_provider.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/last_price_storage.dart';
import 'package:portfolio_tracker/services/market_data_provider.dart';
import 'package:portfolio_tracker/services/yahoo_finance_provider.dart';

/// Orchestrateur des cotations de marché.
///
/// Cette classe ne connaît plus les détails d'une source de cotation
/// particulière : elle délègue la récupération brute (cotation/historique
/// par symbole) à un [MarketDataProvider] injecté (Yahoo Finance par
/// défaut, via [YahooFinanceProvider]), et se concentre sur la logique
/// métier indépendante du fournisseur : normalisation des métaux précieux
/// (poids fin + prime) et conversion en EUR via [ExchangeRateService].
class MarketDataService {
  final ExchangeRateService _exchangeService;
  final MarketDataProvider _provider;

  MarketDataService({MarketDataProvider? provider})
      : _exchangeService = ExchangeRateService(),
        _provider = provider ??
            CachingMarketDataProvider(YahooFinanceProvider(), LastPriceStorage());

  /// Constructeur réservé aux tests : crée une instance sous-classable sans
  /// déclencher d'appels réseau. L'appelant fournit un [ExchangeRateService]
  /// (typiquement un fake construit via [ExchangeRateService.forTesting]) et,
  /// optionnellement, un [MarketDataProvider] de test.
  @visibleForTesting
  MarketDataService.forTesting(
    ExchangeRateService exchangeService, {
    MarketDataProvider? provider,
  })  : _exchangeService = exchangeService,
        _provider = provider ?? YahooFinanceProvider();

  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) =>
      _provider.getQuoteWithMetadata(symbol);

  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30}) =>
      _provider.getHistoricalData(symbol, days: days);

  // ==================== COTATIONS ORIENTÉES ACTIF ====================
  // Ces variantes prennent un [Asset] plutôt qu'un symbole brut. Pour un actif
  // classique elles délèguent simplement aux méthodes par symbole. Pour un
  // métal précieux, elles interrogent le cours de référence (ex. `GC=F`), le
  // transforment en prix d'UNE pièce (poids fin + prime) et le NORMALISENT EN
  // EUR. Le reste de l'app peut alors traiter la position comme une position
  // EUR ordinaire (la devise stockée de ces actifs est « EUR »).

  /// Cotation prête à l'emploi pour [asset].
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async {
    final quote = await getQuoteWithMetadata(asset.quoteSymbol);
    // Gate sur hasMetalPricing (présence d'un cours de référence), PAS sur le
    // seul type : un actif classé « métal » à la main mais sans refSymbol/poids
    // (ex. ETC or coté en direct, override de bucket) doit garder le pricing
    // d'un actif ordinaire — sinon double conversion USD→EUR en aval.
    if (quote == null || !asset.hasMetalPricing) return quote;

    // Taux du cours de référence (USD pour `GC=F`, EUR pour un ETC euro) -> EUR.
    final rate = await _exchangeService.getRateToEur(quote.currency ?? 'USD');
    double? toEur(num? spot) =>
        spot == null ? null : asset.unitPriceFromSpot(spot) * rate;

    final price = toEur(quote.price);
    final previousClose = toEur(quote.previousClose);
    num? change;
    if (price != null && previousClose != null) {
      change = price - previousClose;
    }

    return AssetQuoteData(
      symbol: asset.symbol,
      name: asset.name ?? quote.name,
      price: price,
      // Le pourcentage est inchangé (prime et poids sont des facteurs constants).
      change: change,
      changePercent: quote.changePercent,
      previousClose: previousClose,
      currency: 'EUR',
      exchange: quote.exchange,
      marketState: quote.marketState,
      // Propage l'ancienneté de la quote brute (cf. LOT 2) : sans cela,
      // reconstruire un nouvel AssetQuoteData perdrait l'information de
      // fraîcheur pour les métaux précieux.
      asOf: quote.asOf,
    );
  }

  /// Historique prêt à l'emploi pour [asset] (mêmes règles que [getQuoteForAsset]).
  Future<AssetHistoricalData?> getHistoricalDataForAsset(Asset asset, {int days = 30}) async {
    final data = await getHistoricalData(asset.quoteSymbol, days: days);
    // Même garde que getQuoteForAsset : seul un actif porteur d'un cours de
    // référence subit la transformation métal (cf. [Asset.hasMetalPricing]).
    if (data == null || !asset.hasMetalPricing) return data;

    final rate = await _exchangeService.getRateToEur('USD');
    // NB : on ne connaît pas la devise de l'historique (l'API ne la renvoie pas
    // ici) ; on s'aligne sur la devise probable du cours de référence. Pour un
    // ETC euro (unité gramme) le taux est neutralisé en passant par EUR.
    final effectiveRate = asset.refQuoteUnit == MetalQuoteUnit.gram ? 1.0 : rate;

    return AssetHistoricalData(
      symbol: asset.symbol,
      dates: data.dates,
      prices: data.prices.map((p) => asset.unitPriceFromSpot(p) * effectiveRate).toList(),
      errorMessage: data.errorMessage,
    );
  }
}
// services/market_data_service.dart
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';
import 'package:portfolio_tracker/services/caching_market_data_provider.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/last_price_storage.dart';
import 'package:portfolio_tracker/services/market_data_provider.dart';
import 'package:portfolio_tracker/services/yahoo_finance_provider.dart';

/// Exception levée par [MarketDataService.searchByIsin] (et son
/// [MarketDataProvider] sous-jacent, ex. [YahooFinanceProvider]) en cas
/// d'échec de TRANSPORT/RÉSEAU (timeout, statut HTTP non-200 après retries,
/// erreur socket...).
///
/// À distinguer SOIGNEUSEMENT d'une recherche ABOUTIE (HTTP 200) sans
/// correspondance exploitable : dans ce second cas, [MarketDataService.
/// searchByIsin] retourne toujours une liste vide, JAMAIS cette exception.
/// L'assistant d'import doit réserver son repli « actif non coté » à ce
/// second cas — sur cette exception, il n'y a aucune information sur
/// l'existence du titre : l'UI doit le signaler comme une panne
/// (bandeau + bouton « Réessayer »), pas conclure à tort à un titre non coté.
class IsinSearchException implements Exception {
  /// Message d'erreur, prêt à journaliser (l'UI reste libre de son propre
  /// libellé utilisateur : ce message n'est pas forcément traduit/affichable).
  final String message;

  /// Cause d'origine (typiquement une `ApiError`), pour diagnostic.
  final Object? cause;

  IsinSearchException(this.message, {this.cause});

  @override
  String toString() =>
      'IsinSearchException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

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

  /// Recherche les places candidates pour un [isin] (voir
  /// [MarketDataProvider.searchByIsin]). Utilisée par l'assistant d'import
  /// pour la résolution ISIN → symbole ; jamais appelée par le rafraîchissement.
  ///
  /// Pure délégation : peut lever [IsinSearchException] en cas d'échec de
  /// transport/réseau (voir sa doc). Ne retourne `[]` que pour une recherche
  /// aboutie sans correspondance.
  Future<List<IsinSearchHit>> searchByIsin(String isin, {int quotesCount = 8}) =>
      _provider.searchByIsin(isin, quotesCount: quotesCount);

  // ==================== COTATIONS ORIENTÉES ACTIF ====================
  // Ces variantes prennent un [Asset] plutôt qu'un symbole brut. Pour un actif
  // classique elles délèguent simplement aux méthodes par symbole. Pour un
  // métal précieux, elles interrogent le cours de référence (ex. `GC=F`), le
  // transforment en prix d'UNE pièce (poids fin + prime) et le NORMALISENT EN
  // EUR. Le reste de l'app peut alors traiter la position comme une position
  // EUR ordinaire (la devise stockée de ces actifs est « EUR »).

  /// Cotation prête à l'emploi pour [asset].
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async {
    // Actif NON COTÉ (repli ISIN, titre délisté) : JAMAIS interrogé sur la
    // source de marché — aucun appel réseau, aucune erreur récurrente. Traité
    // comme « sans cotation » (retour null → prix null → 0 en aval). Garde
    // défensive : les boucles de rafraîchissement sautent déjà ces actifs en
    // amont, ce filet garantit l'invariant même si un appelant l'oublie.
    if (!asset.quotable) return null;
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
    // Même garde que getQuoteForAsset : un actif non coté n'a pas d'historique
    // interrogeable (jamais d'appel réseau).
    if (!asset.quotable) return null;
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
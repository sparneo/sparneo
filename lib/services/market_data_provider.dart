// services/market_data_provider.dart
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';

/// Point d'extension pour la source de cotation brute (par symbole).
///
/// Ce contrat couvre UNIQUEMENT la récupération de données brutes auprès
/// d'un fournisseur externe (cotation instantanée + historique d'un
/// symbole). Il ne connaît rien de la logique métier de l'app (métaux
/// précieux, conversion EUR, etc.) : cette logique reste dans
/// [MarketDataService], qui orchestre un [MarketDataProvider].
///
/// Objectif : permettre de remplacer la source de cotation (ex. Yahoo
/// Finance) par une autre implémentation sans toucher au reste de l'app.
abstract class MarketDataProvider {
  /// Cotation instantanée d'un [symbol] (devise d'origine, non convertie).
  /// Retourne `null` en cas d'échec définitif (après retries éventuels).
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol);

  /// Historique des prix d'un [symbol] sur une fenêtre d'environ [days]
  /// jours (l'implémentation choisit la granularité réelle). Retourne
  /// `null` en cas d'échec définitif.
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30});

  /// Recherche les places de cotation candidates pour un [isin] auprès de la
  /// source de marché (endpoint `search`). Retourne la liste des hits (au plus
  /// [quotesCount]), VIDE UNIQUEMENT pour une recherche ABOUTIE sans hit
  /// exploitable (ISIN introuvable, titre délisté / purgé) — une liste vide
  /// déclenche alors en aval le repli « actif non coté » (symbole = ISIN). Un
  /// échec RÉSEAU / transport (timeout, statut != 200 après retries) lève au
  /// contraire une `IsinSearchException` (cf. market_data_service.dart), pour
  /// que l'UI distingue « introuvable » d'une panne. La désambiguïsation (choix
  /// du symbole retenu parmi les hits) n'appartient PAS à cette couche.
  Future<List<IsinSearchHit>> searchByIsin(String isin, {int quotesCount = 8});
}

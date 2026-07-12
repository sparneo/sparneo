// services/market_data_provider.dart
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';

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
}

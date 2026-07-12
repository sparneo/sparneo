// services/yahoo_finance_provider.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/api_error.dart';
import 'package:portfolio_tracker/services/market_data_provider.dart';
import 'package:portfolio_tracker/utils/logger.dart';

/// Implémentation de [MarketDataProvider] adossée à l'endpoint public non
/// officiel `v8/finance/chart` de Yahoo Finance.
///
/// C'est la seule classe qui connaît les URLs, les en-têtes HTTP et le
/// format de réponse propres à Yahoo. Pour brancher une autre source de
/// cotation, il suffit d'écrire une autre implémentation de
/// [MarketDataProvider] et de l'injecter dans [MarketDataService].
class YahooFinanceProvider implements MarketDataProvider {
  // En-têtes communs envoyés à l'API Yahoo Finance.
  //
  // Pourquoi un User-Agent de navigateur : l'endpoint `v8/finance/chart` est
  // un endpoint public NON OFFICIEL de Yahoo (aucune clé, aucun contrat
  // d'API). Il rejette (403/429) les clients qui s'identifient comme des
  // scripts (User-Agent par défaut de `http`, absence de User-Agent, etc.).
  // Envoyer un User-Agent de navigateur courant est la pratique standard de
  // tous les clients open source de cet endpoint (yfinance, yahoo-finance2 /
  // Ghostfolio, Portfolio Performance...) : ce n'est pas un contournement
  // agressif, mais la condition d'accès de fait à une API publique et
  // gratuite. Notre usage reste sobre : requêtes à la demande uniquement
  // (aucun polling en tâche de fond) et backoff exponentiel en cas de 429
  // (voir [retryWithBackoff]).
  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'application/json',
  };

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async {
    final url = Uri.parse(
      'https://query1.finance.yahoo.com/v8/finance/chart/$symbol',
    );

    try {
      // Tentatives avec backoff ; lève une ApiError en cas de statut non-200.
      return await retryWithBackoff<AssetQuoteData?>(
        context: 'getQuoteWithMetadata($symbol)',
        () async {
          final response = await http
              .get(url, headers: _headers)
              .timeout(const Duration(seconds: 10));

          if (response.statusCode != 200) {
            throw ApiError.fromStatusCode(response.statusCode);
          }

          final data = jsonDecode(response.body);

          if (data['chart']['result'] == null ||
              data['chart']['result'].isEmpty) {
            return null;
          }

          final result = data['chart']['result'][0];
          final meta = result['meta'];

          final price = meta['regularMarketPrice'];
          final previousClose = meta['previousClose'];

          num? change;
          num? changePercent;

          if (price != null && previousClose != null) {
            change = price - previousClose;
            changePercent =
                previousClose != 0 ? ((change! / previousClose) * 100) : 0;
          }

          return AssetQuoteData(
            symbol: symbol,
            name: meta['shortName']?.toString() ?? meta['longName']?.toString(),
            price: price,
            change: change,
            changePercent: changePercent,
            volume: result['indicators']['quote'][0]['volume']?.first,
            open: meta['regularMarketOpen'],
            dayHigh: meta['regularMarketDayHigh'],
            dayLow: meta['regularMarketDayLow'],
            previousClose: previousClose,
            currency: meta['currency']?.toString(),
            exchange: meta['exchangeName']?.toString(),
            marketState: meta['marketState']?.toString(),
            fiftyTwoWeekHigh: meta['fiftyTwoWeekHigh'],
            fiftyTwoWeekLow: meta['fiftyTwoWeekLow'],
            instrumentType: meta['instrumentType']?.toString(),
          );
        },
      );
    } catch (e) {
      // Échec final (après retries ou erreur non réessayable) : on conserve
      // le comportement historique en retournant null.
      final apiError = ApiError.fromException(e);
      AppLogger.error('Erreur marché pour $symbol: $apiError');
      return null;
    }
  }

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30}) async {
    String interval = '1d';
    String range;

    if (days == -1) {
        range = 'max';
        interval = '1mo';
      } else if (days == 0) {
        range = 'ytd';
        interval = '1d';
      } else if (days <= 1) {
        range = '1d';
        interval = '5m';
      } else if (days <= 7) {
        range = '5d';
        interval = '15m';
      } else if (days <= 30) {
        range = '1mo';
        interval = '1d';
      } else if (days <= 90) {
        range = '3mo';
        interval = '1d';
      } else if (days <= 180) {
        range = '6mo';
        interval = '1d';
      } else if (days <= 365) {
        range = '1y';
        interval = '1d';
      } else if (days <= 730) {
        range = '2y';
        interval = '1wk';
      } else if (days <= 1825) {
        range = '5y';
        interval = '1wk';
      } else {
        range = '10y';
        interval = '1mo';
      }

    final url = Uri.https(
      'query1.finance.yahoo.com',
      '/v8/finance/chart/$symbol',
      {'range': range, 'interval': interval},
    );

    try {
      // Tentatives avec backoff ; lève une ApiError en cas de statut non-200.
      return await retryWithBackoff<AssetHistoricalData?>(
        context: 'getHistoricalData($symbol)',
        () async {
          final response = await http
              .get(url, headers: _headers)
              .timeout(const Duration(seconds: 10));

          if (response.statusCode != 200) {
            throw ApiError.fromStatusCode(response.statusCode);
          }

          final data = jsonDecode(response.body);

          if (data['chart']['result'] == null ||
              data['chart']['result'].isEmpty) {
            return null;
          }

          final result = data['chart']['result'][0];
          final timestamps = result['timestamp'] as List<dynamic>?;
          final quotes =
              result['indicators']['quote'][0]['close'] as List<dynamic>?;

          if (timestamps == null ||
              quotes == null ||
              timestamps.isEmpty ||
              quotes.isEmpty) {
            return null;
          }

          final dates = <DateTime>[];
          final prices = <num>[];

          for (int i = 0; i < timestamps.length; i++) {
            final timestamp = timestamps[i];
            final price = quotes[i];

            if (timestamp != null && price != null) {
              dates.add(DateTime.fromMillisecondsSinceEpoch(timestamp * 1000));
              prices.add(price);
            }
          }

          return AssetHistoricalData(
            symbol: symbol,
            dates: dates,
            prices: prices,
          );
        },
      );
    } catch (e) {
      // Échec final : on conserve le comportement historique en retournant null.
      final apiError = ApiError.fromException(e);
      AppLogger.error('Erreur historique pour $symbol: $apiError');
      return null;
    }
  }
}

// test/services/caching_market_data_provider_test.dart
//
// Test du décorateur CachingMarketDataProvider (LOT 2 — cache « dernier cours
// connu »). Utilise un faux MarketDataProvider (même style que _FakeProvider
// de market_data_service_test.dart) piloté par le test, adossé à une vraie
// LastPriceStorage sur AppDatabase in-memory (pas de fake de storage : on
// veut prouver le round-trip réel upsert → lecture via le décorateur).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/caching_market_data_provider.dart';
import 'package:portfolio_tracker/services/last_price_storage.dart';
import 'package:portfolio_tracker/services/market_data_provider.dart';

/// Fake du point d'extension [MarketDataProvider] : renvoie ce que le test lui
/// configure (aucun appel réseau). Reprend le style `_FakeProvider` de
/// market_data_service_test.dart.
class _FakeProvider implements MarketDataProvider {
  AssetQuoteData? quoteToReturn;
  AssetHistoricalData? historicalToReturn;

  String? lastQuoteSymbol;
  String? lastHistoricalSymbol;
  int? lastHistoricalDays;

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async {
    lastQuoteSymbol = symbol;
    return quoteToReturn;
  }

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30}) async {
    lastHistoricalSymbol = symbol;
    lastHistoricalDays = days;
    return historicalToReturn;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late AppDatabase appDb;
  late LastPriceStorage cache;
  late _FakeProvider delegate;
  late CachingMarketDataProvider provider;

  setUp(() async {
    appDb = AppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    cache = LastPriceStorage(database: appDb);
    delegate = _FakeProvider();
    provider = CachingMarketDataProvider(delegate, cache);
  });

  tearDown(() async {
    await appDb.close();
  });

  group('CachingMarketDataProvider', () {
    test('succès du délégué : peuple le cache et renvoie la quote live (asOf null)', () async {
      final liveQuote = AssetQuoteData(symbol: 'AAPL', price: 150.0, currency: 'USD');
      delegate.quoteToReturn = liveQuote;

      final result = await provider.getQuoteWithMetadata('AAPL');

      expect(result, same(liveQuote));
      expect(result!.asOf, isNull);

      // Le cache a bien été peuplé en coulisses (vérifié via une nouvelle
      // panne du délégué qui doit resservir cette valeur).
      delegate.quoteToReturn = null;
      final served = await provider.getQuoteWithMetadata('AAPL');
      expect(served, isNotNull);
      expect(served!.price, 150.0);
      expect(served.asOf, isNotNull);
    });

    test('panne du délégué après un succès préalable : sert le cache avec asOf non-null', () async {
      final liveQuote = AssetQuoteData(symbol: 'GC=F', price: 2000.0, currency: 'USD');
      delegate.quoteToReturn = liveQuote;
      await provider.getQuoteWithMetadata('GC=F');

      // Panne : le délégué renvoie null.
      delegate.quoteToReturn = null;
      final result = await provider.getQuoteWithMetadata('GC=F');

      expect(result, isNotNull);
      expect(result!.price, 2000.0);
      expect(result.currency, 'USD');
      expect(result.asOf, isNotNull);
    });

    test('panne du délégué avec quote sans prix : sert aussi le cache', () async {
      final liveQuote = AssetQuoteData(symbol: 'MSFT', price: 300.0, currency: 'USD');
      delegate.quoteToReturn = liveQuote;
      await provider.getQuoteWithMetadata('MSFT');

      // "Échec" au sens du décorateur : quote non-null mais price null.
      delegate.quoteToReturn = AssetQuoteData(symbol: 'MSFT', price: null);
      final result = await provider.getQuoteWithMetadata('MSFT');

      expect(result, isNotNull);
      expect(result!.price, 300.0);
      expect(result.asOf, isNotNull);
    });

    test('cache vide + panne du délégué : renvoie null (comportement inchangé)', () async {
      delegate.quoteToReturn = null;

      final result = await provider.getQuoteWithMetadata('UNKNOWN');

      expect(result, isNull);
    });

    test('getHistoricalData est une pure délégation, sans cache', () async {
      final historical = AssetHistoricalData(
        symbol: 'AAPL',
        dates: [DateTime(2026, 1, 1)],
        prices: [150.0],
      );
      delegate.historicalToReturn = historical;

      final result = await provider.getHistoricalData('AAPL', days: 90);

      expect(result, same(historical));
      expect(delegate.lastHistoricalSymbol, 'AAPL');
      expect(delegate.lastHistoricalDays, 90);
    });
  });
}

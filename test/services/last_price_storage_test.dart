// test/services/last_price_storage_test.dart
//
// Round-trip upsert/get de LastPriceStorage (cache « dernier cours connu »,
// LOT 2) sur une AppDatabase in-memory. Vérifie que les montants TEXT sont
// préservés exactement et que `asOf` est bien posé à la lecture (jamais à
// l'écriture — un AssetQuoteData live n'a pas d'asOf).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/last_price_storage.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late AppDatabase appDb;
  late LastPriceStorage storage;

  setUp(() async {
    appDb = AppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    storage = LastPriceStorage(database: appDb);
  });

  tearDown(() async {
    await appDb.close();
  });

  group('LastPriceStorage', () {
    test('getQuote sur un symbole absent retourne null', () async {
      final result = await storage.getQuote('AAPL');
      expect(result, isNull);
    });

    test('upsertQuote puis getQuote : round-trip fidèle + asOf posé', () async {
      final quote = AssetQuoteData(
        symbol: 'GC=F',
        name: 'Gold Futures',
        price: 2000.5,
        change: -3.25,
        changePercent: -0.16,
        previousClose: 2003.75,
        currency: 'USD',
        exchange: 'CMX',
      );
      final at = DateTime(2026, 7, 1, 12, 30);

      await storage.upsertQuote('GC=F', quote, at: at);
      final cached = await storage.getQuote('GC=F');

      expect(cached, isNotNull);
      expect(cached!.symbol, 'GC=F');
      expect(cached.name, 'Gold Futures');
      // Montants TEXT re-parsés en num : valeur exacte préservée.
      expect(cached.price, 2000.5);
      expect(cached.change, -3.25);
      expect(cached.changePercent, -0.16);
      expect(cached.previousClose, 2003.75);
      expect(cached.currency, 'USD');
      expect(cached.exchange, 'CMX');
      // asOf est posé à la lecture (donnée servie depuis le cache).
      expect(cached.asOf, at);
    });

    test('upsertQuote est un upsert (INSERT OR REPLACE) : le dernier appel fait foi', () async {
      final at1 = DateTime(2026, 7, 1);
      final at2 = DateTime(2026, 7, 2);

      await storage.upsertQuote(
        'AAPL',
        AssetQuoteData(symbol: 'AAPL', price: 150.0, currency: 'USD'),
        at: at1,
      );
      await storage.upsertQuote(
        'AAPL',
        AssetQuoteData(symbol: 'AAPL', price: 155.0, currency: 'USD'),
        at: at2,
      );

      final cached = await storage.getQuote('AAPL');
      expect(cached!.price, 155.0);
      expect(cached.asOf, at2);
    });

    test('un AssetQuoteData sans certains champs (null) survit au round-trip', () async {
      final quote = AssetQuoteData(symbol: 'MSFT', price: 300.0);
      final at = DateTime(2026, 7, 3);

      await storage.upsertQuote('MSFT', quote, at: at);
      final cached = await storage.getQuote('MSFT');

      expect(cached!.price, 300.0);
      expect(cached.change, isNull);
      expect(cached.changePercent, isNull);
      expect(cached.previousClose, isNull);
      expect(cached.currency, isNull);
      expect(cached.exchange, isNull);
      expect(cached.name, isNull);
      expect(cached.asOf, at);
    });
  });
}

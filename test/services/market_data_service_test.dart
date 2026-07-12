// test/services/market_data_service_test.dart
//
// Test de la couture MarketDataService <-> MarketDataProvider PAR COMPOSITION :
// contrairement aux fakes existants (qui sous-classent MarketDataService et
// écrasent ses méthodes publiques), on injecte ici un faux [MarketDataProvider]
// et on vérifie que MarketDataService délègue correctement (symbole, days) et
// applique sa propre logique métier (normalisation métaux précieux + EUR)
// SANS jamais toucher au réseau.

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/market_data_provider.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';

/// Fake du service de taux de change : 0.90 pour USD, identité pour EUR.
/// Même construction que `test/controllers/wallet_controller_test.dart`.
class _FakeExchangeRateService extends ExchangeRateService {
  _FakeExchangeRateService() : super.forTesting();

  @override
  Future<double> getUsdToEurRate() async => 0.90;

  @override
  Future<double> getRateToEur(String currency) async {
    if (currency.toUpperCase() == 'EUR') return 1.0;
    return 0.90;
  }
}

/// Fake du point d'extension [MarketDataProvider] : implémente le contrat par
/// COMPOSITION (pas de sous-classage de MarketDataService). Enregistre les
/// paramètres reçus pour vérifier la délégation, et rend des données fixes
/// configurées par le test (aucun appel réseau).
class _FakeProvider implements MarketDataProvider {
  AssetQuoteData? quoteToReturn;
  AssetHistoricalData? historicalToReturn;

  // Traces des appels reçus, pour vérifier la délégation.
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
  group('MarketDataService (composition avec un MarketDataProvider fake)', () {
    test('getQuoteWithMetadata délègue au provider avec le symbole transmis', () async {
      final fakeProvider = _FakeProvider();
      final fixedQuote = AssetQuoteData(symbol: 'AAPL', price: 150.0, currency: 'USD');
      fakeProvider.quoteToReturn = fixedQuote;

      final service = MarketDataService.forTesting(
        _FakeExchangeRateService(),
        provider: fakeProvider,
      );

      final result = await service.getQuoteWithMetadata('AAPL');

      expect(fakeProvider.lastQuoteSymbol, 'AAPL');
      // Les données du fake sont retournées telles quelles (pas de transformation).
      expect(result, same(fixedQuote));
    });

    test('getHistoricalData délègue au provider avec le bon nombre de jours', () async {
      final fakeProvider = _FakeProvider();
      final fixedHistorical = AssetHistoricalData(
        symbol: 'AAPL',
        dates: [DateTime(2026, 1, 1)],
        prices: [150.0],
      );
      fakeProvider.historicalToReturn = fixedHistorical;

      final service = MarketDataService.forTesting(
        _FakeExchangeRateService(),
        provider: fakeProvider,
      );

      final result = await service.getHistoricalData('AAPL', days: 90);

      expect(fakeProvider.lastHistoricalSymbol, 'AAPL');
      expect(fakeProvider.lastHistoricalDays, 90);
      expect(result, same(fixedHistorical));
    });

    test('getQuoteForAsset sur un actif classique passe par quoteSymbol sans transformation', () async {
      final fakeProvider = _FakeProvider();
      final fixedQuote = AssetQuoteData(symbol: 'MSFT', price: 300.0, currency: 'USD');
      fakeProvider.quoteToReturn = fixedQuote;

      final service = MarketDataService.forTesting(
        _FakeExchangeRateService(),
        provider: fakeProvider,
      );

      final asset = Asset(symbol: 'MSFT', type: AssetType.stock, currency: 'USD');
      final result = await service.getQuoteForAsset(asset);

      // Actif classique : quoteSymbol == symbol de l'actif.
      expect(fakeProvider.lastQuoteSymbol, 'MSFT');
      // Aucune transformation métier pour un actif non-métal : le fake est
      // retourné à l'identique.
      expect(result, same(fixedQuote));
    });

    test('getQuoteForAsset sur un métal précieux applique poids fin + prime + conversion EUR', () async {
      final fakeProvider = _FakeProvider();

      // Spot en USD/once du cours de référence GC=F.
      // Poids fin choisi égal à 1 once troy pile pour simplifier le calcul à
      // la main : perGram = spot / gramsPerTroyOunce, puis * weight = spot.
      final asset = Asset(
        symbol: 'NAP',
        name: 'Napoléon 20 F',
        type: AssetType.preciousMetal,
        refSymbol: 'GC=F',
        refQuoteUnit: MetalQuoteUnit.ounce,
        fineWeightGrams: Asset.gramsPerTroyOunce,
        premiumPercent: 10.0,
      );

      fakeProvider.quoteToReturn = AssetQuoteData(
        symbol: 'GC=F',
        price: 2000.0,
        previousClose: 1900.0,
        changePercent: 5.0,
        currency: 'USD',
        exchange: 'CMX',
        marketState: 'REGULAR',
      );

      final service = MarketDataService.forTesting(
        _FakeExchangeRateService(),
        provider: fakeProvider,
      );

      final result = await service.getQuoteForAsset(asset);

      // Le provider est bien interrogé sur le symbole de référence (spot),
      // pas sur le symbole de la position.
      expect(fakeProvider.lastQuoteSymbol, 'GC=F');

      // Calcul attendu, à la main :
      // unitPriceFromSpot(2000) = (2000 / 31,1034768) * 31,1034768 * 1,10 = 2200
      // puis conversion EUR au taux fake USD->EUR = 0,90 : 2200 * 0,90 = 1980,00 €
      expect(result!.price, closeTo(1980.0, 0.005));

      // Même calcul pour la clôture précédente : 1900 * 1,10 * 0,90 = 1881,00 €
      expect(result.previousClose, closeTo(1881.0, 0.005));

      // La variation absolue est dérivée des prix normalisés : 1980 - 1881 = 99,00 €
      expect(result.change, closeTo(99.0, 0.005));

      // Le pourcentage de variation n'est pas recalculé (facteurs constants).
      expect(result.changePercent, 5.0);

      // La devise et l'identité de la position sont celles de l'actif, pas du spot.
      expect(result.currency, 'EUR');
      expect(result.symbol, 'NAP');
      expect(result.name, 'Napoléon 20 F');
      expect(result.exchange, 'CMX');
      expect(result.marketState, 'REGULAR');
    });

    test(
        'override de bucket en preciousMetal SANS refSymbol → aucune '
        'transformation (pas de double conversion)', () async {
      // Régression du défaut « type ↔ pricing » : classer manuellement un actif
      // ordinaire (ex. AAPL en USD, ou un ETC or) dans le bucket « métal » NE
      // doit PAS déclencher la conversion EUR du pipeline métal — sinon double
      // conversion en aval (_recomputeAssetValues re-convertit sur currency USD).
      // Le pricing métal est gaté sur hasMetalPricing (présence d'un refSymbol),
      // pas sur le seul type.
      final fakeProvider = _FakeProvider();
      final fixedQuote = AssetQuoteData(symbol: 'AAPL', price: 150.0, currency: 'USD');
      fakeProvider.quoteToReturn = fixedQuote;

      final service = MarketDataService.forTesting(
        _FakeExchangeRateService(),
        provider: fakeProvider,
      );

      // preciousMetal (bucket) mais sans refSymbol ni poids → hasMetalPricing == false.
      final asset = Asset(
        symbol: 'AAPL',
        type: AssetType.preciousMetal,
        typeLocked: true,
        currency: 'USD',
      );
      expect(asset.hasMetalPricing, isFalse);

      final result = await service.getQuoteForAsset(asset);

      // quoteSymbol == symbol (pas de refSymbol) ; quote rendue à l'identique,
      // devise NON forcée à EUR, prix NON converti.
      expect(fakeProvider.lastQuoteSymbol, 'AAPL');
      expect(result, same(fixedQuote));
      expect(result!.currency, 'USD');
      expect(result.price, 150.0);
    });

    test(
        'override de bucket en preciousMetal SANS refSymbol → historique brut '
        '(pas de taux appliqué)', () async {
      final fakeProvider = _FakeProvider();
      final fixedHistorical = AssetHistoricalData(
        symbol: '4GLD.DE',
        dates: [DateTime(2026, 1, 1), DateTime(2026, 1, 2)],
        prices: [100.0, 110.0],
      );
      fakeProvider.historicalToReturn = fixedHistorical;

      final service = MarketDataService.forTesting(
        _FakeExchangeRateService(),
        provider: fakeProvider,
      );

      // ETC or coté en EUR, classé « métal » à la main, sans modèle pièce/lingot.
      final asset = Asset(
        symbol: '4GLD.DE',
        type: AssetType.preciousMetal,
        typeLocked: true,
        currency: 'EUR',
      );

      final result = await service.getHistoricalDataForAsset(asset, days: 30);

      // Historique retourné tel quel : aucun facteur de change appliqué.
      expect(result, same(fixedHistorical));
      expect(result!.prices, [100.0, 110.0]);
    });
  });
}

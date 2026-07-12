// lib/services/asset_service.dart
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/account_storage.dart';

class AssetService {
  final String accountId;
  final AccountStorage _storage = AccountStorage();
  final MarketDataService _marketService = MarketDataService();

  AssetService({
    required this.accountId,
  });

  // ⭐ Charger les positions depuis le stockage à chaque fois
  Future<List<Position>> getPositions() async {
    return await _storage.getPositions(accountId);
  }

  // ⭐ Charger les prix et créer la liste complète
  Future<List<PositionWithMarketData>> fetchAllPrices() async {
    final positions = await getPositions(); 
    
    final results = await Future.wait(
      positions.map((position) async {
        final quote = await _marketService.getQuoteForAsset(position.asset);
        if (quote == null || quote.hasError) {
          return PositionWithMarketData(
            position: position,
            errorMessage: 'Erreur de cotation',
          );
        }
        return PositionWithMarketData(
          position: position,
          currentPrice: quote.price?.toDouble(),
          change: quote.change?.toDouble(),
          changePercent: quote.changePercent?.toDouble(),
          currency: quote.currency,
          lastUpdated: DateTime.now(),
        );
      }).toList(),
    );

    return results;
  }
}
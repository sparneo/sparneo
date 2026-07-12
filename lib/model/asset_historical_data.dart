// model/asset_historical_data.dart
class AssetHistoricalData {
  final String symbol;
  final List<DateTime> dates;
  final List<num> prices;
  final String? errorMessage;

  AssetHistoricalData({
    required this.symbol,
    required this.dates,
    required this.prices,
    this.errorMessage,
  });

  bool get hasError => errorMessage != null;
  bool get isEmpty => dates.isEmpty || prices.isEmpty;
}
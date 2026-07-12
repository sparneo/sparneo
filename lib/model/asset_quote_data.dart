// model/asset_quote_data.dart
class AssetQuoteData {
  final String symbol;
  final String? name;
  final num? price;
  final num? change;
  final num? changePercent;
  final int? volume;
  final num? open;
  final num? dayHigh;
  final num? dayLow;
  final num? previousClose;
  final String? currency;
  final String? exchange;
  final String? marketState;
  final num? fiftyTwoWeekHigh;
  final num? fiftyTwoWeekLow;

  /// `null` = donnée live (fraîchement récupérée auprès du provider).
  /// Non-null = donnée servie depuis le cache « dernier cours connu »
  /// (LOT 2), datée de l'instant où elle a été mise en cache.
  final DateTime? asOf;

  /// Type d'instrument brut renvoyé par le provider (ex. `meta.instrumentType`
  /// côté Yahoo Finance : `EQUITY`, `ETF`, `MUTUALFUND`, `CRYPTOCURRENCY`...).
  /// `null` si le provider ne fournit pas cette information. Voir
  /// [AssetType.fromYahooInstrumentType] pour la conversion vers l'enum
  /// applicatif.
  final String? instrumentType;

  AssetQuoteData({
    required this.symbol,
    this.name,
    this.price,
    this.change,
    this.changePercent,
    this.volume,
    this.open,
    this.dayHigh,
    this.dayLow,
    this.previousClose,
    this.currency,
    this.exchange,
    this.marketState,
    this.fiftyTwoWeekHigh,
    this.fiftyTwoWeekLow,
    this.asOf,
    this.instrumentType,
  });

  bool get hasError => price == null;
}
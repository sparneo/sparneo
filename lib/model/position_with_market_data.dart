// lib/model/position_with_market_data.dart
import 'position.dart';
import 'asset.dart';

class PositionWithMarketData {
  final Position position;
  
  // Données de marché dynamiques
  final double? currentPrice;
  final double? change;       
  final double? changePercent;
  final String? currency;
  final DateTime? lastUpdated;
  final String? errorMessage;
  
  // VARIATION SUR PÉRIODE SÉLECTIONNÉE
  final double? periodChange;
  final double? periodChangePercent;

  PositionWithMarketData({
    required this.position,
    this.currentPrice,
    this.change,
    this.changePercent,
    this.currency,
    this.lastUpdated,
    this.errorMessage,
    this.periodChange,
    this.periodChangePercent,
  });

  // Délegations pour faciliter l'accès
  String get symbol => position.symbol;
  String get accountId => position.accountId;
  String get quantity => position.quantity;
  Asset get asset => position.asset;
  AssetType get type => position.asset.type;

  bool get hasError => errorMessage != null;
  bool get isLoading => currentPrice == null && !hasError;
  bool get isPositive => change != null && change! >= 0;

  // Calculs dérivés
  double get totalValue => (currentPrice ?? 0) * (double.tryParse(quantity) ?? 0);
  double get totalChange => (change ?? 0) * (double.tryParse(quantity) ?? 0);

  // --- PLUS-VALUE LATENTE (PRU) ---
  // Tous ces calculs sont EN DEVISE NATIVE de l'actif ; la conversion EUR
  // reste à la charge des widgets (comme pour les autres montants).

  /// Prix de revient unitaire (PRU) saisi par l'utilisateur, ou null.
  double? get averageBuyPrice => position.averageBuyPrice;

  /// Coût total de la position (PRU * quantité). null si aucun PRU.
  double? get costBasis {
    final pru = averageBuyPrice;
    if (pru == null) return null;
    final qty = double.tryParse(quantity) ?? 0;
    return pru * qty;
  }

  /// Plus-value latente en devise native ((prix actuel - PRU) * quantité).
  /// null si le PRU ou le prix actuel est absent.
  double? get unrealizedGain {
    final pru = averageBuyPrice;
    if (pru == null || currentPrice == null) return null;
    final qty = double.tryParse(quantity) ?? 0;
    return (currentPrice! - pru) * qty;
  }

  /// Plus-value latente en pourcentage par rapport au PRU.
  /// null si le PRU est absent/nul ou si le prix actuel est absent.
  double? get unrealizedGainPercent {
    final pru = averageBuyPrice;
    if (pru == null || pru == 0 || currentPrice == null) return null;
    return (currentPrice! - pru) / pru * 100;
  }

  PositionWithMarketData copyWith({
    Position? position,
    double? currentPrice,
    double? change,
    double? changePercent,
    String? currency,
    DateTime? lastUpdated,
    String? errorMessage,
    double? periodChange,
    double? periodChangePercent,
  }) {
    return PositionWithMarketData(
      position: position ?? this.position,
      currentPrice: currentPrice ?? this.currentPrice,
      change: change ?? this.change,
      changePercent: changePercent ?? this.changePercent,
      currency: currency ?? this.currency,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      errorMessage: errorMessage ?? this.errorMessage,
      periodChange: periodChange ?? this.periodChange,
      periodChangePercent: periodChangePercent ?? this.periodChangePercent,
    );
  }
}
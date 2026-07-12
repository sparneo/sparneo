// lib/model/position.dart
import 'asset.dart';

class Position {
  final String accountId;
  final Asset asset;
  final String quantity;
  final double? averageBuyPrice;
  final DateTime? lastUpdated;
  final String? customName;

  Position({
    required this.accountId,
    required this.asset,
    required this.quantity,
    this.averageBuyPrice,
    this.lastUpdated, 
    this.customName,
  });

  // --- Sérialisation JSON ---
  // [fallbackAccountId] permet de retomber sur l'identifiant du compte
  // (clé de stockage) si le champ 'accountId' est absent du JSON.
  factory Position.fromJson(Map<String, dynamic> json, {String? fallbackAccountId}) {
    return Position(
      accountId: json['accountId'] ?? fallbackAccountId ?? '',
      asset: Asset.fromJson(Map<String, dynamic>.from(json['asset'] as Map)),
      quantity: json['quantity']?.toString() ?? '0',
      averageBuyPrice: json['averageBuyPrice']?.toDouble(),
      customName: json['customName'], // ⭐ Lecture du nom personnalisé
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'asset': asset.toJson(),
      'quantity': quantity,
      'averageBuyPrice': averageBuyPrice,
      'customName': customName, // ⭐ Sauvegarde du nom personnalisé
    };
  }

  String get symbol => asset.symbol;
  String get currency => asset.currency;
  String? get name => asset.name;
  AssetType get type => asset.type;
  String get displayName => customName ?? asset.name ?? asset.symbol;

  // Sentinelle interne : permet de distinguer « non fourni » de « mettre à null »
  // pour averageBuyPrice (sinon copyWith ne pourrait jamais effacer le PRU).
  static const Object _undefined = Object();

  Position copyWith({
    String? accountId,
    Asset? asset,
    String? quantity,
    Object? averageBuyPrice = _undefined,
    DateTime? lastUpdated,
    Object? customName = _undefined,
  }) {
    return Position(
      accountId: accountId ?? this.accountId,
      asset: asset ?? this.asset,
      quantity: quantity ?? this.quantity,
      averageBuyPrice: identical(averageBuyPrice, _undefined)
          ? this.averageBuyPrice
          : averageBuyPrice as double?,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      customName: identical(customName, _undefined)
          ? this.customName
          : customName as String?,
    );
  }
}
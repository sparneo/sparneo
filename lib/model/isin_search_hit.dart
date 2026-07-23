// lib/model/isin_search_hit.dart
//
// Un résultat de recherche d'un ISIN auprès de la source de marché (endpoint
// `search`). Un même ISIN cote souvent sur PLUSIEURS places : chaque place
// donne un hit distinct (même titre, symboles différents `.PA`, `.DE`, `.MI`…).
// La désambiguïsation (choix du symbole retenu) est faite par `IsinResolver`,
// jamais dans ce modèle purement porteur de données.

/// Un hit de recherche par ISIN (une place de cotation candidate).
class IsinSearchHit {
  /// Symbole à interroger sur la source de marché (ex. `AIR.PA`).
  final String symbol;

  /// Code de place brut (ex. `PAR`, `GER`, `MIL`). Peut être absent.
  final String? exchange;

  /// Libellé lisible de la place (ex. `Paris`, `XETRA`). Peut être absent.
  final String? exchangeDisplay;

  /// Type d'instrument (`EQUITY`, `ETF`, `MUTUALFUND`…). Peut être absent.
  final String? quoteType;

  final String? shortName;
  final String? longName;

  /// Score de pertinence renvoyé par la recherche (plus haut = plus pertinent).
  /// Sert de départage UNIQUEMENT à rang de préférence de place égal.
  final double? score;

  const IsinSearchHit({
    required this.symbol,
    this.exchange,
    this.exchangeDisplay,
    this.quoteType,
    this.shortName,
    this.longName,
    this.score,
  });

  /// Nom d'affichage best-effort (nom court prioritaire, sinon nom long).
  String? get displayName => shortName ?? longName;
}

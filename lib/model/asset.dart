// lib/model/asset.dart
enum AssetType {
  etf('ETF'),
  stock('Action'),
  bond('Obligation'),
  crypto('Crypto'),
  fund('Fonds'),
  preciousMetal('Métal précieux'),
  realEstate('Immobilier'),
  other('Autre');

  final String label;
  const AssetType(this.label);

  /// Déduit un [AssetType] à partir du champ `meta.instrumentType` renvoyé par
  /// l'endpoint Yahoo Finance `v8/finance/chart` (ex. `EQUITY`, `ETF`,
  /// `MUTUALFUND`, `CRYPTOCURRENCY`...).
  ///
  /// Volontairement incapable de renvoyer [preciousMetal], [bond] ou
  /// [realEstate] : Yahoo ne distingue ni les ETC métaux précieux (un ETC or
  /// comme `4GLD.DE` revient en `EQUITY`), ni les obligations détenues en
  /// direct, ni les foncières/SCPI/REIT (qui reviennent aussi en `EQUITY`).
  /// Ces trois types restent des choix explicites de l'utilisateur, jamais une
  /// déduction automatique — le backfill au rafraîchissement ne reclasse donc
  /// que les positions NON verrouillées (voir [Asset.typeLocked]), et ne peut
  /// de toute façon jamais produire ces valeurs.
  static AssetType fromYahooInstrumentType(String? instrumentType) {
    switch (instrumentType) {
      case 'EQUITY':
        return AssetType.stock;
      case 'ETF':
        return AssetType.etf;
      case 'MUTUALFUND':
        return AssetType.fund;
      case 'CRYPTOCURRENCY':
        return AssetType.crypto;
      case 'INDEX':
      case 'CURRENCY':
      case 'FUTURE':
      default:
        // Valeur inconnue, absente, ou type sans correspondance directe dans
        // notre enum : on ne prétend pas savoir mieux.
        return AssetType.other;
    }
  }
}

/// Unité de cotation d'un cours de métal précieux de référence.
/// - [ounce] : prix par once troy (ex. future `GC=F` en USD/once).
/// - [gram]  : prix par gramme (ex. ETC physique `4GLD.DE` en EUR/g).
enum MetalQuoteUnit { ounce, gram }

class Asset {
  // Constante physique : 1 once troy = 31,1034768 g d'or fin.
  static const double gramsPerTroyOunce = 31.1034768;

  final String symbol;
  final String? name;
  final AssetType type;

  /// `true` = le [type] a été fixé manuellement par l'utilisateur et fait
  /// autorité : la détection automatique (mapping `instrumentType` au
  /// rafraîchissement) ne doit JAMAIS l'écraser. `false` (défaut) = type déduit
  /// automatiquement, librement reclassable au fil des cotations. C'est ce flag
  /// qui rend sûrs à la fois le backfill lazy et les types non auto-détectables
  /// (bond / preciousMetal / realEstate), toujours posés verrouillés.
  final bool typeLocked;

  final String currency;
  final String? exchange;
  final DateTime? lastUpdatedDefinition; // Date de dernière mise à jour de la définition (rare)

  // --- Champs spécifiques aux métaux précieux (pièces / lingots) ---
  // Le `symbol` reste l'identifiant unique de la position (clé de stockage),
  // tandis que [refSymbol] est le symbole Yahoo réellement coté pour obtenir
  // le cours spot. Le prix d'UNE pièce se déduit du spot via le poids fin et
  // la prime (voir [unitPriceFromSpot]).

  /// Symbole Yahoo du cours de référence (ex. `GC=F`, `4GLD.DE`). Null pour les
  /// actifs classiques.
  final String? refSymbol;

  /// Unité de cotation du cours de référence (once troy par défaut).
  final MetalQuoteUnit refQuoteUnit;

  /// Poids de métal fin d'UNE pièce/unité, en grammes.
  final double? fineWeightGrams;

  /// Prime appliquée au-dessus de la valeur métal, en pourcentage (ex. 8.0).
  final double? premiumPercent;

  Asset({
    required this.symbol,
    this.name,
    this.type = AssetType.other,
    this.typeLocked = false,
    this.currency = 'EUR',
    this.exchange,
    this.lastUpdatedDefinition,
    this.refSymbol,
    this.refQuoteUnit = MetalQuoteUnit.ounce,
    this.fineWeightGrams,
    this.premiumPercent,
  });

  String get displayName => name ?? symbol;
  bool get isUsd => currency.toUpperCase() == 'USD';
  bool get isPreciousMetal => type == AssetType.preciousMetal;

  /// Un actif est réellement PRICÉ comme un métal (cours de référence converti
  /// en EUR, prix d'UNE pièce via poids fin/prime) uniquement s'il porte les
  /// données de valorisation métal — pas au seul vu de son [type].
  ///
  /// Distinction critique depuis l'override manuel du type : l'utilisateur peut
  /// classer n'importe quelle position en [AssetType.preciousMetal] pour la
  /// ranger dans le bucket d'allocation « métal » (ex. un ETC or coté en direct
  /// sans modèle pièce/lingot). Une telle position n'a NI [refSymbol] NI poids :
  /// elle doit conserver le pricing d'un actif classique. Ne jamais gater la
  /// mécanique de valorisation sur [isPreciousMetal] (bucket) : la gater ici,
  /// sur la présence effective d'un cours de référence.
  bool get hasMetalPricing =>
      isPreciousMetal && refSymbol != null && refSymbol!.isNotEmpty;

  /// Symbole effectivement interrogé sur le marché : le cours de référence pour
  /// un métal précieux (qui n'est pas coté sous son propre [symbol]), sinon le
  /// symbole de l'actif lui-même.
  String get quoteSymbol => (isPreciousMetal && refSymbol != null && refSymbol!.isNotEmpty)
      ? refSymbol!
      : symbol;

  /// Convertit un cours spot brut (dans la devise de cotation, par once ou par
  /// gramme selon [refQuoteUnit]) en prix d'UNE pièce, prime comprise.
  ///
  /// Identité si l'actif n'est pas un métal précieux ou si le poids fin est
  /// absent/invalide (on retombe alors sur le cours brut, sans transformation).
  double unitPriceFromSpot(num spot) {
    if (!isPreciousMetal) return spot.toDouble();
    final weight = fineWeightGrams;
    if (weight == null || weight <= 0) return spot.toDouble();
    final perGram = refQuoteUnit == MetalQuoteUnit.ounce
        ? spot / gramsPerTroyOunce
        : spot.toDouble();
    return perGram * weight * (1 + (premiumPercent ?? 0) / 100);
  }

  // --- Sérialisation JSON (imbriqué dans Position) ---

  factory Asset.fromJson(Map<String, dynamic> json) {
    return Asset(
      symbol: json['symbol'] ?? '',
      name: json['name'],
      type: json['type'] != null
          ? AssetType.values.firstWhere((t) => t.name == json['type'], orElse: () => AssetType.other)
          : AssetType.other,
      typeLocked: json['typeLocked'] == true,
      currency: json['currency'] ?? 'EUR',
      exchange: json['exchange'],
      refSymbol: json['refSymbol'],
      refQuoteUnit: json['refQuoteUnit'] != null
          ? MetalQuoteUnit.values.firstWhere(
              (u) => u.name == json['refQuoteUnit'],
              orElse: () => MetalQuoteUnit.ounce,
            )
          : MetalQuoteUnit.ounce,
      fineWeightGrams: (json['fineWeightGrams'] as num?)?.toDouble(),
      premiumPercent: (json['premiumPercent'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'symbol': symbol,
      'name': name,
      'type': type.name,
      // Omis quand false (défaut) pour ne pas alourdir l'export/round-trip des
      // positions à type auto-déduit ; fromJson retombe sur false si absent.
      if (typeLocked) 'typeLocked': true,
      'currency': currency,
      'exchange': exchange,
      // Champs métaux précieux : omis (null) pour les actifs classiques afin de
      // ne pas alourdir l'export des positions existantes.
      if (refSymbol != null) 'refSymbol': refSymbol,
      if (isPreciousMetal) 'refQuoteUnit': refQuoteUnit.name,
      if (fineWeightGrams != null) 'fineWeightGrams': fineWeightGrams,
      if (premiumPercent != null) 'premiumPercent': premiumPercent,
    };
  }

  Asset copyWith({
    String? symbol,
    String? name,
    AssetType? type,
    bool? typeLocked,
    String? currency,
    String? exchange,
    DateTime? lastUpdatedDefinition,
    String? refSymbol,
    MetalQuoteUnit? refQuoteUnit,
    double? fineWeightGrams,
    double? premiumPercent,
  }) {
    return Asset(
      symbol: symbol ?? this.symbol,
      name: name ?? this.name,
      type: type ?? this.type,
      typeLocked: typeLocked ?? this.typeLocked,
      currency: currency ?? this.currency,
      exchange: exchange ?? this.exchange,
      lastUpdatedDefinition: lastUpdatedDefinition ?? this.lastUpdatedDefinition,
      refSymbol: refSymbol ?? this.refSymbol,
      refQuoteUnit: refQuoteUnit ?? this.refQuoteUnit,
      fineWeightGrams: fineWeightGrams ?? this.fineWeightGrams,
      premiumPercent: premiumPercent ?? this.premiumPercent,
    );
  }
}

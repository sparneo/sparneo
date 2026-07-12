// lib/model/asset_transaction.dart
import 'dart:math';

/// Sens d'une transaction dans le journal d'un compte.
///
/// La valeur persistée en base est [wire] (anglais, stable) — jamais un label
/// i18n.
///
/// POLITIQUE DE DÉSÉRIALISATION (importante — cf. sûreté du backup) :
///   - [tryFromWire] renvoie `null` pour une valeur inconnue (aucune
///     coercition). C'est la porte STRICTE pour des données EXTERNES (import
///     de backup) : un kind inconnu doit être REJETÉ, jamais pris pour un
///     `buy` (sinon une version ancienne relisant un backup contenant un
///     `adjustment` fabriquerait un faux achat).
///   - [fromWire] LÈVE une [FormatException] pour une valeur inconnue. Aucune
///     coercition silencieuse (contrairement à l'ancienne politique
///     `orElse: buy`). Réservé aux lignes DB déjà validées à l'écriture.
enum TransactionKind {
  buy('buy'),
  sell('sell'),
  dividend('dividend'),
  deposit('deposit'),       // apport de cash sur le compte
  withdrawal('withdrawal'), // retrait de cash

  /// Position initiale DÉCLARATIVE datée : quantité + prix unitaire (base de
  /// coût déclarée) à une date donnée. Sert à amorcer un lot sans historique
  /// d'achat (marqué `meta.declarative = true` dans l'export). Traité par le
  /// moteur WAC comme une entrée :
  /// `runningQty += q ; runningCost += q × unitPrice` (coût 0 si unitPrice nul).
  openingBalance('openingBalance'),

  /// Correction / inventaire : delta SIGNÉ de quantité (`quantity` peut être
  /// négatif) et delta de base de coût associé. Contrairement à buy/sell, ce
  /// n'est pas une opération de marché : aucune plus-value réalisée n'en
  /// découle. Le moteur WAC applique `runningQty += q` puis un delta de coût
  /// (cf. `transaction_analytics.dart` pour la convention exacte).
  ///
  /// Avec `symbol=null` (variante ESPÈCES) : ajustement du solde espèces dérivé
  /// du compte (`amount` = delta signé) — n'affecte AUCUNE position titre.
  adjustment('adjustment'),

  /// Intérêts sur espèces (livret associé au broker, PEA espèces, coupons de
  /// fonds monétaires…). Mouvement CASH pur : `amount` positif, `symbol`
  /// généralement null, aucun effet sur la projection titre. Distinct de
  /// `dividend` (pas de quantité, régime fiscal propre) et de `deposit` (n'est
  /// pas un apport externe — ne fausse pas le suivi des versements).
  /// Saisie MANUELLE (pas `isSystemGenerated`), comme buy/dividend.
  interest('interest'),

  /// Frais autonomes non adossés à un trade : droits de garde, frais de place,
  /// tenue de compte, ligne de taxe isolée. Mouvement CASH pur : `amount`
  /// signé (typiquement négatif ; positif pour un rebate), `symbol` optionnel,
  /// aucun effet sur la projection titre. Le montant est porté par `amount` ;
  /// le champ `fee` reste null sur une ligne `charge`.
  ///
  /// Wire = `'charge'` (et NON `'fee'`) : évite toute collision/confusion avec
  /// le CHAMP `fee` des lignes buy/sell. Saisie MANUELLE.
  charge('charge');

  /// Valeur stable sérialisée en base (ne JAMAIS utiliser .name pour persister).
  final String wire;
  const TransactionKind(this.wire);

  /// Mouvement fabriqué par l'application (et non saisi à la main comme une
  /// opération de marché) : à ne PAS proposer dans les sélecteurs de saisie /
  /// filtres. Affiché en lecture seule dans le journal.
  bool get isSystemGenerated =>
      this == openingBalance || this == adjustment;

  /// Désérialisation STRICTE non-levante : renvoie `null` si [w] n'est pas un
  /// wire connu. À utiliser pour toute donnée EXTERNE (import de backup) afin
  /// de REJETER explicitement un kind inconnu au lieu de le coercer.
  static TransactionKind? tryFromWire(String w) {
    for (final k in values) {
      if (k.wire == w) return k;
    }
    return null;
  }

  /// Désérialise depuis la valeur persistée. LÈVE une [FormatException] pour
  /// toute valeur inconnue — plus aucune coercition silencieuse en [buy].
  /// Réservé aux lignes DB déjà validées à l'écriture ; pour des données
  /// externes utiliser [tryFromWire] et traiter le `null` (rejet).
  static TransactionKind fromWire(String w) {
    final k = tryFromWire(w);
    if (k == null) {
      throw FormatException('TransactionKind inconnu (wire): "$w"');
    }
    return k;
  }
}

/// Entrée du journal de transactions d'un compte.
///
/// Tous les montants numériques ([quantity], [unitPrice], [amount], [fee])
/// sont des [String] (précision exacte, cohérence avec [Position.quantity]).
/// [amount] est l'EFFET NET SIGNÉ sur les espèces DU COMPTE, exprimé dans la
/// DEVISE DE RÈGLEMENT ([settlementCurrency] `??` [currency]) — PAS forcément la
/// devise de cotation. Convention de signe :
///   - négatif pour buy / withdrawal / charge (sortie de cash)
///   - positif pour sell / dividend / deposit / interest (entrée de cash)
///   - `charge` est agnostique au signe (rebate = positif) ; le moteur cash
///     somme [amount] sans jamais réinterpréter son signe.
/// [amount] est stocké tel quel — le modèle ne le recalcule jamais au
/// chargement (fidélité au backup, pas de dérive d'arrondi). En devises
/// croisées (titre USD dans un compte EUR), [amount] est le NET EUR effectif du
/// relevé courtier : le taux de change y est un FAIT PASSÉ figé, JAMAIS
/// recalculé au rejeu (cf. `position_projection.dart`, design cash-ledger §8).
///
/// PARTITION STRICTE DES CHAMPS (invariant anti-double-comptage — cf.
/// `position_projection.dart`) : la projection TITRE lit
/// [quantity]/[unitPrice]/[fee] (en devise de COTATION) et IGNORE
/// [amount]/[settlementCurrency] ; la projection CASH lit UNIQUEMENT [amount]
/// (dans la devise de RÈGLEMENT). En corollaire, [amount] d'un
/// openingBalance/adjustment TITRE (symbol non null) vaut null (déclarer/corriger
/// un lot ne bouge pas le cash), tandis que la variante ESPÈCES (symbol null)
/// porte un [amount] signé.
///
/// [symbol] et [quantity]/[unitPrice] peuvent être null pour les mouvements
/// cash purs (deposit / withdrawal / interest / charge, et les variantes
/// espèces d'openingBalance / adjustment, sans titre associé).
class AssetTransaction {
  final String id;
  final String accountId;
  final String? symbol;       // null pour deposit/withdrawal cash
  final TransactionKind kind;
  final String? quantity;     // String (précision) — null si cash pur
  final String? unitPrice;    // String — null si cash pur
  final String? amount;       // String signé (cf. convention ci-dessus)
  final String currency;      // devise de COTATION (quantity/unitPrice/fee)

  /// Devise de RÈGLEMENT de [amount] (celle du COMPTE), ou `null` = identique à
  /// [currency]. MÉTADONNÉE DE [amount] SEUL : seule la projection CASH la lit
  /// (`cash[settlementCurrency ?? currency] += amount`) ; la partition stricte
  /// des champs (cf. doc de classe) reste intacte. Distingue la devise de
  /// cotation (USD pour un titre US, portée par quantity/unitPrice/fee, comparée
  /// au cours Yahoo pour le PRU) de la devise de règlement (EUR pour un CTO €,
  /// celle de l'effet net sur les espèces). Absent (`null`) = mono-devise
  /// (règlement == cotation) : comportement legacy, rétro-compatible avec toutes
  /// les lignes/backups d'avant ce champ (design cash-ledger §8, option A).
  final String? settlementCurrency;

  final DateTime date;
  final String? fee;
  final String? note;
  final Map<String, dynamic>? meta; // extension future (meta_json côté SQL)

  AssetTransaction({
    required this.id,
    required this.accountId,
    this.symbol,
    required this.kind,
    this.quantity,
    this.unitPrice,
    this.amount,
    required this.currency,
    this.settlementCurrency,
    required this.date,
    this.fee,
    this.note,
    this.meta,
  });

  // ---------------------------------------------------------------------------
  // Sérialisation JSON
  // ---------------------------------------------------------------------------

  /// Désérialise depuis un [Map] JSON.
  ///
  /// TOLÉRANT aux champs ABSENTS : tout champ manquant retombe sur null ou sa
  /// valeur par défaut (`kind` absent → [TransactionKind.buy], compatibilité
  /// des lignes héritées d'avant l'introduction du champ).
  ///
  /// STRICT sur un `kind` PRÉSENT mais INCONNU : [TransactionKind.fromWire]
  /// lève alors une [FormatException] — jamais de coercition silencieuse en
  /// `buy`. [AssetTransaction] étant désérialisé pour l'import de backup
  /// (données externes), c'est le comportement voulu ; l'appelant
  /// (`AccountStorage.importRawData`) intercepte pour un rejet atomique.
  ///
  /// [fallbackAccountId] permet de récupérer l'identifiant du compte depuis
  /// la clé de stockage (ex. le compte parent dans le backup), comme
  /// [Position.fromJson].
  factory AssetTransaction.fromJson(
    Map<String, dynamic> json, {
    String? fallbackAccountId,
  }) {
    return AssetTransaction(
      id: json['id']?.toString() ?? '',
      accountId: json['accountId']?.toString() ?? fallbackAccountId ?? '',
      symbol: json['symbol'] as String?,
      kind: json['kind'] != null
          ? TransactionKind.fromWire(json['kind'] as String)
          : TransactionKind.buy,
      quantity: json['quantity'] as String?,
      unitPrice: json['unitPrice'] as String?,
      amount: json['amount'] as String?,
      currency: json['currency']?.toString() ?? '',
      // TOLÉRANT absent → null (rétro-compat lignes/backups d'avant le champ :
      // règlement == cotation). Une clé présente mais vide est ramenée à null.
      settlementCurrency: (json['settlementCurrency'] as String?)?.isNotEmpty ==
              true
          ? json['settlementCurrency'] as String
          : null,
      date: json['date'] != null
          ? DateTime.parse(json['date'] as String)
          : DateTime.fromMillisecondsSinceEpoch(0),
      fee: json['fee'] as String?,
      note: json['note'] as String?,
      meta: json['meta'] != null
          ? Map<String, dynamic>.from(json['meta'] as Map)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'accountId': accountId,
      'symbol': symbol,
      'kind': kind.wire,
      'quantity': quantity,
      'unitPrice': unitPrice,
      'amount': amount,
      'currency': currency,
      // Clé OPTIONNELLE : émise UNIQUEMENT si non-null (devise de règlement ≠
      // cotation). Une ligne mono-devise n'expose pas la clé → les backups
      // existants restent bit-identiques (rétro-compat, design cash-ledger §8).
      if (settlementCurrency != null) 'settlementCurrency': settlementCurrency,
      'date': date.toIso8601String(),
      'fee': fee,
      'note': note,
      'meta': meta,
    };
  }

  // ---------------------------------------------------------------------------
  // copyWith avec sentinelle
  // ---------------------------------------------------------------------------

  // Sentinelle interne : distingue « non fourni » de « mettre explicitement à
  // null » pour les champs nullable. Sans cette sentinelle, `copyWith(symbol:
  // null)` serait indiscernable de `copyWith()` — impossible d'effacer un champ.
  static const Object _undefined = Object();

  AssetTransaction copyWith({
    String? id,
    String? accountId,
    Object? symbol = _undefined,
    TransactionKind? kind,
    Object? quantity = _undefined,
    Object? unitPrice = _undefined,
    Object? amount = _undefined,
    String? currency,
    Object? settlementCurrency = _undefined,
    DateTime? date,
    Object? fee = _undefined,
    Object? note = _undefined,
    Object? meta = _undefined,
  }) {
    return AssetTransaction(
      id: id ?? this.id,
      accountId: accountId ?? this.accountId,
      symbol: identical(symbol, _undefined) ? this.symbol : symbol as String?,
      kind: kind ?? this.kind,
      quantity:
          identical(quantity, _undefined) ? this.quantity : quantity as String?,
      unitPrice: identical(unitPrice, _undefined)
          ? this.unitPrice
          : unitPrice as String?,
      amount: identical(amount, _undefined) ? this.amount : amount as String?,
      currency: currency ?? this.currency,
      settlementCurrency: identical(settlementCurrency, _undefined)
          ? this.settlementCurrency
          : settlementCurrency as String?,
      date: date ?? this.date,
      fee: identical(fee, _undefined) ? this.fee : fee as String?,
      note: identical(note, _undefined) ? this.note : note as String?,
      meta: identical(meta, _undefined)
          ? this.meta
          : meta as Map<String, dynamic>?,
    );
  }

  // ---------------------------------------------------------------------------
  // Identité
  // ---------------------------------------------------------------------------

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssetTransaction &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  // ---------------------------------------------------------------------------
  // Fabrique d'identifiant
  // ---------------------------------------------------------------------------

  /// Génère un identifiant unique : microsecondes epoch + suffixe base36
  /// aléatoire (même schéma que [Account.generateId] / [Wallet.generateId]).
  static String generateId() {
    final suffix =
        Random().nextInt(0x7FFFFFFF).toRadixString(36).padLeft(6, '0');
    return '${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }
}

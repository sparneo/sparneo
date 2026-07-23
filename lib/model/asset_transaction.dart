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
  charge('charge'),

  /// SORTIE DE TITRES SANS CESSION : transfert de titres hors du compte
  /// (ex. PEA→CTO, virement de titres sortant), PAS une vente de marché. Réduit
  /// la quantité de la position en emportant sa base de coût AU PRORATA (le PRU
  /// des titres restants est INCHANGÉ, comme la jambe coût d'une vente), MAIS
  /// SANS booker aucune plus-value réalisée (un transfert n'est pas une cession)
  /// et SANS aucun effet cash ([amount] `null`, invariant du modèle : partition
  /// stricte des champs — cf. doc de classe). C'est la primitive « sortie de
  /// titres à PRU, sans PV ni cash » qui manquait : `sell` réaliserait une PV et
  /// crédite du cash ; `adjustment` applique un delta de coût FIXE (q×unitPrice),
  /// incapable de réduire la base de coût AU PRORATA du WAC courant sans
  /// connaître le PRU au moment de l'import — d'où un kind dédié.
  ///
  /// Généré à l'import de relevé (jamais saisi à la main) → [isSystemGenerated].
  /// L'entrée symétrique (titres ENTRANTS à coût nul, ex. attribution gratuite)
  /// reste couverte par un `adjustment` TITRE à `unitPrice` nul (coût 0, PRU en
  /// baisse) — aucun `transferIn` n'est requis par les codes traités.
  transferOut('transferOut');

  /// Valeur stable sérialisée en base (ne JAMAIS utiliser .name pour persister).
  final String wire;
  const TransactionKind(this.wire);

  /// Mouvement fabriqué par l'application (et non saisi à la main comme une
  /// opération de marché) : à ne PAS proposer dans les sélecteurs de saisie /
  /// filtres. Affiché en lecture seule dans le journal.
  bool get isSystemGenerated =>
      this == openingBalance || this == adjustment || this == transferOut;

  /// Nature CASH PURE : mouvement d'espèces qui n'affecte JAMAIS une position
  /// titre, même si la ligne source référence un instrument (ex. la TTF
  /// `ODTTF` porte l'ISIN du titre taxé mais reste un frais ; un dépôt peut
  /// être libellé « REM CHQ »/« VIRT RECU »). Sert à ne PAS prendre ces lignes
  /// pour des actifs à résoudre. N'inclut PAS `adjustment`/`openingBalance`
  /// (ambigus : cash SI `symbol` null, titre sinon) — trancher au cas par cas
  /// via la présence d'un symbole/ISIN.
  bool get isCashOnly =>
      this == deposit ||
      this == withdrawal ||
      this == interest ||
      this == charge;

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
  // Séquence d'import (départage intraday) + comparateur chronologique canonique
  // ---------------------------------------------------------------------------

  /// Séquence MONOTONE d'un mouvement ISSU D'UN IMPORT de relevé, lue depuis
  /// `meta['seq']` (tolérante : absente ou illisible → `null`). Elle reflète
  /// l'ORDRE DU FICHIER source (donc l'ordre intraday réel, le relevé étant
  /// chronologique ascendant strict) et sert de DÉPARTAGE des mouvements de MÊME
  /// DATE — indispensable car [id] est généré aléatoirement à l'import
  /// (timestamp+random) : trier sur [id] rendait l'ordre intraday arbitraire, ce
  /// qui, via le clamp anti-survente, faisait disparaître des titres sur les
  /// allers-retours d'un même jour (une vente ordonnée avant son achat). Les
  /// mouvements saisis À LA MAIN n'en portent pas (`null`) → repli sur [id]
  /// (comportement historique inchangé).
  int? get importSeq {
    final v = meta?['seq'];
    return v is num ? v.toInt() : null;
  }

  /// Rang ENTRÉE/SORTIE d'un mouvement selon son effet sur la QUANTITÉ titre :
  /// `0` = entrée ou neutre (n'ajoute jamais de sortie de titres), `1` = sortie.
  /// Sert à ordonner, au sein d'une MÊME DATE, toutes les ENTRÉES avant les
  /// SORTIES — car un compte comptant / PEA n'autorise PAS la vente à découvert :
  /// toute survente transitoire (une vente listée avant son achat le même jour,
  /// cas réel de l'ordre des relevés Bourse Direct) est un artefact d'ordre qui,
  /// via le clamp anti-survente, DÉTRUIRAIT des titres. Entrées-d'abord élimine
  /// tout clamp parasite quel que soit l'ordre du fichier.
  ///
  ///   - Rang 1 (sorties) : `sell`, `transferOut`, et `adjustment` à quantité
  ///     STRICTEMENT NÉGATIVE (delta signé sortant ; les rompus sont un `sell`).
  ///   - Rang 0 (entrées/neutres) : `buy`, `openingBalance`, `adjustment` à
  ///     quantité ≥ 0 (dont l'attribution gratuite) ou espèces (quantité null),
  ///     et tous les mouvements CASH PUR (`dividend`/`deposit`/`withdrawal`/
  ///     `interest`/`charge`, régularisations) qui ne touchent pas la quantité.
  static int _quantityRank(AssetTransaction t) {
    switch (t.kind) {
      case TransactionKind.sell:
      case TransactionKind.transferOut:
        return 1;
      case TransactionKind.adjustment:
        // Rang selon le SIGNE de la quantité (delta signé). Variante espèces
        // (quantity null) ou delta ≥ 0 → entrée/neutre. `double` suffit : on ne
        // teste QUE le signe, aucune précision requise.
        final q = t.quantity;
        if (q != null) {
          final d = double.tryParse(q.replaceAll(',', '.').trim());
          if (d != null && d < 0) return 1;
        }
        return 0;
      case TransactionKind.buy:
      case TransactionKind.openingBalance:
      case TransactionKind.dividend:
      case TransactionKind.deposit:
      case TransactionKind.withdrawal:
      case TransactionKind.interest:
      case TransactionKind.charge:
        return 0;
    }
  }

  /// Comparateur chronologique CANONIQUE du rejeu du journal (source unique,
  /// partagée par le moteur de projection et l'export fiscal) :
  ///   `date` croissante
  ///   → RANG entrée/sortie ([_quantityRank]) : au sein d'une même date, les
  ///     ENTRÉES de titres passent AVANT les SORTIES (pas de survente possible
  ///     en comptant/PEA — élimine le clamp parasite quel que soit l'ordre,
  ///     parfois défaillant, du fichier source) ;
  ///   → [importSeq] SI LES DEUX mouvements en portent une (départage FIN et
  ///     stable entre mouvements de MÊME rang/date, préserve l'ordre du fichier
  ///     là où il est exploitable) ;
  ///   → repli [id] croissant (saisies manuelles sans `seq`, ou edge « manuel +
  ///     importé même rang/date »).
  ///
  /// La quantité nette devient exacte (plus de clamp). Pour le cas courant d'un
  /// aller-retour intraday partant à plat, la PV réalisée reste EXACTE (entrées
  /// d'abord). Seule distorsion résiduelle assumée : « détention préalable +
  /// sortie totale + re-entrée le MÊME jour » (base WAC mêlée) — acceptable vu la
  /// granularité JOURNALIÈRE des dates.
  static int compareChronological(AssetTransaction a, AssetTransaction b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final byRank = _quantityRank(a).compareTo(_quantityRank(b));
    if (byRank != 0) return byRank;
    final sa = a.importSeq;
    final sb = b.importSeq;
    if (sa != null && sb != null) {
      final bySeq = sa.compareTo(sb);
      if (bySeq != 0) return bySeq;
    }
    return a.id.compareTo(b.id);
  }

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

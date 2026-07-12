import 'dart:math';

/// Mode de **valorisation** d'un compte (comment on calcule sa valeur) :
/// `cash` = un solde unique · `preciousMetal` = positions métal (poids × cours
/// × prime) · `investment` = positions titres (symbole × cours marché).
///
/// N'est plus stocké ni choisi directement : c'est une **projection dérivée**
/// de [AccountKind] (voir [AccountKindValuation.valuationType]). Conservé car
/// toute la logique de valorisation/agrégation/UI branche dessus.
enum AccountType { investment, cash, preciousMetal }

/// **Nature du compte — axe unique** choisi par l'utilisateur et seul champ
/// stocké. Il porte à la fois la valorisation (dérivée, [valuationType]) et
/// l'enveloppe fiscale du compte. Un seul axe ⇒ aucune incohérence possible
/// (on ne peut pas décrire un « cash en PEA »).
///
/// **Valorisation dérivée :** [cash] → solde ; [preciousMetal] → métal ; tout le
/// reste → titres (positions).
///
/// **Enveloppe fiscale :** [cto] décrit un compte titres ordinaire ;
/// [pea]/[peaPme]/[assuranceVie]/[pee]/[per] et [crypto] identifient des
/// enveloppes à régime propre. Ces natures servent à décrire fidèlement le
/// compte : l'application n'y attache **aucun calcul d'imposition**, elle expose
/// simplement l'enveloppe telle quelle (cf. export documenté). [cash]/
/// [preciousMetal]/[autre] n'ont pas d'enveloppe particulière.
///
/// [autre] = défaut (compte titres sans enveloppe précisée ; rétro-compat des
/// comptes/backups d'avant l'introduction de la nature). Sérialisé via `.name`.
enum AccountKind {
  cto,
  pea,
  peaPme,
  assuranceVie,
  pee,
  per,
  crypto,
  cash,
  preciousMetal,
  autre,
}

extension AccountKindValuation on AccountKind {
  /// Mode de valorisation induit par la nature du compte.
  AccountType get valuationType {
    switch (this) {
      case AccountKind.cash:
        return AccountType.cash;
      case AccountKind.preciousMetal:
        return AccountType.preciousMetal;
      default:
        return AccountType.investment;
    }
  }

  /// Vrai si le compte détient des titres (toute nature hors cash/métaux).
  /// = l'ensemble des natures dont l'enveloppe fiscale est modifiable.
  bool get isSecurities => valuationType == AccountType.investment;
}

class Account {
  final String id;
  final String walletId;
  final String name;

  /// Nature du compte — **source unique** (valorisation + fiscalité dérivées).
  final AccountKind kind;
  final String currency;
  final String? description;
  final DateTime? createdAt;
  final double? cashBalance;

  Account({
    required this.id,
    required this.walletId,
    required this.name,
    required this.kind,
    this.currency = 'EUR',
    this.description,
    this.createdAt,
    this.cashBalance, // Valeur par défaut null
  });

  /// Mode de valorisation, dérivé de [kind]. Non stocké indépendamment → ne
  /// peut pas diverger de la nature (résout la redondance type/enveloppe).
  AccountType get type => kind.valuationType;

  // --- Sérialisation JSON ---

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'] ?? '', // ⭐ Valeur par défaut
      walletId: json['walletId'] ?? '', // ⭐ Valeur par défaut
      name: json['name'] ?? 'Compte sans nom', // ⭐ Valeur par défaut
      kind: _kindFromJson(json),
      currency: json['currency'] ?? 'EUR',
      description: json['description'],
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : null,
      cashBalance: json['cashBalance'] != null ? (json['cashBalance'] as num).toDouble() : null,
    );
  }

  /// Résout la nature depuis le JSON, avec rétro-compatibilité :
  /// - `kind` présent → parsé (valeur inconnue → AUTRE, pas de crash) ;
  /// - sinon backup/DB d'avant `kind` : reconstitué depuis l'ancien `type`
  ///   (`cash`/`preciousMetal`) et, pour un compte titres, l'ancienne
  ///   `fiscalEnvelope` si présente (ses valeurs = noms d'[AccountKind]).
  static AccountKind _kindFromJson(Map<String, dynamic> json) {
    final rawKind = json['kind'];
    if (rawKind != null) {
      return AccountKind.values
          .firstWhere((k) => k.name == rawKind, orElse: () => AccountKind.autre);
    }
    final rawType = json['type'];
    if (rawType == 'cash') return AccountKind.cash;
    if (rawType == 'preciousMetal') return AccountKind.preciousMetal;
    final rawEnv = json['fiscalEnvelope'];
    if (rawEnv != null) {
      return AccountKind.values
          .firstWhere((k) => k.name == rawEnv, orElse: () => AccountKind.autre);
    }
    return AccountKind.autre;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'walletId': walletId,
      'name': name,
      'kind': kind.name,
      'currency': currency,
      'description': description,
      'createdAt': createdAt?.toIso8601String(),
      'cashBalance': cashBalance,
    };
  }

  // Méthode helper pour obtenir le solde total
  double get totalValue {
    if (type == AccountType.cash) {
      return cashBalance ?? 0.0;
    }
    // Pour les comptes investissement, le calcul se fera via les positions
    return 0.0;
  }

  // Méthode pour créer une copie modifiée
  Account copyWith({
    String? id,
    String? walletId,
    String? name,
    AccountKind? kind,
    String? currency,
    String? description,
    DateTime? createdAt,
    double? cashBalance,
  }) {
    return Account(
      id: id ?? this.id,
      walletId: walletId ?? this.walletId,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      currency: currency ?? this.currency,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      cashBalance: cashBalance ?? this.cashBalance,
    );
  }

  static String generateId() {
    // Microsecondes epoch + suffixe aléatoire en base 36 pour éviter les collisions
    // lors de créations simultanées dans la même milliseconde.
    final suffix = Random().nextInt(0x7FFFFFFF).toRadixString(36).padLeft(6, '0');
    return '${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }
}
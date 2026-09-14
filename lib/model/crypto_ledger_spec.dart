// lib/model/crypto_ledger_spec.dart
//
// Squelette DORMANT du profil crypto (chantier B16, conception interne — « le
// profil reste une DONNÉE »). Rien ici n'est encore appelé depuis
// `StatementImportService` ni depuis aucun service : ce fichier pose seulement
// le vocabulaire (enums) et la forme (classe) qu'un futur
// `crypto_ledger_normalizer.dart` (lot 1) implémentera dans des `switch`
// EXHAUSTIFS, sans `default` — même discipline que `CorporateActionKind` dans
// `broker_profile.dart` : le profil déclare un EFFET, jamais une branche de
// code (pas de `Function` ici, ça casserait `const`/`copyWith`).
//
// Un relevé crypto est un GRAND LIVRE de jambes (une ligne = un mouvement
// d'UN actif), là où un relevé de courtier est un JOURNAL D'OPÉRATIONS (une
// ligne = une opération) : c'est cette différence structurelle qui justifie
// un profil dédié, greffé sur `BrokerProfile.crypto` plutôt qu'une refonte
// du profil titres.

import 'package:portfolio_tracker/model/broker_profile.dart';

/// Stratégie de GROUPAGE des jambes d'un relevé crypto en opérations
/// économiques (ex. les deux jambes d'un échange BTC→USDT). Une nature
/// [CryptoLedgerAction.exchangeLeg] n'est JAMAIS traitée isolément : son
/// `kind` final (achat/vente) dépend de sa CONTREPARTIE, connue seulement
/// une fois le groupe reconstitué.
enum LegGroupingStrategy {
  /// Référence d'opération explicite fournie par le relevé (Kraken `refid`)
  /// — la forme la plus simple et la plus fiable : toutes les jambes d'une
  /// même opération partagent EXACTEMENT la même valeur de
  /// [CryptoLedgerSpec.groupKeyColumn].
  operationReference,

  /// Horodatage EXACT (Binance : un trade = un triplet de lignes à la même
  /// seconde). Fenêtre de tolérance : [CryptoLedgerSpec.groupingWindow]
  /// (zéro pour ce format — l'égalité est stricte).
  sameTimestamp,

  /// Appariement par TEXTE LIBRE (Coinbase `Notes`, ex. « Converted X MLN to
  /// Y DAI ») via [CryptoLedgerSpec.counterpartyPattern]. Le plus fragile
  /// des trois (dépendant de la langue de l'export) : un motif qui ne
  /// matche AUCUNE ligne concernée doit produire un message dédié, jamais
  /// 19 rejets muets.
  counterpartyNote,
}

/// Politique d'AGRÉGATION des récompenses ([CryptoLedgerAction.reward]).
/// Les rewards sont, sur les trois plateformes analysées, le type de ligne
/// DOMINANT en volume (60 à 93 %, micro-montants quotidiens/hebdomadaires) —
/// sans agrégation, le journal crypto écraserait le journal titres existant
/// sous un facteur 20.
enum RewardAggregation {
  /// Aucune agrégation : une ligne source = un mouvement journal (profils
  /// sans volumétrie de reward significative, ou étape intermédiaire de
  /// mise au point).
  none,

  /// Une ligne par (actif de base, mois) — clé stable
  /// `agg:compte:profil:code:AAAA-MM`, REMPLACÉE (jamais dupliquée) si le même
  /// mois s'allonge à un ré-import ultérieur (conception interne).
  monthly,
}

/// Effet d'une nature de ligne (`type`/`Operation`/`Transaction Type`…) sur
/// le modèle B* — le vocabulaire crypto, symétrique de
/// [CorporateActionKind] pour les opérations sur titres classiques. Une
/// nature absente de [CryptoLedgerSpec.actions] reste REJETÉE, jamais
/// coercée (même politique que [BrokerProfile.kindLexicon]).
enum CryptoLedgerAction {
  /// Jambe d'un ÉCHANGE (trade/conversion) — sens et contrepartie résolus
  /// UNIQUEMENT au niveau du GROUPE reconstitué (cf. [LegGroupingStrategy]),
  /// jamais ligne à ligne : un `trade` Kraken solitaire n'est ni un achat ni
  /// une vente tant que sa contrepartie n'est pas connue.
  exchangeLeg,

  /// Entrée GRATUITE (staking, intérêts en nature, airdrop…) → `adjustment`
  /// TITRE à coût nul (mécanisme `freeAttribution` existant), AGRÉGÉE selon
  /// [CryptoLedgerSpec.rewards].
  reward,

  /// Entrée de fonds : fiat → `deposit` ; en nature (crypto reçue d'ailleurs
  /// que le marché de la plateforme) → `adjustment` TITRE au cours du jour
  /// (base de coût réelle, l'actif ne vient pas de nulle part).
  depositIn,

  /// Sortie de fonds : fiat → `withdrawal` ; en nature → `transferOut`
  /// (cohérent avec la décision B16 « on-chain hors périmètre » — la
  /// position sort du compte honnêtement, sans prétendre suivre sa vie
  /// ultérieure hors plateforme).
  withdrawalOut,

  /// Mouvement INTERNE à la plateforme (spot↔staking/earn…) : écarté du
  /// journal (aucun mouvement créé) mais comptabilisé dans un BILAN DE
  /// COHÉRENCE par actif de base (conception interne) — un résidu non nul est
  /// signalé, jamais corrigé en silence.
  internalTransfer,

  /// Migration d'actif (ex. `ETH2`→`ETH`, `MATIC`→`POL`) : neutralisée par
  /// l'alias d'identité APPLIQUÉ AVANT le groupage
  /// ([CryptoLedgerSpec.identityAliases]) — les deux jambes de la migration
  /// se retrouvent alors sur la même identité et nettent exactement à 0.
  /// Rien au journal ; la base de coût reste attachée à la position.
  assetMigration,

  /// Ambigu → REJET MOTIVÉ, jamais journalisé automatiquement — miroir
  /// exact de [CorporateActionKind.manualReview].
  manualReview,
}

/// Spécification DÉCLARATIVE d'un relevé crypto (grand livre de jambes),
/// greffée sur [BrokerProfile.crypto]. `null` sur un [BrokerProfile] = profil
/// titres, tout le pipeline crypto est un NO-OP STRICT.
///
/// AUCUNE stratégie n'est implémentée dans cette classe (ni ici, ni appelée
/// depuis `StatementImportService` à ce stade) : c'est le lot 0 du chantier
/// B16, un squelette dormant que le lot 1 (profil Kraken) viendra
/// instrumenter dans `crypto_ledger_normalizer.dart`.
///
/// PAS de constructeur `const` : [RegExp] n'en a pas. Les profils titres
/// `const` existants (ex. [BrokerProfile.bourseDirect]) ne sont pas affectés
/// — [BrokerProfile.crypto] est optionnel, par défaut `null` (constante).
class CryptoLedgerSpec {
  /// Stratégie de reconstitution des opérations à partir des jambes brutes.
  final LegGroupingStrategy grouping;

  /// Colonne portant la clé de groupage quand [grouping] est
  /// [LegGroupingStrategy.operationReference] (ex. `refid` Kraken). `null`
  /// pour les deux autres stratégies (la clé n'est pas une colonne unique).
  final MovementField? groupKeyColumn;

  /// Fenêtre de tolérance temporelle du groupage (ex. ±10 s pour
  /// [LegGroupingStrategy.counterpartyNote] côté Coinbase — les deux jambes
  /// d'une même conversion portent des horodatages proches mais pas
  /// forcément identiques). [Duration.zero] pour une égalité stricte
  /// ([LegGroupingStrategy.sameTimestamp], Binance).
  final Duration groupingWindow;

  /// Motif d'extraction de la contrepartie dans un champ TEXTE LIBRE
  /// (ex. `Notes` Coinbase : « Converted qty TICKER to… ») — groupes
  /// NOMMÉS `qty`/`asset` attendus par le futur appariement. `null` sauf
  /// pour [LegGroupingStrategy.counterpartyNote]. Un échec de correspondance
  /// est un REJET MOTIVÉ, jamais un repli heuristique.
  final RegExp? counterpartyPattern;

  /// Vocabulaire des natures de ligne → effet crypto ([CryptoLedgerAction]).
  /// CLÉ COMPOSITE quand le format a un sous-type : lookup `'type/subtype'`
  /// D'ABORD, repli `'type'` seul ensuite (cas Kraken, voir [subKindColumn]).
  /// Une nature absente reste REJETÉE — jamais coercée (politique B4,
  /// `broker_profile.dart:209`).
  final Map<String, CryptoLedgerAction> actions;

  /// Colonne du sous-type (ex. `subtype` Kraken), formant la clé composite
  /// `'type/subtype'` de [actions] avec [MovementField.kindLabel]. `null` si
  /// le format n'a pas de sous-type (Coinbase, Binance).
  final String? subKindColumn;

  /// Suffixes marquant une variante JALONNÉE d'un actif (ex. `.S` chez
  /// Kraken : `ADA.S`) — repliés sur l'actif de base par
  /// [identityAliases]/logique dédiée AVANT le groupage, pour que les deux
  /// jambes d'une migration/allocation nettent correctement.
  final Set<String> stakedSuffixes;

  /// Alias d'IDENTITÉ (journal), JAMAIS un ticker de cotation : replie les
  /// variantes/migrations sur UNE identité de position (`Asset.ledgerCode`) — ex.
  /// `ADA.S`→`ADA`, `MATIC`→`POL`. Appliqué à l'étape 2bis, AVANT le groupage
  /// (conception interne). Table DISTINCTE de [quoteAliases] : répliquer un alias
  /// d'identité sur le ticker de cotation peut CASSER la cotation (`MATIC-EUR`
  /// existe, `POL-EUR` non — conception interne).
  final Map<String, String> identityAliases;

  /// Alias de COTATION : associe une identité à un ticker de MARCHÉ
  /// (`Asset.symbol`, ex. `POL`→`POL-USD`). Table DISTINCTE de
  /// [identityAliases] — voir sa doc pour le piège qui impose cette
  /// séparation (conception interne).
  final Map<String, String> quoteAliases;

  /// Colonne CLASSIFIANT chaque actif (ex. `subclass` Kraken : `fiat`,
  /// `stable_coin`, `crypto`…) — reconnaissance FOURNIE par le fichier,
  /// préférée à une liste codée en dur qui vieillirait à chaque nouveau
  /// stablecoin. `null` si le format n'expose pas ce classifieur : repli sur
  /// [fiatAssets]/[stableAssets]. Colonne DÉSIGNÉE PAR NOM (comme
  /// [walletColumn]/[balanceColumn]), PAS [MovementField] : cette notion n'a
  /// pas de correspondant dans le vocabulaire titre et n'en aura pas.
  final String? assetClassColumn;

  /// Repli de classification FIAT quand [assetClassColumn] est `null` ou
  /// muet pour un actif donné (ex. `{'EUR', 'USD'}`).
  final Set<String> fiatAssets;

  /// Repli de classification STABLECOIN, même rôle que [fiatAssets] pour les
  /// stables (ex. `{'USDC', 'USDT'}`).
  final Set<String> stableAssets;

  /// Colonne du PORTEFEUILLE/wallet d'origine (ex. `wallet` Kraken :
  /// `spot/main`, `earn/flexible`…), propre au grand livre — absente de
  /// [MovementField], mappée par NOM directement. `null` si le format n'a
  /// pas cette notion (Binance : tout est `Spot`).
  final String? walletColumn;

  /// Colonne du SOLDE COURANT par (actif, wallet) — oracle de validation d'un
  /// rejeu (conception interne : Kraken `balance`). `null` si le format n'en
  /// fournit pas (Coinbase, Binance — pas d'oracle, garde de complétude
  /// absente de l'aperçu pour ces profils).
  final String? balanceColumn;

  /// Colonnes DISCRIMINANTES du format : leur absence globale déclenche un REFUS
  /// D'IMPORT motivé plutôt qu'un import dégradé (ex. Kraken : un export au format
  /// antérieur, sans `wallet`/`subclass`/`amountusd`, a une sémantique
  /// incompatible avec le modèle de valorisation — conception interne).
  final Set<String> requiredColumns;

  /// Politique d'agrégation des récompenses pour ce profil.
  final RewardAggregation rewards;

  /// Colonne de VALORISATION fournie par le relevé pour les échanges sans jambe
  /// fiat (ex. `amountusd` Kraken, `Subtotal` Coinbase) — cœur du modèle (b) «
  /// valorisation fichier-d'abord » (conception interne). `null` = fichier MUET
  /// (Binance) : repli sur les cours historiques en-app (lot 4), jamais sur ce
  /// lot. Colonne DÉSIGNÉE PAR NOM (comme [walletColumn]/[balanceColumn]), PAS
  /// [MovementField] : cette notion n'a pas de correspondant dans le vocabulaire
  /// titre et n'en aura pas.
  final String? valuationAmountColumn;

  /// Devise de [valuationAmountColumn] (`'USD'` pour les trois plateformes
  /// analysées) — sert à sourcer le taux de change historique vers EUR.
  final String valuationCurrency;

  /// Écart relatif maximal toléré entre les deux valorisations USD des jambes
  /// d'un même échange (conception interne : jamais identiques, médiane 0,64 %)
  /// avant bascule en arbitrage manuel — défaut recommandé `0.10` (10 %, cf.
  /// §5.7 q.3).
  final double maxLegValuationSpread;

  CryptoLedgerSpec({
    required this.grouping,
    this.groupKeyColumn,
    this.groupingWindow = Duration.zero,
    this.counterpartyPattern,
    this.actions = const {},
    this.subKindColumn,
    this.stakedSuffixes = const {},
    this.identityAliases = const {},
    this.quoteAliases = const {},
    this.assetClassColumn,
    this.fiatAssets = const {},
    this.stableAssets = const {},
    this.walletColumn,
    this.balanceColumn,
    this.requiredColumns = const {},
    this.rewards = RewardAggregation.none,
    this.valuationAmountColumn,
    this.valuationCurrency = 'USD',
    this.maxLegValuationSpread = 0.10,
  });
}

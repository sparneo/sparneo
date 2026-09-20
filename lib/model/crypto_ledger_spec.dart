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

  /// Horodatage EXACT (Binance, chantier B16 lot 4 — conception interne) : un
  /// relevé SANS référence d'opération ni oracle de solde (un trade = un triplet
  /// de lignes à la même seconde), où un mouvement composite (trade, conversion)
  /// se reconnaît uniquement à ce que plusieurs jambes partagent la MÊME seconde.
  /// Bucket = valeur exacte de `_Leg.preciseDate` —
  /// [CryptoLedgerSpec.groupingWindow] reste [Duration.zero] pour cette stratégie
  /// (élargir la fenêtre agrégerait des ordres distincts, conception interne). Les
  /// jambes dont [CryptoLedgerSpec.remarkPairedKindLabels] contient le `kindLabel`
  /// sont SOUSTRAITES de ce bucketing brut et appariées séparément par texte libre
  /// (même mécanisme que [counterpartyNote] ci-dessous, Small Assets Exchange BNB)
  /// — voir la doc de ce champ.
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

  /// Achat fiat→crypto (chantier B16 lot 3, conception interne — Coinbase `Buy`) :
  /// ligne UNIQUE portant À LA FOIS la quantité crypto ([MovementField.quantity])
  /// et un montant de valorisation ([MovementField.amount], devise
  /// [MovementField.currency]) — contrairement à [exchangeLeg] (deux jambes
  /// séparées à réunir), tout est déjà sur la même ligne. Traité par
  /// `CryptoLedgerNormalizer. _processFiatTrade`, SOUS LA GARDE « Price Currency »
  /// : chemin fiat direct (`buy`, cash pris tel quel) si la devise de valorisation
  /// est celle DU COMPTE, cascade de valorisation (comme un échange à jambe fiat
  /// étrangère, étage 1-quater) sinon. Distinct de [fiatSell] (plutôt que
  /// sign-checké comme `deposit`/`withdrawal`) : la nature EST déjà la direction,
  /// sans lecture de signe — la quantité crypto d'une ligne `Buy`/`Sell` Coinbase
  /// est toujours positive, un signe n'aurait rien à valider.
  fiatBuy,

  /// Vente crypto→fiat, symétrique exact de [fiatBuy] (Coinbase `Sell`).
  fiatSell,

  /// Ambigu → REJET MOTIVÉ, jamais journalisé automatiquement — miroir
  /// exact de [CorporateActionKind.manualReview].
  manualReview,
}

/// Redirection DÉCLARATIVE de l'action d'une ligne selon la valeur d'une colonne
/// ANNEXE du relevé (chantier B16 lot 3, conception interne — Coinbase : un
/// `Receive` dont `Sender Address` vaut littéralement `Coinbase Earn` est une
/// récompense de staking, pas un dépôt en nature ordinaire, décision auteur §5.7
/// q.4). Une DONNÉE (colonne/valeur/action cible), JAMAIS une closure — même
/// discipline que le reste de ce fichier (« le profil déclare un EFFET, jamais
/// une branche de code »).
///
/// Consommée par `CryptoLedgerNormalizer._resolveAction` : APRÈS résolution
/// de l'action normale (composite `type/subtype` ou repli `type`), pour les
/// lignes dont [kindLabel] coïncide ET dont la cellule [matchColumn]
/// (comparaison EXACTE après `trim`, SENSIBLE À LA CASSE — un identifiant de
/// service n'est jamais une saisie libre à normaliser) vaut [matchValue],
/// [action] REMPLACE le résultat normal. Sans effet sur les autres lignes du
/// même [kindLabel] dont la colonne ne matche pas (elles suivent
/// [CryptoLedgerSpec.actions] normalement) ni si [matchColumn] est absente
/// du fichier (`null` silencieux, jamais un plantage — B4).
class ConditionalActionRedirect {
  /// Type BRUT visé (`_Leg.kindLabel`, ex. `'Receive'`).
  final String kindLabel;

  /// Colonne ANNEXE à consulter, désignée PAR NOM (comme
  /// [CryptoLedgerSpec.walletColumn]) — pas un [MovementField].
  final String matchColumn;

  /// Valeur EXACTE attendue dans [matchColumn] pour déclencher la
  /// redirection.
  final String matchValue;

  /// Action appliquée quand [matchColumn] vaut [matchValue].
  final CryptoLedgerAction action;

  const ConditionalActionRedirect({
    required this.kindLabel,
    required this.matchColumn,
    required this.matchValue,
    required this.action,
  });
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

  /// Colonne TEXTE LIBRE portant la note à faire matcher par
  /// [counterpartyPattern] (ex. `Notes` Coinbase), désignée PAR NOM (comme
  /// [walletColumn]) — pas un [MovementField] (aucun équivalent titre).
  /// `null` sauf pour [LegGroupingStrategy.counterpartyNote].
  final String? notesColumn;

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
  /// (`Asset.symbol`, ex. `POL`→`POL28321-USD`). Table DISTINCTE de
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
  ///
  /// GARDE « Price Currency » (B-2, revue adversariale, chantier B16 lot 3) :
  /// dès qu'un profil mappe [MovementField.currency], `CryptoLedgerNormalizer.
  /// planCryptoImport` compare CETTE cellule à [valuationCurrency] et annule
  /// `leg.valuationUsd` en cas de désaccord — la garde suppose donc que
  /// [MovementField.currency], PARTOUT où un profil le mappe, désigne bien la
  /// devise de [valuationAmountColumn] sur CETTE ligne (le cas Coinbase,
  /// `Price Currency`). Un futur profil qui mapperait [MovementField.currency]
  /// à un AUTRE usage (ex. devise de RÈGLEMENT, sans lien avec la colonne de
  /// valorisation) verrait ses valorisations silencieusement annulées par
  /// cette même garde — vérifier cette hypothèse avant de réutiliser ce champ
  /// pour un nouveau profil crypto.
  final String valuationCurrency;

  /// Écart relatif maximal toléré entre les deux valorisations USD des jambes
  /// d'un même échange (conception interne : jamais identiques, médiane 0,64 %)
  /// avant bascule en arbitrage manuel — défaut recommandé `0.10` (10 %, cf.
  /// §5.7 q.3).
  final double maxLegValuationSpread;

  /// Codes stablecoin dollar de CONFIANCE pour l'étage 1-ter « jambe stablecoin »
  /// du moteur de valorisation (amendement drive lot 2 — décision d'orchestration
  /// mesurée sur le réel : 22 des 27 cas en écart excessif du drive manuel
  /// portaient une jambe USDT/USDC). Une TABLE DÉCLARÉE PAR PROFIL, jamais une
  /// heuristique par nom (« se termine en USDx ») : un stablecoin qui a perdu son
  /// ancrage (ex. `UST`/`USTC`, séquelle Terra déjà gérée par [identityAliases])
  /// n'y entre JAMAIS — ce serait valoriser un échange sur la foi d'une quantité
  /// qui ne vaut plus 1 USD. Codes APRÈS alias (même convention que
  /// [UnvaluedExchange. codePaid]/[codeReceived]). Vide par défaut (repli neutre,
  /// aucun effet sur un profil qui ne renseigne pas ce champ). Kraken : `{'USDT',
  /// 'USDC'}`.
  final Set<String> usdStableCodes;

  /// Natures de ligne dont le TYPE fixe DÉJÀ la direction sans ambiguïté —
  /// clé = libellé brut (`_Leg.kindLabel`), valeur = signe ATTENDU (`true` =
  /// positif/entrant). Consommé par `CryptoLedgerNormalizer.
  /// _processDepositOrWithdrawal` (site ~1030) : une nature présente ICI dont
  /// le signe net contredit la valeur déclarée est un REJET MOTIVÉ
  /// (`cryptoAmbiguousDirection`), jamais une réinterprétation silencieuse —
  /// une nature ABSENTE de cette table (ex. les codes `transfer*` Kraken,
  /// redirigés par SIGNE) n'est jamais soumise à ce contrôle. Vide par
  /// défaut (repli neutre : aucune nature n'est considérée non-ambiguë).
  /// Kraken : `{'deposit': true, 'withdrawal': false}`.
  final Map<String, bool> signFixedKinds;

  /// Natures de ligne SOURCE dont une entrée en nature EST un VRAI apport EXTERNE de
  /// l'utilisateur (dépôt on-chain, crédit type airdrop…) — consommé par
  /// `CryptoLedgerNormalizer.finalizeCryptoExchanges` (site ~795, via
  /// `UnvaluedExchange.sourceKindLabel`) pour décider de poser
  /// `meta['inKindDeposit']` (conception interne, drive B16, « Problème 1 »). Une
  /// nature ABSENTE reste une écriture INTERNE de plateforme (le mouvement
  /// `adjustment` est journalisé identiquement, seule la puce « Dépôt » du journal
  /// l'ignore). Kraken : `{'deposit', 'receive'}` — noter que `receive` N'EST PAS
  /// dans [signFixedKinds] : les deux tables ne coïncident PAS (l'y ajouter serait
  /// un changement de comportement, hors périmètre de ce refactor). Vide par défaut
  /// (repli neutre).
  final Set<String> externalDepositKinds;

  /// Natures de ligne SOURCE dont une sortie en nature EST un VRAI retrait vers un
  /// wallet externe — consommé par `CryptoLedgerNormalizer.
  /// _processDepositOrWithdrawal` (site ~1133, via `leg.kindLabel`) pour décider de
  /// poser `meta['inKindWithdrawal']` (conception interne, retour auteur,
  /// symétrique exact d'[externalDepositKinds] côté sortie). Une nature ABSENTE
  /// reste une écriture INTERNE de plateforme (le mouvement `transferOut` est
  /// journalisé identiquement, seule la puce « Retrait » du journal l'ignore).
  /// Kraken : `{'withdrawal'}`. Vide par défaut (repli neutre).
  ///
  /// NOTE (unification future possible) : [externalDepositKinds] et ce champ
  /// ne sont PAS fusionnés en une seule structure bidirectionnelle malgré la
  /// tentation — Kraken n'a par exemple aucun symétrique retrait de
  /// `receive`, et rien ne garantit qu'un futur profil garde cette symétrie.
  /// Une fusion reste envisageable le jour où au moins deux profils
  /// confirment la même forme, pas avant.
  final Set<String> externalWithdrawalKinds;

  /// Redirections déclaratives d'action pilotées par une colonne annexe (cf.
  /// [ConditionalActionRedirect]) — vide par défaut (repli neutre, aucun
  /// effet sur un profil qui n'en déclare pas).
  final List<ConditionalActionRedirect> conditionalActionRedirects;

  /// `kindLabel` des jambes de FRAIS au sein d'un groupe
  /// [LegGroupingStrategy.sameTimestamp] (Binance, chantier B16 lot 4, conception
  /// interne — ex. `'Transaction Fee'`) — DISTINCT du rôle payé/reçu (déduit du
  /// SIGNE net, jamais du libellé) : une jambe de frais n'est ni l'un ni l'autre,
  /// elle est retirée des jambes « ordinaires » AVANT que `CryptoLedgerNormalizer`
  /// cherche la paire payée/reçue d'un groupe.
  ///
  /// PLUSIEURS jambes de frais RÉDUITES par groupe sont LÉGITIMES (B-1, revue
  /// adversariale, CORRECTIF — une jambe de frais n'est PAS un « rôle » au sens de
  /// la garde d'ambiguïté du groupage, conception interne : « deux Coin distincts
  /// dans un même RÔLE ») : `CryptoLedgerNormalizer. _processBinanceExchangeGroup`
  /// boucle sur CHACUNE, indépendamment, appliquant les mêmes trois issues selon
  /// l'actif de CETTE jambe (jamais une somme entre elles) : absorbée dans la
  /// quantité de la jambe payée/ reçue qui partage son actif (comme Kraken, frais
  /// en nature) ; ou, si son actif est TIERS aux deux jambes du groupe (cas
  /// MAJORITAIRE mesuré, BNB — N17), consommation séparée valorisée en
  /// `sell`+`charge` liés par `meta.feeForGroup` (voir
  /// `UnvaluedExchange.feeForGroup`), la clé de cette entrée étant SUFFIXÉE par
  /// l'actif de frais (`#fee:<actif>`) pour rester DISTINCTE d'une éventuelle autre
  /// jambe de frais tierce du même groupe. LIMITE NOTÉE (documentée, pas codée —
  /// inatteignable sur ce profil) : deux `kindLabel` de frais DISTINCTS portant le
  /// MÊME actif tiers produiraient deux entrées à la clé `#fee:<actif>` IDENTIQUE —
  /// Binance n'a qu'un seul libellé de frais (`'Transaction Fee'`), ce cas ne peut
  /// pas se produire sur ce profil ; s'il se produisait malgré tout, la garde B-1
  /// pré-existante de `CryptoValuationService.resolve` (clé de dédup partagée par ≥
  /// 2 entrées → `ambiguousGroup`) neutralise la collision sans jamais fabriquer
  /// une valorisation erronée. Vide par défaut (repli neutre, aucun effet sur
  /// Kraken/Coinbase — dont les frais vivent dans une COLONNE `fee` de la jambe
  /// elle-même, jamais une ligne à part).
  final Set<String> feeLegKindLabels;

  /// `kindLabel` des jambes dont la CONTREPARTIE se résout par appariement TEXTE
  /// LIBRE (même mécanisme que [LegGroupingStrategy.counterpartyNote], réutilisant
  /// [notesColumn]/[counterpartyPattern]/[groupingWindow]) MÊME SOUS UNE STRATÉGIE
  /// DE GROUPAGE GLOBALE DIFFÉRENTE — Binance, chantier B16 lot 4, conception
  /// interne : `grouping` vaut [LegGroupingStrategy.sameTimestamp] PARTOUT, SAUF
  /// `Small Assets Exchange BNB` (micro-conversions de poussières vers BNB,
  /// appariées par la colonne `Remark`, ex. `"<COIN> to BNB"`) qui s'apparie par
  /// ce texte — le bucketing par horodatage exact fusionnerait à tort TOUTES les
  /// micro-conversions d'un même lot (jusqu'à 44 lignes mesurées) en un seul
  /// groupe N→1 sans pouvoir répartir la quantité BNB reçue entre les actifs cédés
  /// (aucune colonne de valorisation Binance pour une prorata, N17/ §5.4.1). Une
  /// jambe de ce `kindLabel` SANS texte exploitable (Remark absent/vide, ou
  /// appariement non 1-1) est un REJET MOTIVÉ individuel
  /// (`smallAssetsExchangeUnpaired`), jamais une prorata devinée — écart documenté
  /// dans la conception interne (« repli prorata »), consigné SANS trancher
  /// (aucune colonne de poids fiable n'existe côté Binance pour la reconstituer).
  /// Vide par défaut (repli neutre, aucun effet sur Kraken/Coinbase).
  final Set<String> remarkPairedKindLabels;

  CryptoLedgerSpec({
    required this.grouping,
    this.groupKeyColumn,
    this.groupingWindow = Duration.zero,
    this.counterpartyPattern,
    this.notesColumn,
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
    this.feeLegKindLabels = const {},
    this.remarkPairedKindLabels = const {},
    this.maxLegValuationSpread = 0.10,
    this.usdStableCodes = const {},
    this.signFixedKinds = const {},
    this.externalDepositKinds = const {},
    this.externalWithdrawalKinds = const {},
    this.conditionalActionRedirects = const [],
  });
}

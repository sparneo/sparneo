// lib/model/broker_profile.dart
//
// Description DÉCLARATIVE d'un format de relevé courtier : un `BrokerProfile`
// est une DONNÉE (délimiteur/format de fichier, encodage, format de
// date/décimal, mapping de colonnes, vocabulaire des natures d'opération),
// jamais une branche de code. Un profil nommé (courtier précis) n'est qu'une
// instance pré-remplie de cette même classe — cf. `BrokerProfile.
// bourseDirect` pour un exemple, à côté du profil « générique / manuel » où
// l'utilisateur mappe lui-même chaque colonne de son fichier.

import 'dart:convert';

import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/crypto_ledger_spec.dart';

/// Spécification du format de date d'un relevé (ordre jour/mois/année et
/// séparateur). Les relevés français utilisent très majoritairement
/// `JJ/MM/AAAA` (défaut) ; [dayFirst] à `false` couvre le format `MM/JJ/AAAA`
/// (US) pour un profil futur.
class DateFormatSpec {
  final String separator;
  final bool dayFirst;

  /// `true` = année sur 4 chiffres (défaut). `false` = année sur 2 chiffres,
  /// interprétée comme `20xx` (pas de relevé réaliste sous 2000).
  final bool fourDigitYear;

  /// `true` : date compacte SANS séparateur `AAAAMMJJ` (ex. `20150127`, format
  /// Bourse Direct). Dans ce cas [separator]/[dayFirst]/[fourDigitYear] sont
  /// ignorés par le parsing (cf. `StatementImportService._parseDate`).
  final bool compactYmd;

  /// `true` : date SÉPARÉE « année d'abord » `AAAA<sep>MM<sep>JJ` (ex. `2024-03-12`,
  /// format des trois relevés crypto Kraken/Coinbase/Binance — conception interne).
  /// Défaut `false` (comportement historique jour/mois inchangé). PRÉCÉDENCE :
  /// `compactYmd` > [yearFirst] > [dayFirst] — un format compact ignore ce champ
  /// (aucun séparateur à ordonner) ; sans [compactYmd], [yearFirst] prime sur
  /// [dayFirst] quand les deux sont renseignés (ne devrait pas arriver en pratique,
  /// mais lève l'ambiguïté).
  final bool yearFirst;

  const DateFormatSpec({
    this.separator = '/',
    this.dayFirst = true,
    this.fourDigitYear = true,
    this.compactYmd = false,
    this.yearFirst = false,
  });
}

/// Format de fichier d'un relevé : détermine comment [StatementImportService.
/// parse] décode les [bytes] en lignes, indépendamment du mapping de colonnes
/// (identique dans les deux cas).
enum StatementFileFormat {
  /// Texte délimité (`;`, `,`…), décodé selon [BrokerProfile.encoding].
  csv,

  /// Classeur Office Open XML (`.xlsx`) : lu via une extraction ZIP + XML
  /// minimale (cf. `StatementImportService._parseXlsx`), sans dépendance à
  /// l'encodage/délimiteur du profil (ignorés pour ce format).
  xlsx,
}

/// Séparateur décimal utilisé par les nombres d'un relevé.
enum DecimalSeparator {
  comma(','),
  dot('.');

  final String symbol;
  const DecimalSeparator(this.symbol);
}

/// Champs cibles qu'une colonne source peut alimenter lors de la
/// normalisation d'une ligne de relevé en mouvement.
enum MovementField {
  /// Date de négociation (jamais la date de règlement — cf. normalisation).
  date,

  /// Libellé brut de la nature d'opération (« Achat », « Dividende »…),
  /// résolu en [TransactionKind] via [BrokerProfile.kindLexicon].
  kindLabel,

  /// Code ISIN de l'instrument, si le relevé le fournit.
  isin,

  /// Symbole déjà connu (mappé directement par l'utilisateur, sans passer par
  /// une résolution ISIN → symbole).
  symbol,

  /// Libellé de l'instrument (nom affiché sur le relevé).
  label,

  quantity,
  unitPrice,
  fee,

  /// Montant net de l'opération, tel que fourni par le relevé (sera resigné
  /// selon la convention de [TransactionKind] à la normalisation).
  amount,

  /// Devise de COTATION de l'instrument (quantity/unitPrice/fee). Absente ⇒
  /// devise du compte par défaut (MVP mono-devise).
  currency,

  /// Retenue à la source éventuelle sur un dividende (stockée en
  /// `meta.tax`, purement informative).
  tax,

  /// Référence d'opération du courtier (n° d'ordre), si présente — clé de
  /// déduplication idéale quand elle est disponible (cf.
  /// [StatementImportService]).
  operationReference,

  /// SENS ESPÈCES du mouvement (débit/crédit), quand le relevé l'expose de façon
  /// FIABLE (ex. colonne `SensEsp` de Bourse Direct : `D` = débit/sortie, `C` =
  /// crédit/entrée). Utilisé UNIQUEMENT pour signer les mouvements de CASH dont
  /// le kind seul ne fixe pas la direction (régularisations / OST espèces, cf.
  /// [CorporateActionKind.cashRegularization]) — les kinds standard
  /// (buy/sell/deposit/withdrawal/charge/dividend) tirent toujours leur signe du
  /// kind, jamais de cette colonne. Ne PAS confondre avec un éventuel « sens
  /// titre » (dupliqué/inexploitable sur ce format).
  cashDirection,
}

/// Correspondance colonne source → champ cible d'un mouvement. Une colonne
/// peut être désignée par INDEX (position dans la ligne, prioritaire) ou par
/// NOM (résolu contre la ligne d'en-tête si le profil en a une).
class ColumnMapping {
  final Map<MovementField, int> byIndex;
  final Map<MovementField, String> byName;

  const ColumnMapping({
    this.byIndex = const {},
    this.byName = const {},
  });
}

/// Traitement d'une OPÉRATION SUR TITRES (corporate action) d'un relevé, au-delà
/// du simple mapping libellé → [TransactionKind]. Décrit l'EFFET exact attendu
/// sur le modèle B* (quantité / PRU / plus-value réalisée / cash). Un code
/// présent dans [BrokerProfile.corporateActions] est traité selon cette valeur,
/// PRIORITAIREMENT au [BrokerProfile.kindLexicon] (natures d'opération simples).
///
/// Le sens (entrée/sortie de titres) est toujours déduit du CODE d'opération —
/// jamais des colonnes de sens (`SensTit`/`SensEsp`), ambiguës/dupliquées sur ce
/// format.
enum CorporateActionKind {
  /// Sortie de titres par TRANSFERT (ex. PEA→CTO, virement de titres sortant),
  /// PAS une cession de marché. → [TransactionKind.transferOut] : réduit la
  /// quantité au PRU courant, AUCUNE plus-value réalisée, AUCUN cash.
  transferOut,

  /// Attribution GRATUITE de titres (entrants). → [TransactionKind.adjustment]
  /// TITRE, quantité `+N`, `unitPrice` FORCÉ nul (coût 0 → baisse le PRU),
  /// aucun cash.
  freeAttribution,

  /// Rompus (fractions issues d'attribution/split) rachetés EN CASH. S'apparente
  /// à une petite vente → [TransactionKind.sell] : réduit la quantité (fraction)
  /// et crédite le cash du `Net` (petite plus-value réalisée admise).
  fractionalRedemption,

  /// Changement de place de cotation : mêmes titres, nouvelle place (paire
  /// out/in). L'identité d'un actif étant l'ISIN→symbole (indépendante de la
  /// place), le traitement le plus sûr est QUANTITÉ-NEUTRE (no-op) : un
  /// [TransactionKind.adjustment] TITRE à quantité FORCÉE `0` — aucune PV, aucun
  /// cash — qui laisse une trace au journal sans jamais altérer la position.
  placeChange,

  /// Opération AMBIGUË à revoir manuellement (ex. détachement de droit de
  /// souscription `DS`, qui interagit avec une souscription ultérieure) : REJET
  /// motivé, jamais journalisée automatiquement — ne casse pas le PRU du
  /// sous-jacent.
  manualReview,

  /// Mouvement de CASH PUR dont le kind seul ne fixe pas la direction, et dont
  /// un éventuel ISIN n'est qu'une RÉFÉRENCE (le titre concerné), jamais la
  /// position touchée — exactement comme la TTF (`ODTTF`) porte l'ISIN du titre
  /// taxé tout en restant un frais espèces. Couvre les régularisations PEA
  /// (`PEAMI` : remboursement/indemnisation en espèces d'un titre éjecté) et les
  /// OST espèces (`ODOST` : paiement de souscription, les titres arrivant via une
  /// ligne `SOUSC` distincte). → [TransactionKind.adjustment] ESPÈCES (`symbol`
  /// null) ; JAMAIS de rejet sur l'ISIN. Le `Net` étant NON SIGNÉ, le SIGNE
  /// dérive de [MovementField.cashDirection] (`SensEsp` : `D` → −, `C`/défaut →
  /// +).
  cashRegularization,

  /// Récompense de STAKING/EARN crypto (chantier B16, conception interne) — effet
  /// identique à [freeAttribution] (`adjustment` TITRE, `unitPrice` FORCÉ nul, aucun
  /// cash), mais affiché sous un libellé distinct (« Récompense de staking » plutôt
  /// que « Attribution gratuite »), exactement la leçon de la conception interne : ne
  /// jamais faire porter à un libellé générique deux réalités économiques différentes.
  /// Persisté UNIQUEMENT comme `meta['corporateAction'] = 'stakingReward'` (String),
  /// écrit DIRECTEMENT par `CryptoLedgerNormalizer` (agrégation mensuelle, §5.1.8) —
  /// ce code n'est JAMAIS atteint via un [BrokerProfile.corporateActions] (aucun
  /// profil ne mappe de libellé dessus) : le cas existe ici pour que le `switch`
  /// EXHAUSTIF de `StatementImportService._normalizeCorporateAction` reste exhaustif
  /// ET documente l'effet attendu, au cas où un futur profil titres voudrait un jour
  /// l'utiliser directement.
  stakingReward,
}

/// Profil de relevé courtier : délimiteur, encodage, formats numérique/date,
/// mapping de colonnes et lexique des natures d'opération.
class BrokerProfile {
  final String id;
  final String label;
  final String delimiter;
  final Encoding encoding;

  /// `true` si la première ligne du fichier est une ligne d'en-tête (noms de
  /// colonnes) plutôt qu'une ligne de données.
  final bool hasHeaderRow;

  /// Format de fichier (voir [StatementFileFormat]). `csv` par défaut —
  /// [delimiter]/[encoding] ne s'appliquent qu'à ce format.
  final StatementFileFormat format;

  /// Si non nul : la ligne d'en-tête n'est pas forcément la première ligne du
  /// fichier (ex. une ligne de titre au-dessus, cas de l'export « Extraction
  /// de compte » Bourse Direct) — [StatementImportService.parse] recherche la
  /// première ligne contenant une cellule égale (trim, insensible à la casse)
  /// à ce nom de colonne, et ignore tout ce qui la précède. Sans effet si
  /// `null` (comportement historique : la ligne d'en-tête, si elle existe,
  /// est la première du fichier).
  final String? headerDetectionColumn;

  final DateFormatSpec dateFormat;
  final DecimalSeparator decimalSeparator;
  final ColumnMapping columns;

  /// Vocabulaire courtier → nature d'opération (ex. « Achat » → [buy],
  /// « Dividende » → [dividend]). Un libellé absent de ce lexique fait
  /// REJETER la ligne à la normalisation — jamais de coercition en [buy].
  final Map<String, TransactionKind> kindLexicon;

  /// Vocabulaire courtier → OPÉRATION SUR TITRES (corporate action), consulté
  /// PRIORITAIREMENT au [kindLexicon] à la normalisation (cf.
  /// [CorporateActionKind]). Vide par défaut (profils sans opérations sur titres
  /// spécifiques). Un code présent ici mais absent du lexique simple est traité
  /// selon son effet ; un code absent des DEUX reste REJETÉ (jamais coercé).
  final Map<String, CorporateActionKind> corporateActions;

  /// Spécification du GRAND LIVRE crypto (chantier B16, conception interne) —
  /// `null` (défaut, TOUS les profils actuels) = profil titres, le pipeline crypto
  /// de `StatementImportService` est un NO-OP STRICT. Squelette DORMANT au lot 0 :
  /// aucune stratégie de [CryptoLedgerSpec] n'est encore implémentée. `RegExp`
  /// n'étant pas `const`, [CryptoLedgerSpec] n'a pas de constructeur `const` — sans
  /// effet sur les profils `const` existants (ex. [bourseDirect]) puisque ce champ
  /// garde sa valeur par défaut `null`, elle-même constante.
  final CryptoLedgerSpec? crypto;

  const BrokerProfile({
    required this.id,
    required this.label,
    required this.delimiter,
    required this.encoding,
    this.hasHeaderRow = true,
    this.format = StatementFileFormat.csv,
    this.headerDetectionColumn,
    required this.dateFormat,
    required this.decimalSeparator,
    required this.columns,
    required this.kindLexicon,
    this.corporateActions = const {},
    this.crypto,
  });

  /// Profil « Générique / manuel » (MVP, seul profil livré) : l'utilisateur
  /// mappe lui-même chaque colonne de son fichier et choisit le vocabulaire de
  /// natures d'opération. Les valeurs par défaut (`;`, Latin-1, virgule
  /// décimale, `JJ/MM/AAAA`) couvrent le triplet le plus fréquent des exports
  /// bancaires français ; l'utilisateur les ajuste depuis l'écran d'import
  /// (aperçu des premières lignes) avant de confirmer le mapping.
  factory BrokerProfile.genericManual({
    String delimiter = ';',
    Encoding encoding = latin1,
    bool hasHeaderRow = true,
    DateFormatSpec dateFormat = const DateFormatSpec(),
    DecimalSeparator decimalSeparator = DecimalSeparator.comma,
    required ColumnMapping columns,
    required Map<String, TransactionKind> kindLexicon,
  }) {
    return BrokerProfile(
      id: 'generic-manual',
      label: 'Générique / manuel',
      delimiter: delimiter,
      encoding: encoding,
      hasHeaderRow: hasHeaderRow,
      dateFormat: dateFormat,
      decimalSeparator: decimalSeparator,
      columns: columns,
      kindLexicon: kindLexicon,
    );
  }

  /// Profil « Bourse Direct », pré-rempli à partir de l'export « Extraction de
  /// compte » (`.xlsx`) : ligne d'en-tête repérée par la présence de
  /// `CodeOperation` (une ligne de titre la précède), colonnes mappées par NOM
  /// (résistant à un éventuel réordonnancement de colonnes par le courtier),
  /// date compacte `AAAAMMJJ`, décimale point (la lecture `.xlsx` canonise
  /// déjà tout nombre en notation point — cf.
  /// `StatementImportService._parseXlsx`). Montants (`Net`) fournis NON
  /// SIGNÉS par le courtier : le signe est déduit du [kindLexicon] par
  /// `StatementImportService.normalize`, jamais ré-inféré ici.
  ///
  /// OPÉRATIONS SUR TITRES (corporate actions) : traitées via
  /// [corporateActions] selon leur effet réel sur le modèle (cf.
  /// [CorporateActionKind]) plutôt que rejetées en bloc —
  ///   - `RTFIS` / `VRSOR` → sortie de titres SANS cession (transfert) ;
  ///   - `ATTRI` → attribution gratuite (coût 0) ;
  ///   - `ODRMP` → rompus rachetés en cash (petite vente) ;
  ///   - `CHGPL` → changement de place (quantité-neutre) ;
  ///   - `DS` → détachement de droit (ambigu, à revoir) ;
  ///   - `PEAMI` / `ODOST` → cash PUR (l'ISIN n'est qu'une référence, jamais
  ///     rejeté ; signe via `SensEsp`) : régularisation PEA / OST espèces.
  /// `VRSOR` était auparavant mappé à tort sur `withdrawal` (retrait
  /// d'ESPÈCES) : c'est une sortie de TITRES — corrigé ici. `ODOST` était mappé
  /// sur `dividend` (cash ENTRANT) alors que `SensEsp=D` = paiement de
  /// souscription SORTANT — corrigé ici. Tout autre code reste REJETÉ.
  factory BrokerProfile.bourseDirect() {
    return const BrokerProfile(
      id: 'bourse-direct',
      label: 'Bourse Direct',
      delimiter: ';', // sans effet en xlsx, conservé pour cohérence du modèle
      encoding: utf8, // idem
      hasHeaderRow: true,
      format: StatementFileFormat.xlsx,
      headerDetectionColumn: 'CodeOperation',
      dateFormat: DateFormatSpec(compactYmd: true),
      decimalSeparator: DecimalSeparator.dot,
      columns: ColumnMapping(byName: {
        MovementField.date: 'DateOperation',
        MovementField.kindLabel: 'CodeOperation',
        // Libellé de la valeur (nom lisible de la position), utilisé comme
        // `Asset.name` à la création — sinon le nom retomberait sur l'ISIN.
        MovementField.label: 'libelleMouvement',
        MovementField.isin: 'isin',
        MovementField.quantity: 'Quantite',
        MovementField.unitPrice: 'cours',
        MovementField.fee: 'Courtage',
        MovementField.amount: 'Net',
        // Sens ESPÈCES FIABLE (D=débit/sortie, C=crédit/entrée) : signe des
        // mouvements cash dont le kind ne fixe pas la direction (régul. / OST).
        MovementField.cashDirection: 'SensEsp',
      }),
      kindLexicon: {
        'AC': TransactionKind.buy,
        'VCPT': TransactionKind.sell,
        'CO': TransactionKind.dividend,
        'PEAIE': TransactionKind.deposit,
        'ODTTF': TransactionKind.charge,
        'SOUSC': TransactionKind.buy,
      },
      corporateActions: {
        // Sorties de titres SANS cession (transferts). `VRSOR` NE PONCTIONNE
        // PLUS le cash (ancien bug `withdrawal`) : il sort des titres.
        'RTFIS': CorporateActionKind.transferOut,
        'VRSOR': CorporateActionKind.transferOut,
        // Attribution gratuite (coût 0), rompus rachetés (petite vente),
        // changement de place (quantité-neutre).
        'ATTRI': CorporateActionKind.freeAttribution,
        'ODRMP': CorporateActionKind.fractionalRedemption,
        'CHGPL': CorporateActionKind.placeChange,
        // Ambigu / à revoir manuellement.
        'DS': CorporateActionKind.manualReview,
        // Mouvements de cash PUR (l'ISIN n'est qu'une référence, jamais rejeté ;
        // signe via SensEsp) : régularisation PEA (`PEAMI`, typiquement crédit)
        // et OST espèces (`ODOST` = paiement de souscription, débit — les titres
        // arrivent via `SOUSC`). `ODOST` n'est PLUS un `dividend` (qui l'aurait
        // compté en cash ENTRANT à tort).
        'PEAMI': CorporateActionKind.cashRegularization,
        'ODOST': CorporateActionKind.cashRegularization,
      },
    );
  }

  /// Profil « Kraken » (export « Ledgers » CSV, lot 1 du chantier B16 — conception
  /// interne). Grand livre de JAMBES (une ligne = un mouvement d'UN actif) : le
  /// [crypto] greffé fait toute la différence avec [bourseDirect] — le
  /// [kindLexicon]/[corporateActions] de la classe TITRE restent vides,
  /// `CryptoLedgerNormalizer` résout les 22 natures via [CryptoLedgerSpec.actions]
  /// (clé composite `'type/subtype'`, repli `'type'`).
  ///
  /// REFUS DE L'ANCIEN FORMAT (conception interne) : un export Kraken antérieur (10
  /// colonnes, sans `wallet`/`subclass`/`amountusd`) a une sémantique incompatible
  /// avec le modèle de valorisation (b) — `requiredColumns` déclenche un refus
  /// GLOBAL motivé dans `CryptoLedgerNormalizer`, jamais un import dégradé.
  factory BrokerProfile.kraken() {
    return BrokerProfile(
      id: 'kraken-ledgers',
      label: 'Kraken',
      delimiter: ',',
      encoding: utf8,
      hasHeaderRow: true,
      dateFormat: const DateFormatSpec(separator: '-', yearFirst: true),
      decimalSeparator: DecimalSeparator.dot,
      columns: const ColumnMapping(byName: {
        MovementField.date: 'time',
        MovementField.kindLabel: 'type',
        MovementField.symbol: 'asset',
        MovementField.quantity: 'amount',
        MovementField.fee: 'fee',
        MovementField.operationReference: 'refid',
      }),
      kindLexicon: const {},
      crypto: CryptoLedgerSpec(
        grouping: LegGroupingStrategy.operationReference,
        groupKeyColumn: MovementField.operationReference,
        subKindColumn: 'subtype',
        walletColumn: 'wallet',
        balanceColumn: 'balance',
        // Colonnes DISCRIMINANTES : leur absence signe l'ancien format Kraken
        // (N1) → refus global motivé, jamais d'import dégradé.
        requiredColumns: const {'wallet', 'subclass', 'amountusd'},
        // Classifieur FOURNI par le fichier (N13) — jamais une liste en dur.
        assetClassColumn: 'subclass',
        stakedSuffixes: const {'.S'},
        // Alias d'IDENTITÉ (journal), appliqués AVANT le groupage (§5.1.5) :
        // ETH2→ETH (migration earn), MATIC→POL (rebranding Polygon),
        // UST→USTC / LUNA→LUNC (séquelles Terra, délistages convertis).
        identityAliases: const {
          'ETH2': 'ETH',
          'MATIC': 'POL',
          'UST': 'USTC',
          'LUNA': 'LUNC',
        },
        // Alias de COTATION, table DISTINCTE (N12) : ces identités ne cotent
        // qu'en USD chez Yahoo (`<CODE>-EUR` répond 404). Piège vérifié à la
        // main le 18/09/2026 : un ticker `-USD` NU peut désigner un homonyme
        // sans rapport (Yahoo désambiguïse les identités crypto ambiguës par
        // un id CoinMarketCap suffixé au code) — `POL-USD` répond « Proof Of
        // Liquidity », `SGB-USD` répond « SubGame », `STRK-USD` répond
        // « Strike », alors que les identités visées sont respectivement
        // Polygon, Songbird et Starknet. D'où les trois tickers à id
        // numérique ci-dessous, vérifiés un par un (les 4 autres alias sont
        // les bonnes identités, sans collision).
        quoteAliases: const {
          'POL': 'POL28321-USD',
          'FLR': 'FLR-USD',
          'SGB': 'SGB12186-USD',
          'STRK': 'STRK22691-USD',
          'MOVR': 'MOVR-USD',
          'GLMR': 'GLMR-USD',
          'ETHW': 'ETHW-USD',
        },
        valuationAmountColumn: 'amountusd',
        valuationCurrency: 'USD',
        rewards: RewardAggregation.monthly,
        maxLegValuationSpread: 0.10,
        // Étage 1-ter (amendement drive lot 2 : liste de CONFIANCE, PAS UST/USTC
        // (séquelle Terra, ancrage perdu) — cf. la doc de
        // [CryptoLedgerSpec.usdStableCodes].
        usdStableCodes: const {'USDT', 'USDC'},
        // Vocabulaire des types EXTERNES (chantier B16 lot 3, préparation
        // Coinbase) — cf. la doc de chaque champ dans `CryptoLedgerSpec` pour
        // le site moteur consommateur. `deposit`/`withdrawal` sont les seules
        // natures dont le TYPE fixe déjà la direction sans ambiguïté ; les
        // codes `transfer*` (redirigés par signe) n'entrent JAMAIS dans
        // [signFixedKinds]. `receive` est un apport externe reconnu par
        // [externalDepositKinds] mais N'EST PAS dans [signFixedKinds] (pas de
        // contrôle de signe sur cette nature aujourd'hui) — voir la note de
        // [CryptoLedgerSpec.externalDepositKinds] sur cette asymétrie.
        signFixedKinds: const {'deposit': true, 'withdrawal': false},
        externalDepositKinds: const {'deposit', 'receive'},
        externalWithdrawalKinds: const {'withdrawal'},
        // Table de mapping complète (conception interne). `spend`/`receive` SANS
        // sous-type (42 paires crypto↔fiat + 3 crypto↔crypto) atteignent le REPLI
        // `'type'` seul (clé composite absente faute de sous-type sur ces lignes) —
        // seule la variante `dustsweeping` porte un sous-type explicite.
        //
        // NOTE (assumption documentée) : les 4 sous-types `transfer` spot↔staking et les
        // libellés exacts `dustsweeping`/`spotfromfutures` sont NOMMÉS d'après le
        // vocabulaire de la conception interne — l'export réel n'a pas pu être relu pour
        // figer l'orthographe exacte des `subtype` (fixtures 100 % synthétiques,
        // politique du chantier). Si un futur export porte une graphie différente pour un
        // de ces sous-types, la clé composite `type/subtype` correspondante ne matche
        // AUCUNE entrée de cette table : la ligne part en rejet motivé
        // `unknownCryptoAction` (B4, jamais de coercition) — `_resolveAction`
        // (crypto_ledger_normalizer.dart) réserve le repli sur le type nu aux seules
        // lignes SANS sous-type renseigné, jamais à un sous-type présent mais méconnu
        // (B-1, revue adversariale : un repli aveugle aurait silencieusement réinterprété
        // un sous-type inconnu comme le sens du type nu — position détruite sans alerte).
        actions: const {
          'trade/tradespot': CryptoLedgerAction.exchangeLeg,
          'spend': CryptoLedgerAction.exchangeLeg,
          'receive': CryptoLedgerAction.exchangeLeg,
          'spend/dustsweeping': CryptoLedgerAction.exchangeLeg,
          'receive/dustsweeping': CryptoLedgerAction.exchangeLeg,
          'staking': CryptoLedgerAction.reward,
          'earn/reward': CryptoLedgerAction.reward,
          'earn/airdrop': CryptoLedgerAction.reward,
          'earn/migration': CryptoLedgerAction.assetMigration,
          'earn/allocation': CryptoLedgerAction.internalTransfer,
          'earn/deallocation': CryptoLedgerAction.internalTransfer,
          'earn/autoallocation': CryptoLedgerAction.internalTransfer,
          'earn/delistingconversion': CryptoLedgerAction.assetMigration,
          'transfer/spottostaking': CryptoLedgerAction.internalTransfer,
          'transfer/stakingtospot': CryptoLedgerAction.internalTransfer,
          'transfer/spotfromstaking': CryptoLedgerAction.internalTransfer,
          'transfer/stakingfromspot': CryptoLedgerAction.internalTransfer,
          // `depositIn` posé ici par convention : le sens EFFECTIF de ces trois codes
          // ambigus (« 3 entrées + 3 sorties réelles » / poussières de délistage, conception
          // interne) est redérivé du SIGNE net par `CryptoLedgerNormalizer` (redirection
          // depositIn↔withdrawalOut selon le signe, §C) — contrairement à
          // `deposit`/`withdrawal` (Kraken) dont le TYPE fixe déjà la direction sans
          // ambiguïté.
          'transfer/spotfromfutures': CryptoLedgerAction.depositIn,
          'transfer': CryptoLedgerAction.depositIn,
          'transfer/delistingconversion': CryptoLedgerAction.depositIn,
          'deposit': CryptoLedgerAction.depositIn,
          'withdrawal': CryptoLedgerAction.withdrawalOut,
        },
      ),
    );
  }

  BrokerProfile copyWith({
    String? delimiter,
    Encoding? encoding,
    bool? hasHeaderRow,
    StatementFileFormat? format,
    String? headerDetectionColumn,
    DateFormatSpec? dateFormat,
    DecimalSeparator? decimalSeparator,
    ColumnMapping? columns,
    Map<String, TransactionKind>? kindLexicon,
    Map<String, CorporateActionKind>? corporateActions,
    CryptoLedgerSpec? crypto,
  }) {
    return BrokerProfile(
      id: id,
      label: label,
      delimiter: delimiter ?? this.delimiter,
      encoding: encoding ?? this.encoding,
      hasHeaderRow: hasHeaderRow ?? this.hasHeaderRow,
      format: format ?? this.format,
      headerDetectionColumn: headerDetectionColumn ?? this.headerDetectionColumn,
      dateFormat: dateFormat ?? this.dateFormat,
      decimalSeparator: decimalSeparator ?? this.decimalSeparator,
      columns: columns ?? this.columns,
      kindLexicon: kindLexicon ?? this.kindLexicon,
      corporateActions: corporateActions ?? this.corporateActions,
      crypto: crypto ?? this.crypto,
    );
  }
}

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

  const DateFormatSpec({
    this.separator = '/',
    this.dayFirst = true,
    this.fourDigitYear = true,
    this.compactYmd = false,
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
    );
  }
}

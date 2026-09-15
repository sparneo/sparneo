// lib/model/import_preview.dart
//
// Agrégat de résultat pour l'écran de prévisualisation d'un import de
// relevé : mouvements à créer / doublons ignorés / lignes rejetées / actifs
// nouveaux à résoudre. AUCUNE écriture n'est faite ici — c'est le
// contrôleur qui décide de la confirmation.

import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';

/// Candidat de REMPLACEMENT d'un agrégat mensuel de récompenses crypto déjà en
/// base (chantier B16, conception interne) : même `importKey` `agg:…` que
/// [ImportedMovement.importKey], mais CONTENU différent (le mois s'est allongé à
/// un ré-import — ex. 12 lignes source → 30) ET le mouvement en base porte
/// `meta['aggregation'] == 'monthly'` (garde stricte, §5.1.8b) — sans cette
/// garde un mouvement NON-agrégat de même clé serait une anomalie (`rejects`),
/// jamais un candidat de remplacement. Le mouvement de remplacement lui-même vit
/// dans [ImportedMovement.transaction] (même objet que celui qu'on aurait
/// autrement mis dans `toCreate`) — cette classe ne fait qu'exposer le DELTA
/// pour l'aperçu.
class AggregateReplacement {
  /// Mouvement de remplacement (nouvel agrégat), prêt à être écrit — c'est
  /// son `meta['importKey']` qui doit figurer dans
  /// `LedgerService.importMovements(replaceImportKeys:)` à la confirmation.
  final ImportedMovement movement;

  /// Mois du bucket (`AAAA-MM`), pour l'affichage.
  final String month;

  /// Nombre de lignes source de l'agrégat EN BASE (avant remplacement).
  final int previousRowCount;

  /// Nombre de lignes source du NOUVEL agrégat (après remplacement).
  final int newRowCount;

  /// Delta de quantité (nouveau − ancien), signé, pour l'affichage
  /// (« +0,83 ADA »).
  final String quantityDelta;

  const AggregateReplacement({
    required this.movement,
    required this.month,
    required this.previousRowCount,
    required this.newRowCount,
    required this.quantityDelta,
  });
}

/// Actif introduit par l'import et pas encore résolu à un symbole existant.
/// La résolution (mapper à une position existante par ISIN, chercher un
/// symbole coté, ou créer un actif sans cotation) est hors de la couche pure
/// — cette classe ne fait que porter l'information nécessaire à cette étape.
class NewAssetCandidate {
  final String? isin;
  final String label;

  /// Symbole déjà proposé (mappé directement par l'utilisateur), ou `null`
  /// si une résolution reste à faire.
  final String? proposedSymbol;

  /// `true` (défaut) = l'actif sera créé COTÉ ([proposedSymbol] est un symbole
  /// de marché à interroger). `false` = repli « non coté » : l'actif est créé
  /// avec `symbol == isin` et ne sera jamais interrogé sur la source de marché
  /// (titre délisté / purgé). Reporté tel quel sur [Asset.quotable] à la
  /// confirmation.
  final bool quotable;

  /// `true` = LIGNE SOLDÉE : l'import projette une quantité nette ≤ 0 (titre
  /// acheté puis intégralement revendu, droit de souscription consommé…). L'actif
  /// est tout de même matérialisé (pour l'intégrité du journal) mais en position
  /// clôturée (quantité 0, masquée). N'est PAS une nouvelle position OUVERTE :
  /// à ce titre il n'est PAS présenté dans la liste « Nouveaux actifs » de
  /// l'aperçu (le modèle de valorisation ne concerne que les positions
  /// détenues). Toujours créé avec [proposedSymbol] = ISIN et [quotable] = false.
  final bool closedLine;

  /// Code d'actif du RELEVÉ CRYPTO d'origine (`ledgerCode`, APRÈS alias
  /// d'identité) — `null` pour tout candidat issu d'un profil titres. Transmis tel
  /// quel à `Asset.ledgerCode` à la création (conception interne) : c'est la clé
  /// de la cascade de résolution ticker, DISTINCTE de [isin].
  final String? ledgerCode;

  /// `true` si [quotable] == `false` à cause d'une PANNE RÉSEAU (timeout, 429…)
  /// rencontrée par la cascade de résolution ticker (`AccountController.
  /// _resolveCryptoTicker`, conception interne), plutôt qu'une non-existence
  /// CONSTATÉE (404 sur les deux étages réseau) — distinction à faire à l'écran
  /// (patron conception interne : une panne de transport n'est jamais assimilée à
  /// une invalidité). Toujours `false` pour un candidat titre.
  final bool networkFailure;

  const NewAssetCandidate({
    this.isin,
    required this.label,
    this.proposedSymbol,
    this.quotable = true,
    this.closedLine = false,
    this.ledgerCode,
    this.networkFailure = false,
  });
}

/// Delta projeté (avant → après import) d'UNE position ou du cash.
///
/// RÉSERVE DE FORME uniquement : la couche pure ne calcule aucune projection
/// (cela suppose de rejouer le journal EXISTANT du compte, une donnée dont
/// cette couche ne dispose pas) — tous les champs restent `null` ici et sont
/// remplis par le contrôleur une fois le compte cible connu.
class ProjectedDelta {
  /// `null` = delta du cash (pas d'une position titre).
  final String? symbol;
  final String? quantityBefore;
  final String? quantityAfter;
  final double? averageBuyPriceBefore;
  final double? averageBuyPriceAfter;
  final double? cashBefore;
  final double? cashAfter;

  const ProjectedDelta({
    this.symbol,
    this.quantityBefore,
    this.quantityAfter,
    this.averageBuyPriceBefore,
    this.averageBuyPriceAfter,
    this.cashBefore,
    this.cashAfter,
  });
}

/// Résultat agrégé de la normalisation d'un relevé, prêt pour la
/// prévisualisation utilisateur.
class ImportPreview {
  /// Refus GLOBAL motivé (ex. N1 : ancien format Kraken sans `wallet`/
  /// `subclass`/`amountusd`, conception interne) — `null` dans l'immense majorité
  /// des cas. Non-null ⇒ tous les autres champs restent vides : AUCUN mouvement
  /// n'est proposé, le fichier entier est refusé plutôt que d'importer un journal
  /// dégradé. Clé stable i18n-able (comme [ImportedMovement.rejectReason]),
  /// jamais un message déjà traduit — la traduction vient avec la passe UX.
  final String? globalRejectReason;

  /// Mouvements normalisés à créer (candidats non dupliqués, non rejetés).
  final List<ImportedMovement> toCreate;

  /// Mouvements normalisés dont l'`importKey` existe déjà dans le journal du
  /// compte cible — ignorés par défaut à la confirmation (ré-import du même
  /// relevé = no-op).
  final List<ImportedMovement> duplicates;

  /// Mouvements d'ESPÈCES dont l'`importKey` est INCONNUE du journal, mais qui
  /// portent la même date, le même kind et le même montant qu'un mouvement
  /// déjà journalisé : **doublons PROBABLES, pas certains**.
  ///
  /// Motif (constaté sur un relevé réel) : l'identité d'un mouvement d'espèces
  /// dans la clé de dédup est son **libellé** (texte libre du relevé — un
  /// dépôt n'a ni ISIN ni symbole, cf. `_contentKey`). Une simple reformulation
  /// côté courtier suffit donc à casser la dédup et à réimporter le même
  /// versement, gonflant la trésorerie **en silence**. Cas mesuré : 22 dépôts
  /// sur 27, mêmes date et montant, libellé modifié → 22 doublons non détectés.
  ///
  /// **Indécidable par construction** : le relevé ne porte AUCUNE heure, donc
  /// deux versements réellement distincts du même montant le même jour sont
  /// indiscernables d'un doublon. On ne tranche donc PAS à la place de
  /// l'utilisateur — ces mouvements sont EXCLUS de [toCreate] (défaut prudent :
  /// une trésorerie gonflée en silence est plus dommageable qu'un versement
  /// manquant, qui reste visible ici) et l'aperçu propose de les importer
  /// quand même.
  final List<ImportedMovement> probableDuplicates;

  /// Lignes rejetées (kind non mappé, date/montant invalide…), avec motif.
  final List<ImportedMovement> rejects;

  /// Actifs nouveaux introduits par [toCreate], en attente de résolution.
  final List<NewAssetCandidate> newAssets;

  /// Delta projeté par position + cash. Vide dans la couche pure (voir
  /// [ProjectedDelta]) — rempli plus tard par le contrôleur.
  final List<ProjectedDelta> projectedDeltas;

  /// Symboles titres touchés par l'import dont la position existante est
  /// LEGACY DÉCLARÉE (`derived_at` NULL, aucun journal) : le relevé ne
  /// couvre qu'une période, jamais toute l'historique de la position, donc
  /// AUCUN delta n'est reprojeté pour eux (miroir en lecture seule de la
  /// garde anti-écrasement de `LedgerService.importMovements`). Sert à
  /// avertir l'utilisateur (« ce relevé ne couvre pas tout l'historique de
  /// X ») avant confirmation.
  final List<String> legacySymbols;

  // -------------------------------------------------------------------------
  // Extensions crypto (chantier B16, lot 1 — conception interne). Champs à défaut
  // VIDE : n'importe quel appelant existant (profils titres) reste bit-identique.
  // Alimentés UNIQUEMENT par `AccountController` quand `profile.crypto != null`.
  // -------------------------------------------------------------------------

  /// Échanges/entrées en nature sans valorisation disponible (modèle (b),
  /// conception interne) — EXCLUS de [toCreate], groupe « Échanges à valoriser »
  /// à l'écran. La valorisation elle-même (lot 2) n'est PAS faite ici.
  final List<UnvaluedExchange> unvaluedExchanges;

  /// Actifs de base dont les transferts internes ne nettent pas à zéro
  /// (conception interne) — groupe « Transferts internes non équilibrés ».
  final List<UnbalancedInternalTransfer> unbalancedInternalTransfers;

  /// Ruptures de la chaîne `balance` (oracle Kraken, conception interne) — carte «
  /// Relevé incomplet », JAMAIS bloquante.
  final List<ChainRupture> chainRuptures;

  /// Écarts entre quantité projetée et `balance` finales déclarées (conception
  /// interne) — carte « Écart de quantité », JAMAIS bloquante ni corrective.
  final List<QuantityGap> quantityGaps;

  /// Agrégats mensuels de récompenses dont la CLÉ existe déjà en base mais le
  /// CONTENU diffère (mois allongé à un ré-import, conception interne) : ni doublon
  /// (exclu de [duplicates]), ni mouvement neuf (exclu de [toCreate]) — nécessite
  /// `replaceImportKeys` à la confirmation.
  final List<AggregateReplacement> replacements;

  /// Nombre de lignes source consommées par l'agrégation mensuelle des
  /// récompenses crypto (conception interne) — pour l'affichage seul.
  final int aggregatedRewardSourceRows;

  /// `true` si la série FX historique (`ExchangeRateService. getDailyRatesToEur`)
  /// était INDISPONIBLE (échec réseau/HTTP/parsing) au moment de résoudre les
  /// échanges crypto sans jambe fiat (chantier B16, lot 2, conception interne) —
  /// dans ce cas, [unvaluedExchanges] contient TOUS les échanges concernés (aucun
  /// n'a pu être valorisé), chacun avec `manualReason == 'fxUnavailable'` ; le
  /// reste du fichier (rewards, dépôts/retraits, trades à jambe fiat) est TOUJOURS
  /// normalisé normalement — **aucune coercition, rien n'est bloqué globalement**.
  /// Sert à l'écran à afficher un bandeau dédié (« Réessayer / Saisir les valeurs /
  /// N'importer que le reste », conception interne) plutôt que de laisser croire à
  /// un simple lot d'échanges ambigus. `false` par défaut (comportement inchangé
  /// pour tout appelant non-crypto).
  final bool cryptoFxUnavailable;

  const ImportPreview({
    this.globalRejectReason,
    this.toCreate = const [],
    this.duplicates = const [],
    this.probableDuplicates = const [],
    this.rejects = const [],
    this.newAssets = const [],
    this.projectedDeltas = const [],
    this.legacySymbols = const [],
    this.unvaluedExchanges = const [],
    this.unbalancedInternalTransfers = const [],
    this.chainRuptures = const [],
    this.quantityGaps = const [],
    this.replacements = const [],
    this.aggregatedRewardSourceRows = 0,
    this.cryptoFxUnavailable = false,
  });

  /// Reconstruction PARTIELLE — I-3 (revue adversariale) : les points d'appel
  /// qui ne modifient QU'UN sous-ensemble de champs (ex.
  /// `_applyResolvedSymbols`/`_previewToWrite`, statement_import_page.dart)
  /// doivent passer par CETTE méthode plutôt que par un constructeur
  /// `ImportPreview(...)` manuel — un tel constructeur manuel omet
  /// silencieusement tout champ non listé (ex. les 7 champs crypto du lot
  /// B16), un risque resté sans conséquence tant qu'aucun appelant ne
  /// dépendait de ces champs après reconstruction, mais une bombe à
  /// retardement dès le lot 2.
  ImportPreview copyWith({
    String? globalRejectReason,
    List<ImportedMovement>? toCreate,
    List<ImportedMovement>? duplicates,
    List<ImportedMovement>? probableDuplicates,
    List<ImportedMovement>? rejects,
    List<NewAssetCandidate>? newAssets,
    List<ProjectedDelta>? projectedDeltas,
    List<String>? legacySymbols,
    List<UnvaluedExchange>? unvaluedExchanges,
    List<UnbalancedInternalTransfer>? unbalancedInternalTransfers,
    List<ChainRupture>? chainRuptures,
    List<QuantityGap>? quantityGaps,
    List<AggregateReplacement>? replacements,
    int? aggregatedRewardSourceRows,
    bool? cryptoFxUnavailable,
  }) {
    return ImportPreview(
      globalRejectReason: globalRejectReason ?? this.globalRejectReason,
      toCreate: toCreate ?? this.toCreate,
      duplicates: duplicates ?? this.duplicates,
      probableDuplicates: probableDuplicates ?? this.probableDuplicates,
      rejects: rejects ?? this.rejects,
      newAssets: newAssets ?? this.newAssets,
      projectedDeltas: projectedDeltas ?? this.projectedDeltas,
      legacySymbols: legacySymbols ?? this.legacySymbols,
      unvaluedExchanges: unvaluedExchanges ?? this.unvaluedExchanges,
      unbalancedInternalTransfers:
          unbalancedInternalTransfers ?? this.unbalancedInternalTransfers,
      chainRuptures: chainRuptures ?? this.chainRuptures,
      quantityGaps: quantityGaps ?? this.quantityGaps,
      replacements: replacements ?? this.replacements,
      aggregatedRewardSourceRows:
          aggregatedRewardSourceRows ?? this.aggregatedRewardSourceRows,
      cryptoFxUnavailable: cryptoFxUnavailable ?? this.cryptoFxUnavailable,
    );
  }
}

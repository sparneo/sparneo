// lib/model/import_preview.dart
//
// Agrégat de résultat pour l'écran de prévisualisation d'un import de
// relevé : mouvements à créer / doublons ignorés / lignes rejetées / actifs
// nouveaux à résoudre. AUCUNE écriture n'est faite ici — c'est le
// contrôleur qui décide de la confirmation.

import 'package:portfolio_tracker/model/imported_movement.dart';

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

  const NewAssetCandidate({
    this.isin,
    required this.label,
    this.proposedSymbol,
    this.quotable = true,
    this.closedLine = false,
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

  const ImportPreview({
    this.toCreate = const [],
    this.duplicates = const [],
    this.probableDuplicates = const [],
    this.rejects = const [],
    this.newAssets = const [],
    this.projectedDeltas = const [],
    this.legacySymbols = const [],
  });
}

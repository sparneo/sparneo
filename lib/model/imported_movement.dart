// lib/model/imported_movement.dart
//
// DTO intermédiaire produit par la normalisation d'UNE ligne de relevé : soit
// un mouvement candidat prêt à être journalisé, soit un rejet motivé. Reste
// une donnée pure — aucune logique de résolution d'actif ni d'écriture ici.

import 'package:portfolio_tracker/model/asset_transaction.dart';

/// Résultat de la normalisation d'une ligne de relevé.
///
/// Exactement un des deux constructeurs nommés est utilisé : [candidate] pour
/// une ligne normalisée avec succès, [rejected] pour une ligne écartée. Pas de
/// sous-classement — un DTO simple, [isRejected] distingue les deux cas.
class ImportedMovement {
  /// Ligne source brute (valeurs de colonnes telles que lues du fichier),
  /// conservée pour l'écran de diagnostic/rejet et pour l'affichage.
  final List<String> sourceRow;

  /// Numéro de ligne PHYSIQUE 1-based de la ligne dans le fichier source, pour
  /// l'affichage (« Ligne 12 ») — pensé pour retrouver la ligne DANS le
  /// relevé tel que l'utilisateur le voit. Pour un `.xlsx`, c'est le n° de
  /// ligne du tableur (attribut `r` de `<row>`, exact même avec des lignes
  /// vides) ; pour un CSV, l'index 1-based dans les lignes décodées (approché
  /// si le décodeur élimine des vides). Renseigné par `normalize` via
  /// `sourceLines` ; en l'absence de `sourceLines` (appels directs, ex.
  /// tests), il vaut l'index 0-based de la ligne de données.
  final int sourceRowIndex;

  /// Mouvement candidat, ou `null` si la ligne est rejetée. Porte déjà
  /// `meta['importKey']` (identique à [importKey]).
  final AssetTransaction? transaction;

  /// ISIN lu sur la ligne, s'il est mappé et non vide.
  final String? isin;

  /// Libellé de l'instrument lu sur la ligne, s'il est mappé et non vide.
  final String? label;

  /// `true` si le mouvement porte un instrument (buy/sell/dividend…) dont le
  /// symbole n'est pas encore résolu : une couche supérieure doit faire
  /// correspondre [isin]/[label] à un symbole (ou créer un actif sans
  /// cotation) avant que ce mouvement puisse être confirmé/journalisé.
  final bool needsAssetResolution;

  /// Symbole déjà résolu au moment de la normalisation (mappé directement
  /// par l'utilisateur dans le profil, sans passer par une résolution
  /// ISIN → symbole), ou `null` si non résolu.
  final String? resolvedSymbol;

  /// Clé de déduplication du mouvement (voir `StatementImportService` pour
  /// l'algorithme). `null` pour une ligne rejetée — un rejet n'entre jamais
  /// dans le calcul de dédup.
  final String? importKey;

  /// Motif de rejet, sous forme de clé stable i18n-able (ex.
  /// `'unknownKind'`, `'invalidDate'`) — jamais un message déjà traduit.
  /// `null` si la ligne a été normalisée avec succès.
  final String? rejectReason;

  ImportedMovement.candidate({
    required this.sourceRow,
    required this.sourceRowIndex,
    required AssetTransaction this.transaction,
    this.isin,
    this.label,
    this.needsAssetResolution = false,
    this.resolvedSymbol,
    required String this.importKey,
  }) : rejectReason = null;

  ImportedMovement.rejected({
    required this.sourceRow,
    required this.sourceRowIndex,
    required String this.rejectReason,
    this.isin,
    this.label,
  })  : transaction = null,
        needsAssetResolution = false,
        resolvedSymbol = null,
        importKey = null;

  bool get isRejected => rejectReason != null;
}

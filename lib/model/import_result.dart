// lib/model/import_result.dart
//
// Bilan d'un import ADDITIF de relevé (LedgerService.importMovements) :
// compteur de mouvements écrits + ventilation des symboles titres selon la
// décision de reprojection. Donnée PURE — aucune écriture ici ; consommée par
// le contrôleur / l'écran de prévisualisation pour le retour utilisateur.

/// Résultat d'un appel à `LedgerService.importMovements`.
class ImportResult {
  /// Nombre de mouvements insérés/remplacés dans le journal du compte.
  final int movementsWritten;

  /// Symboles pour lesquels une ligne `positions` a été CRÉÉE (actifs nouveaux
  /// absents du compte avant l'import).
  final List<String> createdSymbols;

  /// Symboles titres dont la position a été REPROJETÉE depuis le journal
  /// (symbole nouveau, déjà projeté, ou legacy adopté sur ancre cohérente).
  final List<String> reprojectedSymbols;

  /// Symboles titres LAISSÉS EN LEGACY : leur déclaration (quantité / PRU
  /// saisis à la main) est PRÉSERVÉE — jamais écrasée par une projection
  /// partielle (le relevé ne couvre qu'une période). Le solde espèces a tout de
  /// même été reprojeté. Sert au feedback UI (le contrôleur a averti en amont).
  final List<String> legacySymbols;

  const ImportResult({
    this.movementsWritten = 0,
    this.createdSymbols = const [],
    this.reprojectedSymbols = const [],
    this.legacySymbols = const [],
  });
}

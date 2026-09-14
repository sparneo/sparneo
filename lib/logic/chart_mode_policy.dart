// lib/logic/chart_mode_policy.dart
//
// Politique PURE de résolution du mode de courbe par défaut (mode 1 « Vos
// positions » / mode 2 « Évolution réelle », design conception interne).
//
// POURQUOI une politique plutôt qu'un `bool` en dur dans chaque vue : le mode
// réel est le défaut depuis le 29/07 (il montre ce qui s'est VRAIMENT passé),
// mais il se reconstruit depuis le JOURNAL — un journal incomplet (positions
// héritées sans aucun mouvement, espèces non ancrées, titre sans historique
// de cours) produit une courbe qui ne représente qu'une FRACTION du
// patrimoine réel. Affichée par défaut, elle plaçait un chiffre faux sous les
// yeux d'un nouvel utilisateur dès l'ouverture. La garde `hasRealCurve`
// (série non vide) ne distinguait pas « complète » de « 40 % du patrimoine ».
//
// Les trois vues concernées (patrimoine, compte, position) partagent donc
// cette seule décision, testable hors Flutter.

/// Seuil de COUVERTURE (part du patrimoine courant que le dernier point de la
/// courbe réelle représente) en dessous duquel le mode réel n'est plus offert
/// PAR DÉFAUT.
///
/// 0,8 — choisi pour laisser passer l'écart NORMAL, de l'ordre de quelques
/// pour cent, entre les deux sources de prix qui composent le ratio : le
/// dernier point de la courbe est valorisé au dernier COURS HISTORIQUE de la
/// grille (clôture de la veille, ou du vendredi un dimanche), la valorisation
/// courante à la COTATION LIVE. Un patrimoine parfaitement journalisé tourne
/// donc autour de 0,95–1,05, jamais exactement 1. En revanche une
/// reconstruction MATÉRIELLEMENT incomplète (une position héritée sur trois,
/// un livret non ancré qui pèse un quart du total) tombe très en dessous :
/// 0,8 sépare les deux régimes sans être bavard.
const double kRealCurveCoverageThreshold = 0.8;

/// Vrai si [coverage] atteste une reconstruction matériellement incomplète
/// (strictement sous [kRealCurveCoverageThreshold]).
///
/// `null` (pas de courbe réelle, ou valorisation courante nulle/négative donc
/// ratio dénué de sens) n'est PAS une incomplétude : on ne sait rien, on
/// n'accuse rien.
bool isRealCurveIncomplete(double? coverage) =>
    coverage != null && coverage < kRealCurveCoverageThreshold;

/// Résout le mode de courbe EFFECTIF d'une vue.
///
/// - [persistedChoice] : choix explicite de l'utilisateur pour CETTE portée
///   (patrimoine / compte / position), `null` s'il n'a jamais tranché.
/// - [hasRealCurve] : une série mode 2 existe-t-elle ? Sans elle il n'y a
///   qu'un mode possible (le sélecteur est d'ailleurs masqué côté vue).
/// - [coverage] : cf. [isRealCurveIncomplete].
///
/// Ordre des règles, volontaire :
///   1. pas de courbe réelle ⇒ `false`, quoi qu'ait choisi l'utilisateur
///      (garde de robustesse préexistante : jamais de graphe vide) ;
///   2. choix explicite ⇒ il gagne, MÊME sur une couverture basse. La garde
///      est un défaut prudent, pas une tutelle : qui a demandé l'évolution
///      réelle la garde, et la note chiffrée sous le graphe l'avertit ;
///   3. sinon ⇒ mode réel, sauf couverture connue et insuffisante.
bool resolveUseRealCurve({
  required bool? persistedChoice,
  required bool hasRealCurve,
  required double? coverage,
}) {
  if (!hasRealCurve) return false;
  if (persistedChoice != null) return persistedChoice;
  return !isRealCurveIncomplete(coverage);
}

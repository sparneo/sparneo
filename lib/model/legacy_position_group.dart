// lib/model/legacy_position_group.dart

import 'package:flutter/foundation.dart';

/// Positions HÉRITÉES d'UN compte : détenues (elles pèsent dans la valeur
/// affichée) mais sans AUCUN mouvement journalisé, donc absentes de la courbe
/// « Évolution réelle ».
///
/// POURQUOI un groupe et pas une liste plate de symboles côté patrimoine :
/// l'écran patrimoine ne sait pas agir sur un titre — la déclaration de
/// l'opération d'origine vit un niveau plus bas, sur l'écran du compte. Il
/// nomme donc ce qui se trouve juste en dessous (le compte), avec son compte de
/// positions, et laisse l'écran compte nommer les titres. Chaque écran cite ce
/// sur quoi on peut agir depuis lui.
@immutable
class LegacyPositionGroup {
  /// Identifiant du compte concerné — cible de la navigation depuis la note
  /// (`AccountView(initialAccountId: ...)`).
  final String accountId;

  /// Nom du compte tel qu'affiché ailleurs dans l'app (« PEA », « CTO »…).
  final String accountName;

  /// Symboles hérités de ce compte, dans l'ordre de découverte des positions
  /// (stable d'un rendu à l'autre : `_allPositionsData` conserve l'ordre de
  /// chargement). Jamais vide — un groupe sans symbole n'est pas construit.
  final List<String> symbols;

  const LegacyPositionGroup({
    required this.accountId,
    required this.accountName,
    required this.symbols,
  });

  int get count => symbols.length;

  @override
  bool operator ==(Object other) =>
      other is LegacyPositionGroup &&
      other.accountId == accountId &&
      other.accountName == accountName &&
      listEquals(other.symbols, symbols);

  @override
  int get hashCode => Object.hash(accountId, accountName, Object.hashAll(symbols));

  @override
  String toString() =>
      'LegacyPositionGroup($accountId, $accountName, $symbols)';
}

// lib/utils/bounded_concurrency.dart

/// Borne de concurrence des rafales de requêtes vers la source de marché
/// (Yahoo Finance) : au plus [maxConcurrentMarketRequests] cotations/
/// historiques en vol simultanément, quel que soit le nombre de symboles du
/// compte/patrimoine. Centralisée ici (plutôt que dupliquée dans chaque
/// contrôleur) : même constante que l'assistant d'import ISIN
/// (StatementImportPage._maybeAutoResolveNewAssets) — évite les 429 sur un
/// portefeuille à beaucoup de titres.
const int maxConcurrentMarketRequests = 5;

/// Exécute [task] sur chaque élément de [items] avec au plus [maxConcurrent]
/// tâches EN VOL simultanément, et renvoie les résultats DANS L'ORDRE
/// D'ENTRÉE — invariant important : plusieurs appelants indexent
/// `results[i]` en parallèle de la liste source d'origine (ex.
/// `symbolsList[i]`), un réordonnancement casserait cet appariement.
///
/// Implémentation "par vagues" : calquée sur le lotissement déjà en place
/// dans `StatementImportPage._maybeAutoResolveNewAssets` (lots de taille
/// fixe enchaînés via `Future.wait`) — suffisant pour border une rafale de
/// requêtes réseau (Yahoo Finance) sans réécrire un vrai pool à fenêtre
/// glissante. Chaque vague attend `Future.wait` avant de lancer la suivante :
/// une tâche rapide d'une vague n'accélère donc pas le départ de la vague
/// suivante tant que la plus lente de la vague courante n'est pas terminée
/// (léger sous-emploi de la concurrence par rapport à un pool réel à fenêtre
/// glissante, jugé acceptable pour ce lot).
///
/// Propagation d'erreur ALIGNÉE sur `Future.wait` (comportement historique
/// attendu par les appelants, qui enveloppent déjà leurs appels dans un
/// try/catch) : dès qu'une tâche de la vague courante lève, l'exception
/// remonte à l'appelant et les vagues SUIVANTES ne sont jamais lancées.
///
/// [maxConcurrent] <= 0 est traité comme « pas de borne » (tout en une seule
/// vague), pour rester permissif plutôt que de planter sur un appel mal
/// configuré. [items] vide renvoie `[]` sans invoquer [task].
Future<List<R>> mapBounded<T, R>(
  Iterable<T> items,
  int maxConcurrent,
  Future<R> Function(T item) task,
) async {
  final list = items.toList();
  if (list.isEmpty) return [];
  final step = maxConcurrent > 0 ? maxConcurrent : list.length;

  final results = <R>[];
  for (var i = 0; i < list.length; i += step) {
    final batch = list.skip(i).take(step);
    results.addAll(await Future.wait(batch.map(task)));
  }
  return results;
}

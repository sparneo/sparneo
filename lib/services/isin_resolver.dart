// lib/services/isin_resolver.dart
//
// Désambiguïsation d'une liste de hits de recherche par ISIN → UN symbole
// retenu. Logique PURE (aucune I/O, aucun état) : c'est le point critique de
// la résolution ISIN, un mauvais choix attacherait un cours/devise faux à une
// position réelle. Testée directement (pas de réseau).
//
// Ordre de préférence (orienté patrimoine local EUR / PEA — actions & ETF
// FR/UE) :
//   0. Euronext Paris        (`.PA`, place PAR/Paris)
//   1. Autres Euronext EUR   (`.AS` Amsterdam, `.BR` Bruxelles, `.LS` Lisbonne)
//   2. Xetra / Francfort     (`.DE`, `.F`)
//   3. tout le reste
// À rang de préférence ÉGAL, on départage par le meilleur `score`. Le rang
// DOMINE toujours le score : un `.PA` est préféré à un `.DE` mieux scoré. Ne
// jamais prendre aveuglément le premier résultat ni le meilleur score seul.

import 'package:portfolio_tracker/model/isin_search_hit.dart';

class IsinResolver {
  /// Retourne le hit retenu selon l'ordre de préférence, ou `null` si [hits]
  /// est vide / ne contient aucun symbole exploitable.
  static IsinSearchHit? pickBest(List<IsinSearchHit> hits) {
    IsinSearchHit? best;
    var bestRank = 1 << 30;
    var bestScore = double.negativeInfinity;

    for (final h in hits) {
      if (h.symbol.trim().isEmpty) continue;
      final rank = _venueRank(h);
      final score = h.score ?? 0;
      // Rang strictement meilleur → adoption inconditionnelle (le rang prime).
      // Rang égal → départage par score strictement supérieur (stable : à
      // score égal, le premier rencontré est conservé).
      if (rank < bestRank || (rank == bestRank && score > bestScore)) {
        best = h;
        bestRank = rank;
        bestScore = score;
      }
    }
    return best;
  }

  /// Rang de préférence d'une place (0 = meilleur). Reconnaît la place via le
  /// suffixe du symbole EN PREMIER (le plus fiable), avec repli sur les champs
  /// `exchange` / `exchangeDisplay` quand le symbole ne porte pas de suffixe.
  static int _venueRank(IsinSearchHit h) {
    final sym = h.symbol.toUpperCase();
    final exch = (h.exchange ?? '').toUpperCase();
    final disp = (h.exchangeDisplay ?? '').toLowerCase();

    bool endsWith(String suffix) => sym.endsWith(suffix);

    // 0. Euronext Paris.
    if (endsWith('.PA') || exch == 'PAR' || disp.contains('paris')) {
      return 0;
    }
    // 1. Autres Euronext en EUR.
    if (endsWith('.AS') ||
        endsWith('.BR') ||
        endsWith('.LS') ||
        exch == 'AMS' ||
        exch == 'BRU' ||
        exch == 'LIS' ||
        disp.contains('amsterdam') ||
        disp.contains('brussels') ||
        disp.contains('lisbon')) {
      return 1;
    }
    // 2. Xetra / Francfort.
    if (endsWith('.DE') ||
        endsWith('.F') ||
        exch == 'GER' ||
        exch == 'FRA' ||
        exch == 'XETRA' ||
        disp.contains('xetra') ||
        disp.contains('frankfurt')) {
      return 2;
    }
    // 3. Le reste (départagé au seul score contre ses pairs de rang 3).
    return 3;
  }
}

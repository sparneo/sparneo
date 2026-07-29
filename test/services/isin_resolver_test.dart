// test/services/isin_resolver_test.dart
//
// Désambiguïsation ISIN → symbole (logique PURE, aucun réseau). Le point
// critique de la résolution : un mauvais choix attacherait un cours/devise
// faux à une position réelle. Fixtures synthétiques (symboles/scores fabriqués).

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/model/isin_search_hit.dart';
import 'package:portfolio_tracker/services/isin_resolver.dart';

IsinSearchHit _hit(String symbol, {String? exch, String? disp, double? score}) =>
    IsinSearchHit(
      symbol: symbol,
      exchange: exch,
      exchangeDisplay: disp,
      score: score,
    );

void main() {
  group('IsinResolver.pickBest', () {
    test('liste vide → null', () {
      expect(IsinResolver.pickBest(const []), isNull);
    });

    test('hits multiples (.PA, .DE, .MI) → retient .PA', () {
      final hits = [
        _hit('X.DE', score: 90),
        _hit('X.MI', score: 95),
        _hit('AIR.PA', score: 10),
      ];
      expect(IsinResolver.pickBest(hits)!.symbol, equals('AIR.PA'));
    });

    test('Paris préféré même si un autre marché a un meilleur score', () {
      final hits = [
        _hit('X.DE', score: 1000),
        _hit('AIR.PA', score: 1),
      ];
      // Le rang de place DOMINE le score.
      expect(IsinResolver.pickBest(hits)!.symbol, equals('AIR.PA'));
    });

    test('aucun .PA → ordre de préférence : autres Euronext EUR avant Xetra', () {
      final hits = [
        _hit('X.DE', score: 99),
        _hit('X.AS', score: 5), // Amsterdam (rang 1) devant Francfort (rang 2)
      ];
      expect(IsinResolver.pickBest(hits)!.symbol, equals('X.AS'));
    });

    test('aucun .PA ni autre Euronext → Xetra avant le reste', () {
      final hits = [
        _hit('X.L', score: 99), // Londres (rang 3)
        _hit('X.DE', score: 5), // Francfort (rang 2)
      ];
      expect(IsinResolver.pickBest(hits)!.symbol, equals('X.DE'));
    });

    test('aucune place préférée → meilleur score', () {
      final hits = [
        _hit('X.L', score: 12),
        _hit('X.TO', score: 80),
        _hit('X.SW', score: 40),
      ];
      expect(IsinResolver.pickBest(hits)!.symbol, equals('X.TO'));
    });

    test('reconnaissance de Paris via exchange/exchDisp (pas de suffixe)', () {
      final hits = [
        _hit('AIR', exch: 'PAR', disp: 'Paris', score: 3),
        _hit('AIR.DE', score: 99),
      ];
      expect(IsinResolver.pickBest(hits)!.symbol, equals('AIR'));
    });

    test('égalité de rang → départage par score, stable au premier à score égal',
        () {
      final a = _hit('A.US', score: 50);
      final b = _hit('B.US', score: 50);
      // Score égal : le premier rencontré est conservé.
      expect(IsinResolver.pickBest([a, b])!.symbol, equals('A.US'));
      expect(IsinResolver.pickBest([b, a])!.symbol, equals('B.US'));
    });

    test('symbole vide ignoré', () {
      final hits = [
        _hit('', score: 100),
        _hit('X.TO', score: 1),
      ];
      expect(IsinResolver.pickBest(hits)!.symbol, equals('X.TO'));
    });
  });

  group('IsinResolver.venueRank', () {
    test('Paris → rang 0', () {
      expect(IsinResolver.venueRank(_hit('AIR.PA')), equals(0));
    });

    test('Amsterdam/Bruxelles/Lisbonne → rang 1', () {
      expect(IsinResolver.venueRank(_hit('X.AS')), equals(1));
      expect(IsinResolver.venueRank(_hit('X.BR')), equals(1));
      expect(IsinResolver.venueRank(_hit('X.LS')), equals(1));
    });

    test('Xetra/Francfort → rang 2', () {
      expect(IsinResolver.venueRank(_hit('X.DE')), equals(2));
      expect(IsinResolver.venueRank(_hit('X.F')), equals(2));
    });

    test('reste (ex. Londres/Stuttgart) → rang 3, le cas 0E2B.IL réel', () {
      // Cas réel qui a motivé le correctif (cf. rapport) : LU1190417599 ne
      // renvoie que Londres (0E2B.IL) et Stuttgart, jamais Paris — le rang 3
      // doit être exposé pour signaler cette résolution peu sûre.
      expect(IsinResolver.venueRank(_hit('0E2B.IL')), equals(3));
      expect(IsinResolver.venueRank(_hit('X.SG')), equals(3));
    });
  });
}

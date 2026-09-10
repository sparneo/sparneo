// test/logic/chart_mode_policy_test.dart
//
// Politique de résolution du mode de courbe par défaut : table de cas
// exhaustive sur les trois entrées (choix persisté × présence de courbe
// réelle × couverture). Pur, sans Flutter ni base.

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/logic/chart_mode_policy.dart';

void main() {
  group('isRealCurveIncomplete', () {
    test('null (couverture inconnue) n\'accuse rien', () {
      expect(isRealCurveIncomplete(null), isFalse);
    });

    test('sous le seuil : incomplet', () {
      expect(isRealCurveIncomplete(0.0), isTrue);
      expect(isRealCurveIncomplete(0.42), isTrue);
      expect(isRealCurveIncomplete(kRealCurveCoverageThreshold - 1e-9), isTrue);
    });

    test('au seuil ou au-dessus : complet', () {
      expect(isRealCurveIncomplete(kRealCurveCoverageThreshold), isFalse);
      expect(isRealCurveIncomplete(0.97), isFalse);
      // Ratio > 1 : le dernier cours historique peut dépasser la cotation
      // live (marché en baisse depuis la clôture) — jamais une incomplétude.
      expect(isRealCurveIncomplete(1.04), isFalse);
    });
  });

  group('resolveUseRealCurve — table de cas', () {
    // Chaque ligne : (choix persisté, hasRealCurve, couverture) → attendu.
    const cases = <({
      String label,
      bool? persistedChoice,
      bool hasRealCurve,
      double? coverage,
      bool expected,
    })>[
      // 1. Aucune courbe réelle : toujours false, quoi qu'ait choisi
      //    l'utilisateur (garde de robustesse : jamais de graphe vide).
      (
        label: 'pas de courbe réelle, aucun choix',
        persistedChoice: null,
        hasRealCurve: false,
        coverage: null,
        expected: false,
      ),
      (
        label: 'pas de courbe réelle, choix « réel » persisté',
        persistedChoice: true,
        hasRealCurve: false,
        coverage: 1.0,
        expected: false,
      ),
      (
        label: 'pas de courbe réelle, choix « positions » persisté',
        persistedChoice: false,
        hasRealCurve: false,
        coverage: null,
        expected: false,
      ),

      // 2. Aucun choix persisté : la couverture décide.
      (
        label: 'aucun choix, couverture inconnue → mode réel (défaut 29/07)',
        persistedChoice: null,
        hasRealCurve: true,
        coverage: null,
        expected: true,
      ),
      (
        label: 'aucun choix, couverture pile au seuil → mode réel',
        persistedChoice: null,
        hasRealCurve: true,
        coverage: kRealCurveCoverageThreshold,
        expected: true,
      ),
      (
        label: 'aucun choix, couverture juste sous le seuil → repli mode 1',
        persistedChoice: null,
        hasRealCurve: true,
        coverage: kRealCurveCoverageThreshold - 0.01,
        expected: false,
      ),
      (
        label: 'aucun choix, couverture très basse (journal fragmentaire)',
        persistedChoice: null,
        hasRealCurve: true,
        coverage: 0.12,
        expected: false,
      ),
      (
        label: 'aucun choix, couverture > 1 (écart de source de prix)',
        persistedChoice: null,
        hasRealCurve: true,
        coverage: 1.05,
        expected: true,
      ),

      // 3. Choix explicite : il prime, MÊME sur une couverture basse — la
      //    garde est un défaut prudent, pas une tutelle.
      (
        label: 'choix « réel » malgré une couverture basse → réel quand même',
        persistedChoice: true,
        hasRealCurve: true,
        coverage: 0.20,
        expected: true,
      ),
      (
        label: 'choix « positions » malgré une couverture parfaite',
        persistedChoice: false,
        hasRealCurve: true,
        coverage: 1.0,
        expected: false,
      ),
      (
        label: 'choix « positions » avec couverture inconnue',
        persistedChoice: false,
        hasRealCurve: true,
        coverage: null,
        expected: false,
      ),
    ];

    for (final c in cases) {
      test(c.label, () {
        expect(
          resolveUseRealCurve(
            persistedChoice: c.persistedChoice,
            hasRealCurve: c.hasRealCurve,
            coverage: c.coverage,
          ),
          c.expected,
        );
      });
    }
  });

  test('le seuil vaut 0,8 (contrat gelé — le changer change l\'UI par défaut)',
      () {
    expect(kRealCurveCoverageThreshold, 0.8);
  });
}

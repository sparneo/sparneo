// test/utils/bounded_concurrency_test.dart
//
// Tests du helper pur [mapBounded] (borne de concurrence pour les rafales
// réseau vers Yahoo Finance). Aucun appel réseau ici : uniquement des
// délais synthétiques ([Future.delayed]) pour observer le chevauchement des
// tâches et prouver la borne de concurrence.

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/utils/bounded_concurrency.dart';

void main() {
  group('mapBounded', () {
    test('préserve l\'ordre des résultats malgré des durées de tâche désordonnées', () async {
      // Délais volontairement décroissants/désordonnés : si l'implémentation
      // réordonnait par ordre de complétion (ex. un Stream non trié), ce test
      // le détecterait.
      const delaysMs = [30, 5, 20, 1, 10];

      final results = await mapBounded<int, int>(delaysMs, 2, (d) async {
        await Future.delayed(Duration(milliseconds: d));
        return d * 10;
      });

      expect(results, delaysMs.map((d) => d * 10).toList());
    });

    test('respecte réellement la borne de concurrence maximale', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      final items = List.generate(10, (i) => i);

      final results = await mapBounded<int, int>(items, 3, (i) async {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await Future.delayed(const Duration(milliseconds: 10));
        inFlight--;
        return i;
      });

      expect(results, items); // ordre préservé en prime
      expect(maxInFlight, lessThanOrEqualTo(3));
      // Preuve que le test exerce bien du parallélisme (sinon la borne
      // serait trivialement respectée par un simple traitement séquentiel).
      expect(maxInFlight, greaterThan(1));
    });

    test('liste vide : renvoie [] sans invoquer task', () async {
      var callCount = 0;
      final results = await mapBounded<int, int>([], 5, (i) async {
        callCount++;
        return i;
      });

      expect(results, isEmpty);
      expect(callCount, 0);
    });

    test('maxConcurrent <= 0 : comportement permissif (traite tout en une vague)', () async {
      final results = await mapBounded<int, int>([1, 2, 3], 0, (i) async => i * 2);
      expect(results, [2, 4, 6]);
    });

    test(
      'propage l\'exception d\'une tâche, comme Future.wait (comportement attendu des appelants, déjà enveloppés en try/catch)',
      () async {
        expect(
          () => mapBounded<int, int>([1, 2, 3], 5, (i) async {
            if (i == 2) throw Exception('boom');
            return i;
          }),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('une tâche en échec dans une vague empêche les vagues suivantes de démarrer', () async {
      final started = <int>[];
      final items = [1, 2, 3, 4]; // vagues de 2 : [1, 2] puis [3, 4]

      await expectLater(
        mapBounded<int, int>(items, 2, (i) async {
          started.add(i);
          if (i == 2) throw Exception('boom');
          return i;
        }),
        throwsA(isA<Exception>()),
      );

      // La vague [3, 4] n'a jamais été lancée : comportement Future.wait
      // (une exception dans une vague interrompt l'enchaînement des vagues
      // suivantes du helper).
      expect(started, [1, 2]);
    });
  });
}

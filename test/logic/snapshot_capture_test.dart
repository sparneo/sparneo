// test/logic/snapshot_capture_test.dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/snapshot_capture.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/valuation_snapshot.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Account _makeAccount(String id, AccountKind kind) {
  return Account(id: id, walletId: 'w1', name: 'Compte $id', kind: kind);
}

ValuationSnapshot _makeSnap(String date, double totalValue) {
  return ValuationSnapshot(
    date: date,
    totalValue: totalValue,
    capturedAt: 0,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // SnapshotCapture.buildIfEligible
  // =========================================================================

  group('SnapshotCapture.buildIfEligible', () {
    final now = DateTime(2024, 6, 15, 10, 30);
    final investment = _makeAccount('inv1', AccountKind.autre);
    final cash = _makeAccount('cash1', AccountKind.cash);

    test('!marketDataComplete → null', () {
      final result = SnapshotCapture.buildIfEligible(
        accountValues: {'inv1': 1000.0},
        marketDataComplete: false,
        accounts: [investment],
        walletId: 'w1',
        now: now,
      );
      expect(result, isNull);
    });

    test('walletId null → null', () {
      final result = SnapshotCapture.buildIfEligible(
        accountValues: {'inv1': 1000.0},
        marketDataComplete: true,
        accounts: [investment],
        walletId: null,
        now: now,
      );
      expect(result, isNull);
    });

    test('total <= 0 avec compte investissement → null (cotations suspectes)', () {
      final result = SnapshotCapture.buildIfEligible(
        accountValues: {'inv1': 0.0},
        marketDataComplete: true,
        accounts: [investment],
        walletId: 'w1',
        now: now,
      );
      expect(result, isNull);
    });

    test('total <= 0 cash-only → capture (un wallet 100% cash à zéro est légitime)', () {
      final result = SnapshotCapture.buildIfEligible(
        accountValues: {'cash1': 0.0},
        marketDataComplete: true,
        accounts: [cash],
        walletId: 'w1',
        now: now,
      );
      // Pas de compte non-cash → la garde ne s'applique pas → snapshot créé
      expect(result, isNotNull);
      expect(result!.totalValue, 0.0);
    });

    test('total > 0 → snapshot construit avec les bons champs', () {
      final result = SnapshotCapture.buildIfEligible(
        accountValues: {'inv1': 1000.0, 'cash1': 500.0},
        marketDataComplete: true,
        accounts: [investment, cash],
        walletId: 'w1',
        now: now,
      );
      expect(result, isNotNull);
      // totalValue = somme exacte de accountValues
      expect(result!.totalValue, closeTo(1500.0, 1e-9));
      // date au format YYYY-MM-DD
      expect(result.date, '2024-06-15');
      // accountCount = nombre de comptes
      expect(result.accountCount, 2);
      // capturedAt = epoch ms de now
      expect(result.capturedAt, now.millisecondsSinceEpoch);
    });

    test('total = somme exacte des valeurs des comptes', () {
      final result = SnapshotCapture.buildIfEligible(
        accountValues: {'a': 100.0, 'b': 200.0, 'c': 300.0},
        marketDataComplete: true,
        accounts: [investment],
        walletId: 'w1',
        now: now,
      );
      expect(result, isNotNull);
      expect(result!.totalValue, closeTo(600.0, 1e-9));
    });
  });

  // =========================================================================
  // SnapshotCapture.projectSnapshotsToChart
  // =========================================================================

  group('SnapshotCapture.projectSnapshotsToChart', () {
    // chartDates : 7 jours consécutifs
    final chartDates = List<DateTime>.generate(7, (i) => DateTime(2024, 6, 10 + i));
    // chartDates[0] = 2024-06-10, chartDates[6] = 2024-06-16

    test('chartDates vide → []', () {
      final result = SnapshotCapture.projectSnapshotsToChart(
        [_makeSnap('2024-06-12', 1000.0)],
        [],
      );
      expect(result, isEmpty);
    });

    test('< 2 points dans la fenêtre → []', () {
      final result = SnapshotCapture.projectSnapshotsToChart(
        [_makeSnap('2024-06-12', 1000.0)], // 1 seul point
        chartDates,
      );
      expect(result, isEmpty);
    });

    test('snapshot hors fenêtre (avant) → filtré', () {
      final result = SnapshotCapture.projectSnapshotsToChart(
        [
          _makeSnap('2024-06-09', 999.0), // avant chartDates[0]
          _makeSnap('2024-06-11', 1000.0),
          _makeSnap('2024-06-13', 1200.0),
        ],
        chartDates,
      );
      // Seuls 2024-06-11 et 2024-06-13 passent le filtre → 2 points → liste non vide
      expect(result.length, 2);
    });

    test('snapshot hors fenêtre (après) → filtré', () {
      final result = SnapshotCapture.projectSnapshotsToChart(
        [
          _makeSnap('2024-06-11', 1000.0),
          _makeSnap('2024-06-13', 1200.0),
          _makeSnap('2024-06-17', 9999.0), // après chartDates[6]
        ],
        chartDates,
      );
      expect(result.length, 2);
    });

    test('≥ 2 points dans la fenêtre → retourne des FlSpot avec x = indice chartDates', () {
      final result = SnapshotCapture.projectSnapshotsToChart(
        [
          _makeSnap('2024-06-10', 1000.0), // indice 0
          _makeSnap('2024-06-15', 1500.0), // indice 5
        ],
        chartDates,
      );
      expect(result.length, 2);
      expect(result[0], isA<FlSpot>());
      // 2024-06-10 == chartDates[0] → x = 0
      expect(result[0].x, 0.0);
      expect(result[0].y, 1000.0);
      // 2024-06-15 == chartDates[5] → x = 5
      expect(result[1].x, 5.0);
      expect(result[1].y, 1500.0);
    });

    test('snapshot avec date invalide → ignoré', () {
      final result = SnapshotCapture.projectSnapshotsToChart(
        [
          _makeSnap('pas-une-date', 999.0),
          _makeSnap('2024-06-11', 1000.0),
          _makeSnap('2024-06-13', 1200.0),
        ],
        chartDates,
      );
      // Seuls les 2 snapshots valides passent
      expect(result.length, 2);
    });

    test('liste de snapshots vide → []', () {
      final result = SnapshotCapture.projectSnapshotsToChart([], chartDates);
      expect(result, isEmpty);
    });
  });
}

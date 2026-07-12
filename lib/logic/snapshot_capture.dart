// lib/logic/snapshot_capture.dart

import 'package:fl_chart/fl_chart.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/valuation_snapshot.dart';

/// Décisions pures liées aux snapshots de valorisation.
///
/// L'I/O ([SnapshotStorage.upsertSnapshot], [SnapshotStorage.getSnapshots]) et
/// le try/catch RESTENT dans la vue. Cette classe ne contient que les calculs
/// et les gardes testables indépendamment.
class SnapshotCapture {
  SnapshotCapture._(); // classe non instanciable

  /// Décide si un snapshot doit être capturé et le construit, ou retourne null.
  ///
  /// Gardes (dans l'ordre) :
  ///   1. [marketDataComplete] == false → null (données incomplètes, on ne
  ///      persiste jamais un total silencieusement sous-évalué).
  ///   2. [walletId] == null → null.
  ///   3. total <= 0 && un compte non-cash existe → null (cotations suspectes).
  ///   4. Sinon → snapshot avec total = fold des [accountValues], date =
  ///      [ValuationSnapshot.dateKeyFor]\([now]\), accountCount = [accounts.length].
  ///
  /// L'I/O (upsertSnapshot) et le try/catch RESTENT dans la vue.
  static ValuationSnapshot? buildIfEligible({
    required Map<String, double> accountValues,
    required bool marketDataComplete,
    required List<Account> accounts,
    required String? walletId,
    required DateTime now,
  }) {
    // Invariant : JAMAIS de snapshot sur données de marché incomplètes.
    if (!marketDataComplete) return null;
    if (walletId == null) return null;

    // total = somme de tous les comptes (cash inclus)
    final total = accountValues.values.fold(0.0, (a, b) => a + b);

    // Garde-fou : total nul avec au moins un compte non-cash = suspect,
    // probablement des cotations à zéro non détectées.
    if (total <= 0 && accounts.any((a) => a.type != AccountType.cash)) {
      return null;
    }

    return ValuationSnapshot(
      date: ValuationSnapshot.dateKeyFor(now),
      totalValue: total,
      capturedAt: now.millisecondsSinceEpoch,
      accountCount: accounts.length,
    );
  }

  /// Projette une liste de [ValuationSnapshot] sur l'axe X d'un graphique
  /// défini par [chartDates].
  ///
  /// - Filtre sur la fenêtre temporelle [chartDates.first … chartDates.last]
  ///   par jour local normalisé (heure 00:00).
  /// - Projette via [HistoryAggregator.findNearestIndexBounded].
  /// - Retourne [] si [chartDates] est vide ou si < 2 points sont produits.
  ///
  /// La lecture [SnapshotStorage.getSnapshots] RESTE dans la vue.
  static List<FlSpot> projectSnapshotsToChart(
    List<ValuationSnapshot> snapshots,
    List<DateTime> chartDates,
  ) {
    if (chartDates.isEmpty) return [];

    final chartStart = chartDates.first;
    final chartEnd = chartDates.last;

    final spots = <FlSpot>[];

    for (final snap in snapshots) {
      // Convertir 'YYYY-MM-DD' en DateTime (date locale, heure 00:00)
      final snapDate = DateTime.tryParse(snap.date);
      if (snapDate == null) continue;

      // Filtrer sur la période affichée
      final snapDay = DateTime(snapDate.year, snapDate.month, snapDate.day);
      final startDay = DateTime(chartStart.year, chartStart.month, chartStart.day);
      final endDay = DateTime(chartEnd.year, chartEnd.month, chartEnd.day);
      if (snapDay.isBefore(startDay) || snapDay.isAfter(endDay)) continue;

      // Trouver l'indice X le plus proche dans chartDates
      final xIndex = HistoryAggregator.findNearestIndexBounded(chartDates, snapDay);
      if (xIndex == -1) continue;

      spots.add(FlSpot(xIndex.toDouble(), snap.totalValue));
    }

    // Moins de 2 points → série non affichée (pas de droite possible)
    return spots.length >= 2 ? spots : [];
  }
}

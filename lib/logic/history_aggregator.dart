// lib/logic/history_aggregator.dart

import 'dart:math';

import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/utils/logger.dart';

/// Résultat de [HistoryAggregator.aggregateGlobalHistoricalData].
typedef GlobalAggregationResult = ({
  List<DateTime> chartDates,
  List<double> chartValues,
  double? periodStartValue,
  double? periodEndValue,
  double? periodChange,
  double? periodChangePercent,
});

/// Résultat de [HistoryAggregator.aggregateHistoricalData].
typedef AccountAggregationResult = ({
  List<DateTime> dates,
  List<double> values,
  double? startValue,
  double? endValue,
  double? change,
  double? changePercent,
});

/// Résultat de [HistoryAggregator.computeAccountsPeriodChanges].
typedef AccountsPeriodChangesResult = ({
  Map<String, double> accountPeriodChanges,
  Map<String, double> accountPeriodChangePercents,
});

/// Agrégation de données historiques. Toutes les méthodes sont statiques et
/// pures : aucun accès à l'état d'un widget, aucun I/O.
class HistoryAggregator {
  HistoryAggregator._(); // classe non instanciable

  // ---------------------------------------------------------------------------
  // Recherche de l'index le plus proche — DEUX variantes aux comportements
  // distincts aux bornes. NE PAS fusionner : wallet_view et account_view
  // utilisent chacun leur propre variante.
  // ---------------------------------------------------------------------------

  /// Version de wallet_view : AVEC gardes aux bornes.
  ///
  /// Si [target] est avant la première date, retourne 0.
  /// Si [target] est après la dernière date, retourne [dates.length - 1].
  /// Sinon, retourne l'indice de la date la plus proche.
  static int findNearestIndexBounded(List<DateTime> dates, DateTime target) {
    if (dates.isEmpty) return -1;
    if (target.isBefore(dates.first)) return 0;
    if (target.isAfter(dates.last)) return dates.length - 1;

    int closestIndex = 0;
    DateTime closestDate = dates[0];

    for (int i = 0; i < dates.length; i++) {
      final diff = dates[i].difference(target).abs();
      final closestDiff = closestDate.difference(target).abs();

      if (diff < closestDiff) {
        closestDate = dates[i];
        closestIndex = i;
      }
    }
    return closestIndex;
  }

  /// Version de account_view : SANS gardes aux bornes.
  ///
  /// Retourne toujours l'indice de la date la plus proche, même si [target]
  /// est avant la première ou après la dernière date.
  /// Comportement aux bornes identique à findNearestIndexBounded pour les
  /// dates dans la plage, mais sans le clamp précoce pour les dates hors plage.
  static int findNearestIndexUnbounded(List<DateTime> dates, DateTime target) {
    if (dates.isEmpty) return -1;

    int closestIndex = 0;
    DateTime closestDate = dates[0];

    for (int i = 0; i < dates.length; i++) {
      if (dates[i].difference(target).abs().compareTo(closestDate.difference(target).abs()) < 0) {
        closestDate = dates[i];
        closestIndex = i;
      }
    }

    return closestIndex;
  }

  // ---------------------------------------------------------------------------
  // Agrégation globale (wallet_view : _aggregateGlobalHistoricalData)
  // ---------------------------------------------------------------------------

  /// Agrège les données historiques de tous les symboles du patrimoine en une
  /// seule série temporelle EUR.
  ///
  /// - [symbolToData] : map symbole → données historiques.
  /// - [allPositionsData] : toutes les positions avec données de marché.
  /// - [cashBalances] : map accountId → solde cash EN EUR (constant sur toutes
  ///   les dates).
  /// - [usdToEurRate] : taux de change USD→EUR courant.
  ///
  /// Retourne un [GlobalAggregationResult]. Si aucune date historique n'est
  /// disponible, chartDates et chartValues sont vides et les valeurs de période
  /// sont null.
  static GlobalAggregationResult aggregateGlobalHistoricalData({
    required Map<String, AssetHistoricalData?> symbolToData,
    required List<PositionWithMarketData> allPositionsData,
    required Map<String, double> cashBalances,
    required double usdToEurRate,
  }) {
    final allDates = <DateTime>{};
    for (final data in symbolToData.values) {
      if (data != null && !data.isEmpty) {
        allDates.addAll(data.dates);
      }
    }

    if (allDates.isEmpty) {
      return (
        chartDates: <DateTime>[],
        chartValues: <double>[],
        periodStartValue: null,
        periodEndValue: null,
        periodChange: null,
        periodChangePercent: null,
      );
    }

    final sortedDates = allDates.toList()..sort();
    final dateValues = <DateTime, double>{};

    for (final targetDate in sortedDates) {
      double totalValueEur = 0;

      // Ajouter les soldes cash (constants pour chaque date)
      for (final cashBalance in cashBalances.values) {
        totalValueEur += cashBalance;
      }

      for (final positionData in allPositionsData) {
        final symbol = positionData.symbol;
        final historicalData = symbolToData[symbol];

        if (historicalData != null && !historicalData.isEmpty) {
          final index = findNearestIndexBounded(historicalData.dates, targetDate);

          if (index != -1) {
            final quantity = double.tryParse(positionData.quantity) ?? 0;
            double price = historicalData.prices[index].toDouble();

            if (positionData.asset.currency.toUpperCase() == 'USD') {
              price = price * usdToEurRate;
            }

            totalValueEur += price * quantity;
          }
        }
      }

      dateValues[targetDate] = totalValueEur;
    }

    final chartDates = dateValues.keys.toList()..sort();
    final chartValues = chartDates.map((date) => dateValues[date] ?? 0).toList();

    double? periodStartValue;
    double? periodEndValue;
    double? periodChange;
    double? periodChangePercent;

    if (chartValues.isNotEmpty) {
      periodStartValue = chartValues.first;
      periodEndValue = chartValues.last;
      periodChange = periodEndValue - periodStartValue;
      periodChangePercent = periodStartValue != 0
          ? (periodChange / periodStartValue) * 100
          : 0.0;
    }

    return (
      chartDates: chartDates,
      chartValues: chartValues,
      periodStartValue: periodStartValue,
      periodEndValue: periodEndValue,
      periodChange: periodChange,
      periodChangePercent: periodChangePercent,
    );
  }

  // ---------------------------------------------------------------------------
  // Variations par compte (wallet_view : _computeAccountsPeriodChanges)
  // ---------------------------------------------------------------------------

  /// Calcule les variations de période pour chaque compte à partir de la map
  /// d'historique DÉJÀ récupérée (plus aucun appel réseau ici).
  ///
  /// Les comptes cash reçoivent une variation de 0 (solde statique).
  static AccountsPeriodChangesResult computeAccountsPeriodChanges({
    required List<Account> accounts,
    required Map<String, List<PositionWithMarketData>> accountPositions,
    required Map<String, AssetHistoricalData?> symbolToData,
    required double usdToEurRate,
  }) {
    final accountPeriodChanges = <String, double>{};
    final accountPeriodChangePercents = <String, double>{};

    for (final account in accounts) {
      // COMPTES CASH : Pas de variation historique (solde statique)
      if (account.type == AccountType.cash) {
        accountPeriodChanges[account.id] = 0;
        accountPeriodChangePercents[account.id] = 0;
        continue;
      }

      final positions = accountPositions[account.id] ?? [];

      if (positions.isEmpty) {
        accountPeriodChanges[account.id] = 0;
        accountPeriodChangePercents[account.id] = 0;
        continue;
      }

      double startValue = 0;
      double endValue = 0;

      for (final pos in positions) {
        final hData = symbolToData[pos.symbol];
        if (hData != null && !hData.isEmpty) {
          final qty = double.tryParse(pos.quantity) ?? 0;

          double startPrice = hData.prices.first.toDouble();
          double endPrice = hData.prices.last.toDouble();

          if (pos.asset.currency.toUpperCase() == 'USD') {
            startPrice *= usdToEurRate;
            endPrice *= usdToEurRate;
          }

          startValue += startPrice * qty;
          endValue += endPrice * qty;
        }
      }

      final change = endValue - startValue;
      final changePercent = startValue != 0 ? (change / startValue) * 100 : 0.0;

      accountPeriodChanges[account.id] = change;
      accountPeriodChangePercents[account.id] = changePercent;
    }

    return (
      accountPeriodChanges: accountPeriodChanges,
      accountPeriodChangePercents: accountPeriodChangePercents,
    );
  }

  // ---------------------------------------------------------------------------
  // Agrégation par compte (account_view : _aggregateHistoricalData)
  // ---------------------------------------------------------------------------

  /// Agrège les données historiques de toutes les positions d'un compte.
  ///
  /// [results] et [currentPositions] sont appairés par index (results[i]
  /// correspond à currentPositions[i]). Les positions sans donnée historique
  /// (null/empty) sont ignorées sans décaler les autres index.
  ///
  /// ⚠️ Utilise [findNearestIndexUnbounded] (variante sans gardes aux bornes),
  /// conformément à l'implémentation originale de account_view.
  static AccountAggregationResult aggregateHistoricalData({
    required List<AssetHistoricalData?> results,
    required List<PositionWithMarketData> currentPositions,
    required double usdToEurRate,
  }) {
    final maxLen = min(results.length, currentPositions.length);

    // Retourne le résultat historique valide pour une position donnée, ou null.
    AssetHistoricalData? validResultAt(int i) {
      final data = results[i];
      if (data != null && !data.isEmpty) return data;
      return null;
    }

    final hasAnyValidResult = List<int>.generate(maxLen, (i) => i)
        .any((i) => validResultAt(i) != null);

    if (!hasAnyValidResult) {
      return (
        dates: <DateTime>[],
        values: <double>[],
        startValue: null,
        endValue: null,
        change: null,
        changePercent: null,
      );
    }

    // Collecter toutes les dates uniques
    final allDates = <DateTime>{};
    for (int i = 0; i < maxLen; i++) {
      final result = validResultAt(i);
      if (result == null) continue;
      allDates.addAll(result.dates);
    }

    final sortedDates = allDates.toList()..sort();

    // Pré-calculer un index date→prix pour chaque position (évite la recherche
    // linéaire répétée). null pour les positions sans donnée historique.
    final dateToPriceMaps = <Map<DateTime, double>?>[];
    for (int i = 0; i < maxLen; i++) {
      final result = validResultAt(i);
      if (result == null) {
        dateToPriceMaps.add(null);
        continue;
      }
      final map = <DateTime, double>{};
      for (int j = 0; j < result.dates.length; j++) {
        map[result.dates[j]] = result.prices[j].toDouble();
      }
      dateToPriceMaps.add(map);
    }

    final dateValues = <DateTime, double>{};

    for (final date in sortedDates) {
      double totalValueEur = 0;

      for (int i = 0; i < maxLen; i++) {
        final result = validResultAt(i);
        if (result == null) continue; // Position sans donnée historique

        final positionData = currentPositions[i];
        final position = positionData.position;
        final quantity = double.tryParse(position.quantity) ?? 0;

        // Recherche directe dans le map pré-calculé
        double? price = dateToPriceMaps[i]![date];

        // Si pas de prix exact, chercher le plus proche
        if (price == null) {
          final nearestIdx = findNearestIndexUnbounded(result.dates, date);
          if (nearestIdx == -1) continue;
          price = result.prices[nearestIdx].toDouble();
        }

        if (position.asset.currency.toUpperCase() == 'USD') {
          price = price * usdToEurRate;
        }

        totalValueEur += price * quantity;
      }

      dateValues[date] = totalValueEur;
    }

    final chartDates = dateValues.keys.toList()..sort();
    final chartValues = chartDates.map((d) => dateValues[d] ?? 0).toList();

    double? startValue, endValue, change, changePercent;
    if (chartValues.isNotEmpty) {
      startValue = chartValues.first;
      endValue = chartValues.last;
      change = endValue - startValue;
      changePercent = startValue != 0 ? (change / startValue) * 100 : 0.0;
    }

    return (
      dates: chartDates,
      values: chartValues,
      startValue: startValue,
      endValue: endValue,
      change: change,
      changePercent: changePercent,
    );
  }

  // ---------------------------------------------------------------------------
  // Variations individuelles (account_view : _computeIndividualPeriodChanges)
  // ---------------------------------------------------------------------------

  /// Calcule les variations individuelles de chaque position.
  ///
  /// Retourne une nouvelle liste de [PositionWithMarketData] (ne mute pas
  /// l'état). [results] et [currentPositions] sont appairés par index.
  ///
  /// ⚠️ [copyWith] de [PositionWithMarketData] utilise ?? et ne peut pas
  /// remettre un champ à null — la sémantique est conservée à l'identique.
  static List<PositionWithMarketData> computeIndividualPeriodChanges({
    required List<AssetHistoricalData?> results,
    required List<PositionWithMarketData> currentPositions,
    required double usdToEurRate,
  }) {
    if (results.length != currentPositions.length) {
      AppLogger.warning(
        'Mismatch: ${currentPositions.length} positions vs ${results.length} résultats historiques',
      );
      // On ne traite que les indices communs
    }

    final maxLen = min(results.length, currentPositions.length);

    return List<PositionWithMarketData>.generate(currentPositions.length, (i) {
      final positionData = currentPositions[i];

      if (i >= maxLen) return positionData; // Pas de donnée historique dispo

      final historicalData = results[i];

      if (historicalData != null && !historicalData.isEmpty) {
        final startPrice = historicalData.prices.first.toDouble();
        final endPrice = historicalData.prices.last.toDouble();
        final quantity = double.tryParse(positionData.quantity) ?? 0;
        final isUsd = positionData.asset.currency.toUpperCase() == 'USD';

        final startPriceEur = isUsd ? startPrice * usdToEurRate : startPrice;
        final endPriceEur = isUsd ? endPrice * usdToEurRate : endPrice;

        final periodChange = (endPriceEur - startPriceEur) * quantity;
        final startValue = startPriceEur * quantity;
        final periodChangePercent = startValue != 0
            ? ((endPriceEur - startPriceEur) / startPriceEur * 100)
            : 0.0;

        return positionData.copyWith(
          periodChange: periodChange,
          periodChangePercent: periodChangePercent,
        );
      }

      return positionData;
    });
  }
}

// test/logic/history_aggregator_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

AssetHistoricalData _histData(String symbol, List<DateTime> dates, List<double> prices) {
  return AssetHistoricalData(symbol: symbol, dates: dates, prices: prices);
}

PositionWithMarketData _makePos({
  required String symbol,
  required String currency,
  required String quantity,
  double? price,
}) {
  final asset = Asset(symbol: symbol, currency: currency);
  final position = Position(accountId: 'acc1', asset: asset, quantity: quantity);
  return PositionWithMarketData(position: position, currentPrice: price);
}

Account _makeAccount(String id, AccountKind kind) {
  return Account(id: id, walletId: 'w1', name: 'Compte $id', kind: kind);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // findNearestIndexBounded (variante wallet_view — AVEC gardes aux bornes)
  // =========================================================================

  group('HistoryAggregator.findNearestIndexBounded', () {
    final dates = [
      DateTime(2024, 6, 10),
      DateTime(2024, 6, 15),
      DateTime(2024, 6, 20),
    ];

    test('liste vide → -1', () {
      expect(HistoryAggregator.findNearestIndexBounded([], DateTime(2024, 6, 15)), -1);
    });

    test('date exacte → indice correct', () {
      expect(HistoryAggregator.findNearestIndexBounded(dates, DateTime(2024, 6, 15)), 1);
    });

    test('date entre deux bornes → indice le plus proche', () {
      // 2024-06-13 : diff(10,13)=3j, diff(15,13)=2j → plus proche du 15 (index 1)
      expect(HistoryAggregator.findNearestIndexBounded(dates, DateTime(2024, 6, 13)), 1);
    });

    test('bounded : date AVANT la première → retourne 0 (garde isBefore active)', () {
      expect(HistoryAggregator.findNearestIndexBounded(dates, DateTime(2024, 1, 1)), 0);
    });

    test('bounded : date APRÈS la dernière → retourne length-1 (garde isAfter active)', () {
      expect(
        HistoryAggregator.findNearestIndexBounded(dates, DateTime(2025, 1, 1)),
        dates.length - 1,
      );
    });

    test('date exactement à la première → 0', () {
      expect(HistoryAggregator.findNearestIndexBounded(dates, DateTime(2024, 6, 10)), 0);
    });

    test('date exactement à la dernière → length-1', () {
      expect(HistoryAggregator.findNearestIndexBounded(dates, DateTime(2024, 6, 20)), 2);
    });
  });

  // =========================================================================
  // findNearestIndexUnbounded (variante account_view — SANS gardes aux bornes)
  // =========================================================================

  group('HistoryAggregator.findNearestIndexUnbounded', () {
    final dates = [
      DateTime(2024, 6, 10),
      DateTime(2024, 6, 15),
      DateTime(2024, 6, 20),
    ];

    test('liste vide → -1', () {
      expect(HistoryAggregator.findNearestIndexUnbounded([], DateTime(2024, 6, 15)), -1);
    });

    test('date exacte → indice correct', () {
      expect(HistoryAggregator.findNearestIndexUnbounded(dates, DateTime(2024, 6, 15)), 1);
    });

    test('unbounded : date AVANT la première → 0 (via loop, pas de garde)', () {
      // Sans garde, le loop compare et trouve que dates[0] est la plus proche
      expect(HistoryAggregator.findNearestIndexUnbounded(dates, DateTime(2024, 1, 1)), 0);
    });

    test('unbounded : date APRÈS la dernière → length-1 (via loop, pas de garde)', () {
      expect(
        HistoryAggregator.findNearestIndexUnbounded(dates, DateTime(2025, 1, 1)),
        dates.length - 1,
      );
    });

    test('divergence documentée : bounded retourne 0 via garde isBefore, '
        'unbounded via loop — résultat identique mais chemin différent', () {
      // Une date très antérieure à la liste :
      // Bounded → court-circuite via isBefore → 0 immédiatement
      // Unbounded → parcourt toute la liste → retourne 0 (le plus proche)
      final veryOld = DateTime(2000, 1, 1);
      expect(HistoryAggregator.findNearestIndexBounded(dates, veryOld), 0);
      expect(HistoryAggregator.findNearestIndexUnbounded(dates, veryOld), 0);
    });

    test('divergence documentée : bounded court-circuite via isAfter, '
        'unbounded via loop pour date après la dernière', () {
      // Une date très postérieure à la liste :
      // Bounded → court-circuite via isAfter → length-1 immédiatement
      // Unbounded → parcourt toute la liste → retourne length-1
      final future = DateTime(2099, 12, 31);
      expect(HistoryAggregator.findNearestIndexBounded(dates, future), 2);
      expect(HistoryAggregator.findNearestIndexUnbounded(dates, future), 2);
    });
  });

  // =========================================================================
  // aggregateGlobalHistoricalData (wallet_view)
  // =========================================================================

  group('HistoryAggregator.aggregateGlobalHistoricalData', () {
    test('dates unifiées multi-séries : toutes les dates sont présentes', () {
      final d1 = [DateTime(2024, 6, 10), DateTime(2024, 6, 12)];
      final d2 = [DateTime(2024, 6, 11), DateTime(2024, 6, 13)];

      final pos1 = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '1', price: 100.0);
      final pos2 = _makePos(symbol: 'BBB', currency: 'EUR', quantity: '1', price: 200.0);

      final symbolToData = {
        'AAA': _histData('AAA', d1, [100.0, 110.0]),
        'BBB': _histData('BBB', d2, [200.0, 220.0]),
      };

      final result = HistoryAggregator.aggregateGlobalHistoricalData(
        symbolToData: symbolToData,
        allPositionsData: [pos1, pos2],
        cashBalances: {},
        usdToEurRate: 0.92,
      );

      // 4 dates uniques
      expect(result.chartDates.length, 4);
      expect(result.chartDates.first, DateTime(2024, 6, 10));
      expect(result.chartDates.last, DateTime(2024, 6, 13));
    });

    test('cash constant ajouté à chaque date', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '1', price: 100.0);

      final symbolToData = {
        'AAA': _histData('AAA', dates, [100.0, 110.0]),
      };

      const cashBalance = 500.0;
      final result = HistoryAggregator.aggregateGlobalHistoricalData(
        symbolToData: symbolToData,
        allPositionsData: [pos],
        cashBalances: {'cashAcc': cashBalance},
        usdToEurRate: 0.92,
      );

      // À la date[0] : prix AAA = 100 × 1 = 100 + 500 cash = 600
      expect(result.chartValues[0], closeTo(600.0, 1e-9));
      // À la date[1] : prix AAA = 110 × 1 = 110 + 500 cash = 610
      expect(result.chartValues[1], closeTo(610.0, 1e-9));
    });

    test('start/end/change/percent corrects', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '2', price: 100.0);

      final symbolToData = {
        'AAA': _histData('AAA', dates, [100.0, 150.0]),
      };

      final result = HistoryAggregator.aggregateGlobalHistoricalData(
        symbolToData: symbolToData,
        allPositionsData: [pos],
        cashBalances: {},
        usdToEurRate: 0.92,
      );

      // start = 100×2 = 200, end = 150×2 = 300
      expect(result.periodStartValue, closeTo(200.0, 1e-9));
      expect(result.periodEndValue, closeTo(300.0, 1e-9));
      expect(result.periodChange, closeTo(100.0, 1e-9));
      expect(result.periodChangePercent, closeTo(50.0, 1e-9));
    });

    test('startValue == 0 → periodChangePercent = 0 (pas de division par zéro)', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '1', price: 0.0);

      final symbolToData = {
        'AAA': _histData('AAA', dates, [0.0, 100.0]),
      };

      final result = HistoryAggregator.aggregateGlobalHistoricalData(
        symbolToData: symbolToData,
        allPositionsData: [pos],
        cashBalances: {},
        usdToEurRate: 0.92,
      );

      expect(result.periodStartValue, 0.0);
      expect(result.periodChangePercent, 0.0);
    });

    test('aucune donnée historique → chartDates et chartValues vides', () {
      final result = HistoryAggregator.aggregateGlobalHistoricalData(
        symbolToData: {'AAA': null},
        allPositionsData: [],
        cashBalances: {},
        usdToEurRate: 0.92,
      );

      expect(result.chartDates, isEmpty);
      expect(result.chartValues, isEmpty);
    });
  });

  // =========================================================================
  // computeAccountsPeriodChanges (wallet_view)
  // =========================================================================

  group('HistoryAggregator.computeAccountsPeriodChanges', () {
    test('compte cash → variation = 0', () {
      final account = _makeAccount('cash1', AccountKind.cash);
      final result = HistoryAggregator.computeAccountsPeriodChanges(
        accounts: [account],
        accountPositions: {},
        symbolToData: {},
        usdToEurRate: 0.92,
      );

      expect(result.accountPeriodChanges['cash1'], 0.0);
      expect(result.accountPeriodChangePercents['cash1'], 0.0);
    });

    test('compte investissement avec positions → change et percent corrects', () {
      final account = _makeAccount('inv1', AccountKind.autre);
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '2', price: 100.0);
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];

      final result = HistoryAggregator.computeAccountsPeriodChanges(
        accounts: [account],
        accountPositions: {'inv1': [pos]},
        symbolToData: {'AAA': _histData('AAA', dates, [100.0, 120.0])},
        usdToEurRate: 0.92,
      );

      // start = 100×2 = 200, end = 120×2 = 240, change = 40
      expect(result.accountPeriodChanges['inv1'], closeTo(40.0, 1e-9));
      expect(result.accountPeriodChangePercents['inv1'], closeTo(20.0, 1e-9));
    });

    test('compte investissement sans positions → variation = 0', () {
      final account = _makeAccount('inv2', AccountKind.autre);
      final result = HistoryAggregator.computeAccountsPeriodChanges(
        accounts: [account],
        accountPositions: {'inv2': []},
        symbolToData: {},
        usdToEurRate: 0.92,
      );

      expect(result.accountPeriodChanges['inv2'], 0.0);
      expect(result.accountPeriodChangePercents['inv2'], 0.0);
    });
  });

  // =========================================================================
  // aggregateHistoricalData (account_view)
  // =========================================================================

  group('HistoryAggregator.aggregateHistoricalData', () {
    test('dates unifiées, start/end/change/percent corrects', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '3', price: 100.0);

      final result = HistoryAggregator.aggregateHistoricalData(
        results: [_histData('AAA', dates, [100.0, 130.0])],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      // start = 100×3 = 300, end = 130×3 = 390
      expect(result.startValue, closeTo(300.0, 1e-9));
      expect(result.endValue, closeTo(390.0, 1e-9));
      expect(result.change, closeTo(90.0, 1e-9));
      expect(result.changePercent, closeTo(30.0, 1e-9));
    });

    test('startValue == 0 → changePercent = 0 (pas de division par zéro)', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '1', price: 0.0);

      final result = HistoryAggregator.aggregateHistoricalData(
        results: [_histData('AAA', dates, [0.0, 100.0])],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      expect(result.startValue, 0.0);
      expect(result.changePercent, 0.0);
    });

    test('position USD : conversion appliquée', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'USD1', currency: 'USD', quantity: '1', price: 100.0);

      final result = HistoryAggregator.aggregateHistoricalData(
        results: [_histData('USD1', dates, [100.0, 100.0])],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      // Prix × rate = 100 × 0.92 = 92 EUR, start = end → change = 0
      expect(result.startValue, closeTo(92.0, 1e-9));
      expect(result.endValue, closeTo(92.0, 1e-9));
      expect(result.change, closeTo(0.0, 1e-9));
    });

    test('tous les résultats null → dates et values vides', () {
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '1', price: 100.0);
      final result = HistoryAggregator.aggregateHistoricalData(
        results: [null],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      expect(result.dates, isEmpty);
      expect(result.values, isEmpty);
      expect(result.change, isNull);
    });

    test('dates multi-séries unifiées', () {
      final d1 = [DateTime(2024, 6, 10), DateTime(2024, 6, 12)];
      final d2 = [DateTime(2024, 6, 11), DateTime(2024, 6, 13)];
      final pos1 = _makePos(symbol: 'AA', currency: 'EUR', quantity: '1', price: 100.0);
      final pos2 = _makePos(symbol: 'BB', currency: 'EUR', quantity: '1', price: 200.0);

      final result = HistoryAggregator.aggregateHistoricalData(
        results: [_histData('AA', d1, [100.0, 110.0]), _histData('BB', d2, [200.0, 220.0])],
        currentPositions: [pos1, pos2],
        usdToEurRate: 0.92,
      );

      // 4 dates uniques
      expect(result.dates.length, 4);
    });
  });

  // =========================================================================
  // computeIndividualPeriodChanges (account_view)
  // =========================================================================

  group('HistoryAggregator.computeIndividualPeriodChanges', () {
    test('calcule correctement periodChange et periodChangePercent', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '2', price: 100.0);

      final updated = HistoryAggregator.computeIndividualPeriodChanges(
        results: [_histData('AAA', dates, [100.0, 150.0])],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      // periodChange = (150-100) × 2 = 100
      // periodChangePercent = (150-100)/100 × 100 = 50%
      expect(updated[0].periodChange, closeTo(100.0, 1e-9));
      expect(updated[0].periodChangePercent, closeTo(50.0, 1e-9));
    });

    test('position sans donnée historique → conservée telle quelle', () {
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '1', price: 100.0);

      final updated = HistoryAggregator.computeIndividualPeriodChanges(
        results: [null],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      expect(updated[0].periodChange, isNull);
      expect(updated[0].periodChangePercent, isNull);
    });

    test('position USD : conversion appliquée', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'USD1', currency: 'USD', quantity: '1', price: 100.0);

      final updated = HistoryAggregator.computeIndividualPeriodChanges(
        results: [_histData('USD1', dates, [100.0, 200.0])],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      // startEur = 100×0.92 = 92, endEur = 200×0.92 = 184
      // periodChange = (184-92) × 1 = 92
      expect(updated[0].periodChange, closeTo(92.0, 1e-9));
    });

    test('startValue == 0 → periodChangePercent = 0 (pas de division par zéro)', () {
      final dates = [DateTime(2024, 6, 10), DateTime(2024, 6, 11)];
      final pos = _makePos(symbol: 'AAA', currency: 'EUR', quantity: '1', price: 0.0);

      final updated = HistoryAggregator.computeIndividualPeriodChanges(
        results: [_histData('AAA', dates, [0.0, 100.0])],
        currentPositions: [pos],
        usdToEurRate: 0.92,
      );

      expect(updated[0].periodChangePercent, 0.0);
    });
  });
}

// test/logic/history_aggregator_test.dart
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
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

  // =========================================================================
  // priceEurAt (helper partagé A1 — extrait de reconstructRealNetWorth)
  // =========================================================================

  group('HistoryAggregator.priceEurAt', () {
    test('data null → 0.0', () {
      expect(
        HistoryAggregator.priceEurAt(null, null, DateTime(2024, 6, 15), 0.92),
        0.0,
      );
    });

    test('data vide → 0.0', () {
      final empty = _histData('AAA', [], []);
      expect(
        HistoryAggregator.priceEurAt(empty, null, DateTime(2024, 6, 15), 0.92),
        0.0,
      );
    });

    test('EUR : prix brut, pas de conversion', () {
      final data = _histData('AAA', [DateTime(2024, 6, 10)], [100.0]);
      final asset = Asset(symbol: 'AAA', currency: 'EUR');
      expect(
        HistoryAggregator.priceEurAt(data, asset, DateTime(2024, 6, 10), 0.92),
        100.0,
      );
    });

    test('USD : conversion via usdToEurRate', () {
      final data = _histData('AAA', [DateTime(2024, 6, 10)], [100.0]);
      final asset = Asset(symbol: 'AAA', currency: 'USD');
      expect(
        HistoryAggregator.priceEurAt(data, asset, DateTime(2024, 6, 10), 0.92),
        closeTo(92.0, 1e-9),
      );
    });

    test('asset null : traité comme non-USD (pas de conversion)', () {
      final data = _histData('AAA', [DateTime(2024, 6, 10)], [100.0]);
      expect(
        HistoryAggregator.priceEurAt(data, null, DateTime(2024, 6, 10), 0.92),
        100.0,
      );
    });

    test('date hors bornes → clampée (findNearestIndexBounded)', () {
      final data = _histData(
        'AAA',
        [DateTime(2024, 6, 10), DateTime(2024, 6, 20)],
        [100.0, 120.0],
      );
      final asset = Asset(symbol: 'AAA', currency: 'EUR');
      // Avant la première date → clampé au premier prix.
      expect(
        HistoryAggregator.priceEurAt(data, asset, DateTime(2024, 1, 1), 0.92),
        100.0,
      );
      // Après la dernière date → clampé au dernier prix.
      expect(
        HistoryAggregator.priceEurAt(data, asset, DateTime(2025, 1, 1), 0.92),
        120.0,
      );
    });
  });

  // =========================================================================
  // computeRealGains (B7 correction financière — gain de PÉRIODE, Modified
  // Dietz). Le gain TOTAL est désormais un calcul SÉPARÉ, cf.
  // test/logic/real_net_worth_test.dart : HistoryAggregator.computeRealTotalGain.
  // =========================================================================

  group('HistoryAggregator.computeRealGains', () {
    test('cas nominal (2 points) : periodGain et periodGainPercent corrects', () {
      // V 40000→52000, F 8000→15000 (exemple de la spec). Avec 2 points, le
      // seul flux intermédiaire coïncide avec le point final (poids Modified
      // Dietz = 0) : le dénominateur se réduit à V[0] — cas dégénéré attendu.
      final gains = HistoryAggregator.computeRealGains(
        values: [40000.0, 52000.0],
        externalFlows: [8000.0, 15000.0],
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 31)],
      );

      // periodGain = (52000-40000) - (15000-8000) = 12000 - 7000 = 5000
      expect(gains.periodGain, closeTo(5000.0, 1e-9));
      // periodGainPercent = 5000 / 40000 * 100 = 12.5
      expect(gains.periodGainPercent, closeTo(12.5, 1e-9));
    });

    test('moins-value : periodGain négatif', () {
      final gains = HistoryAggregator.computeRealGains(
        values: [10000.0, 9000.0],
        externalFlows: [8000.0, 8000.0],
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 31)],
      );

      // gap[0] = 2000, gap[1] = 1000 → periodGain = -1000
      expect(gains.periodGain, closeTo(-1000.0, 1e-9));
      expect(gains.periodGainPercent, closeTo(-10.0, 1e-9)); // -1000/10000
    });

    test('N < 2 (un seul point) : tout null (pas de fenêtre)', () {
      final gains = HistoryAggregator.computeRealGains(
        values: [12000.0],
        externalFlows: [10000.0],
        gridDates: [DateTime(2024, 1, 1)],
      );

      expect(gains.periodGain, isNull);
      expect(gains.periodGainPercent, isNull);
    });

    test('N == 0 (listes vides) : tout null', () {
      final gains = HistoryAggregator.computeRealGains(
        values: [],
        externalFlows: [],
        gridDates: [],
      );

      expect(gains.periodGain, isNull);
      expect(gains.periodGainPercent, isNull);
    });

    test('longueurs V/F/gridDates différentes : incohérent → tout null', () {
      final gains = HistoryAggregator.computeRealGains(
        values: [1000.0, 2000.0, 3000.0],
        externalFlows: [1000.0, 2000.0],
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 2), DateTime(2024, 1, 3)],
      );

      expect(gains.periodGain, isNull);
      expect(gains.periodGainPercent, isNull);
    });

    test('gridDates de longueur différente de values (même si F correspond) → tout null', () {
      final gains = HistoryAggregator.computeRealGains(
        values: [1000.0, 2000.0],
        externalFlows: [1000.0, 2000.0],
        gridDates: [DateTime(2024, 1, 1)],
      );

      expect(gains.periodGain, isNull);
      expect(gains.periodGainPercent, isNull);
    });

    test('denom <= 0 → periodGainPercent null, mais periodGain reste calculé', () {
      final gains = HistoryAggregator.computeRealGains(
        values: [0.0, 5000.0],
        externalFlows: [0.0, 4000.0],
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 31)],
      );

      // periodGain = (5000-0) - (4000-0) = 1000, calculable même si V[0] == 0
      expect(gains.periodGain, closeTo(1000.0, 1e-9));
      expect(gains.periodGainPercent, isNull);
    });

    test(
      'Modified Dietz : gros dépôt EN MILIEU de fenêtre → % PAS gonflé par '
      'rapport au % naïf periodGain/V[0]',
      () {
        // Grille à 3 points régulièrement espacés : début, milieu, fin.
        final gridDates = [
          DateTime(2024, 1, 1),
          DateTime(2024, 1, 16), // milieu (15 jours des deux côtés sur 30)
          DateTime(2024, 1, 31),
        ];
        // Dépôt de 9000 survenu exactement au point milieu (F saute de 0 à
        // 9000 entre l'index 0 et l'index 1, rien entre 1 et 2).
        final values = [1000.0, 10000.0, 10100.0];
        final externalFlows = [0.0, 9000.0, 9000.0];

        final gains = HistoryAggregator.computeRealGains(
          values: values,
          externalFlows: externalFlows,
          gridDates: gridDates,
        );

        // periodGain = (10100-1000) - (9000-0) = 9100 - 9000 = 100 (gain de
        // marché RÉEL, isolé du dépôt).
        expect(gains.periodGain, closeTo(100.0, 1e-9));

        // % naïf (periodGain/V[0]*100) serait 100/1000*100 = 10 % — trompeur,
        // car il ignore que 9000 des 10000 n'étaient investis que sur la
        // moitié de la fenêtre.
        const naivePercent = 100.0 / 1000.0 * 100.0;
        expect(gains.periodGainPercent, isNot(closeTo(naivePercent, 1e-6)));

        // Modified Dietz : denom = V[0] + w1·(F[1]-F[0]) + w2·(F[2]-F[1])
        //                = 1000 + 0.5·9000 + 0·0 = 5500
        // periodGainPercent = 100/5500*100 ≈ 1.818 % — bien plus bas que le %
        // naïf, cohérent avec un capital réellement engagé bien supérieur.
        expect(gains.periodGainPercent, closeTo(100.0 / 5500.0 * 100.0, 1e-6));
        expect(gains.periodGainPercent! < naivePercent, isTrue);
      },
    );

    test(
      'cash pur ajouté en constante aux deux séries : periodGain INCHANGÉ '
      '(la constante s\'annule dans l\'écart valeur−flux)',
      () {
        const pureCash = 50000.0;
        final gridDates = [DateTime(2024, 1, 1), DateTime(2024, 1, 31)];
        final withoutCash = HistoryAggregator.computeRealGains(
          values: [40000.0, 52000.0],
          externalFlows: [8000.0, 15000.0],
          gridDates: gridDates,
        );
        final withCash = HistoryAggregator.computeRealGains(
          values: [40000.0 + pureCash, 52000.0 + pureCash],
          externalFlows: [8000.0 + pureCash, 15000.0 + pureCash],
          gridDates: gridDates,
        );

        // Le GAIN (montant) est rigoureusement identique...
        expect(withCash.periodGain, closeTo(withoutCash.periodGain!, 1e-9));
        // ...mais le POURCENTAGE diffère : son dénominateur (V[0]) inclut, lui,
        // la constante cash — c'est volontaire (cf. doc de computeRealGains).
        expect(
          withCash.periodGainPercent,
          isNot(closeTo(withoutCash.periodGainPercent!, 1e-6)),
        );
      },
    );

    // -----------------------------------------------------------------------
    // Préfixe « patrimoine inexistant » (régression du 29/07) — sur « Max », la
    // grille vient de l'historique de COTATION du titre : un ETF listé en 2001
    // impose 25 ans de grille à un compte ouvert en 2023, ce qui écrasait les
    // pondérations Modified Dietz et faisait exploser le `%` (+3 688 %).
    // -----------------------------------------------------------------------

    test('préfixe entièrement nul : la fenêtre effective démarre au dernier '
        'point nul, le % n\'est plus dilué par les années « à vide »', () {
      // 20 ans de grille, patrimoine créé seulement sur les 2 dernières
      // années : 1000 € apportés, valant 1200 € à la fin.
      final dates = [
        DateTime(2006, 1, 1),
        DateTime(2016, 1, 1),
        DateTime(2024, 1, 1), // dernier point nul → borne gauche effective
        DateTime(2025, 1, 1), // apport de 1000
        DateTime(2026, 1, 1),
      ];
      final gains = HistoryAggregator.computeRealGains(
        values: [0.0, 0.0, 0.0, 1000.0, 1200.0],
        externalFlows: [0.0, 0.0, 0.0, 1000.0, 1000.0],
        gridDates: dates,
      );

      // periodGain est INCHANGÉ par le bornage (préfixe nul des deux séries).
      expect(gains.periodGain, closeTo(200.0, 1e-9));

      // Fenêtre effective 2024→2026 (2 ans). Le flux de 1000 tombe à
      // mi-parcours → poids (2026-2025)/(2026-2024) = 0,5 → denom = 500.
      // → 200 / 500 = +40 %. Sur la grille COMPLÈTE (20 ans), le poids aurait
      // été ~0,05 → denom ~50 → +400 %, chiffre absurde que ce test verrouille.
      expect(gains.periodGainPercent, closeTo(40.0, 0.5));
      expect(gains.periodGainPercent, lessThan(100.0));
    });

    test('préfixe nul : l\'annualisé est calculé sur la durée EFFECTIVE, pas '
        'sur la grille complète', () {
      final dates = [
        DateTime(2006, 1, 1),
        DateTime(2024, 1, 1),
        DateTime(2025, 1, 1),
        DateTime(2026, 1, 1),
      ];
      final gains = HistoryAggregator.computeRealGains(
        values: [0.0, 0.0, 1000.0, 1200.0],
        externalFlows: [0.0, 0.0, 1000.0, 1000.0],
        gridDates: dates,
      );

      // Fenêtre effective = 2 ans (>= 548 j) → annualisé produit, et STRICTEMENT
      // inférieur au cumulé (composition sur 2 ans), pas dilué sur 20 ans.
      expect(gains.periodGainPercentAnnualized, isNotNull);
      expect(
        gains.periodGainPercentAnnualized!,
        lessThan(gains.periodGainPercent!),
      );
      // Sur 2 ans : (1+0,4)^(1/2) − 1 ≈ +18,3 %/an.
      expect(gains.periodGainPercentAnnualized, closeTo(18.3, 1.0));
    });

    test('AUCUN préfixe nul (cas courant) : calcul strictement identique '
        '(non-régression du bornage)', () {
      final dates = [
        DateTime(2024, 1, 1),
        DateTime(2024, 6, 1),
        DateTime(2024, 12, 1),
      ];
      final gains = HistoryAggregator.computeRealGains(
        values: [10000.0, 11000.0, 12500.0],
        externalFlows: [8000.0, 8500.0, 8500.0],
        gridDates: dates,
      );

      // periodGain = (12500-10000) - (8500-8000) = 2000.
      expect(gains.periodGain, closeTo(2000.0, 1e-9));
      // denom = 10000 + w × 500 avec w = (12/01 - 06/01)/(12/01 - 01/01),
      // soit ~0,545 → ~10272 → ~19,5 %.
      expect(gains.periodGainPercent, closeTo(19.47, 0.1));
    });

    test('séries entièrement nulles : tout null (aucune fenêtre exploitable)', () {
      final gains = HistoryAggregator.computeRealGains(
        values: [0.0, 0.0, 0.0],
        externalFlows: [0.0, 0.0, 0.0],
        gridDates: [
          DateTime(2024, 1, 1),
          DateTime(2025, 1, 1),
          DateTime(2026, 1, 1),
        ],
      );

      expect(gains.periodGain, isNull);
      expect(gains.periodGainPercent, isNull);
    });
  });

  // =========================================================================
  // Annualisation du % de période (B7 lot annualisation) — cf. doc dense de
  // computeRealGains : sur les fenêtres longues (>= 1 an), le % Modified
  // Dietz cumulé (rapporté au capital MOYEN pondéré) devient difficile à
  // comparer d'une fenêtre à l'autre ; on lui ADJOINT (jamais on ne le
  // remplace) un rendement annualisé, comparable à un indice.
  // =========================================================================

  group('HistoryAggregator.computeRealGains — annualisation', () {
    test(
      'fenêtre < 1 an : periodGainPercent cumulé inchangé, '
      'periodGainPercentAnnualized == null',
      () {
        // Cas nominal repris ci-dessus : 30 jours, très en-deçà du seuil de
        // 365 jours.
        final gains = HistoryAggregator.computeRealGains(
          values: [40000.0, 52000.0],
          externalFlows: [8000.0, 15000.0],
          gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 31)],
        );

        expect(gains.periodGainPercent, closeTo(12.5, 1e-9));
        expect(gains.periodGainPercentAnnualized, isNull);
      },
    );

    test(
      'fenêtre de 12 ans, r = 1.834 (183.4 % cumulé) : periodGainPercent '
      'reste 183.4 %, periodGainPercentAnnualized ≈ 9.07 %',
      () {
        // 2 points ⇒ denom Modified Dietz se réduit à V[0] (cf. commentaire du
        // cas nominal plus haut) : periodGainPercent cumulé == periodGain/V[0]*100,
        // ce qui permet de viser r = 1.834 exactement. Span calé sur
        // 12 x 365.25 jours PILE (plutôt que deux dates calendaires) pour que
        // `years` vaille exactement 12 dans la formule d'annualisation, sans
        // aléa de calendrier (années bissextiles).
        final start = DateTime(2012, 1, 1);
        final end = start.add(const Duration(days: 4383)); // 12 x 365.25

        const v0 = 20000.0;
        const periodGain = 1.834 * v0; // r = periodGain / v0 = 1.834
        final gains = HistoryAggregator.computeRealGains(
          values: [v0, v0 + periodGain],
          externalFlows: [0.0, 0.0],
          gridDates: [start, end],
        );

        // Cumulé = 183.4 % avant annualisation (vérifie l'hypothèse de calcul
        // ci-dessus avant de juger l'annualisation elle-même).
        expect(gains.periodGain, closeTo(periodGain, 1e-6));

        // Le cumulé N'EST PLUS JAMAIS écrasé : les deux valeurs coexistent.
        expect(gains.periodGainPercent, closeTo(183.4, 0.05));
        expect(gains.periodGainPercentAnnualized, closeTo(9.07, 0.05));
      },
    );

    test(
      'fenêtre exactement 548 jours (18 mois, borne incluse) : annualisé '
      'non-null et FRANCHEMENT distinct du cumulé',
      () {
        final gains = HistoryAggregator.computeRealGains(
          values: [10000.0, 12000.0],
          externalFlows: [0.0, 0.0],
          gridDates: [
            DateTime(2022, 1, 1),
            DateTime(2022, 1, 1).add(const Duration(days: 548)),
          ],
        );

        // Cumulé = 20 % (periodGain/V[0]) INCHANGÉ ; annualisé ≈ 12,9 %/an —
        // l'écart justifie l'affichage du second nombre.
        expect(gains.periodGainPercent, closeTo(20.0, 1e-6));
        expect(gains.periodGainPercentAnnualized, closeTo(12.9, 0.2));
      },
    );

    test(
      'fenêtre de 365 jours PILE : PAS d\'annualisé — la formule redonnerait '
      'le cumulé (doublon inutile à l\'écran)',
      () {
        final gains = HistoryAggregator.computeRealGains(
          values: [10000.0, 11000.0],
          externalFlows: [0.0, 0.0],
          gridDates: [
            DateTime(2022, 1, 1),
            DateTime(2022, 1, 1).add(const Duration(days: 365)),
          ],
        );

        expect(gains.periodGainPercent, closeTo(10.0, 1e-6));
        expect(gains.periodGainPercentAnnualized, isNull);
      },
    );

    test(
      'fenêtre juste sous le seuil (547 jours) : pas encore annualisée',
      () {
        final gains = HistoryAggregator.computeRealGains(
          values: [10000.0, 11000.0],
          externalFlows: [0.0, 0.0],
          gridDates: [
            DateTime(2022, 1, 1),
            DateTime(2022, 1, 1).add(const Duration(days: 547)),
          ],
        );

        expect(gains.periodGainPercent, closeTo(10.0, 1e-6));
        expect(gains.periodGainPercentAnnualized, isNull);
      },
    );

    test(
      'perte cumulée >= 100 % (1 + r <= 0) sur une fenêtre longue : cumulé '
      'conservé, periodGainPercentAnnualized == null (racine réelle impossible)',
      () {
        final start = DateTime(2012, 1, 1);
        final end = start.add(const Duration(days: 4383)); // 12 ans, >= 365

        // r = -1.5 (perte de 150 % du capital moyen) : 1 + r = -0.5 <= 0.
        final gains = HistoryAggregator.computeRealGains(
          values: [10000.0, -5000.0],
          externalFlows: [0.0, 0.0],
          gridDates: [start, end],
        );

        expect(gains.periodGainPercent, closeTo(-150.0, 1e-6));
        expect(gains.periodGainPercentAnnualized, isNull);
      },
    );

    test(
      'span nul (deux points à la même date) : pas de crash, cumulé conservé',
      () {
        final sameDate = DateTime(2024, 6, 1);
        expect(
          () => HistoryAggregator.computeRealGains(
            values: [10000.0, 10500.0],
            externalFlows: [0.0, 0.0],
            gridDates: [sameDate, sameDate],
          ),
          returnsNormally,
        );

        final gains = HistoryAggregator.computeRealGains(
          values: [10000.0, 10500.0],
          externalFlows: [0.0, 0.0],
          gridDates: [sameDate, sameDate],
        );
        // spanDays == 0 < 365 : jamais annualisé, aucun NaN/crash.
        expect(gains.periodGainPercentAnnualized, isNull);
        expect(gains.periodGainPercent, closeTo(5.0, 1e-9));
      },
    );
  });

  // =========================================================================
  // buildDateGrid (design B8, doc 19 §4.3/§7 Lot 1) : grille synthétique pour
  // un patrimoine (ou compte) SANS AUCUN titre — pas de série de prix pour en
  // dériver une grille. PUR, sans I/O.
  // =========================================================================

  group('HistoryAggregator.buildDateGrid', () {
    test('plage tenant dans maxPoints : un point par jour, from et to inclus', () {
      final grid = HistoryAggregator.buildDateGrid(
        from: DateTime(2024, 1, 1),
        to: DateTime(2024, 1, 5),
        maxPoints: 365,
      );

      expect(grid, [
        DateTime.utc(2024, 1, 1),
        DateTime.utc(2024, 1, 2),
        DateTime.utc(2024, 1, 3),
        DateTime.utc(2024, 1, 4),
        DateTime.utc(2024, 1, 5),
      ]);
    });

    test('date-only UTC : heure/minute ignorées (normalisation cohérente avec '
        '_dateOnlyUtc de position_projection.dart, doc 19 §4.3 règle 1)', () {
      final grid = HistoryAggregator.buildDateGrid(
        from: DateTime(2024, 1, 1, 23, 59),
        to: DateTime(2024, 1, 2, 0, 1),
        maxPoints: 365,
      );

      expect(grid, [DateTime.utc(2024, 1, 1), DateTime.utc(2024, 1, 2)]);
      // Toutes les dates produites sont bien UTC, sans composante horaire.
      for (final d in grid) {
        expect(d.isUtc, isTrue);
        expect(d.hour, 0);
        expect(d.minute, 0);
      }
    });

    test('borne gauche = from (déjà résolu par l\'appelant comme max(période, '
        'premier mouvement), doc 19 §4.3 règle 2) : AUCUN point avant', () {
      // Simule un appelant qui a résolu from = max(début de période demandé,
      // premier mouvement du journal) — ici le journal ne remonte qu'au
      // 10 mars 2024, bien après le début de période réclamé (2020).
      final periodStart = DateTime(2020, 1, 1);
      final firstMovement = DateTime(2024, 3, 10);
      final from =
          firstMovement.isAfter(periodStart) ? firstMovement : periodStart;

      final grid = HistoryAggregator.buildDateGrid(
        from: from,
        to: DateTime(2024, 3, 12),
        maxPoints: 365,
      );

      expect(grid.first, DateTime.utc(2024, 3, 10));
      expect(
        grid.any((d) => d.isBefore(DateTime.utc(2024, 3, 10))),
        isFalse,
        reason: 'avant le premier mouvement, la valeur est 0 — pas une '
            'extrapolation, donc pas de point fabriqué',
      );
    });

    test('plage dépassant maxPoints (perf « Max » ~10 ans, §8.5) : '
        'sous-échantillonnée à un pas régulier, "to" TOUJOURS le dernier point', () {
      final from = DateTime(2014, 1, 1);
      final to = DateTime(2024, 1, 1); // ~3653 jours
      const maxPoints = 200;

      final grid = HistoryAggregator.buildDateGrid(
        from: from,
        to: to,
        maxPoints: maxPoints,
      );

      // Budget respecté (à ±1 point près, le dernier segment pouvant être
      // plus court que le pas).
      expect(grid.length, lessThanOrEqualTo(maxPoints + 1));
      expect(grid.first, DateTime.utc(2014, 1, 1));
      expect(grid.last, DateTime.utc(2024, 1, 1));

      // Sous-échantillonnage réel : jamais un point par jour sur cette plage.
      for (var i = 1; i < grid.length - 1; i++) {
        expect(
          grid[i].difference(grid[i - 1]).inDays,
          greaterThan(1),
          reason: 'pas régulier attendu, pas un point par jour',
        );
      }
    });

    test('plage EXACTEMENT égale à maxPoints jours (borne incluse) : '
        'encore un point par jour', () {
      final from = DateTime(2024, 1, 1);
      final to = from.add(const Duration(days: 30));

      final grid = HistoryAggregator.buildDateGrid(
        from: from,
        to: to,
        maxPoints: 30,
      );

      expect(grid.length, 31); // 30 jours d'écart + le point de départ
    });

    test('from == to : un seul point, pas de fabrication', () {
      final d = DateTime(2024, 6, 15);
      final grid =
          HistoryAggregator.buildDateGrid(from: d, to: d, maxPoints: 100);

      expect(grid, [DateTime.utc(2024, 6, 15)]);
    });

    test('from postérieur à to (plage inversée, défensif) : un seul point, '
        'pas de crash', () {
      final grid = HistoryAggregator.buildDateGrid(
        from: DateTime(2024, 6, 20),
        to: DateTime(2024, 6, 10),
        maxPoints: 100,
      );

      expect(grid, [DateTime.utc(2024, 6, 20)]);
    });
  });

  // =========================================================================
  // Escalier de cash d'un compte cash ANCRÉ (design B8, doc 19 §4.3) —
  // buildCashTimeline/cashAt/journalHasCashAnchor de position_projection.dart,
  // DÉJÀ testés unitairement ailleurs (real_net_worth_test.dart) : ici on
  // vérifie le scénario du lot B8, un livret avec openingBalance + deposit +
  // withdrawal + interest datés.
  // =========================================================================

  group('Escalier de cash d\'un compte cash ancré (livret)', () {
    test('openingBalance puis deposit/withdrawal/interest datés → escalier '
        'attendu à chaque date, y compris AVANT tout mouvement', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'livret1',
        symbol: null,
        kind: TransactionKind.openingBalance,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'livret1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '500',
        currency: 'EUR',
        date: DateTime(2024, 2, 1),
      );
      final withdrawal = AssetTransaction(
        id: 'w1',
        accountId: 'livret1',
        symbol: null,
        kind: TransactionKind.withdrawal,
        amount: '-200',
        currency: 'EUR',
        date: DateTime(2024, 3, 1),
      );
      final interest = AssetTransaction(
        id: 'i1',
        accountId: 'livret1',
        symbol: null,
        kind: TransactionKind.interest,
        amount: '15',
        currency: 'EUR',
        date: DateTime(2024, 4, 1),
      );

      final txs = [opening, deposit, withdrawal, interest];
      // Prérequis du scénario : ce journal ANCRE bien le compte (opening
      // ESPÈCES est un mouvement d'ancrage, cf. position_projection.dart:477).
      expect(journalHasCashAnchor(txs), isTrue);

      final timeline = buildCashTimeline(txs);

      // Avant tout mouvement : map vide (≡ 0, aucune poche connue).
      expect(cashAt(timeline, DateTime(2023, 12, 31)), isEmpty);
      // Après l'ouverture (1er janvier) : 1000.
      expect(cashAt(timeline, DateTime(2024, 1, 15))['EUR'], Decimal.parse('1000'));
      // Après le dépôt (1er février) : 1000 + 500 = 1500.
      expect(cashAt(timeline, DateTime(2024, 2, 15))['EUR'], Decimal.parse('1500'));
      // Après le retrait (1er mars) : 1500 − 200 = 1300.
      expect(cashAt(timeline, DateTime(2024, 3, 15))['EUR'], Decimal.parse('1300'));
      // Après les intérêts (1er avril) : 1300 + 15 = 1315.
      expect(cashAt(timeline, DateTime(2024, 4, 15))['EUR'], Decimal.parse('1315'));
    });
  });

  // =========================================================================
  // reconstructRealNetWorth avec un compte cash ANCRÉ dans txsByAccount
  // (design B8, doc 19 §4.3 : « aucune signature à changer — élargir
  // simplement txsByAccount aux comptes cash côté appelant »). Non-régression
  // sur le cas titres seuls (déjà couvert en détail par real_net_worth_test.
  // dart) ET nouveau cas : un livret ancré SEUL, aucun titre.
  // =========================================================================

  group('HistoryAggregator.reconstructRealNetWorth — compte cash ancré '
      '(design B8)', () {
    test('non-régression : titres seuls, aucun compte cash → comportement '
        'inchangé', () {
      final buyTx = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '100',
        amount: '-1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      final hist = _histData('AAPL', [DateTime(2024, 1, 2)], [100.0]);

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buyTx],
        },
        txsByAccount: {
          'acc1': [buyTx],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 2)],
      );

      // Compte NON ancré (que des buy) : cash non injecté, seule la valeur
      // titre compte — comportement identique à avant B8.
      expect(r.values.single, 1000.0);
    });

    test('NOUVEAU : un livret ancré SEUL (zéro titre) contribue via le '
        'journal, comme un escalier réel — PAS comme une constante '
        'rétroprojetée (cas d\'usage central de B8, doc 19 §0.3)', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'livret1',
        symbol: null,
        kind: TransactionKind.openingBalance,
        amount: '2000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final interest = AssetTransaction(
        id: 'i1',
        accountId: 'livret1',
        symbol: null,
        kind: TransactionKind.interest,
        amount: '20',
        currency: 'EUR',
        date: DateTime(2024, 6, 1),
      );

      // Aucun titre → aucune grille de prix : buildDateGrid fournit la
      // grille synthétique (le SEUL nouveau cas d'usage de la fonction).
      final gridDates = HistoryAggregator.buildDateGrid(
        from: DateTime(2024, 1, 1),
        to: DateTime(2024, 12, 31),
        maxPoints: 365,
      );

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: const {},
        txsByAccount: {
          'livret1': [opening, interest],
        },
        symbolToData: const {},
        assetBySymbol: const {},
        usdToEurRate: 1.0,
        gridDates: gridDates,
      );

      final idxBeforeInterest = gridDates.indexOf(DateTime.utc(2024, 5, 1));
      final idxAfterInterest = gridDates.indexOf(DateTime.utc(2024, 7, 1));
      expect(idxBeforeInterest, isNot(-1));
      expect(idxAfterInterest, isNot(-1));

      // Escalier réel : 2000 avant l'intérêt de juin, 2020 après — PAS une
      // constante de 2020 rétroprojetée sur toute l'année (ce que ferait
      // l'ANCIEN traitement via addConstantPureCash).
      expect(r.values[idxBeforeInterest], 2000.0);
      expect(r.values[idxAfterInterest], 2020.0);
      expect(r.values.first, 2000.0); // 1er janvier : avant tout intérêt
      expect(r.values.last, 2020.0); // 31 décembre : après l'intérêt
    });
  });

  // =========================================================================
  // ANTI-DOUBLE-COMPTAGE DU CASH — piège n°1 [BLOQUANT], doc 19 §6.5/§8.1 :
  // un compte cash ANCRÉ ne doit contribuer QUE via txsByAccount
  // (reconstructRealNetWorth), JAMAIS aussi via addConstantPureCash. Ce test
  // doit échouer clairement si un futur lot régresse sur cet invariant (ex.
  // un contrôleur qui recommencerait à sommer TOUS les comptes cash dans
  // pureCashEur sans filtrer par journalHasCashAnchor).
  // =========================================================================

  group('Anti-double-comptage du cash (invariant §6.5, PIÈGE N°1 [BLOQUANT])', () {
    test('un compte cash ancré compté DEUX FOIS (reconstructRealNetWorth + '
        'addConstantPureCash) diverge du compte correct (une seule fois)', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'livretAncre',
        symbol: null,
        kind: TransactionKind.openingBalance,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      // Prérequis du scénario : ce compte EST ancré (sinon le piège ne se
      // pose pas — un compte non ancré est de toute façon hors de
      // txsByAccount pour le cash, cf. gating M1).
      expect(journalHasCashAnchor([opening]), isTrue);

      final gridDates = [DateTime(2024, 1, 1), DateTime(2024, 1, 10)];

      // Chemin CORRECT (design B8 §1) : le compte ancré passe par
      // txsByAccount UNIQUEMENT — reconstructRealNetWorth en dérive le cash
      // une seule fois.
      final correct = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: const {},
        txsByAccount: {
          'livretAncre': [opening],
        },
        symbolToData: const {},
        assetBySymbol: const {},
        usdToEurRate: 1.0,
        gridDates: gridDates,
      );
      expect(correct.values, [1000.0, 1000.0]);

      // Chemin FAUTIF (régression du piège n°1) : le MÊME compte ancré est
      // EN PLUS injecté en constante via addConstantPureCash — exactement
      // l'erreur qu'un appelant du Lot 2 doit éviter en filtrant les comptes
      // cash par journalHasCashAnchor avant de composer pureCashEur.
      final wronglyDoubleCounted =
          HistoryAggregator.addConstantPureCash(correct.values, 1000.0);

      // Les deux résultats ne doivent JAMAIS coïncider : si ce test se
      // mettait à échouer parce que `wronglyDoubleCounted == correct.values`,
      // ce serait le signe d'une régression AILLEURS qui aurait swallow le
      // double comptage, pas une preuve qu'il est devenu inoffensif.
      expect(wronglyDoubleCounted, isNot(equals(correct.values)));
      expect(wronglyDoubleCounted, [2000.0, 2000.0]);

      // Documentation exécutable de l'invariant : composé CORRECTEMENT
      // (aucun compte non ancré supplémentaire ici → pureCashEur = 0), le
      // résultat final doit rester identique à `correct` seul.
      final properlyComposed =
          HistoryAggregator.addConstantPureCash(correct.values, 0.0);
      expect(properlyComposed, correct.values);
    });
  });

  // ===========================================================================
  // Borne gauche « Max » (29/07) : la grille naît de l'historique de COTATION
  // (Yahoo range=max), qui remonte à l'introduction du support — 22 ans de
  // ligne plate à zéro devant un compte ouvert bien plus tard. « Max » doit
  // signifier « depuis le début de MON suivi ».
  // ===========================================================================

  group('HistoryAggregator.applyGridFrom', () {
    final grid = [
      DateTime(2001, 1, 1),
      DateTime(2015, 6, 1),
      DateTime(2023, 5, 10, 17, 35),
      DateTime(2024, 1, 1),
    ];

    test('from null : grille INCHANGÉE (périodes autres que Max)', () {
      expect(HistoryAggregator.applyGridFrom(grid, null), same(grid));
    });

    test('grille vide : renvoyée telle quelle', () {
      expect(HistoryAggregator.applyGridFrom(const [], DateTime(2024)), isEmpty);
    });

    test('coupe ce qui précède, en CONSERVANT un point d\'ancrage à zéro', () {
      final trimmed =
          HistoryAggregator.applyGridFrom(grid, DateTime(2023, 5, 10, 10));
      // Le 2015 est gardé comme ANCRE (patrimoine encore à 0 ce jour-là) : sans
      // lui, le premier point porterait déjà la position déclarée du 10/05 et
      // « gain(Max) » ne partirait pas de zéro. Tout le reste (2001) est coupé.
      expect(trimmed, [
        DateTime(2015, 6, 1),
        DateTime(2023, 5, 10, 17, 35),
        DateTime(2024, 1, 1),
      ]);
    });

    test('borne antérieure à TOUTE la grille : aucune ancre à ajouter, grille '
        'complète', () {
      expect(HistoryAggregator.applyGridFrom(grid, DateTime(1990)), grid);
    });

    test('invariant d\'ancrage : le premier point retenu est TOUJOURS '
        'antérieur au premier mouvement (sauf s\'il n\'en existe aucun)', () {
      final from = DateTime(2023, 5, 10, 10);
      final trimmed = HistoryAggregator.applyGridFrom(grid, from);
      expect(trimmed.first.isBefore(DateTime(2023, 5, 10)), isTrue);
    });

    test('le JOUR du premier mouvement est inclus même si le point coté est '
        'antérieur en heure (normalisation à minuit)', () {
      // Mouvement à 10h, cotation du même jour à 9h : le point DOIT rester —
      // et il n'y a rien avant, donc pas d'ancre à ajouter.
      final g = [DateTime(2023, 5, 10, 9), DateTime(2023, 5, 11)];
      final trimmed =
          HistoryAggregator.applyGridFrom(g, DateTime(2023, 5, 10, 10));
      expect(trimmed, g);
    });

    test('aucun point après la borne : grille COMPLÈTE conservée (repli — un '
        'graphe vide serait pire)', () {
      final trimmed = HistoryAggregator.applyGridFrom(grid, DateTime(2030));
      expect(trimmed, grid);
    });
  });
}

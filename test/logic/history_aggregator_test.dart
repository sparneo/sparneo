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
}

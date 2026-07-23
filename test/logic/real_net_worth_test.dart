// test/logic/real_net_worth_test.dart
//
// Mode 2 « évolution réelle du patrimoine » (B7, design doc 18, Lot 1) :
// HistoryAggregator.reconstructRealNetWorth, PURE, bâtie sur les timelines de
// position_projection.dart (buildQuantityTimeline / buildCashTimeline).

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';

AssetHistoricalData _histData(String symbol, List<DateTime> dates, List<double> prices) {
  return AssetHistoricalData(symbol: symbol, dates: dates, prices: prices);
}

void main() {
  group('HistoryAggregator.reconstructRealNetWorth — grille vide', () {
    test('gridDates vide → dates et values vides', () {
      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: const {},
        txsByAccount: const {},
        symbolToData: const {},
        assetBySymbol: const {},
        usdToEurRate: 1.0,
        gridDates: const [],
      );
      expect(r.dates, isEmpty);
      expect(r.values, isEmpty);
    });
  });

  group('HistoryAggregator.reconstructRealNetWorth — escalier + cash datés', () {
    test('titre acheté en cours de fenêtre + cash projeté : valeurs correctes à chaque date', () {
      // AAPL acheté le 2 (10 titres @100, réglé -1000), dépôt initial le 1er.
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
      final depositTx = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '2000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 3)],
        [100.0, 105.0],
      );

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buyTx],
        },
        txsByAccount: {
          'acc1': [depositTx, buyTx],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 3)],
      );

      // Date 1 : AAPL pas encore acheté (0 titre) ; cash = 2000 (dépôt seul).
      expect(r.values[0], 2000.0);
      // Date 3 : 10 AAPL @105 (prix le plus proche) + cash 2000-1000=1000.
      expect(r.values[1], 105.0 * 10 + 1000.0);
    });

    test('symbole soldé mi-période : contribue tant que détenu, 0 après (pas de fantôme, §8.5)', () {
      final buyTx = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '100',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final sellTx = AssetTransaction(
        id: 's1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.sell,
        quantity: '10',
        unitPrice: '110',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 5),
      );

      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 2), DateTime(2024, 1, 10)],
        [100.0, 120.0],
      );

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buyTx, sellTx],
        },
        txsByAccount: {
          'acc1': [buyTx, sellTx],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 2), DateTime(2024, 1, 10)],
      );

      expect(r.values[0], 100.0 * 10); // détenu, pas de cash ancré
      expect(r.values[1], 0.0, reason: 'soldé le 5 → 0, pas de valeur fantôme');
    });

    test('symbole sans historique de prix → contribue 0 (repli « dernier cours » = Lot 2, hors périmètre)', () {
      final buyTx = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'XYZ',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '100',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'XYZ': [buyTx],
        },
        txsByAccount: {
          'acc1': [buyTx],
        },
        symbolToData: {'XYZ': null}, // pas de donnée
        assetBySymbol: {'XYZ': Asset(symbol: 'XYZ', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 5)],
      );

      expect(r.values.single, 0.0);
    });
  });

  group('HistoryAggregator.reconstructRealNetWorth — gating cash (M1)', () {
    test('compte sans ancrage (que des buy) → cash NON injecté (pas de négatif fictif)', () {
      final buyOnly = AssetTransaction(
        id: 'x1',
        accountId: 'acc2',
        symbol: 'MSFT',
        kind: TransactionKind.buy,
        quantity: '5',
        unitPrice: '50',
        amount: '-250', // effet cash déclaré, mais le compte n'est PAS ancré
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final hist = _histData('MSFT', [DateTime(2024, 1, 1)], [50.0]);

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'MSFT': [buyOnly],
        },
        txsByAccount: {
          'acc2': [buyOnly],
        },
        symbolToData: {'MSFT': hist},
        assetBySymbol: {'MSFT': Asset(symbol: 'MSFT', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 1)],
      );

      // Sans le gating, on aurait 5×50 − 250 = 0. Avec gating : seul le titre
      // compte, le cash −250 (non ancré) est écarté.
      expect(r.values.single, 250.0);
    });

    test('compte ANCRÉ (deposit présent) → son cash EST injecté', () {
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc3',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: const {},
        txsByAccount: {
          'acc3': [deposit],
        },
        symbolToData: const {},
        assetBySymbol: const {},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 1)],
      );

      expect(r.values.single, 1000.0);
    });
  });

  group('Invariant §8.1/M4 — valeur_réelle(dernière date) == mode 1 (même dernier close, journal 100% journalisé)', () {
    test('fixture journalisée sans legacy : reconstructRealNetWorth == aggregateGlobalHistoricalData à t1', () {
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
      final depositTx = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '2000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final interestTx = AssetTransaction(
        id: 'i1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.interest,
        amount: '5',
        currency: 'EUR',
        date: DateTime(2024, 1, 10),
      );

      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 3), DateTime(2024, 1, 5), DateTime(2024, 1, 8), DateTime(2024, 1, 10)],
        [100.0, 105.0, 110.0, 115.0, 120.0],
      );
      final symbolToData = {'AAPL': hist};
      final gridDates = hist.dates;

      // Cash dérivé du même journal : 2000 − 1000 + 5 = 1005.
      final mode2 = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buyTx],
        },
        txsByAccount: {
          'acc1': [depositTx, buyTx, interestTx],
        },
        symbolToData: symbolToData,
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: gridDates,
      );

      // Mode 1 : mêmes quantités ACTUELLES (10, seule valeur finale du
      // journal) et même cash dérivé (1005), figés sur toute la fenêtre —
      // à la dernière date, les deux modes doivent coïncider (M4 : même
      // dernier close, mêmes quantités si journal complet).
      final asset = Asset(symbol: 'AAPL', currency: 'EUR');
      final position = Position(accountId: 'acc1', asset: asset, quantity: '10');
      final posWithData = PositionWithMarketData(position: position, currentPrice: 120.0);

      final mode1 = HistoryAggregator.aggregateGlobalHistoricalData(
        symbolToData: symbolToData,
        allPositionsData: [posWithData],
        cashBalances: {'acc1': 1005.0},
        usdToEurRate: 1.0,
      );

      expect(mode2.dates.last, gridDates.last);
      expect(mode1.chartDates.last, gridDates.last);
      expect(mode2.values.last, closeTo(mode1.chartValues.last, 1e-9));
      // Valeur explicite attendue : 120×10 + 1005 = 2205.
      expect(mode2.values.last, closeTo(2205.0, 1e-9));
    });
  });

  group('Change USD→EUR (M-1) — titre ET cash convertis au taux courant', () {
    test('titre USD + poche cash USD : les deux passent par usdToEurRate', () {
      // AAPL coté en USD : achat 10 @100 USD (titre, pas d'effet cash).
      final buyUsd = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '100',
        amount: null,
        currency: 'USD',
        date: DateTime(2024, 1, 1),
      );
      // Dépôt d'espèces EN USD (ancre le compte + poche cash USD).
      final depositUsd = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '500',
        currency: 'USD',
        date: DateTime(2024, 1, 1),
      );
      final hist = _histData('AAPL', [DateTime(2024, 1, 1)], [100.0]);

      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buyUsd],
        },
        txsByAccount: {
          'acc1': [depositUsd, buyUsd],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'USD')},
        usdToEurRate: 0.9,
        gridDates: [DateTime(2024, 1, 1)],
      );

      // Titre : 10×100×0.9 = 900 €. Cash : 500×0.9 = 450 €. Total 1350 €.
      // Sans conversion (bug fx), on lirait 1000 + 500 = 1500.
      expect(r.values.single, closeTo(1350.0, 1e-9));
    });
  });

  group('Aller-retour intraday (M-5) — se referme au close, un seul palier', () {
    test('achat +10 puis vente −10 le MÊME jour → timeline à un palier, qtyAfter 0', () {
      final buy = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '100',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 3, 9), // 9h
      );
      final sell = AssetTransaction(
        id: 's1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.sell,
        quantity: '10',
        unitPrice: '110',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 3, 15), // 15h, même jour
      );

      final timeline = buildQuantityTimeline([buy, sell]);
      // Coalescence par date-only : un seul palier pour le 3 janvier.
      expect(timeline.length, 1);
      expect(timeline.single.qtyAfter, Decimal.zero);

      // Et au niveau reconstruction : aucune valeur fantôme au close du jour.
      final hist = _histData('AAPL', [DateTime(2024, 1, 3)], [105.0]);
      final r = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buy, sell],
        },
        txsByAccount: {
          'acc1': [buy, sell],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 3)],
      );
      expect(r.values.single, 0.0);
    });
  });
}

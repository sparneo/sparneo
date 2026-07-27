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

  // ---------------------------------------------------------------------------
  // Lot 2 (glue réseau, design doc 18 §9) : les deux fonctions pures extraites
  // pour rester testables sans I/O — buildLastPriceFallback (repli « dernier
  // cours ») et addConstantPureCash (composition cash pur sans double-comptage).
  // ---------------------------------------------------------------------------

  group('HistoryAggregator.buildLastPriceFallback', () {
    test('titre détenu sans historique → série plate au dernier cours + repli non-null', () {
      final buyTx = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'XYZ',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '42',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final gridDates = [DateTime(2024, 1, 1), DateTime(2024, 1, 5), DateTime(2024, 1, 10)];
      final fallback = HistoryAggregator.buildLastPriceFallback(
        symbol: 'XYZ',
        txs: [buyTx],
        gridDates: gridDates,
      );

      expect(fallback, isNotNull);
      expect(fallback!.symbol, 'XYZ');
      expect(fallback.dates, [gridDates.first, gridDates.last]);
      expect(fallback.prices, [42.0, 42.0]);
    });

    test('dernier cours = unitPrice du dernier buy/sell CHRONOLOGIQUE, pas le dernier de la liste', () {
      final buyTx = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'XYZ',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '42',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final sellTx = AssetTransaction(
        id: 's1',
        accountId: 'acc1',
        symbol: 'XYZ',
        kind: TransactionKind.sell,
        quantity: '4',
        unitPrice: '50',
        currency: 'EUR',
        date: DateTime(2024, 1, 5),
      );

      // Liste passée dans l'ordre INVERSE de la date : le tri chronologique
      // interne doit malgré tout retenir le vendu (dernier dans le temps).
      final fallback = HistoryAggregator.buildLastPriceFallback(
        symbol: 'XYZ',
        txs: [sellTx, buyTx],
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 10)],
      );

      expect(fallback!.prices, [50.0, 50.0]);
    });

    test('symbole jamais détenu sur la fenêtre → null (pas de repli, pas de flag)', () {
      final buyTx = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'XYZ',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '42',
        currency: 'EUR',
        date: DateTime(2024, 1, 20), // après toute la fenêtre
      );

      final fallback = HistoryAggregator.buildLastPriceFallback(
        symbol: 'XYZ',
        txs: [buyTx],
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 10)],
      );

      expect(fallback, isNull);
    });

    test('aucun buy/sell avec unitPrice (ex. openingBalance sans prix) → repli à 0', () {
      final opening = AssetTransaction(
        id: 'o1',
        accountId: 'acc1',
        symbol: 'XYZ',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final fallback = HistoryAggregator.buildLastPriceFallback(
        symbol: 'XYZ',
        txs: [opening],
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 10)],
      );

      expect(fallback!.prices, [0.0, 0.0]);
    });
  });

  group('HistoryAggregator.addConstantPureCash — sans double-comptage', () {
    test('ajoute le cash pur en CONSTANTE à chaque point, sans toucher le cash déjà dérivé', () {
      // Reconstruction mode 2 d'un compte non-cash ANCRÉ (cash dérivé inclus
      // par reconstructRealNetWorth) : 1000 € de dépôt, titre acheté après.
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final buy = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '5',
        unitPrice: '100',
        amount: '-500',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      final hist = _histData('AAPL', [DateTime(2024, 1, 1), DateTime(2024, 1, 3)], [100.0, 100.0]);

      final reconstructed = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buy],
        },
        txsByAccount: {
          'acc1': [deposit, buy],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 3)],
      );
      // Avant cash pur : 0 (rien détenu) + 1000 (cash dérivé) = 1000, puis
      // 500 (5×100) + 500 (1000-500 cash dérivé) = 1000.
      expect(reconstructed.values, [1000.0, 1000.0]);

      // Un DEUXIÈME compte, de type cash pur (300 €, aucun journal), n'est PAS
      // connu de reconstructRealNetWorth (absent de txsByAccount) : composé
      // en aval, en CONSTANTE.
      final withPureCash = HistoryAggregator.addConstantPureCash(
        reconstructed.values,
        300.0,
      );

      expect(withPureCash, [1300.0, 1300.0]);
      // Le cash dérivé du compte non-cash (1000, variable selon la date dans
      // le cas général) n'est PAS resommé : seule la constante 300 s'ajoute,
      // identique aux deux points malgré des compositions internes distinctes.
      expect(withPureCash[0] - reconstructed.values[0], 300.0);
      expect(withPureCash[1] - reconstructed.values[1], 300.0);
    });

    test('pureCashEur == 0 → renvoie la même liste sans altération', () {
      final values = [10.0, 20.0, 30.0];
      final result = HistoryAggregator.addConstantPureCash(values, 0.0);
      expect(result, [10.0, 20.0, 30.0]);
    });
  });

  // ---------------------------------------------------------------------------
  // Lot 3b (design doc 18 §7.2/§11.4) : courbe des APPORTS NETS CUMULÉS
  // (versements − retraits d'espèces), superposée à la courbe de valeur en
  // mode réel — décision produit : cash PUR, pas la base flux complète.
  // ---------------------------------------------------------------------------

  group('HistoryAggregator.buildContributionsCurve', () {
    test('dépôt J1 puis retrait J5 : 0 avant J1, cumul en escalier ensuite', () {
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '2000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final withdrawal = AssetTransaction(
        id: 'w1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.withdrawal,
        amount: '-500',
        currency: 'EUR',
        date: DateTime(2024, 1, 5),
      );

      final gridDates = [
        DateTime(2023, 12, 31), // avant tout mouvement
        DateTime(2024, 1, 1), // jour du dépôt
        DateTime(2024, 1, 3), // entre les deux mouvements
        DateTime(2024, 1, 5), // jour du retrait
        DateTime(2024, 1, 10), // après
      ];

      final values = HistoryAggregator.buildContributionsCurve(
        txsByAccount: {
          'acc1': [deposit, withdrawal],
        },
        gridDates: gridDates,
        usdToEurRate: 1.0,
      );

      expect(values, [0.0, 2000.0, 2000.0, 1500.0, 1500.0]);
    });

    test('conversion USD : poche cash USD convertie au taux courant', () {
      final depositUsd = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'USD',
        date: DateTime(2024, 1, 1),
      );

      final values = HistoryAggregator.buildContributionsCurve(
        txsByAccount: {
          'acc1': [depositUsd],
        },
        gridDates: [DateTime(2024, 1, 1)],
        usdToEurRate: 0.9,
      );

      expect(values.single, closeTo(900.0, 1e-9));
    });

    test('buy/dividend ne contribuent JAMAIS aux apports (seuls deposit/withdrawal comptent)', () {
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final buy = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '5',
        unitPrice: '100',
        amount: '-500',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      final dividend = AssetTransaction(
        id: 'div1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.dividend,
        amount: '50',
        currency: 'EUR',
        date: DateTime(2024, 1, 3),
      );

      final values = HistoryAggregator.buildContributionsCurve(
        txsByAccount: {
          'acc1': [deposit, buy, dividend],
        },
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 3)],
        usdToEurRate: 1.0,
      );

      // Le buy (-500) et le dividende (+50) ne bougent JAMAIS l'apport : reste
      // à 1000 (le seul deposit) sur toute la fenêtre, malgré les mouvements
      // cash ultérieurs de buy/dividend.
      expect(values, [1000.0, 1000.0]);
    });

    test('gridDates vide → liste vide', () {
      final values = HistoryAggregator.buildContributionsCurve(
        txsByAccount: const {},
        gridDates: const [],
        usdToEurRate: 1.0,
      );
      expect(values, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // B7 correction financière (design §11.4) : courbe des FLUX EXTERNES
  // COMPLETS — remplace buildContributionsCurve pour la courbe superposée ET
  // pour computeRealGains (Modified Dietz). Deux briques : cash (a) + titre
  // valorisé au jour du flux (b), cf. doc de buildExternalFlowsCurve.
  // ---------------------------------------------------------------------------

  group('HistoryAggregator.buildExternalFlowsCurve', () {
    test('gridDates vide → liste vide', () {
      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: const {},
        txsByAccount: const {},
        symbolToData: const {},
        assetBySymbol: const {},
        gridDates: const [],
        usdToEurRate: 1.0,
      );
      expect(values, isEmpty);
    });

    test('openingBalance TITRE : valorisé au cours DU JOUR DU FLUX (pas le prix déclaré)', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50', // PRU déclaré — NE DOIT PAS servir à la valorisation
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 5)],
        [100.0, 110.0], // cours de MARCHÉ, différent du PRU déclaré (50)
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [opening],
        },
        txsByAccount: {
          'acc1': [opening],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2023, 12, 31), DateTime(2024, 1, 1), DateTime(2024, 1, 5)],
        usdToEurRate: 1.0,
      );

      // Avant le flux : 0. À partir du 1er janvier : 10 × 100 (cours du jour
      // du flux) = 1000, PAS 10 × 50 (PRU déclaré).
      expect(values, [0.0, 1000.0, 1000.0]);
    });

    test('transferOut PARTIELLEMENT clampé (M2) : contribue le delta EFFECTIF, pas le déclaré', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      // Déclare une sortie de 15 titres alors que seuls 10 sont détenus.
      final transferOut = AssetTransaction(
        id: 't1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.transferOut,
        quantity: '15',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 5),
      );
      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 5)],
        [100.0, 120.0],
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [opening, transferOut],
        },
        txsByAccount: {
          'acc1': [opening, transferOut],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 5)],
        usdToEurRate: 1.0,
      );

      // J1 : +10×100 = 1000. J5 : transferOut clampé à -10 (pas -15, stock
      // insuffisant) × 120 = -1200 → cumul = 1000 - 1200 = -200.
      expect(values, [1000.0, -200.0]);
    });

    test('buy/sell : flux 0 des deux côtés (transfert interne cash↔titre, pas un flux externe)', () {
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '2000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final buy = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '100',
        fee: '5',
        amount: '-1005',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      final hist = _histData('AAPL', [DateTime(2024, 1, 2)], [100.0]);

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [buy],
        },
        txsByAccount: {
          'acc1': [deposit, buy],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 2)],
        usdToEurRate: 1.0,
      );

      // Le dépôt (2000) reste seul visible : le buy (-1005 cash / +10 titres)
      // ne bouge JAMAIS le flux externe, malgré les frais inclus dans `amount`.
      expect(values, [2000.0, 2000.0]);
    });

    test('dividende/frais EXCLUS (performance, pas capital)', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final dividend = AssetTransaction(
        id: 'div1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.dividend,
        amount: '50',
        currency: 'EUR',
        date: DateTime(2024, 1, 3),
      );
      final charge = AssetTransaction(
        id: 'c1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.charge,
        amount: '-20',
        currency: 'EUR',
        date: DateTime(2024, 1, 4),
      );
      final hist = _histData('AAPL', [DateTime(2024, 1, 1)], [100.0]);

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [opening],
        },
        txsByAccount: {
          'acc1': [opening, dividend, charge],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 4)],
        usdToEurRate: 1.0,
      );

      // Seul l'openingBalance (1000) compte — ni le dividende ni le frais.
      expect(values, [1000.0, 1000.0]);
    });

    test('openingBalance/adjustment ESPÈCES : DÉSORMAIS en flux (non-régression du bug ex-buildContributionsCurve)', () {
      final openingCash = AssetTransaction(
        id: 'obc1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.openingBalance,
        amount: '500',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final adjustCash = AssetTransaction(
        id: 'adj1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.adjustment,
        amount: '-100',
        currency: 'EUR',
        date: DateTime(2024, 1, 5),
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: const {},
        txsByAccount: {
          'acc1': [openingCash, adjustCash],
        },
        symbolToData: const {},
        assetBySymbol: const {},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 5)],
        usdToEurRate: 1.0,
      );

      expect(values, [500.0, 400.0]);
    });

    test('adjustment TITRE : valorisé au jour du flux, distinct de l\'adjustment ESPÈCES', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final adjustTitre = AssetTransaction(
        id: 'adjt1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.adjustment,
        quantity: '5', // +5 titres (ex. attribution gratuite)
        unitPrice: '0',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 3),
      );
      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 3)],
        [100.0, 105.0],
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [opening, adjustTitre],
        },
        txsByAccount: {
          'acc1': [opening, adjustTitre],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 3)],
        usdToEurRate: 1.0,
      );

      // J1 : 10×100=1000. J3 : +5×105 (cours du jour, pas le prix nul déclaré
      // par l'ajustement) = 525 → cumul 1525.
      expect(values, [1000.0, 1525.0]);
    });

    test('aller-retour intraday : deux flux titre le MÊME jour se SOMMENT', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1, 9),
      );
      final adjustSameDay = AssetTransaction(
        id: 'adj1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.adjustment,
        quantity: '2',
        unitPrice: '0',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1, 15), // même jour, plus tard
      );
      final hist = _histData('AAPL', [DateTime(2024, 1, 1)], [100.0]);

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [opening, adjustSameDay],
        },
        txsByAccount: {
          'acc1': [opening, adjustSameDay],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1)],
        usdToEurRate: 1.0,
      );

      // (10+2) × 100 = 1200, les deux contributions du jour SOMMÉES (pas
      // "dernière écrase" comme un escalier d'état).
      expect(values.single, closeTo(1200.0, 1e-9));
    });

    test('USD : flux titre converti au taux courant', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50',
        amount: null,
        currency: 'USD',
        date: DateTime(2024, 1, 1),
      );
      final hist = _histData('AAPL', [DateTime(2024, 1, 1)], [100.0]);

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [opening],
        },
        txsByAccount: {
          'acc1': [opening],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'USD')},
        gridDates: [DateTime(2024, 1, 1)],
        usdToEurRate: 0.9,
      );

      // 10 × 100 USD × 0.9 = 900 EUR.
      expect(values.single, closeTo(900.0, 1e-9));
    });

    test('prix manquant pour le symbole : contribue 0 (repli géré en amont par l\'appelant)', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [opening],
        },
        txsByAccount: {
          'acc1': [opening],
        },
        symbolToData: {'AAPL': null}, // pas de repli fourni ici
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1)],
        usdToEurRate: 1.0,
      );

      expect(values.single, 0.0);
    });
  });

  // ---------------------------------------------------------------------------
  // B7 correction financière (design §7.3, décision « voie b ») : gain TOTAL
  // en ÉTAT COURANT (base coût), INDÉPENDANT de toute grille de dates.
  // ---------------------------------------------------------------------------

  group('HistoryAggregator.computeRealTotalGain', () {
    PositionWithMarketData makePos({
      required String symbol,
      required String currency,
      required String quantity,
      double? price,
      double? pru,
    }) {
      final asset = Asset(symbol: symbol, currency: currency);
      final position = Position(
        accountId: 'acc1',
        asset: asset,
        quantity: quantity,
        averageBuyPrice: pru,
      );
      return PositionWithMarketData(position: position, currentPrice: price);
    }

    test('non-réalisé simple : une position à PRU connu', () {
      final pos = makePos(symbol: 'AAPL', currency: 'EUR', quantity: '10', price: 100.0, pru: 80.0);

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [pos],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 1.0,
      );

      // unrealizedGain = (100-80)×10 = 200 ; valueIncluded = 100×10 = 1000 ;
      // capital = 1000-200 = 800 ; percent = 200/800×100 = 25.
      expect(result.totalGain, closeTo(200.0, 1e-9));
      expect(result.totalGainPercent, closeTo(25.0, 1e-9));
      expect(result.noBasisSymbols, isEmpty);
    });

    test('le CASH entre dans le capital investi (dénominateur du %), jamais dans le gain', () {
      // 10 000 € versés : 5 000 € investis en titres valant 6 000 €, 5 000 €
      // restés en espèces. Le gain est de +1 000 € sur un capital de 10 000 €,
      // soit +10 % — et NON +20 % (ce que donnerait un capital amputé du cash).
      final pos = makePos(
        symbol: 'AAPL',
        currency: 'EUR',
        quantity: '100',
        price: 60.0,
        pru: 50.0,
      );

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [pos],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 1.0,
        cashEur: 5000.0,
      );

      // valueIncluded = 5000 (cash) + 6000 (titres) = 11000
      // capital = 11000 - 1000 = 10000 → 1000/10000 = +10 %
      expect(result.totalGain, closeTo(1000.0, 1e-9));
      expect(result.totalGainPercent, closeTo(10.0, 1e-9));
    });

    test('cash seul, aucun titre : capital = cash, gain nul', () {
      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 1.0,
        cashEur: 3000.0,
      );

      expect(result.totalGain, closeTo(0.0, 1e-9));
      // capital = 3000 - 0 = 3000 > 0 → 0/3000 = 0 %
      expect(result.totalGainPercent, closeTo(0.0, 1e-9));
    });

    test('réalisé : plus-value bookée sur une vente, titre totalement soldé', () {
      final buy = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '100',
        amount: '-1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final sell = AssetTransaction(
        id: 's1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.sell,
        quantity: '10',
        unitPrice: '120',
        amount: '1200',
        currency: 'EUR',
        date: DateTime(2024, 1, 10),
      );

      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [], // plus aucune position résiduelle
        txsBySymbol: {
          'AAPL': [buy, sell],
        },
        txsByAccount: {
          'acc1': [buy, sell],
        },
        usdToEurRate: 1.0,
      );

      // realizedGain = (120-100)×10 = 200. Aucune position → capital = -200
      // (négatif) → percent null, mais le montant reste calculé.
      expect(result.totalGain, closeTo(200.0, 1e-9));
      expect(result.totalGainPercent, isNull);
    });

    test('revenus : dividende/intérêt/frais SIGNÉS, aucun autre kind', () {
      final dividend = AssetTransaction(
        id: 'div1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.dividend,
        amount: '50',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final interest = AssetTransaction(
        id: 'int1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.interest,
        amount: '10',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      final charge = AssetTransaction(
        id: 'chg1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.charge,
        amount: '-5',
        currency: 'EUR',
        date: DateTime(2024, 1, 3),
      );
      // Un dépôt NE DOIT PAS être compté (partition stricte : ni performance).
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [],
        txsBySymbol: const {},
        txsByAccount: {
          'acc1': [dividend, interest, charge, deposit],
        },
        usdToEurRate: 1.0,
      );

      // 50 + 10 - 5 = 55 (le dépôt de 1000 est EXCLU).
      expect(result.totalGain, closeTo(55.0, 1e-9));
    });

    test('position sans PRU connu : EXCLUE des deux termes + noBasisSymbols', () {
      final posNoBasis = makePos(symbol: 'AAPL', currency: 'EUR', quantity: '10', price: 100.0, pru: null);
      final posWithBasis = makePos(symbol: 'MSFT', currency: 'EUR', quantity: '5', price: 50.0, pru: 40.0);

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [posNoBasis, posWithBasis],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 1.0,
      );

      // AAPL (sans PRU) exclue des deux termes : seule MSFT compte.
      // unrealized MSFT = (50-40)×5 = 50 ; valueIncluded = 50×5 = 250 ;
      // capital = 250-50 = 200 ; percent = 50/200×100 = 25.
      expect(result.totalGain, closeTo(50.0, 1e-9));
      expect(result.totalGainPercent, closeTo(25.0, 1e-9));
      expect(result.noBasisSymbols, {'AAPL'});
    });

    test('position LEGACY (aucune entrée dans txsBySymbol) avec PRU connu : INCLUSE', () {
      final legacyPos = makePos(symbol: 'LEGACY', currency: 'EUR', quantity: '5', price: 70.0, pru: 50.0);

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [legacyPos],
        txsBySymbol: const {}, // journal garanti vide (legacy)
        txsByAccount: const {},
        usdToEurRate: 1.0,
      );

      // unrealized = (70-50)×5 = 100.
      expect(result.totalGain, closeTo(100.0, 1e-9));
      expect(result.noBasisSymbols, isEmpty);
    });

    test('USD : non-réalisé converti au taux courant', () {
      final pos = makePos(symbol: 'AAPL', currency: 'USD', quantity: '10', price: 110.0, pru: 100.0);

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [pos],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 0.9,
      );

      // unrealized natif = (110-100)×10 = 100 USD × 0.9 = 90 EUR.
      // valueIncluded = 110×10×0.9 = 990 ; capital = 990-90 = 900 ;
      // percent = 90/900×100 = 10.
      expect(result.totalGain, closeTo(90.0, 1e-9));
      expect(result.totalGainPercent, closeTo(10.0, 1e-9));
    });

    test('invariant : valeur = capital + gains (dérivé de totalGain/totalGainPercent)', () {
      final pos = makePos(symbol: 'AAPL', currency: 'EUR', quantity: '10', price: 100.0, pru: 80.0);

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [pos],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 1.0,
      );

      // valueIncluded connu indépendamment (valeur de marché de la position) :
      const expectedValueIncluded = 1000.0; // 100 × 10
      final capital = result.totalGain! / (result.totalGainPercent! / 100.0);
      expect(capital + result.totalGain!, closeTo(expectedValueIncluded, 1e-6));
    });

    test('capital <= 0 → totalGainPercent null, totalGain reste calculé', () {
      // Position dont le gain latent DÉPASSE la valeur de marché actuelle
      // (cas dégénéré : PRU très supérieur au prix, capital = valeur - gain
      // devient positif... on force plutôt via un gros gain réalisé sans
      // position résiduelle, cf. test "réalisé" ci-dessus — ici on vérifie le
      // cas limite capital == 0 via un dividende dépassant la valeur détenue.
      final pos = makePos(symbol: 'AAPL', currency: 'EUR', quantity: '1', price: 10.0, pru: 8.0);
      final bigDividend = AssetTransaction(
        id: 'div1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.dividend,
        amount: '100', // dividende disproportionné → capital négatif
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [pos],
        txsBySymbol: const {},
        txsByAccount: {
          'acc1': [bigDividend],
        },
        usdToEurRate: 1.0,
      );

      // totalGain = (10-8)×1 + 100 = 102 ; valueIncluded = 10 ;
      // capital = 10-102 = -92 (<=0) → percent null.
      expect(result.totalGain, closeTo(102.0, 1e-9));
      expect(result.totalGainPercent, isNull);
    });

    test('positions et journaux vides → totalGain 0.0, percent null (rien à calculer)', () {
      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 1.0,
      );

      expect(result.totalGain, 0.0);
      expect(result.totalGainPercent, isNull);
      expect(result.noBasisSymbols, isEmpty);
    });
  });
}

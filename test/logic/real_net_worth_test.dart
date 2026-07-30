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

    test('openingBalance TITRE : valorisé à la BASE DE COÛT DÉCLARÉE (pas le cours du jour)', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.openingBalance,
        quantity: '10',
        unitPrice: '50', // PRU déclaré — c'est LUI qui valorise le flux
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

      // Avant le flux : 0. À partir du 1er janvier : 10 × 50 (PRU DÉCLARÉ)
      // = 500, PAS 10 × 100 (cours du jour). C'est ce qui fait tenir
      // « Valeur − Capital investi == gain total base-coût » (29/07).
      expect(values, [0.0, 500.0, 500.0]);
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

      // J1 : +10×50 = 500 de base de coût. J5 : transferOut clampé à 10 titres
      // (pas 15, stock insuffisant) emporte la quote-part WAC correspondante,
      // soit TOUTE la base de coût → cumul 0. La valorisation au cours du jour
      // (120) n'intervient plus : c'est le capital, pas le marché, qui sort.
      expect(values, [500.0, 0.0]);
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

      // Seul l'openingBalance (10 × 50 = 500 de base de coût) compte — ni le
      // dividende ni le frais.
      expect(values, [500.0, 500.0]);
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

    test('adjustment TITRE à coût nul (attribution gratuite) : AUCUN capital investi', () {
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

      // J1 : 10×50 = 500 de base de coût. J3 : l'attribution gratuite déclare
      // un prix NUL (`unitPrice: '0'`) — elle n'apporte donc AUCUN capital, et
      // la valeur qu'elle ajoute au patrimoine est intégralement du GAIN. Le
      // cumul reste à 500. (Le repli au cours du jour est réservé à une
      // position initiale SANS prix déclaré, cas « base de coût inconnue ».)
      expect(values, [500.0, 500.0]);
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

      // 10×50 (base de coût déclarée) + 2×0 (attribution gratuite) = 500 : les
      // deux contributions du MÊME jour sont bien SOMMÉES (pas « la dernière
      // écrase », comme le ferait un escalier d'état).
      expect(values.single, closeTo(500.0, 1e-9));
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

      // Base de coût 10 × 50 USD = 500 USD × 0,9 = 450 EUR (le cours du jour,
      // 100 USD, n'intervient plus).
      expect(values.single, closeTo(450.0, 1e-9));
    });

    test('prix de marché absent mais PRU DÉCLARÉ : le flux vaut quand même sa '
        'base de coût (elle ne dépend plus du marché)', () {
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
        symbolToData: {'AAPL': null}, // aucune donnée de marché
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1)],
        usdToEurRate: 1.0,
      );

      // 10 × 50 : la base de coût déclarée est autoportante. Avant le passage
      // au coût de revient (29/07), l'absence de cours donnait 0 ici.
      expect(values.single, 500.0);
    });

    // -------------------------------------------------------------------------
    // (b bis) ACHAT/VENTE SANS JAMBE CASH — régression du 29/07 : sur un compte
    // sans trésorerie suivie (or physique acheté au comptoir), les `buy`
    // n'ont pas d'`amount`, donc ne débitent aucune espèce. Les traiter en
    // « transfert interne, net 0 » faisait apparaître tout le prix d'achat
    // comme un GAIN PUR (écart valeur−flux gonflé du montant acheté).
    // -------------------------------------------------------------------------

    test('buy SANS amount : compté comme flux EXTERNE au prix traité (qty×PU+frais)', () {
      final buy = AssetTransaction(
        id: 'b1',
        accountId: 'acc1',
        symbol: 'OR',
        kind: TransactionKind.buy,
        quantity: '2',
        unitPrice: '585',
        fee: '12',
        amount: null, // ← aucune jambe cash : capital venu de l'EXTÉRIEUR
        currency: 'EUR',
        date: DateTime(2024, 10, 8),
      );
      final hist = _histData(
        'OR',
        [DateTime(2024, 10, 8), DateTime(2024, 10, 9)],
        [600.0, 620.0], // cours de marché ≠ prix traité : on doit ignorer
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'OR': [buy],
        },
        txsByAccount: {
          'acc1': [buy],
        },
        symbolToData: {'OR': hist},
        assetBySymbol: {'OR': Asset(symbol: 'OR', currency: 'EUR')},
        gridDates: [
          DateTime(2024, 10, 7),
          DateTime(2024, 10, 8),
          DateTime(2024, 10, 9),
        ],
        usdToEurRate: 1.0,
      );

      // 2 × 585 + 12 = 1182 (prix RÉELLEMENT traité), pas 2 × 600 = 1200.
      expect(values, [0.0, 1182.0, 1182.0]);
    });

    test('buy AVEC amount : reste un transfert interne, AUCUN flux externe '
        '(non-régression, anti-double-comptage)', () {
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
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
        amount: '-1000', // ← jambe cash présente : financé EN INTERNE
        currency: 'EUR',
        date: DateTime(2024, 1, 5),
      );
      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 5)],
        [100.0, 100.0],
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [buy],
        },
        txsByAccount: {
          'acc1': [deposit, buy],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 5)],
        usdToEurRate: 1.0,
      );

      // Seul le versement de 2000 est un flux externe : l'achat déplace de la
      // trésorerie DÉJÀ comptée vers du titre (net 0 des deux côtés).
      expect(values, [2000.0, 2000.0]);
    });

    // -------------------------------------------------------------------------
    // Ancrage PAR COMPTE (réconciliation du 29/07) — un `buy`/`sell` PORTANT
    // un `amount` n'est un transfert interne QUE si son compte est ANCRÉ
    // ([journalHasCashAnchor]) : sans mouvement d'ancrage, la jambe cash
    // annoncée par `amount` n'est projetée nulle part en aval
    // (reconstructRealNetWorth exclut le cash d'un compte non ancré), donc
    // (b bis) doit la traiter comme un flux externe malgré la présence
    // d'`amount` — sans ça, le capital investi reste plat à zéro pendant que
    // la valeur de la position grimpe, et toute la valeur passe pour du gain.
    // -------------------------------------------------------------------------

    test('buy AVEC amount SUR COMPTE NON ANCRÉ : redevient un flux EXTERNE — '
        'le gain fantôme se rejouait aussi via un `amount` renseigné, pas '
        'seulement en son absence (b bis seul)', () {
      // Compte SANS AUCUN mouvement d'ancrage (pas de deposit/withdrawal/
      // interest/charge/openingBalance espèces) : journalHasCashAnchor([buy])
      // est FAUX bien que `buy` porte un `amount`.
      final buy = AssetTransaction(
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
      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 2), DateTime(2024, 1, 10)],
        [100.0, 100.0, 120.0],
      );
      final gridDates = [
        DateTime(2024, 1, 1),
        DateTime(2024, 1, 2),
        DateTime(2024, 1, 10),
      ];

      final flows = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [buy],
        },
        txsByAccount: {
          'acc1': [buy],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: gridDates,
        usdToEurRate: 1.0,
      );

      // 10 × 100 = 1000, prix RÉELLEMENT traité (pas `amount`, ignoré ici) :
      // le capital vient de l'extérieur du compte, aucune timeline cash
      // n'existant pour ce compte non ancré.
      expect(flows, [0.0, 1000.0, 1000.0]);

      final reconstructed = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {
          'AAPL': [buy],
        },
        txsByAccount: {
          'acc1': [buy],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: gridDates,
      );
      // AVANT le fix : la valeur montait à 1200 pendant que le flux restait
      // plat à 0 — (b bis) traitait le `buy` comme un transfert interne
      // (jambe cash « déjà prise en compte par (a) ») alors que
      // reconstructRealNetWorth exclut PRÉCISÉMENT le cash de ce compte non
      // ancré (gating M1) : les deux mécanismes s'annulaient, écart 1200 au
      // lieu de 200.
      expect(reconstructed.values, [0.0, 1000.0, 1200.0]);

      final gap = reconstructed.values.last - flows.last;
      expect(gap, closeTo(200.0, 1e-9));

      // INVARIANT (garde symétrique posée côté AccountController : cashEur:
      // 0 sur un compte non ancré) — l'écart des deux courbes doit coïncider
      // avec le gain total base-coût de la carte.
      final position = PositionWithMarketData(
        position: Position(
          accountId: 'acc1',
          asset: Asset(symbol: 'AAPL', currency: 'EUR'),
          quantity: '10',
          averageBuyPrice: 100.0, // coût déclaré du seul achat (1000 / 10)
        ),
        currentPrice: 120.0,
      );
      final totalGain = HistoryAggregator.computeRealTotalGain(
        positions: [position],
        txsBySymbol: {
          'AAPL': [buy],
        },
        txsByAccount: {
          'acc1': [buy],
        },
        usdToEurRate: 1.0,
        cashEur: 0.0,
      );
      expect(totalGain.totalGain, closeTo(gap, 1e-9));
      expect(totalGain.totalGain, closeTo(200.0, 1e-9));
    });

    test('MIXTE : deux comptes du MÊME appel, un ANCRÉ un NON — chacun '
        'traité selon son PROPRE ancrage, testé PAR TRANSACTION via '
        '`tx.accountId` (même symbole détenu sur les deux)', () {
      final depositAnchored = AssetTransaction(
        id: 'd1',
        accountId: 'acc-anchored',
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final buyAnchored = AssetTransaction(
        id: 'b1',
        accountId: 'acc-anchored',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '5',
        unitPrice: '100',
        amount: '-500', // financé EN INTERNE : compte ANCRÉ par le dépôt
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      final buyUnanchored = AssetTransaction(
        id: 'b2',
        accountId: 'acc-unanchored',
        symbol: 'AAPL', // MÊME symbole, AUTRE compte
        kind: TransactionKind.buy,
        quantity: '5',
        unitPrice: '100',
        amount: '-500', // porte un `amount`, mais CE compte n'a AUCUN ancrage
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      final hist = _histData(
        'AAPL',
        [DateTime(2024, 1, 1), DateTime(2024, 1, 2)],
        [100.0, 100.0],
      );

      final flows = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'AAPL': [buyAnchored, buyUnanchored],
        },
        txsByAccount: {
          'acc-anchored': [depositAnchored, buyAnchored],
          'acc-unanchored': [buyUnanchored],
        },
        symbolToData: {'AAPL': hist},
        assetBySymbol: {'AAPL': Asset(symbol: 'AAPL', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 1, 2)],
        usdToEurRate: 1.0,
      );

      // J1 : seul le dépôt (1000) est visible. J2 : + 500 du buy NON ancré
      // (5 × 100, compté comme flux externe) ; le buy ANCRÉ, lui, reste à 0
      // (transfert interne, sa jambe cash étant projetée par acc-anchored).
      expect(flows, [1000.0, 1500.0]);
    });

    test('sell SANS amount : flux externe NÉGATIF au produit traité (qty×PU−frais)', () {
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'acc1',
        symbol: 'OR',
        kind: TransactionKind.openingBalance,
        quantity: '4',
        unitPrice: '500',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final sell = AssetTransaction(
        id: 's1',
        accountId: 'acc1',
        symbol: 'OR',
        kind: TransactionKind.sell,
        quantity: '1',
        unitPrice: '700',
        fee: '10',
        amount: null, // produit encaissé HORS du compte
        currency: 'EUR',
        date: DateTime(2024, 6, 1),
      );
      final hist = _histData(
        'OR',
        [DateTime(2024, 1, 1), DateTime(2024, 6, 1)],
        [500.0, 700.0],
      );

      final values = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {
          'OR': [opening, sell],
        },
        txsByAccount: {
          'acc1': [opening, sell],
        },
        symbolToData: {'OR': hist},
        assetBySymbol: {'OR': Asset(symbol: 'OR', currency: 'EUR')},
        gridDates: [DateTime(2024, 1, 1), DateTime(2024, 6, 1)],
        usdToEurRate: 1.0,
      );

      // J1 : openingBalance 4 × 500 (cours du jour) = 2000.
      // J6 : vente sortie de 1 × 700 − 10 = 690 → 2000 − 690 = 1310.
      expect(values, [2000.0, 1310.0]);
    });

    test('scénario « or physique » complet : l\'écart valeur−flux redevient le '
        'gain économique réel (régression du compte a-metal)', () {
      // Reproduit EXACTEMENT le journal du compte de démo « Or physique » qui
      // affichait +3 061 € de gains là où le calcul base-coût donnait +618 €.
      final opening = AssetTransaction(
        id: 'ob1',
        accountId: 'a-metal',
        symbol: 'OR',
        kind: TransactionKind.openingBalance,
        quantity: '2',
        unitPrice: '478',
        amount: null,
        currency: 'EUR',
        date: DateTime(2023, 5, 10),
      );
      final buy1 = AssetTransaction(
        id: 'b1',
        accountId: 'a-metal',
        symbol: 'OR',
        kind: TransactionKind.buy,
        quantity: '2',
        unitPrice: '585',
        fee: '12',
        amount: null,
        currency: 'EUR',
        date: DateTime(2024, 10, 8),
      );
      final buy2 = AssetTransaction(
        id: 'b2',
        accountId: 'a-metal',
        symbol: 'OR',
        kind: TransactionKind.buy,
        quantity: '1',
        unitPrice: '985',
        amount: null,
        currency: 'EUR',
        date: DateTime(2025, 2, 14),
      );

      final dates = [
        // Point d'ANCRAGE antérieur au premier mouvement (cf.
        // HistoryAggregator.applyGridFrom) : patrimoine encore à zéro.
        DateTime(2023, 5, 9),
        DateTime(2023, 5, 10),
        DateTime(2024, 10, 8),
        DateTime(2025, 2, 14),
        DateTime(2026, 7, 29),
      ];
      // Cours du jour de l'openingBalance VOLONTAIREMENT ≠ prix déclaré (478) :
      // c'est la divergence méthodologique documentée, seul écart résiduel
      // attendu à la fin de ce test.
      final hist = _histData('OR', dates, [340.19, 340.19, 600.0, 1000.0, 900.0]);

      final txs = [opening, buy1, buy2];
      final flows = HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: {'OR': txs},
        txsByAccount: {'a-metal': txs},
        symbolToData: {'OR': hist},
        assetBySymbol: {'OR': Asset(symbol: 'OR', currency: 'EUR')},
        gridDates: dates,
        usdToEurRate: 1.0,
      );

      // Flux cumulés == BASE DE COÛT TOTALE : openingBalance au PRU déclaré
      // (2 × 478 = 956) + les deux achats à leur prix traité (1182 puis 985).
      // Le cours du jour de l'openingBalance (340,19) n'intervient plus.
      expect(flows.last, closeTo(956.0 + 1182.0 + 985.0, 1e-9));

      final reconstructed = HistoryAggregator.reconstructRealNetWorth(
        txsBySymbol: {'OR': txs},
        txsByAccount: {'a-metal': txs},
        symbolToData: {'OR': hist},
        assetBySymbol: {'OR': Asset(symbol: 'OR', currency: 'EUR')},
        usdToEurRate: 1.0,
        gridDates: dates,
      );

      // 5 pièces/lingotins détenus à la fin, au cours de 900 = 4500. Aucun
      // cash (aucun mouvement ne porte d'`amount`).
      expect(reconstructed.values.last, closeTo(4500.0, 1e-9));

      // RÉCONCILIATION EXACTE (objectif du lot 29/07) : l'écart entre les deux
      // courbes EST le gain total base-coût, au centime — plus aucun résidu.
      // Base de coût : 2×478 + (2×585+12) + 985 = 3123 → gain 4500 − 3123.
      // Avant ce lot, cet écart valait 1 652,62 € (2 155 € d'achats non
      // comptés + 275,62 € de valorisation au cours du jour).
      final gap = reconstructed.values.last - flows.last;
      const costBasisGain = 4500.0 - 3123.0;
      expect(gap, closeTo(costBasisGain, 1e-9));

      // Grâce au point d'ancrage, la grille part d'un patrimoine NUL :
      // values[0] == flows[0] == 0.
      expect(reconstructed.values.first, 0.0);
      expect(flows.first, 0.0);

      // INVARIANT « Max » (29/07) : sur une fenêtre couvrant TOUTE la vie du
      // compte, le gain de PÉRIODE affiché sous le graphe est EXACTEMENT le
      // gain TOTAL affiché dans la carte. Sans le point d'ancrage, la fenêtre
      // démarrait sur un état déjà entamé et les deux chiffres divergeaient
      // (constaté : +899,57 € contre +608,82 €).
      final gains = HistoryAggregator.computeRealGains(
        values: reconstructed.values,
        externalFlows: flows,
        gridDates: dates,
      );
      expect(gains.periodGain, closeTo(costBasisGain, 1e-9));
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
      // chargesTotal isole la SEULE part `charge` (-5), signée, sans changer
      // totalGain (toujours 55, dividende+intérêt+frais confondus).
      expect(result.chargesTotal, closeTo(-5.0, 1e-9));
      // Compte ANCRÉ (dépôt + intérêt + frais) : les revenus entrent dans la
      // courbe → aucun résidu invisible à signaler.
      expect(result.unanchoredRevenueEur, closeTo(0.0, 1e-9));
    });

    test('résidu invisible : dividende sur un compte NON ancré remonté à part',
        () {
      // Compte titres sans trésorerie suivie (aucun deposit/withdrawal/
      // interest/charge/openingBalance espèces) : un achat l'ouvre, un
      // dividende est encaissé. Le dividende compte dans le gain total mais
      // reste invisible dans la courbe (aucune timeline cash construite) — il
      // doit ressortir dans unanchoredRevenueEur pour la note sous le graphe.
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
      final dividend = AssetTransaction(
        id: 'div1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.dividend,
        amount: '205.79',
        currency: 'EUR',
        date: DateTime(2024, 6, 1),
      );
      final pos = makePos(
        symbol: 'AAPL',
        currency: 'EUR',
        quantity: '10',
        price: 100.0,
        pru: 100.0,
      );

      final result = HistoryAggregator.computeRealTotalGain(
        positions: [pos],
        txsBySymbol: {
          'AAPL': [buy, dividend],
        },
        txsByAccount: {
          'acc1': [buy, dividend],
        },
        usdToEurRate: 1.0,
      );

      // Le dividende est dans le gain total ET isolé comme résidu invisible.
      expect(result.totalGain, closeTo(205.79, 1e-9));
      expect(result.unanchoredRevenueEur, closeTo(205.79, 1e-9));
    });

    test('un compte ANCRÉ par un simple dépôt n\'a aucun résidu de revenus', () {
      final deposit = AssetTransaction(
        id: 'd1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      final dividend = AssetTransaction(
        id: 'div1',
        accountId: 'acc1',
        symbol: 'AAPL',
        kind: TransactionKind.dividend,
        amount: '42',
        currency: 'EUR',
        date: DateTime(2024, 6, 1),
      );

      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [],
        txsBySymbol: const {},
        txsByAccount: {
          'acc1': [deposit, dividend],
        },
        usdToEurRate: 1.0,
      );

      // Dividende compté au gain, mais le dépôt ancre le compte → pas de résidu.
      expect(result.totalGain, closeTo(42.0, 1e-9));
      expect(result.unanchoredRevenueEur, closeTo(0.0, 1e-9));
    });

    test('chargesTotal isole la part frais (fx règlement), totalGain inchangé', () {
      // Mélange dividend/interest/charge, dont un charge en USD réglé pour
      // vérifier que chargesTotal applique le MÊME fx que le terme (3)
      // complet (devise de RÈGLEMENT, pas de cotation).
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
      final chargeEur = AssetTransaction(
        id: 'chg1',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.charge,
        amount: '-5',
        currency: 'EUR',
        date: DateTime(2024, 1, 3),
      );
      final chargeUsd = AssetTransaction(
        id: 'chg2',
        accountId: 'acc1',
        symbol: null,
        kind: TransactionKind.charge,
        amount: '-10',
        currency: 'USD',
        date: DateTime(2024, 1, 4),
      );

      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [],
        txsBySymbol: const {},
        txsByAccount: {
          'acc1': [dividend, interest, chargeEur, chargeUsd],
        },
        usdToEurRate: 0.9,
      );

      // totalGain = 50 + 10 - 5 - 10×0.9 = 46 — EXACTEMENT ce que donnerait
      // le calcul actuel sans chargesTotal (non-régression du terme principal).
      expect(result.totalGain, closeTo(46.0, 1e-9));
      // chargesTotal = -5 + (-10×0.9) = -14, isolé des revenus dividend+interest.
      expect(result.chargesTotal, closeTo(-14.0, 1e-9));
    });

    test('aucun mouvement charge → chargesTotal 0.0', () {
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

      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [],
        txsBySymbol: const {},
        txsByAccount: {
          'acc1': [dividend, interest],
        },
        usdToEurRate: 1.0,
      );

      expect(result.totalGain, closeTo(60.0, 1e-9));
      expect(result.chargesTotal, 0.0);
    });

    test('positions et journaux vides → chargesTotal 0.0', () {
      final result = HistoryAggregator.computeRealTotalGain(
        positions: const [],
        txsBySymbol: const {},
        txsByAccount: const {},
        usdToEurRate: 1.0,
      );

      expect(result.chargesTotal, 0.0);
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

    // -------------------------------------------------------------------
    // Correctif « jambe cash d'une opération sur titre » (réconciliation du
    // 29/07) : un `adjustment` symbole + `amount` SANS quantité exploitable
    // est le produit en numéraire d'une opération sur titre (le moteur cash
    // lit `amount` quel que soit le kind) — il doit compter dans le résultat,
    // sans quoi la carte « Gains totaux » sous-évalue un montant réellement
    // encaissé. Scénario réel : Altice USA (US02156K1034), 89 titres reçus
    // gratuitement le 22/05/2018, sortis sans cession le 15/06/2018, puis le
    // compte crédité de 1 491,03 € le 18/06/2018 (regroupement/rachat traité
    // hors du suivi titre).
    // -------------------------------------------------------------------
    group('correctif — adjustment jambe cash (symbole + amount, sans quantité)', () {
      test(
          'scénario Altice complet : attribution gratuite + transferOut + '
          'adjustment cash → le gain total inclut le montant, et '
          'Valeur − Capital investi == gain total (invariant face à '
          'buildExternalFlowsCurve)', () {
        // Ancrage espèces réel (dépôt initial) — SYMÉTRIQUE sur les deux
        // courbes (valeur ET flux externes), donc neutre pour l'invariant ;
        // sans lui, reconstructRealNetWorth n'injecterait AUCUN cash
        // (gating journalHasCashAnchor), ce qui viderait artificiellement
        // l'écart valeur−flux et masquerait le bug que ce test vérifie.
        final deposit = AssetTransaction(
          id: 'dep1',
          accountId: 'acc1',
          symbol: null,
          kind: TransactionKind.deposit,
          amount: '1000',
          currency: 'EUR',
          date: DateTime(2018, 1, 1),
        );
        // Attribution gratuite : quantité SANS montant, coût nul VOULU.
        final freeShares = AssetTransaction(
          id: 'adj-free',
          accountId: 'acc1',
          symbol: 'US02156K1034',
          kind: TransactionKind.adjustment,
          quantity: '89',
          unitPrice: '0',
          amount: null,
          currency: 'EUR',
          date: DateTime(2018, 5, 22),
        );
        // Sortie sans cession (transfert) — aucune plus-value réalisée.
        final transferOut = AssetTransaction(
          id: 'xout1',
          accountId: 'acc1',
          symbol: 'US02156K1034',
          kind: TransactionKind.transferOut,
          quantity: '89',
          amount: null,
          currency: 'EUR',
          date: DateTime(2018, 6, 15),
        );
        // Jambe cash : montant SANS quantité — le cas de ce correctif.
        final cashLeg = AssetTransaction(
          id: 'adj-cash',
          accountId: 'acc1',
          symbol: 'US02156K1034',
          kind: TransactionKind.adjustment,
          quantity: null,
          amount: '1491.03',
          currency: 'EUR',
          date: DateTime(2018, 6, 18),
        );

        final txsBySymbol = {
          'US02156K1034': [freeShares, transferOut, cashLeg],
        };
        final txsByAccount = {
          'acc1': [deposit, freeShares, transferOut, cashLeg],
        };

        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [], // titre totalement soldé (transferOut intégral)
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          usdToEurRate: 1.0,
        );

        // Aucune plus-value réalisée (transferOut n'en réalise jamais), rien
        // en non-réalisé (aucune position résiduelle) : le SEUL contributeur
        // est la jambe cash de 1 491,03 €.
        expect(result.totalGain, closeTo(1491.03, 1e-9));
        // Ce n'est PAS un `charge` : le sous-total dédié reste à 0.
        expect(result.chargesTotal, 0.0);

        // Invariant : Valeur(dernier point) − Capital investi(dernier point)
        // == gain total, vérifié en rejouant les DEUX courbes indépendamment
        // de computeRealTotalGain (aucune dérivation commune, cf. doc de
        // buildExternalFlowsCurve).
        final gridDates = [
          DateTime(2018, 1, 1),
          DateTime(2018, 5, 22),
          DateTime(2018, 6, 15),
          DateTime(2018, 6, 18),
          DateTime(2018, 7, 1),
        ];
        final valueCurve = HistoryAggregator.reconstructRealNetWorth(
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          symbolToData: const {}, // pas d'historique — quantité finale nulle
          assetBySymbol: {
            'US02156K1034': Asset(symbol: 'US02156K1034', currency: 'EUR'),
          },
          usdToEurRate: 1.0,
          gridDates: gridDates,
        );
        final flowsCurve = HistoryAggregator.buildExternalFlowsCurve(
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          symbolToData: const {},
          assetBySymbol: {
            'US02156K1034': Asset(symbol: 'US02156K1034', currency: 'EUR'),
          },
          usdToEurRate: 1.0,
          gridDates: gridDates,
        );

        // Valeur finale : 0 titre (transferOut intégral) + cash 1000 (dépôt)
        // + 1491,03 (jambe cash) = 2491,03. Flux finaux : 1000 (dépôt, seul
        // flux cash externe — la jambe cash est EXCLUE de (a), symbole non
        // nul) + 0 (flux titre : attribution à coût nul + transferOut d'un
        // coût déjà nul) = 1000. Écart = 1491,03, EXACTEMENT result.totalGain.
        final gap = valueCurve.values.last - flowsCurve.last;
        expect(gap, closeTo(result.totalGain!, 1e-9));
        expect(gap, closeTo(1491.03, 1e-9));
      });

      test('quantité ET montant présents (donnée ambiguë) : RIEN compté en résultat', () {
        final ambiguous = AssetTransaction(
          id: 'adj-ambig',
          accountId: 'acc1',
          symbol: 'FR0013088606',
          kind: TransactionKind.adjustment,
          quantity: '10',
          unitPrice: '5',
          amount: '50', // ressemble à un prix d'acquisition, pas à un résultat
          currency: 'EUR',
          date: DateTime(2020, 12, 4),
        );

        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [],
          txsBySymbol: {
            'FR0013088606': [ambiguous],
          },
          txsByAccount: {
            'acc1': [ambiguous],
          },
          usdToEurRate: 1.0,
        );

        // quantité exploitable (10) → exclu du cas « jambe cash » ; adjustment
        // n'est de toute façon pas un kind « revenu » ; aucune vente → aucune
        // plus-value réalisée. Rien ne doit être compté.
        expect(result.totalGain, closeTo(0.0, 1e-9));
        expect(result.chargesTotal, 0.0);
      });

      test(
          'symbol == null (correction de solde) : jamais compté en résultat '
          '(non-régression du double-comptage avec buildExternalFlowsCurve, '
          'qui la compte déjà comme apport externe)', () {
        final balanceCorrection = AssetTransaction(
          id: 'adj-balance',
          accountId: 'acc1',
          symbol: null,
          kind: TransactionKind.adjustment,
          quantity: null,
          amount: '-100',
          currency: 'EUR',
          date: DateTime(2021, 3, 1),
        );

        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [],
          txsBySymbol: const {},
          txsByAccount: {
            'acc1': [balanceCorrection],
          },
          usdToEurRate: 1.0,
        );

        // symbol == null → jamais une jambe cash de titre : c'est une
        // correction de solde, déjà comptée comme apport externe par le
        // filtre (a) de buildExternalFlowsCurve (cf. test dédié
        // « openingBalance/adjustment ESPÈCES » ci-dessus) — la compter ici
        // la doublerait.
        expect(result.totalGain, closeTo(0.0, 1e-9));
      });
    });

    // -------------------------------------------------------------------
    // Correctif « jambe cash d'un buy/sell » (réconciliation du 29/07,
    // extension EXACTE du correctif « adjustment jambe cash » ci-dessus à la
    // même famille sur un `buy`/`sell` : un `amount` SANS quantité
    // exploitable). Scénario réel : Altice USA (NL0011333752), `sell`
    // quantité `'0'` du 22/05/2018, `amount: '7.74'` — un solde de
    // liquidation. Le moteur cash lit `amount` quel que soit le kind (partition
    // stricte) : ce montant entre déjà dans la valeur/le solde, le moteur
    // titre (qui ne lit que les quantités) n'y voit rien — sans ce terme la
    // carte « Gains totaux » affichait 7,74 € de moins que la courbe.
    // -------------------------------------------------------------------
    group('correctif — buy/sell jambe cash (symbole + amount, sans quantité)', () {
      test(
          'sell quantité \'0\' + amount (scénario Altice réel) : compte en '
          'résultat, et Valeur − Capital investi == gain total (invariant '
          'face à buildExternalFlowsCurve, compte ANCRÉ)', () {
        // Ancrage espèces réel (dépôt initial) — même rôle que dans le test
        // adjustment ci-dessus : sans lui, reconstructRealNetWorth
        // n'injecterait AUCUN cash (gating journalHasCashAnchor) et
        // masquerait le bug que ce test vérifie.
        final deposit = AssetTransaction(
          id: 'dep1',
          accountId: 'acc1',
          symbol: null,
          kind: TransactionKind.deposit,
          amount: '1000',
          currency: 'EUR',
          date: DateTime(2018, 1, 1),
        );
        // Jambe cash pure d'un `sell` : quantité NULLE, montant réellement
        // encaissé (solde de liquidation) — le cas de ce correctif.
        final liquidationSell = AssetTransaction(
          id: 'sell-liq',
          accountId: 'acc1',
          symbol: 'NL0011333752',
          kind: TransactionKind.sell,
          quantity: '0',
          unitPrice: '15.346',
          amount: '7.74',
          currency: 'EUR',
          date: DateTime(2018, 5, 22),
        );

        final txsBySymbol = {
          'NL0011333752': [liquidationSell],
        };
        final txsByAccount = {
          'acc1': [deposit, liquidationSell],
        };

        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [], // titre jamais détenu (quantité toujours 0)
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          usdToEurRate: 1.0,
        );

        // Terme (2) : replayLedger d'un sell quantité 0, sans position
        // préalable ni frais → proceeds = 0×15,346 − 0 = 0, costBasisSold = 0
        // (runningQty déjà nul) → realized = 0. Le SEUL contributeur est donc
        // la jambe cash de 7,74 € captée par le terme (3).
        expect(result.totalGain, closeTo(7.74, 1e-9));
        // Ce n'est PAS un `charge` : le sous-total dédié reste à 0.
        expect(result.chargesTotal, 0.0);

        final gridDates = [
          DateTime(2018, 1, 1),
          DateTime(2018, 5, 22),
          DateTime(2018, 7, 1),
        ];
        final valueCurve = HistoryAggregator.reconstructRealNetWorth(
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          symbolToData: const {}, // pas d'historique — quantité toujours nulle
          assetBySymbol: {
            'NL0011333752': Asset(symbol: 'NL0011333752', currency: 'EUR'),
          },
          usdToEurRate: 1.0,
          gridDates: gridDates,
        );
        final flowsCurve = HistoryAggregator.buildExternalFlowsCurve(
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          symbolToData: const {},
          assetBySymbol: {
            'NL0011333752': Asset(symbol: 'NL0011333752', currency: 'EUR'),
          },
          usdToEurRate: 1.0,
          gridDates: gridDates,
        );

        // Valeur finale : 0 titre (quantité toujours nulle) + cash 1000
        // (dépôt) + 7,74 (jambe cash du sell, lue par buildCashTimeline SUR
        // TOUS les mouvements du compte ancré, kind-agnostic) = 1007,74.
        // Flux finaux : (a) ne retient QUE le dépôt (le sell n'est ni
        // deposit/withdrawal ni openingBalance/adjustment ESPÈCES) ; (b bis)
        // exclut explicitement ce sell car `hasAmount && isAnchored`
        // (jambe cash déjà projetée par (a)/le cash timeline de la valeur ⇒
        // AUCUN recoupement avec ce sell) → flux = 1000 (dépôt seul).
        // Écart = 7,74, EXACTEMENT result.totalGain.
        expect(flowsCurve.last, closeTo(1000.0, 1e-9));
        final gap = valueCurve.values.last - flowsCurve.last;
        expect(gap, closeTo(result.totalGain!, 1e-9));
        expect(gap, closeTo(7.74, 1e-9));
      });

      test('buy quantité \'0\' + amount : compte en résultat, symétrique du sell', () {
        final deposit = AssetTransaction(
          id: 'dep2',
          accountId: 'acc1',
          symbol: null,
          kind: TransactionKind.deposit,
          amount: '1000',
          currency: 'EUR',
          date: DateTime(2019, 1, 1),
        );
        // Jambe cash pure d'un `buy` : quantité NULLE, montant réellement
        // débité (ex. frais de régularisation d'une opération sur titre sans
        // aucune quantité acquise).
        final regularizationBuy = AssetTransaction(
          id: 'buy-reg',
          accountId: 'acc1',
          symbol: 'FR0000TEST3',
          kind: TransactionKind.buy,
          quantity: '0',
          amount: '-12.5',
          currency: 'EUR',
          date: DateTime(2019, 2, 1),
        );

        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [],
          txsBySymbol: {
            'FR0000TEST3': [regularizationBuy],
          },
          txsByAccount: {
            'acc1': [deposit, regularizationBuy],
          },
          usdToEurRate: 1.0,
        );

        // Terme (2) : un buy ne modifie jamais `realized` (seul un sell le
        // fait) → 0. Le dépôt est du capital, pas un gain → 0. Le SEUL
        // contributeur est donc la jambe cash négative du buy, au terme (3).
        expect(result.totalGain, closeTo(-12.5, 1e-9));
        expect(result.chargesTotal, 0.0);
      });

      test(
          'sell à quantité EXPLOITABLE : rien compté au terme (3) — le '
          'résultat vient du rejeu du terme (2), pas de amount (non-régression '
          'du double-comptage)', () {
        // Sans position préalable (positions: const []) ; quantité vendue
        // 5 × prix unitaire 10 = 50, sans frais → proceeds = 50, costBasisSold
        // = 0 (runningQty nul avant la vente) → realized = 50. `amount` (45,
        // délibérément DIFFÉRENT de 50) ne doit PAS entrer en ligne de compte :
        // s'il l'était, on obtiendrait 95 (double-comptage) ou 45 (amount
        // écrasant le rejeu) au lieu de 50.
        final realSell = AssetTransaction(
          id: 'sell-real',
          accountId: 'acc1',
          symbol: 'FR0000TEST1',
          kind: TransactionKind.sell,
          quantity: '5',
          unitPrice: '10',
          amount: '45',
          currency: 'EUR',
          date: DateTime(2020, 1, 1),
        );

        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [],
          txsBySymbol: {
            'FR0000TEST1': [realSell],
          },
          txsByAccount: {
            'acc1': [realSell],
          },
          usdToEurRate: 1.0,
        );

        expect(result.totalGain, closeTo(50.0, 1e-9));
        expect(result.chargesTotal, 0.0);
      });

      test(
          'buy à quantité EXPLOITABLE : rien compté au terme (3) — un buy ne '
          'modifie jamais le réalisé (non-régression du double-comptage)', () {
        // `amount` (-31) ne doit JAMAIS entrer dans le résultat ici : un buy
        // ne modifie jamais `realized` (seul un sell le fait), et sans PRU
        // stocké (positions: const []) le terme (1) ne voit rien non plus. Si
        // le garde-fou « quantité exploitable » disparaissait, ce test
        // détecterait immédiatement le double-comptage (totalGain passerait
        // de 0 à -31).
        final realBuy = AssetTransaction(
          id: 'buy-real',
          accountId: 'acc1',
          symbol: 'FR0000TEST2',
          kind: TransactionKind.buy,
          quantity: '3',
          unitPrice: '10',
          fee: '1',
          amount: '-31',
          currency: 'EUR',
          date: DateTime(2020, 6, 1),
        );

        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [],
          txsBySymbol: {
            'FR0000TEST2': [realBuy],
          },
          txsByAccount: {
            'acc1': [realBuy],
          },
          usdToEurRate: 1.0,
        );

        expect(result.totalGain, closeTo(0.0, 1e-9));
        expect(result.chargesTotal, 0.0);
      });

      test(
          'compte NON ancré : buildExternalFlowsCurve ne recoupe PAS ce '
          '`sell` avec `amount` — valorisé à qty × unitPrice ± fee (≈0 ici, '
          'PAS `amount`), vérifie la note anti-double-comptage de (b bis)', () {
        // Aucun mouvement d'ancrage (deposit/withdrawal/interest/charge ou
        // openingBalance/adjustment ESPÈCES) sur ce compte → NON ancré. (b
        // bis) ne l'exclut alors PAS de la boucle titre, mais le valorise à
        // `qty × unitPrice ± fee` = `0 × 15,346 − 0` (fee absent) = 0 — donc
        // AUCUNE contribution (le code ignore une contribution nulle), jamais
        // le montant `amount` de 7,74 €. Pas le même euro compté deux fois
        // (7,74 ≠ 0), mais un écart résiduel reste possible hors du périmètre
        // testé ici (compte non ancré, hors invariant garanti) — signalé,
        // non corrigé (cf. rapport).
        final liquidationSell = AssetTransaction(
          id: 'sell-liq-unanchored',
          accountId: 'acc2',
          symbol: 'NL0011333752',
          kind: TransactionKind.sell,
          quantity: '0',
          unitPrice: '15.346',
          amount: '7.74',
          currency: 'EUR',
          date: DateTime(2018, 5, 22),
        );

        final txsBySymbol = {
          'NL0011333752': [liquidationSell],
        };
        final txsByAccount = {
          'acc2': [liquidationSell],
        };

        final gridDates = [
          DateTime(2018, 5, 22),
          DateTime(2018, 7, 1),
        ];
        final flowsCurve = HistoryAggregator.buildExternalFlowsCurve(
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          symbolToData: const {},
          assetBySymbol: {
            'NL0011333752': Asset(symbol: 'NL0011333752', currency: 'EUR'),
          },
          usdToEurRate: 1.0,
          gridDates: gridDates,
        );
        // Aucune contribution : ni `amount` (jamais lu par (b bis)) ni un
        // `qty × unitPrice ± fee` non nul (qty == 0, fee absent).
        expect(flowsCurve, everyElement(closeTo(0.0, 1e-9)));

        // computeRealTotalGain, lui, ne teste PAS l'ancrage (comme le cas
        // adjustment ci-dessus) : le montant reste compté en résultat même
        // ici — documenté pour mémoire, hors invariant garanti (réservé aux
        // comptes ANCRÉS, cf. doc de computeRealTotalGain).
        final result = HistoryAggregator.computeRealTotalGain(
          positions: const [],
          txsBySymbol: txsBySymbol,
          txsByAccount: txsByAccount,
          usdToEurRate: 1.0,
        );
        expect(result.totalGain, closeTo(7.74, 1e-9));
      });
    });

    // -------------------------------------------------------------------
    // Correctif « puce partiel » (réconciliation du 29/07) : noBasisSymbols
    // ne doit signaler qu'un avoir EFFECTIVEMENT DÉTENU (isHeldPosition),
    // jamais une position soldée dont le PRU n'a simplement jamais été
    // stocké — sa plus-value est de toute façon déjà comptée par le terme
    // (2) (rejeu du journal, indépendant de l'état courant).
    // -------------------------------------------------------------------
    group('correctif — noBasisSymbols ne retient que les positions DÉTENUES', () {
      test('seules des positions SOLDÉES manquent de PRU → noBasisSymbols vide', () {
        final soldee1 = makePos(symbol: 'SOLDEE1', currency: 'EUR', quantity: '0', pru: null);
        final soldee2 = makePos(symbol: 'SOLDEE2', currency: 'EUR', quantity: '0', price: 42.0, pru: null);

        final result = HistoryAggregator.computeRealTotalGain(
          positions: [soldee1, soldee2],
          txsBySymbol: const {},
          txsByAccount: const {},
          usdToEurRate: 1.0,
        );

        expect(result.noBasisSymbols, isEmpty);
        // Une position soldée ne pèse de toute façon rien dans la valeur
        // (valueIncluded inchangé) ni dans le gain (unrealizedGain est déjà
        // null, exclu du terme (1) comme avant ce correctif).
        expect(result.totalGain, closeTo(0.0, 1e-9));
      });

      test(
          'mélange soldée/détenue sans PRU : seule la position DÉTENUE '
          'figure dans noBasisSymbols', () {
        final soldeeSansPru = makePos(symbol: 'SOLDEE', currency: 'EUR', quantity: '0', pru: null);
        final detenueSansPru = makePos(symbol: 'NOPRU', currency: 'EUR', quantity: '5', price: 50.0, pru: null);
        final detenueAvecPru = makePos(symbol: 'MSFT', currency: 'EUR', quantity: '5', price: 50.0, pru: 40.0);

        final result = HistoryAggregator.computeRealTotalGain(
          positions: [soldeeSansPru, detenueSansPru, detenueAvecPru],
          txsBySymbol: const {},
          txsByAccount: const {},
          usdToEurRate: 1.0,
        );

        expect(result.noBasisSymbols, {'NOPRU'});
      });
    });
  });
}

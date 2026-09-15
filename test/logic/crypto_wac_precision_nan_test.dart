// test/logic/crypto_wac_precision_nan_test.dart
//
// RÉGRESSION — « Capital investi » invisible et « Depuis l'origine, hors
// apports · -NaN · — » sur un compte crypto alimenté par l'import Kraken (B16).
//
// CAUSE RACINE : la base de coût du moteur est un [Rational] EXACT dont le
// dénominateur enfle à chaque sortie PARTIELLE (quote-part WAC d'une `sell`
// ou d'un `transferOut` : `runningCost × qEff/runningQty`). Avec des quantités
// CRYPTO à 8-10 décimales, il gagne ~10 chiffres par sortie ; passé ~35
// sorties sur un même symbole, numérateur ET dénominateur dépassent la
// dynamique du `double` et `Rational.toDouble()` — une simple division
// `BigInt/BigInt` — rend `Infinity / Infinity`, c'est-à-dire **NaN**.
// Ce NaN empoisonnait [LedgerStep.costDelta], donc la courbe des flux externes
// (« Capital investi », que `fl_chart` ne trace pas et que la règle d'échelle
// écarte d'office), donc `periodGain` — affiché « -NaN » sous le graphe.
// Les titres ordinaires y échappaient : leurs quantités entières gardent un
// dénominateur trivial. Correctif : [rationalToDisplayDouble].
//
// Fixture 100 % SYNTHÉTIQUE, calquée sur les formes émises par
// `CryptoLedgerNormalizer` : virement SEPA, achats à jambe EUR, retraits
// on-chain en nature, agrégats mensuels de récompenses (quantité seule),
// dépôt en nature à coût.

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/widgets/charts/valuation_line_chart.dart';
import 'package:rational/rational.dart';

const _accountId = 'kraken1';
const _symbol = 'XBT-USD';

/// Actif crypto tel que résolu par l'import : cotation USD, mais journal
/// (PRU / coût) DÉJÀ en EUR — d'où le [Asset.ledgerCode] non nul.
final _asset = Asset(symbol: _symbol, currency: 'USD', ledgerCode: 'XBT');

DateTime _d(int i) => DateTime.utc(2017, 1, 1).add(Duration(days: i * 20));

/// Journal crypto synthétique : 1 virement SEPA d'ancrage, puis N cycles
/// « achat à jambe EUR + retrait on-chain partiel », plus un agrégat mensuel
/// de récompenses (quantité seule) et un dépôt en nature à coût.
///
/// [exits] pilote le nombre de sorties PARTIELLES : c'est LUI qui fait enfler
/// le dénominateur de la base de coût.
List<AssetTransaction> _journal({required int exits}) {
  final txs = <AssetTransaction>[
    AssetTransaction(
      id: 'sepa',
      accountId: _accountId,
      symbol: null,
      kind: TransactionKind.deposit,
      amount: '20000',
      currency: 'EUR',
      settlementCurrency: 'EUR',
      date: _d(0),
    ),
    // Dépôt en nature valorisé à son coût (adjustment quantité + prix, AUCUN
    // cash) — un apport RÉEL, qui doit peser dans le capital investi.
    AssetTransaction(
      id: 'depositInKind',
      accountId: _accountId,
      symbol: _symbol,
      kind: TransactionKind.adjustment,
      quantity: '0.4212345678',
      unitPrice: '1000.5',
      currency: 'EUR',
      date: _d(1),
    ),
    // Agrégat MENSUEL de récompenses : quantité seule, ni montant ni prix
    // (attribution gratuite, coût nul VOULU).
    AssetTransaction(
      id: 'rewards-2017-02',
      accountId: _accountId,
      symbol: _symbol,
      kind: TransactionKind.adjustment,
      quantity: '0.0001234567',
      currency: 'EUR',
      date: _d(2),
    ),
  ];

  for (var i = 0; i < exits; i++) {
    // Achat à jambe EUR réelle (cash sortant), quantité à 10 décimales.
    txs.add(AssetTransaction(
      id: 'buy$i',
      accountId: _accountId,
      symbol: _symbol,
      kind: TransactionKind.buy,
      quantity: '1.${1234567891 + i * 7919}',
      unitPrice: '${3000 + i}.12',
      fee: '0.26',
      amount: '-${3000 + i}',
      currency: 'EUR',
      settlementCurrency: 'EUR',
      date: _d(3 + i * 2),
    ));
    // Retrait on-chain EN NATURE : aucune espèce, quote-part WAC retirée.
    txs.add(AssetTransaction(
      id: 'out$i',
      accountId: _accountId,
      symbol: _symbol,
      kind: TransactionKind.transferOut,
      quantity: '0.000${987654321 + i * 6971}',
      currency: 'EUR',
      date: _d(4 + i * 2),
    ));
  }
  return txs;
}

/// Rejoue le journal exactement comme l'écran compte en mode « Évolution
/// réelle » : valeur reconstruite + courbe des flux externes sur une grille
/// commune, puis gain de période.
({
  List<double> values,
  List<double> flows,
  RealGains gains,
}) _rebuild(List<AssetTransaction> journal) {
  final grid = [for (var i = 0; i <= 100; i++) _d(i)];
  final hist = AssetHistoricalData(
    symbol: _symbol,
    dates: grid,
    prices: [for (final _ in grid) 4000.0],
  );
  final txsBySymbol = {
    _symbol: journal.where((t) => t.symbol == _symbol).toList(),
  };
  final txsByAccount = {_accountId: journal};

  final values = HistoryAggregator.reconstructRealNetWorth(
    txsBySymbol: txsBySymbol,
    txsByAccount: txsByAccount,
    symbolToData: {_symbol: hist},
    assetBySymbol: {_symbol: _asset},
    usdToEurRate: 0.9,
    gridDates: grid,
  ).values;
  final flows = HistoryAggregator.buildExternalFlowsCurve(
    txsBySymbol: txsBySymbol,
    txsByAccount: txsByAccount,
    symbolToData: {_symbol: hist},
    assetBySymbol: {_symbol: _asset},
    usdToEurRate: 0.9,
    gridDates: grid,
  );
  final gains = HistoryAggregator.computeRealGains(
    values: values,
    externalFlows: flows,
    gridDates: grid,
  );
  return (values: values, flows: flows, gains: gains);
}

void main() {
  group('Base de coût WAC crypto — conversion en double sans NaN', () {
    test(
        'rationalToDisplayDouble : dénominateur hors dynamique du double → '
        'valeur finie, jamais NaN', () {
      // Fraction de valeur 12 345,678 dont les DEUX termes dépassent 1e308 :
      // c'est exactement ce que produit une base de coût après une trentaine
      // de quote-parts WAC crypto.
      // Dénominateur IRRÉDUCTIBLE de 321 chiffres (le package canonise toute
      // fraction : la faire simplement « grosse » ne suffirait pas).
      final den = BigInt.from(10).pow(320) + BigInt.one;
      final r = Rational(den * BigInt.from(12345678) ~/ BigInt.from(1000), den);
      expect(r.toDouble().isNaN, isTrue, reason: 'piège du package rational');
      expect(rationalToDisplayDouble(r), closeTo(12345.678, 1e-6));
    });

    test('chemin rapide : valeur INCHANGÉE au bit près', () {
      final r = Rational(BigInt.from(1), BigInt.from(3));
      expect(rationalToDisplayDouble(r), r.toDouble());
    });

    test(
        '35 retraits on-chain partiels : costDelta et PRU restent finis '
        '(NaN avant correctif)', () {
      final deltas = <double>[];
      final r = replayLedger(
        _journal(exits: 35),
        onStep: (s) => deltas.add(s.costDelta),
      );
      expect(deltas.where((d) => !d.isFinite), isEmpty);
      expect(r.averagePrice, isNotNull);
      expect(r.averagePrice!.isFinite, isTrue);
    });
  });

  group('Écran compte crypto, mode « Évolution réelle »', () {
    test(
        'courbe « Capital investi » : entièrement finie et non nulle '
        '(les apports réels existent)', () {
      final r = _rebuild(_journal(exits: 35));

      expect(r.values.where((v) => !v.isFinite), isEmpty,
          reason: 'la courbe de valeur était déjà correcte');
      expect(r.flows.where((v) => !v.isFinite), isEmpty,
          reason: 'NaN ici → fl_chart ne trace RIEN (courbe invisible)');
      // Virement SEPA (20 000 €) + dépôt en nature à coût, moins les retraits
      // on-chain : le capital investi reste franchement positif.
      expect(r.flows.last, greaterThan(0.0));
    });

    test('la ligne « hors apports » n\'affiche jamais -NaN', () {
      final r = _rebuild(_journal(exits: 35));
      expect(r.gains.periodGain, isNotNull);
      expect(r.gains.periodGain!.isFinite, isTrue);
    });

    test(
        'la règle d\'échelle ne masque plus la série (symptôme « icône œil »)',
        () {
      final r = _rebuild(_journal(exits: 35));
      final valueMin = r.values.reduce((a, b) => a < b ? a : b);
      final valueMax = r.values.reduce((a, b) => a > b ? a : b);
      final flowMin = r.flows.reduce((a, b) => a < b ? a : b);
      final flowMax = r.flows.reduce((a, b) => a > b ? a : b);
      // Avec un NaN, `contributionsFitOnValueScale` rendait `false` (toute
      // comparaison à NaN est fausse) : la série était écartée du tracé et la
      // légende n'offrait plus que la bascule œil.
      expect(
        ValuationLineChart.contributionsFitOnValueScale(
          valueMin: valueMin,
          valueMax: valueMax,
          contributionsMin: flowMin,
          contributionsMax: flowMax,
        ),
        isTrue,
      );
    });
  });

  group('Garde de [computeRealGains] : série corrompue', () {
    test('un NaN dans les flux → tout null, jamais un chiffre', () {
      final gains = HistoryAggregator.computeRealGains(
        values: const [100.0, 200.0],
        externalFlows: const [0.0, double.nan],
        gridDates: [_d(0), _d(1)],
      );
      expect(gains.periodGain, isNull);
      expect(gains.periodGainPercent, isNull);
      expect(gains.periodGainPercentAnnualized, isNull);
    });
  });
}

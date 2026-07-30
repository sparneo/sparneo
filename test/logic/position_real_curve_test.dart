// test/logic/position_real_curve_test.dart
//
// Mode « Évolution réelle » de la PAGE DÉTAIL D'UNE POSITION : même machinerie
// que l'écran compte, appelée dans une configuration particulière — un SEUL
// symbole et `txsByAccount` VIDE, une position n'ayant pas de trésorerie propre
// (les espèces vivent au niveau du compte).
//
// Ce fichier garde ce contrat d'appel, pas le moteur (couvert par
// real_net_worth_test.dart) : c'est lui que la page suppose, et une régression
// y transformerait silencieusement la courbe en ligne plate à zéro.
//
// Le défaut d'origine : la page affichait `prix passé × quantité d'AUJOURD'HUI`.
// Un renfort récent était donc reprojeté sur toute la fenêtre, comme si la
// quantité actuelle avait toujours été détenue.

import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';

const _symbol = 'CW8';
final _asset = Asset(symbol: _symbol, currency: 'EUR');

/// Quatre dates de cotation à prix CONSTANT (100 €) : tout mouvement de la
/// courbe ne peut alors venir que de la quantité détenue, jamais du marché.
final _dates = [
  DateTime(2026, 1, 1),
  DateTime(2026, 1, 2),
  DateTime(2026, 1, 3),
  DateTime(2026, 1, 4),
];

AssetHistoricalData get _flatPrices => AssetHistoricalData(
      symbol: _symbol,
      dates: _dates,
      prices: const [100.0, 100.0, 100.0, 100.0],
    );

AssetTransaction _buy({
  required String id,
  required String quantity,
  required DateTime date,
}) =>
    AssetTransaction(
      id: id,
      accountId: 'acc1',
      symbol: _symbol,
      kind: TransactionKind.buy,
      quantity: quantity,
      unitPrice: '100',
      amount: '-${(double.parse(quantity) * 100).toStringAsFixed(0)}',
      currency: 'EUR',
      date: date,
    );

({List<double> values, List<double> flows}) _rebuild(
  List<AssetTransaction> journal, {
  List<DateTime>? grid,
}) {
  final gridDates = grid ?? _dates;
  final r = HistoryAggregator.reconstructRealNetWorth(
    txsBySymbol: {_symbol: journal},
    // VIDE : c'est tout l'objet de ce fichier — une position n'a pas de cash.
    txsByAccount: const {},
    symbolToData: {_symbol: _flatPrices},
    assetBySymbol: {_symbol: _asset},
    usdToEurRate: 1.0,
    gridDates: gridDates,
  );
  final flows = HistoryAggregator.buildExternalFlowsCurve(
    txsBySymbol: {_symbol: journal},
    txsByAccount: const {},
    symbolToData: {_symbol: _flatPrices},
    assetBySymbol: {_symbol: _asset},
    usdToEurRate: 1.0,
    gridDates: gridDates,
  );
  return (values: r.values, flows: flows);
}

void main() {
  group('courbe réelle d\'une position (un symbole, aucune trésorerie)', () {
    test(
        'un renfort en cours de fenêtre fait une MARCHE : la quantité d\'avant '
        'n\'est pas reprojetée en arrière', () {
      // 10 titres détenus depuis le 1er, +40 le 3 janvier. Prix constant.
      final journal = [
        _buy(id: 'b1', quantity: '10', date: DateTime(2026, 1, 1)),
        _buy(id: 'b2', quantity: '40', date: DateTime(2026, 1, 3)),
      ];

      final rebuilt = _rebuild(journal);

      expect(rebuilt.values, [1000.0, 1000.0, 5000.0, 5000.0]);
      // Ce que montrait l'ancienne page (quantité actuelle × cours passés) :
      // 5 000 € du premier au dernier jour — soit 4 000 € de patrimoine
      // inventés sur les deux premières dates.
    });

    test(
        'txsByAccount VIDE ne produit PAS une courbe nulle (le titre seul '
        'porte toute la valeur)', () {
      final rebuilt =
          _rebuild([_buy(id: 'b1', quantity: '3', date: DateTime(2026, 1, 1))]);

      expect(rebuilt.values.every((v) => v == 300.0), isTrue);
    });

    test('le capital investi suit le COÛT d\'acquisition, en escalier', () {
      final journal = [
        _buy(id: 'b1', quantity: '10', date: DateTime(2026, 1, 1)),
        _buy(id: 'b2', quantity: '40', date: DateTime(2026, 1, 3)),
      ];

      expect(_rebuild(journal).flows, [1000.0, 1000.0, 5000.0, 5000.0]);
    });

    test(
        'le gain de période EXCLUT l\'achat de la fenêtre (sinon un renfort '
        'passerait pour une performance)', () {
      final journal = [
        _buy(id: 'b1', quantity: '10', date: DateTime(2026, 1, 1)),
        _buy(id: 'b2', quantity: '40', date: DateTime(2026, 1, 3)),
      ];
      final rebuilt = _rebuild(journal);

      final gains = HistoryAggregator.computeRealGains(
        values: rebuilt.values,
        externalFlows: rebuilt.flows,
        gridDates: _dates,
      );

      // Prix constant : la valeur passe de 1 000 à 5 000 € sans le moindre
      // gain de marché. `fin − début` aurait annoncé +4 000 €.
      expect(gains.periodGain, closeTo(0, 0.01));
    });

    test('une position SANS journal n\'a pas de courbe réelle', () {
      // Cas legacy (quantité saisie à la main) : la page doit alors masquer le
      // sélecteur plutôt que proposer un mode vide.
      final rebuilt = _rebuild(const []);
      expect(rebuilt.values.every((v) => v == 0), isTrue);
    });

    test(
        'grille « Max » rognée au premier mouvement : pas de plat à zéro devant '
        'le premier achat', () {
      // Le titre cote depuis le 1er ; premier achat le 3.
      final journal = [
        _buy(id: 'b1', quantity: '10', date: DateTime(2026, 1, 3)),
      ];
      final firstTxDate = DateTime(2026, 1, 3);

      final trimmed = HistoryAggregator.applyGridFrom(_dates, firstTxDate);
      // Une date d'ancrage AVANT le premier mouvement est conservée (elle porte
      // le zéro d'où part la marche), pas les deux.
      expect(trimmed.first, DateTime(2026, 1, 2));

      final rebuilt = _rebuild(journal, grid: trimmed);
      expect(rebuilt.values, [0.0, 1000.0, 1000.0]);
    });

    test('la borne « Max » ne s\'applique qu\'à cette période', () {
      // Garde de non-régression du câblage de la page : sur toute autre période
      // la fenêtre est déjà bornée par sa durée, la rogner l'amputerait.
      expect(ChartPeriod.max.days, -1);
      expect(HistoryAggregator.applyGridFrom(_dates, null), _dates);
    });
  });
}

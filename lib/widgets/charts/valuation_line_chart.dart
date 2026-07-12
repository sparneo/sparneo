// lib/widgets/charts/valuation_line_chart.dart
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/indicator.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';

/// Graphique linéaire de valorisation, partagé par WalletView et AccountView.
///
/// Paramètres communs aux deux vues :
/// - [dates] / [values]       : séries de données de l'axe temporel.
/// - [snapshotSpots]          : série secondaire de snapshots réels (pointillés
///                              violets) ; liste vide = série absente.
/// - [periodChange]           : variation de période (nul = couleur verte par
///                              défaut, valeur < 0 = rouge).
/// - [selectedPeriod]         : période active (format axe / tooltip).
///
/// Paramètres de mise en page (défauts = wallet_view) :
/// - [height]                 : hauteur fixée par le parent ; null = dynamique
///                              (account_view utilise une hauteur calculée).
/// - [leftTitlesReservedSize] : espace pour l'axe gauche (wallet_view : 40,
///                              account_view : 50).
/// - [barWidth]               : épaisseur de la courbe principale (wallet : 3,
///                              account : 2).
/// - [showSnapshotLegend]     : afficher la légende sous le graphique quand la
///                              série snapshot est visible (toujours true dans
///                              wallet_view, peut être false dans account_view).
class ValuationLineChart extends StatelessWidget {
  final List<DateTime> dates;
  final List<double> values;
  final List<FlSpot> snapshotSpots;
  final double? periodChange;
  final ChartPeriod selectedPeriod;

  // Paramètres de mise en page
  final double? height;
  final double leftTitlesReservedSize;
  final double barWidth;
  final bool showSnapshotLegend;

  // Nombre cible de graduations par axe (l'axe Y peut en produire une de
  // plus ou de moins selon l'arrondi « nice », l'axe X une de moins après
  // déduplication des libellés identiques).
  static const int _targetYLabelCount = 4;
  static const int _targetXLabelCount = 5;

  // Plafond de labels pour les périodes au format calendaire — mensuel ou
  // annuel (au-delà, on écrème : 1 mois/an sur n, à pas régulier).
  static const int _maxCalendarLabelCount = 6;

  const ValuationLineChart({
    super.key,
    required this.dates,
    required this.values,
    required this.selectedPeriod,
    this.snapshotSpots = const [],
    this.periodChange,
    // Défauts wallet_view
    this.height = 200,
    this.leftTitlesReservedSize = 40,
    this.barWidth = 3,
    this.showSnapshotLegend = true,
  });

  /// Arrondit [rough] à l'intervalle « rond » le plus proche (1, 2 ou
  /// 5 × 10^n), pour des graduations lisibles quelle que soit l'amplitude.
  static double _niceInterval(double rough) {
    final magnitude = pow(10, (log(rough) / ln10).floor()).toDouble();
    final normalized = rough / magnitude;
    final double factor;
    if (normalized < 1.5) {
      factor = 1;
    } else if (normalized < 3) {
      factor = 2;
    } else if (normalized < 7) {
      factor = 5;
    } else {
      factor = 10;
    }
    return factor * magnitude;
  }

  /// Formate un montant pour l'axe des ordonnées de façon compacte
  /// (« 154 k€ », « 1.5 M€ »). L'unité est choisie une fois pour tout l'axe
  /// (d'après [axisMaxAbs]) afin que toutes les graduations partagent la même
  /// échelle, et le nombre de décimales est déduit de [interval] pour que deux
  /// graduations consécutives restent distinctes.
  static String _formatAxisAmount(
      double value, double interval, double axisMaxAbs) {
    final double divisor;
    final String suffix;
    if (axisMaxAbs >= 1000000) {
      divisor = 1000000;
      suffix = ' M€';
    } else if (axisMaxAbs >= 10000) {
      divisor = 1000;
      suffix = ' k€';
    } else {
      divisor = 1;
      suffix = ' €';
    }

    final scaled = value / divisor;
    final scaledInterval = interval / divisor;
    final int decimals;
    if (scaledInterval >= 1) {
      decimals = 0;
    } else if (scaledInterval >= 0.1) {
      decimals = 1;
    } else {
      decimals = 2;
    }
    return '${scaled.toStringAsFixed(decimals)}$suffix';
  }

  /// Indice de la date la plus proche de [target] dans [dates] (liste triée,
  /// recherche dichotomique).
  static int _nearestIndexByTime(List<DateTime> dates, DateTime target) {
    var lo = 0;
    var hi = dates.length - 1;
    if (!target.isAfter(dates[lo])) return lo;
    if (!target.isBefore(dates[hi])) return hi;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (dates[mid].isBefore(target)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return target.difference(dates[lo]).abs() <=
            dates[hi].difference(target).abs()
        ? lo
        : hi;
  }

  /// Indice du premier point à la date [target] ou APRÈS (liste triée,
  /// recherche dichotomique). Utilisé pour les cibles calendaires (« 1er du
  /// mois », « 1er janvier ») : le point le plus proche pourrait être fin de
  /// la période précédente (1er non coté, week-end/férié) et produirait le
  /// libellé du mauvais mois ou de la mauvaise année.
  static int _firstIndexAtOrAfter(List<DateTime> dates, DateTime target) {
    var lo = 0;
    var hi = dates.length - 1;
    if (!dates[lo].isBefore(target)) return lo;
    if (dates[hi].isBefore(target)) return hi; // garde : cible après la fin
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (dates[mid].isBefore(target)) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi;
  }

  /// Vrai si [Formatters.formatAxisDate] rend un libellé de MOIS pour cette
  /// période (les labels doivent alors tomber au 1er de chaque mois).
  static bool _usesMonthlyAxisFormat(ChartPeriod period) {
    switch (period) {
      case ChartPeriod.month3:
      case ChartPeriod.month6:
      case ChartPeriod.year1:
      case ChartPeriod.ytd:
        return true;
      default:
        return false;
    }
  }

  /// Vrai si [Formatters.formatAxisDate] rend un libellé d'ANNÉE pour cette
  /// période (les labels doivent alors tomber au 1er janvier de chaque année).
  static bool _usesYearlyAxisFormat(ChartPeriod period) {
    switch (period) {
      case ChartPeriod.year2:
      case ChartPeriod.year5:
      case ChartPeriod.year10:
      case ChartPeriod.max:
        return true;
      default:
        return false;
    }
  }

  /// Cibles calendaires — 1er janvier de chaque année si [yearly], sinon 1er
  /// de chaque mois — comprises dans [first … last]. Au-delà de
  /// [_maxCalendarLabelCount], écrémage à pas régulier (1 sur n : la séquence
  /// reste régulière, sans trou isolé — ex. 1A → 1 mois sur 2, MAX → 1 année
  /// sur n).
  static List<DateTime> _calendarStartTargets(
      DateTime first, DateTime last,
      {required bool yearly}) {
    DateTime startOfPeriod(DateTime d) =>
        yearly ? DateTime(d.year) : DateTime(d.year, d.month);
    DateTime next(DateTime d) =>
        yearly ? DateTime(d.year + 1) : DateTime(d.year, d.month + 1);

    final targets = <DateTime>[];
    var cursor = startOfPeriod(first);
    if (cursor.isBefore(first)) cursor = next(cursor);
    while (!cursor.isAfter(last)) {
      targets.add(cursor);
      cursor = next(cursor);
    }

    if (targets.length > _maxCalendarLabelCount) {
      final step = (targets.length / _maxCalendarLabelCount).ceil();
      return [for (var i = 0; i < targets.length; i += step) targets[i]];
    }
    return targets;
  }

  /// Instants cibles à étiqueter, équirépartis sur l'étendue temporelle
  /// réelle [dates.first … dates.last].
  static List<DateTime> _evenTimeTargets(List<DateTime> dates) {
    final spanUs = dates.last.difference(dates.first).inMicroseconds;
    if (spanUs <= 0) return [dates.first];
    return [
      for (var k = 0; k < _targetXLabelCount; k++)
        dates.first.add(
            Duration(microseconds: spanUs * k ~/ (_targetXLabelCount - 1))),
    ];
  }

  /// Sélectionne les indices à étiqueter sur l'axe temporel.
  ///
  /// L'échantillonnage Yahoo n'est PAS uniforme (trous les week-ends/jours
  /// fériés, plusieurs points le même jour quand les symboles cotent à des
  /// heures différentes) : une sélection par indice (`index % pas`) produit
  /// des libellés dupliqués ou mal répartis. Les cibles sont donc TEMPORELLES,
  /// selon trois régimes calqués sur le format de [Formatters.formatAxisDate] :
  /// - format annuel (2A/5A/10A/MAX) : le 1er janvier de chaque année de
  ///   l'étendue → années séquentielles, sans saut ;
  /// - format mensuel (3M/6M/1A/YTD) : le 1er de chaque mois de l'étendue ;
  ///   dans les deux cas, cible rattachée au premier point coté de la période
  ///   (voir [_firstIndexAtOrAfter]) ;
  /// - autres formats (J/S/1M) : [_targetXLabelCount] instants équirépartis,
  ///   rattachés au point le plus proche dans le temps.
  /// Puis déduplication (indices ET libellés formatés identiques).
  static Map<int, String> _computeTimeLabels(
      List<DateTime> dates, ChartPeriod period, String locale) {
    final labels = <int, String>{};
    if (dates.isEmpty) return labels;

    // Ancrage calendaire (1er du mois / 1er janvier). Repli équiréparti si
    // l'étendue contient moins de deux débuts de période (ex. YTD début
    // janvier, ou 2A sélectionné avec très peu d'historique).
    final yearly = _usesYearlyAxisFormat(period);
    var anchored = yearly || _usesMonthlyAxisFormat(period);
    List<DateTime> targets;
    if (anchored) {
      targets = _calendarStartTargets(dates.first, dates.last, yearly: yearly);
      if (targets.length < 2) {
        anchored = false;
        targets = _evenTimeTargets(dates);
      }
    } else {
      targets = _evenTimeTargets(dates);
    }

    String? previousLabel;
    for (final target in targets) {
      final index = anchored
          ? _firstIndexAtOrAfter(dates, target)
          : _nearestIndexByTime(dates, target);
      if (labels.containsKey(index)) continue;

      final label = Formatters.formatAxisDate(dates[index], period, locale);
      if (label == previousLabel) continue;

      labels[index] = label;
      previousLabel = label;
    }
    return labels;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;

    if (values.isEmpty || dates.isEmpty) {
      return Center(child: Text(l10n.noHistoricalData));
    }

    // Couleur principale selon la variation de période
    final mainColor = AppColors.gainLoss(
        context, periodChange != null && periodChange! >= 0);

    // Couleur série snapshots : accent tertiaire du thème (vestige de l'ancienne
    // charte mauve, désormais dérivé de la seed pour s'adapter au thème sombre).
    final snapshotColor = Theme.of(context).colorScheme.tertiary;

    // Bornes Y : étendues aux snapshots pour éviter que la série pointillée
    // soit rognée hors de la zone de tracé (correctif vague 2).
    double minY = values.reduce((a, b) => a < b ? a : b);
    double maxY = values.reduce((a, b) => a > b ? a : b);

    if (snapshotSpots.isNotEmpty) {
      for (final s in snapshotSpots) {
        if (s.y < minY) minY = s.y;
        if (s.y > maxY) maxY = s.y;
      }
    }

    final padding = (maxY - minY) * 0.1;

    // Bornes réelles du graphique (marge de 10 % de part et d'autre).
    var chartMinY = minY - padding;
    var chartMaxY = maxY + padding;
    if (chartMaxY - chartMinY <= 0) {
      // Série plate : élargir artificiellement pour un rendu correct.
      final margin = max(chartMaxY.abs() * 0.05, 1.0);
      chartMinY -= margin;
      chartMaxY += margin;
    }

    // Intervalle « rond » de l'axe Y (~4 graduations). Seuls les multiples de
    // cet intervalle sont étiquetés : les bornes brutes min/max sont exclues
    // (minIncluded/maxIncluded à false) car elles se superposaient aux
    // graduations rondes voisines.
    final yInterval =
        _niceInterval((chartMaxY - chartMinY) / _targetYLabelCount);
    final yAxisMaxAbs = max(chartMinY.abs(), chartMaxY.abs());

    // Labels de l'axe temporel, sélectionnés par le TEMPS (voir
    // _computeTimeLabels) : indice de point → libellé.
    final xLabelByIndex = _computeTimeLabels(dates, selectedPeriod, locale);

    // Couleur des labels d'axes, lisible en thème clair comme sombre.
    final axisLabelColor = Theme.of(context).colorScheme.onSurfaceVariant;

    // Série principale (reconstruction historique)
    final mainSeries = LineChartBarData(
      spots: dates
          .asMap()
          .entries
          .map((e) => FlSpot(e.key.toDouble(), values[e.key]))
          .toList(),
      isCurved: true,
      color: mainColor,
      barWidth: barWidth,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        color: mainColor.withValues(alpha: 0.1),
      ),
    );

    final List<LineChartBarData> allSeries = [mainSeries];

    // Série secondaire : snapshots réels (pointillés, visible si ≥ 2 points)
    if (snapshotSpots.isNotEmpty) {
      allSeries.add(LineChartBarData(
        spots: snapshotSpots,
        isCurved: false,
        color: snapshotColor,
        barWidth: 2,
        dashArray: [6, 4], // 6 px tracé, 4 px espace
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    final chartWidget = LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              // Un « tick » par point de données : la sélection réelle des
              // labels est faite en amont (xLabelByIndex). Sans intervalle
              // explicite, fl_chart génère des ticks fractionnaires qui,
              // tronqués en indices, dupliquaient les libellés.
              interval: 1,
              getTitlesWidget: (value, meta) {
                final label = xLabelByIndex[value.round()];
                if (label == null) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  // Rabat les labels des extrémités vers l'intérieur de la
                  // zone de tracé pour éviter qu'ils soient rognés.
                  fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 9, color: axisLabelColor),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: leftTitlesReservedSize,
              interval: yInterval,
              // Ne pas étiqueter les bornes brutes min/max : elles se
              // superposent aux graduations rondes voisines.
              minIncluded: false,
              maxIncluded: false,
              getTitlesWidget: (value, meta) {
                return Text(
                  _formatAxisAmount(value, yInterval, yAxisMaxAbs),
                  style: TextStyle(fontSize: 9, color: axisLabelColor),
                );
              },
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(show: false),
        minX: 0,
        maxX: dates.length.toDouble() - 1,
        minY: chartMinY,
        maxY: chartMaxY,
        lineBarsData: allSeries,
        lineTouchData: LineTouchData(
          handleBuiltInTouches: true,
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((touchedSpot) {
                final isSnapshotSeries = touchedSpot.barIndex == 1;
                final spotIndex = touchedSpot.spotIndex;

                // Pour la série principale, l'index X == indice dans dates.
                // Pour la série snapshots, FlSpot.x est aussi un indice dans
                // dates (même référentiel).
                final xIndex = isSnapshotSeries
                    ? touchedSpot.x.toInt().clamp(0, dates.length - 1)
                    : spotIndex;
                final date = dates[xIndex];
                final totalValue = touchedSpot.y;

                final dateLabel = Formatters.formatTooltipDate(
                    date, selectedPeriod, locale);

                // Série snapshot : distingué visuellement (point ●)
                final label = isSnapshotSeries
                    ? '$dateLabel\n${Formatters.formatEur(totalValue)} ●'
                    : '$dateLabel\n${Formatters.formatEur(totalValue)}';

                return LineTooltipItem(
                  label,
                  TextStyle(
                    color:
                        isSnapshotSeries ? snapshotColor : Colors.white,
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                );
              }).toList();
            },
            tooltipPadding: const EdgeInsets.all(8),
            tooltipMargin: 8,
          ),
        ),
      ),
    );

    // Le widget final : hauteur fixe ou dynamique selon le paramètre
    Widget sized = height != null
        ? SizedBox(height: height, child: chartWidget)
        : chartWidget;

    // Légende discrète sous le graphique, uniquement quand la série est visible
    // et que showSnapshotLegend est activé.
    if (snapshotSpots.isEmpty || !showSnapshotLegend) {
      return sized;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Quand height est fourni, on utilise Expanded pour que le graphique
        // remplisse le reste de l'espace laissé par la légende.
        height != null
            ? SizedBox(height: height! - 22, child: chartWidget)
            : Expanded(child: chartWidget),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Indicator(
            color: snapshotColor,
            text: l10n.realValueSeriesLabel,
            size: 10,
            textColor: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

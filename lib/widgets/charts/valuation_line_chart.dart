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
/// - [contributionsSpots]     : série « Capital investi » (mode réel) — ligne
///                              SOLIDE des versements−retraits cumulés, sous la
///                              courbe de valeur (l'écart visualise le gain) ;
///                              liste vide = série absente.
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
class ValuationLineChart extends StatefulWidget {
  final List<DateTime> dates;
  final List<double> values;
  final List<FlSpot> contributionsSpots;
  final double? periodChange;
  final ChartPeriod selectedPeriod;

  // Paramètres de mise en page
  final double? height;
  final double leftTitlesReservedSize;
  final double barWidth;

  // Nombre cible de graduations par axe (l'axe Y peut en produire une de
  // plus ou de moins selon l'arrondi « nice », l'axe X une de moins après
  // déduplication des libellés identiques).
  //
  // CIBLE, pas plafond : le nombre effectivement retenu est en outre borné par
  // la place disponible (cf. [maxLabelsForExtent]). Ces deux nombres étaient
  // seuls à décider jusqu'au 31/07, sans égard pour la taille du graphe ni pour
  // l'échelle de police : à 2,0 les étiquettes de l'axe Y se chevauchaient sur
  // le graphe court de l'écran compte, et les dates se collaient les unes aux
  // autres sur les écrans compte et position.
  static const int _targetYLabelCount = 4;
  static const int _targetXLabelCount = 5;

  /// Hauteur d'une ligne de texte rapportée à sa taille de police.
  static const double _labelLineHeightFactor = 1.3;

  /// Largeur moyenne d'un caractère rapportée à la taille de police — majorant
  /// pour les chiffres et séparateurs qui composent les libellés d'axes.
  static const double _labelCharWidthFactor = 0.62;

  /// Blanc minimal entre deux étiquettes voisines, en pixels. En dessous elles
  /// se lisent comme un seul bloc même sans se chevaucher.
  static const double _minLabelGapPx = 6;

  // Plafond de labels pour les périodes au format calendaire — mensuel ou
  // annuel (au-delà, on écrème : 1 mois/an sur n, à pas régulier).
  static const int _maxCalendarLabelCount = 6;

  /// Taille de police des étiquettes d'axes (gauche et bas).
  static const double _axisFontSize = 9;

  /// Espace réservé à l'axe des abscisses, à l'échelle de police 1. Reprend le
  /// défaut de fl_chart, désormais explicite parce qu'il est mis à l'échelle.
  static const double _bottomTitlesReservedSize = 22;

  /// Amplitude MINIMALE, en pixels, que doit conserver la courbe de valeur pour
  /// rester lisible une fois l'axe étiré au capital investi (cf.
  /// [contributionsFitOnValueScale]). En dessous, une courbe se lit comme un
  /// trait : ses variations ne sont plus distinguables de l'épaisseur du tracé.
  static const double _minValueAmplitudePx = 40;

  /// Hauteur de tracé supposée quand [height] est nul (graphe en hauteur
  /// dynamique) — valeur par défaut du widget, cf. constructeur.
  static const double _assumedPlotHeightPx = 200;

  /// Largeur de tracé supposée quand le parent n'en impose pas (contraintes
  /// horizontales non bornées) — ordre de grandeur d'un mobile.
  static const double _assumedPlotWidthPx = 300;

  /// Espace vertical du bandeau de légende : 6 dp d'écart au graphe, plus la
  /// ligne de la bascule — 17 dp de texte encadrés par le rembourrage qui lui
  /// tient lieu de cible tactile (41 dp mesurés sur Pixel 7a, cf.
  /// [_contributionsToggle]).
  ///
  /// ESTIMATION, et seulement pour la règle d'écrasement via [_chromeHeightPx] :
  /// la mise en page, elle, n'en dépend plus (le tracé prend ce que la légende
  /// laisse). Un écart de quelques pixels décale donc marginalement un seuil, il
  /// ne casse plus rien.
  static const double _legendBandHeightPx = 6 + 41;

  /// Espace vertical pris par la légende et l'axe des abscisses, à retrancher
  /// de [height] pour obtenir la hauteur réellement dessinable.
  static const double _chromeHeightPx =
      _legendBandHeightPx + _bottomTitlesReservedSize;

  const ValuationLineChart({
    super.key,
    required this.dates,
    required this.values,
    required this.selectedPeriod,
    this.contributionsSpots = const [],
    this.periodChange,
    // Défauts wallet_view
    this.height = 200,
    this.leftTitlesReservedSize = 40,
    this.barWidth = 3,
  });

  /// La ligne « capital investi » peut-elle partager l'échelle de la courbe de
  /// valeur sans l'aplatir ?
  ///
  /// Problème mesuré (retour d'écran du 30/07, périodes J/1M/3M) : l'axe Y était
  /// calculé sur l'UNION des deux séries. Or sur une fenêtre courte la valeur ne
  /// varie que de quelques centaines d'euros pendant que son écart au capital
  /// investi en fait plusieurs milliers — la courbe de valeur se retrouvait
  /// confinée dans 5 à 10 % de la hauteur, donc visuellement plate. La ligne
  /// secondaire, qui n'est le plus souvent qu'un palier constant sur ces
  /// fenêtres, effaçait ainsi l'information principale.
  ///
  /// Règle : l'axe est piloté par la VALEUR, et la ligne du capital investi n'y
  /// est admise que si la courbe de valeur conserve au moins
  /// [_minValueAmplitudePx] pixels d'amplitude une fois l'axe étiré. Sinon la
  /// ligne n'est pas tracée et son niveau est donné en toutes lettres sous le
  /// graphe (l'utilisateur pouvant toujours la rappeler d'un clic).
  ///
  /// **Critère en PIXELS, et non en proportion** (révision du 30/07 sur retour
  /// d'écran : « sur 1A ça reste lisible malgré la sortie de l'échelle »). Un
  /// simple ratio ignorait la taille du graphe et se trompait dans les deux
  /// sens : trop strict sur 1A, où la valeur garde une amplitude confortable
  /// bien que le capital soit loin en dessous ; trop permissif sur un graphe
  /// court, où la même proportion ne fait plus que quelques pixels. Ce qui rend
  /// une courbe lisible n'est pas la fraction de hauteur qu'elle occupe, mais
  /// le nombre de pixels qu'il lui reste — la règle mesure donc exactement ça,
  /// et s'adapte d'elle-même à la hauteur allouée ([plotHeightPx]).
  ///
  /// Le déclencheur reste GÉOMÉTRIQUE, jamais un seuil de période : la ligne
  /// reste visible sur 1M si l'écart est faible, et disparaît sur 1A si l'écart
  /// est énorme — c'est l'écrasement qui est en cause, pas la durée.
  ///
  /// Exception : une courbe de valeur PLATE (compte cash sans mouvement, point
  /// unique) n'a rien à écraser. Son amplitude serait nulle quoi qu'on fasse,
  /// alors que l'affichage des deux paliers reste parfaitement lisible — on
  /// garde donc la ligne (comportement d'origine).
  static bool contributionsFitOnValueScale({
    required double valueMin,
    required double valueMax,
    required double contributionsMin,
    required double contributionsMax,
    double plotHeightPx = _assumedPlotHeightPx,
  }) {
    final valueSpan = valueMax - valueMin;
    // Plate à 0,1 % près de son niveau : aucune variation à préserver.
    if (valueSpan <= max(valueMax.abs(), valueMin.abs()) * 0.001) return true;

    final unionSpan =
        max(valueMax, contributionsMax) - min(valueMin, contributionsMin);
    if (unionSpan <= 0) return true;

    // Pixels restants à la courbe de valeur une fois l'axe étiré aux deux
    // séries. La marge de 10 % ajoutée plus bas aux bornes réduit les deux
    // termes du même facteur : elle n'entre pas dans le rapport.
    final valueAmplitudePx = plotHeightPx * valueSpan / unionSpan;
    return valueAmplitudePx >= _minValueAmplitudePx;
  }

  /// Combien d'étiquettes un axe long de [extentPx] peut porter sans que deux
  /// voisines se touchent, chacune occupant [labelExtentPx] dans cette
  /// direction (sa hauteur de ligne sur l'axe Y, sa largeur sur l'axe X).
  ///
  /// C'est la contrainte que les nombres cibles ignoraient : ils fixaient un
  /// nombre de graduations sans regarder ni la taille du graphe, ni l'échelle
  /// de police du système — deux grandeurs qui varient d'un facteur 2 entre le
  /// grand graphe de l'écran position à l'échelle 1 et le graphe court de
  /// l'écran compte à l'échelle 2,0.
  ///
  /// Plancher à 2 : un axe porte au moins ses deux extrémités, et un intervalle
  /// calculé sur une cible de 1 ou 0 n'aurait pas de sens.
  static int maxLabelsForExtent(double extentPx, double labelExtentPx) {
    if (labelExtentPx <= 0) return _targetXLabelCount;
    return max(2, (extentPx / (labelExtentPx + _minLabelGapPx)).floor());
  }

  /// Écrème [labels] à au plus [maxCount] entrées, à pas régulier (1 sur n),
  /// en conservant l'ordre des abscisses.
  ///
  /// Même parti pris que l'écrémage calendaire de [_calendarStartTargets] : une
  /// séquence régulière plutôt qu'un choix « intelligent » qui laisserait des
  /// trous isolés et ferait croire à une irrégularité des données.
  static Map<int, String> thinLabels(Map<int, String> labels, int maxCount) {
    if (labels.length <= maxCount) return labels;
    final keys = labels.keys.toList()..sort();
    final step = (keys.length / maxCount).ceil();
    return {
      for (var i = 0; i < keys.length; i += step) keys[i]: labels[keys[i]]!,
    };
  }

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
  State<ValuationLineChart> createState() => _ValuationLineChartState();
}

class _ValuationLineChartState extends State<ValuationLineChart> {
  /// Choix EXPLICITE de l'utilisateur sur la ligne « capital investi » —
  /// `null` tant qu'il n'a rien décidé, auquel cas la règle automatique
  /// ([ValuationLineChart.contributionsFitOnValueScale]) tranche.
  ///
  /// Le seuil de cette règle est un arbitrage, pas une mesure : cette bascule
  /// donne le dernier mot à l'utilisateur dans les deux sens — forcer la ligne
  /// malgré l'écrasement, ou la masquer alors qu'elle tiendrait, pour lire la
  /// courbe de valeur en plein cadre. Volontairement de SESSION (aucune
  /// persistance) : c'est un geste de lecture, pas un réglage.
  bool? _userWantsContributions;

  @override
  Widget build(BuildContext context) {
    // Alias locaux : le corps ci-dessous est celui du widget avant son passage
    // en StatefulWidget (bascule d'affichage du capital investi).
    final dates = widget.dates;
    final values = widget.values;
    final contributionsSpots = widget.contributionsSpots;
    final periodChange = widget.periodChange;
    final selectedPeriod = widget.selectedPeriod;
    final height = widget.height;
    final leftTitlesReservedSize = widget.leftTitlesReservedSize;
    final barWidth = widget.barWidth;

    final l10n = AppLocalizations.of(context)!;
    final locale = Localizations.localeOf(context).languageCode;

    if (values.isEmpty || dates.isEmpty) {
      return Center(child: Text(l10n.noHistoricalData));
    }

    // Couleur principale selon la variation de période. `null` (variation non
    // calculable) → couleur de GAIN, conformément au contrat documenté
    // ci-dessus. L'ancienne condition (`!= null && >= 0`) rendait ROUGE tout
    // graphe dont la variation était inconnue, ce qui affichait une perte là
    // où il n'y avait qu'une absence de mesure — trompeur, et contraire à la
    // doc de ce widget (correctif du 29/07).
    final mainColor =
        AppColors.gainLoss(context, periodChange == null || periodChange >= 0);

    // Couleur série capital investi : accent tertiaire du thème (dérivé de la
    // seed pour s'adapter au thème sombre).
    final contributionsColor = Theme.of(context).colorScheme.tertiary;

    // Bornes Y : calculées sur la seule courbe de VALEUR — la série secondaire
    // ne les élargit que si elle tient sur cette échelle (cf. plus bas).
    double minY = values.reduce((a, b) => a < b ? a : b);
    double maxY = values.reduce((a, b) => a > b ? a : b);

    // Capital investi : n'entre dans les bornes QUE s'il n'aplatit pas la
    // courbe de valeur (cf. [contributionsFitOnValueScale]). Sinon la série est
    // écartée du tracé et son niveau est restitué en texte sous le graphe.
    var contributionsMin = 0.0;
    var contributionsMax = 0.0;
    var showContributionsSeries = false;
    // Vrai seulement quand c'est la RÈGLE qui a écarté la ligne — pas
    // l'utilisateur : les deux cas se disent différemment sous le graphe.
    var contributionsHiddenByRule = false;
    if (contributionsSpots.isNotEmpty) {
      contributionsMin = contributionsSpots.first.y;
      contributionsMax = contributionsSpots.first.y;
      for (final s in contributionsSpots) {
        if (s.y < contributionsMin) contributionsMin = s.y;
        if (s.y > contributionsMax) contributionsMax = s.y;
      }
      final fits = ValuationLineChart.contributionsFitOnValueScale(
        valueMin: minY,
        valueMax: maxY,
        contributionsMin: contributionsMin,
        contributionsMax: contributionsMax,
        // Hauteur dessinable ESTIMÉE : la règle raisonne en pixels, elle a
        // donc besoin de la place allouée à CE graphe (150 à 250 selon la vue).
        // Volontairement pas la hauteur mesurée du LayoutBuilder plus bas : sa
        // décision détermine le contenu de la légende, dont la hauteur détermine
        // celle du tracé — la mesurer ici fermerait le cycle. Les graduations,
        // elles, ne rétroagissent sur rien : elles peuvent se mesurer.
        plotHeightPx: height != null
            ? max(
                height - ValuationLineChart._chromeHeightPx,
                ValuationLineChart._minValueAmplitudePx,
              )
            : ValuationLineChart._assumedPlotHeightPx,
      );
      // Le choix explicite de l'utilisateur prime sur la règle, dans les DEUX
      // sens (forcer la ligne malgré l'écrasement, ou la masquer alors qu'elle
      // tiendrait pour lire la valeur en plein cadre).
      showContributionsSeries = _userWantsContributions ?? fits;
      contributionsHiddenByRule = !fits && _userWantsContributions == null;
      if (showContributionsSeries) {
        if (contributionsMin < minY) minY = contributionsMin;
        if (contributionsMax > maxY) maxY = contributionsMax;
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

    final yAxisMaxAbs = max(chartMinY.abs(), chartMaxY.abs());

    // Labels de l'axe temporel, sélectionnés par le TEMPS (voir
    // _computeTimeLabels) : indice de point → libellé. Écrémés plus bas selon
    // la largeur réellement disponible.
    final rawXLabels =
        ValuationLineChart._computeTimeLabels(dates, selectedPeriod, locale);
    final longestXLabelChars =
        rawXLabels.values.fold<int>(0, (longest, s) => max(longest, s.length));

    // Couleur des labels d'axes, lisible en thème clair comme sombre.
    final axisLabelColor = Theme.of(context).colorScheme.onSurfaceVariant;

    // L'espace réservé aux axes est un dp FIXE alors que leurs étiquettes
    // suivent l'échelle de police du système. Mesuré sur Pixel 7a le 31/07 : à
    // 1,5, « 160 k€ » ne tient plus dans les 40 dp de l'axe gauche, se replie
    // sur deux lignes, et son « k€ » vient se superposer aux chiffres du palier
    // voisin — quatre étiquettes sur six illisibles, les six à 2,0 ; en bas,
    // les dates sont tranchées en deux. Les gouttières suivent donc l'échelle.
    const axisFontSize = ValuationLineChart._axisFontSize;
    final axisTextScale =
        MediaQuery.textScalerOf(context).scale(axisFontSize) / axisFontSize;
    final scaledLeftTitlesReservedSize = leftTitlesReservedSize * axisTextScale;
    final scaledBottomTitlesReservedSize =
        ValuationLineChart._bottomTitlesReservedSize * axisTextScale;
    final scaledAxisFontSize = axisFontSize * axisTextScale;

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

    // Indice de barre de la série secondaire (pour le tooltip ci-dessous) —
    // dépend de l'ORDRE d'ajout, jamais supposé fixe.
    int? contributionsBarIndex;

    // Série secondaire : capital investi cumulé (mode réel, B7 Lot 3b) — ligne
    // SOLIDE sous la courbe de valeur, sans remplissage (l'écart vertical
    // visualise le gain).
    //
    // EN ESCALIER, jamais lissée : le capital investi est constant entre deux
    // mouvements et saute d'un coup au mouvement — c'est une fonction en
    // marches, pas un signal continu. Un lissage (`isCurved`) inventait une
    // progression graduelle entre deux apports, laissait la courbe DÉPASSER
    // ses propres paliers par débordement de spline, et pouvait la faire
    // croiser la courbe de valeur là où l'écart réel ne changeait pas de
    // signe — donc un gain/perte visuellement faux (retour du 29/07).
    if (showContributionsSeries) {
      contributionsBarIndex = allSeries.length;
      allSeries.add(LineChartBarData(
        spots: contributionsSpots,
        isCurved: false,
        isStepLineChart: true,
        // « forward » = garde la valeur courante jusqu'au point suivant, puis
        // saute : le palier tient jusqu'au mouvement, exactement comme le
        // capital réel. (« middle », le défaut, casserait la marche en son
        // milieu, à une date où rien ne s'est produit.)
        lineChartStepData: const LineChartStepData(
          stepDirection: LineChartStepData.stepDirectionForward,
        ),
        color: contributionsColor,
        barWidth: 2,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    final chartWidget = LayoutBuilder(builder: (context, constraints) {
      // Place réellement laissée au TRACÉ, gouttières d'axes déduites. Elle ne
      // peut se déduire d'aucune constante : la hauteur dépend de ce que la
      // légende a laissé (donc de la police), la largeur du parent. Contraintes
      // non bornées (hauteur dynamique) : repli sur les tailles supposées.
      final plotHeightPx = constraints.maxHeight.isFinite
          ? max(constraints.maxHeight - scaledBottomTitlesReservedSize, 1.0)
          : ValuationLineChart._assumedPlotHeightPx;
      final plotWidthPx = constraints.maxWidth.isFinite
          ? max(constraints.maxWidth - scaledLeftTitlesReservedSize, 1.0)
          : ValuationLineChart._assumedPlotWidthPx;

      // Axe Y : intervalle « rond » sur le nombre de graduations que la HAUTEUR
      // peut porter, sans dépasser la cible. Seuls les multiples de cet
      // intervalle sont étiquetés : les bornes brutes min/max sont exclues
      // (minIncluded/maxIncluded à false) car elles se superposaient aux
      // graduations rondes voisines.
      final yLabelCount = min(
        ValuationLineChart._targetYLabelCount,
        ValuationLineChart.maxLabelsForExtent(
          plotHeightPx,
          scaledAxisFontSize * ValuationLineChart._labelLineHeightFactor,
        ),
      );
      final yInterval = ValuationLineChart._niceInterval(
          (chartMaxY - chartMinY) / yLabelCount);

      // Axe X : écrémage des libellés déjà sélectionnés, au nombre que la
      // LARGEUR peut porter côte à côte. Le libellé le plus long fait la
      // mesure — ils sont de longueur homogène sur une même période (« 01/26 »,
      // « janv. », « 2024 »).
      final xLabelByIndex = ValuationLineChart.thinLabels(
        rawXLabels,
        ValuationLineChart.maxLabelsForExtent(
          plotWidthPx,
          longestXLabelChars *
              scaledAxisFontSize *
              ValuationLineChart._labelCharWidthFactor,
        ),
      );

      return LineChart(
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
                reservedSize: scaledBottomTitlesReservedSize,
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
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: axisFontSize,
                        color: axisLabelColor,
                      ),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: scaledLeftTitlesReservedSize,
                interval: yInterval,
                // Ne pas étiqueter les bornes brutes min/max : elles se
                // superposent aux graduations rondes voisines.
                minIncluded: false,
                maxIncluded: false,
                getTitlesWidget: (value, meta) {
                  return Text(
                    ValuationLineChart._formatAxisAmount(value, yInterval, yAxisMaxAbs),
                    // Une seule ligne, sans repli : si l'étiquette dépasse encore
                    // la gouttière, mieux vaut qu'elle rogne que qu'elle se replie
                    // sur la graduation voisine (c'est le repli qui produisait la
                    // superposition, pas le dépassement).
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: axisFontSize,
                      color: axisLabelColor,
                    ),
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
                  final isContributionsSeries =
                      contributionsBarIndex != null &&
                          touchedSpot.barIndex == contributionsBarIndex;
                  final spotIndex = touchedSpot.spotIndex;

                  // Série principale comme série « capital investi » : un point
                  // par date, l'indice du point EST l'indice dans dates.
                  final date = dates[spotIndex];
                  final totalValue = touchedSpot.y;

                  final dateLabel = Formatters.formatTooltipDate(
                      date, selectedPeriod, locale);

                  final label =
                      '$dateLabel\n${Formatters.formatEur(totalValue)}';

                  final labelColor =
                      isContributionsSeries ? contributionsColor : Colors.white;

                  return LineTooltipItem(
                    label,
                    TextStyle(
                      color: labelColor,
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
    });

    // Le widget final : hauteur fixe ou dynamique selon le paramètre
    Widget sized = height != null
        ? SizedBox(height: height, child: chartWidget)
        : chartWidget;

    // Légende discrète sous le graphique : présente dès que la série
    // « capital investi » est tracée.
    final bool showContributionsLegend = showContributionsSeries;
    // Série fournie mais NON tracée (elle aplatirait la valeur) : son niveau
    // est restitué en toutes lettres, faute de quoi elle disparaîtrait sans
    // explication d'une période à l'autre.
    final bool contributionsOffScale =
        contributionsSpots.isNotEmpty && !showContributionsSeries;

    if (!showContributionsLegend && !contributionsOffScale) {
      return sized;
    }

    final legendTextColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final legendChildren = <Widget>[
      // Quand la ligne apports est présente, une pastille « Valeur » lève
      // l'ambiguïté sur la série principale (l'écart entre les deux
      // visualise le gain).
      if (showContributionsLegend) ...[
        Indicator(
          color: mainColor,
          text: l10n.chartSeriesValueLegend,
          size: 10,
          textColor: legendTextColor,
        ),
        // La pastille « Capital investi » est le BOUTON de masquage : elle
        // désigne déjà la série, la rendre cliquable évite un réglage de plus
        // sous un graphe déjà dense.
        _contributionsToggle(
          context,
          tooltip: l10n.chartContributionsHideTooltip,
          visible: true,
          child: Indicator(
            color: contributionsColor,
            text: l10n.chartSeriesContributionsLegend,
            size: 10,
            textColor: legendTextColor,
          ),
        ),
      ],
    ];

    final withLegend = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Le tracé prend ce que la légende laisse, il ne se voit PAS allouer un
        // budget calculé. Retrancher une hauteur de bandeau supposée revenait à
        // parier sur les métriques du texte : le pari s'est perdu d'un pixel dès
        // la première mesure sur appareil (bandeau réel 41 dp, budget 40), et il
        // se serait reperdu à chaque changement de police ou de langue.
        Expanded(child: chartWidget),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: legendChildren.isEmpty
              ? _contributionsHiddenNote(
                  context,
                  l10n,
                  contributionsMin,
                  contributionsMax,
                  byRule: contributionsHiddenByRule,
                )
              : Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  // La bascule est deux fois plus haute que la pastille nue
                  // « Valeur » (son rembourrage lui sert de cible tactile) :
                  // sans centrage, l'alignement par le haut du Wrap décalait
                  // les deux libellés de 12 dp l'un sous l'autre.
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ...legendChildren,
                    if (contributionsOffScale)
                      _contributionsHiddenNote(
                        context,
                        l10n,
                        contributionsMin,
                        contributionsMax,
                        byRule: contributionsHiddenByRule,
                      ),
                  ],
                ),
        ),
      ],
    );

    // `Expanded` ci-dessus exige une hauteur bornée. Quand le parent n'en donne
    // pas, [height] la fournit ; sinon c'est au parent de contraindre (contrat
    // inchangé du cas height == null).
    return height != null
        ? SizedBox(height: height, child: withLegend)
        : withLegend;
  }

  /// Niveau du capital investi quand sa ligne n'est pas tracée : montant seul
  /// s'il est resté constant sur la fenêtre, bornes s'il a bougé (un apport
  /// dans la période est une information que le texte doit porter puisque la
  /// marche n'est plus visible).
  ///
  /// [byRule] distingue les deux raisons de ne pas la tracer, qui ne se disent
  /// pas pareil : « hors de l'échelle » quand la règle automatique a tranché,
  /// « masqué » quand l'utilisateur l'a lui-même replié — lui répondre qu'elle
  /// est hors échelle alors qu'il vient de la masquer serait une contre-vérité.
  Widget _contributionsHiddenNote(
    BuildContext context,
    AppLocalizations l10n,
    double contributionsMin,
    double contributionsMax, {
    required bool byRule,
  }) {
    final moved = (contributionsMax - contributionsMin).abs() >= 0.005;
    final String text;
    if (moved) {
      final from = Formatters.formatEur(contributionsMin);
      final to = Formatters.formatEur(contributionsMax);
      text = byRule
          ? l10n.chartContributionsOffScaleRange(from, to)
          : l10n.chartContributionsHiddenRange(from, to);
    } else {
      final amount = Formatters.formatEur(contributionsMax);
      text = byRule
          ? l10n.chartContributionsOffScale(amount)
          : l10n.chartContributionsHidden(amount);
    }

    return _contributionsToggle(
      context,
      tooltip: l10n.chartContributionsShowTooltip,
      visible: false,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Enveloppe cliquable de la bascule « capital investi », commune à la
  /// pastille de légende et à la note de repli.
  ///
  /// L'œil barré/ouvert est indispensable : sans lui, rien ne signalerait
  /// qu'un texte de légende est un bouton — un contrôle invisible n'existe pas
  /// (même constat que les filtres du journal hors écran, le 30/07).
  Widget _contributionsToggle(
    BuildContext context, {
    required String tooltip,
    required bool visible,
    required Widget child,
  }) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => setState(() => _userWantsContributions = !visible),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          // Le rembourrage vertical EST la cible tactile : la ligne de texte ne
          // fait que 16 dp, et mesurée au doigt sur Pixel 7a le 31/07 la boîte
          // n'en faisait que 20 — 41 % du minimum Material de 48. Porté à 12, il
          // la met à 40 dp. Pas 48 : chaque dp se paie ici en hauteur de tracé
          // (cf. [_legendBandHeightPx]), et 40 prend l'essentiel du gain pour un
          // tiers du coût.
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Souple : la note de repli porte deux montants et dépassait la
              // largeur d'un mobile (débordement mesuré en test). Elle passe à
              // la ligne au lieu de déborder ; la pastille de légende, courte,
              // n'est pas affectée.
              Flexible(child: child),
              const SizedBox(width: 4),
              Icon(
                visible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 12,
                color: color,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// test/widgets/valuation_line_chart_test.dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/charts/valuation_line_chart.dart';

// ValuationLineChart utilise AppLocalizations (noHistoricalData,
// libellés de légende) : on configure les delegates pour éviter le
// null-check en test.
Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: SizedBox(width: 360, child: child),
      ),
    );

/// Textes rendus dans le graphique qui matchent [re] (labels d'axes).
List<String> _textsMatching(WidgetTester tester, RegExp re) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where(re.hasMatch)
    .toList();

/// Série de dates NON uniformes façon Yahoo Finance : deux points par jour
/// ouvré (clôtures Paris 17h35 et US 22h00), trous les week-ends.
List<DateTime> _yahooLikeDates() {
  final dates = <DateTime>[];
  for (var day = 1; day <= 30; day++) {
    final d = DateTime(2026, 6, day);
    if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
      continue;
    }
    dates
      ..add(DateTime(2026, 6, day, 17, 35))
      ..add(DateTime(2026, 6, day, 22, 0));
  }
  return dates;
}

void main() {
  testWidgets(
      'axe temporel : labels dédupliqués et en nombre raisonnable '
      'malgré un échantillonnage non uniforme', (tester) async {
    final dates = _yahooLikeDates();
    final values =
        List<double>.generate(dates.length, (i) => 150000.0 + i * 100);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.month1,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    // Format 1M = jj/mm. Aucun libellé dupliqué (régression « 08/06 08/06 »),
    // et une répartition d'environ 4-6 labels.
    final labels = _textsMatching(tester, RegExp(r'^\d{2}/\d{2}$'));
    expect(labels.toSet().length, labels.length,
        reason: 'les labels de dates ne doivent pas être dupliqués');
    expect(labels.length, inInclusiveRange(3, 6));
  });

  testWidgets(
      'axe des ordonnées : graduations rondes compactes, sans les bornes '
      'brutes min/max', (tester) async {
    // Bornes du cas réel observé : 147035 → 154665.
    const minVal = 147035.0;
    const maxVal = 154665.0;
    final dates =
        List<DateTime>.generate(31, (i) => DateTime(2026, 6, 1 + i, 18));
    final values = List<double>.generate(
        dates.length, (i) => minVal + (maxVal - minVal) * i / 30);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.month1,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    // Intervalle « nice » attendu : 2000 € → graduations 148/150/152/154 k€.
    for (final expected in ['148 k€', '150 k€', '152 k€', '154 k€']) {
      expect(find.text(expected), findsOneWidget);
    }

    // Les bornes brutes (147035/154665 ± marge) ne doivent plus apparaître
    // (régression : chevauchement avec les graduations rondes voisines).
    expect(_textsMatching(tester, RegExp(r'^\d{5,} €$')), isEmpty);
  });

  testWidgets('montants < 10 k€ : labels en euros pleins', (tester) async {
    final dates =
        List<DateTime>.generate(10, (i) => DateTime(2026, 6, 1 + i, 18));
    final values = List<double>.generate(dates.length, (i) => 5000.0 + i * 80);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.month1,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    expect(_textsMatching(tester, RegExp(r'^\d+ €$')), isNotEmpty);
    expect(_textsMatching(tester, RegExp(r'k€$')), isEmpty);
  });

  testWidgets('série plate : rendu sans erreur (bornes élargies)',
      (tester) async {
    final dates =
        List<DateTime>.generate(10, (i) => DateTime(2026, 6, 1 + i, 18));
    final values = List<double>.filled(dates.length, 1000.0);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.month1,
      periodChange: 0.0,
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(LineChart), findsOneWidget);
    expect(_textsMatching(tester, RegExp(r'€$')), isNotEmpty);
  });

  testWidgets(
      'format mensuel (3M) : labels ancrés au 1er de chaque mois, '
      'même quand le 1er n\'est pas coté', (tester) async {
    // 15 avril → 10 juillet 2026, un point par jour ouvré à 18h, et le
    // 1er mai explicitement absent (férié) : le label « mai » doit quand
    // même apparaître, rattaché au premier point coté de mai.
    final dates = <DateTime>[];
    for (var d = DateTime(2026, 4, 15);
        !d.isAfter(DateTime(2026, 7, 10));
        d = d.add(const Duration(days: 1))) {
      if (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
        continue;
      }
      if (d.month == 5 && d.day == 1) continue; // 1er mai férié
      dates.add(DateTime(d.year, d.month, d.day, 18));
    }
    final values =
        List<double>.generate(dates.length, (i) => 150000.0 + i * 100);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.month3,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    // Débuts de mois dans l'étendue : 1er mai, 1er juin, 1er juillet.
    // « avr. » (position équirépartie de l'ancienne logique) ne doit PAS
    // apparaître : les labels sont ancrés aux changements de mois réels.
    expect(find.text('mai'), findsOneWidget);
    expect(find.text('juin'), findsOneWidget);
    expect(find.text('juil.'), findsOneWidget);
    expect(find.text('avr.'), findsNothing);
  });

  testWidgets('format mensuel (1A) : écrémage à ~6 labels sans doublon',
      (tester) async {
    // 1 an de points hebdomadaires : 13 débuts de mois dans l'étendue,
    // écrémés à 1 mois sur n (≤ 6 labels).
    final dates = <DateTime>[];
    for (var d = DateTime(2025, 7, 3);
        !d.isAfter(DateTime(2026, 7, 3));
        d = d.add(const Duration(days: 7))) {
      dates.add(DateTime(d.year, d.month, d.day, 18));
    }
    final values =
        List<double>.generate(dates.length, (i) => 150000.0 + i * 50);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.year1,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    // Labels de mois abrégés français (avec ou sans point, ex. « mai »,
    // « janv. »).
    final labels =
        _textsMatching(tester, RegExp(r'^[a-zéû]{3,5}\.?$', caseSensitive: false));
    expect(labels, isNotEmpty);
    expect(labels.length, lessThanOrEqualTo(6));
    expect(labels.toSet().length, labels.length,
        reason: 'les labels de mois ne doivent pas être dupliqués');
  });

  testWidgets(
      'format mensuel, étendue < 2 débuts de mois : repli équiréparti '
      'sans erreur', (tester) async {
    // YTD début janvier : aucune frontière de mois dans l'étendue.
    final dates =
        List<DateTime>.generate(15, (i) => DateTime(2026, 1, 2 + i, 18));
    final values =
        List<double>.generate(dates.length, (i) => 150000.0 + i * 100);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.ytd,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Un seul mois couvert → un seul label après déduplication.
    expect(find.text('janv.'), findsOneWidget);
  });

  testWidgets(
      'format annuel (5A) : années séquentielles ancrées au 1er janvier, '
      'même quand le 1er janvier n\'est pas coté', (tester) async {
    // Points hebdomadaires (mardis) de janvier 2021 à juillet 2026 : aucun
    // 1er janvier n'est coté → chaque année doit être rattachée à son premier
    // point coté. Régression visée : « 2023 » sautée par l'ancienne sélection
    // équirépartie + déduplication.
    final dates = <DateTime>[];
    for (var d = DateTime(2021, 1, 5);
        !d.isAfter(DateTime(2026, 7, 3));
        d = d.add(const Duration(days: 7))) {
      dates.add(DateTime(d.year, d.month, d.day, 18));
    }
    final values =
        List<double>.generate(dates.length, (i) => 100000.0 + i * 100);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.year5,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    // Débuts d'année dans l'étendue : 2022 → 2026, séquence complète.
    for (final year in ['2022', '2023', '2024', '2025', '2026']) {
      expect(find.text(year), findsOneWidget);
    }
    // Le 1er janvier 2021 précède la première date : pas de cible 2021.
    expect(find.text('2021'), findsNothing);
  });

  testWidgets('format annuel (10A) : écrémage à pas régulier, sans trou isolé',
      (tester) async {
    // ~11 débuts d'année dans l'étendue → écrémés (1 année sur n), la
    // séquence conservant un pas constant.
    final dates = <DateTime>[];
    for (var d = DateTime(2016, 3, 10);
        !d.isAfter(DateTime(2026, 7, 3));
        d = d.add(const Duration(days: 14))) {
      dates.add(DateTime(d.year, d.month, d.day, 18));
    }
    final values =
        List<double>.generate(dates.length, (i) => 100000.0 + i * 50);

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      selectedPeriod: ChartPeriod.year10,
      periodChange: 100.0,
    )));
    await tester.pumpAndSettle();

    final years = _textsMatching(tester, RegExp(r'^\d{4}$'))
        .map(int.parse)
        .toList();
    expect(years, isNotEmpty);
    expect(years.length, lessThanOrEqualTo(6));
    expect(years.toSet().length, years.length,
        reason: 'pas d\'année dupliquée');
    // Pas constant entre années consécutives (pas de trou isolé).
    final steps = [
      for (var i = 1; i < years.length; i++) years[i] - years[i - 1],
    ];
    expect(steps.toSet(), hasLength(1),
        reason: 'l\'écrémage doit garder une séquence régulière');
  });

  group('formatTooltipDate : année incluse pour les périodes >= 1 an', () {
    final dt = DateTime(2023, 6, 5, 17, 35);

    test('périodes longues → jour/mois/année', () {
      for (final period in [
        ChartPeriod.year1,
        ChartPeriod.year2,
        ChartPeriod.year5,
        ChartPeriod.year10,
        ChartPeriod.max,
      ]) {
        expect(Formatters.formatTooltipDate(dt, period), '05/06/2023',
            reason: 'période $period');
      }
    });

    test('périodes courtes → formats inchangés', () {
      expect(Formatters.formatTooltipDate(dt, ChartPeriod.month3), '05/06');
      expect(Formatters.formatTooltipDate(dt, ChartPeriod.month6), '05/06');
      expect(Formatters.formatTooltipDate(dt, ChartPeriod.ytd), '05/06');
      expect(
          Formatters.formatTooltipDate(dt, ChartPeriod.week), '05/06 17h35');
      expect(Formatters.formatTooltipDate(dt, ChartPeriod.day), '17h35');
    });
  });

  // ---------------------------------------------------------------------------
  // Couleur de la courbe principale (correctif du 29/07) : elle suit le SIGNE
  // de la variation de période. Le cas `null` (variation non calculable) doit
  // rendre la couleur de GAIN — le contrat documenté du widget — et non celle
  // de perte, qui affichait une perte là où il n'y a qu'absence de mesure.
  // ---------------------------------------------------------------------------

  group('couleur de la courbe selon periodChange', () {
    final dates = [
      DateTime(2026, 6, 1),
      DateTime(2026, 6, 2),
      DateTime(2026, 6, 3),
    ];
    const values = [100.0, 110.0, 120.0];

    Future<Color> mainColorFor(WidgetTester tester, double? periodChange) async {
      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: values,
        selectedPeriod: ChartPeriod.month1,
        periodChange: periodChange,
      )));
      await tester.pumpAndSettle();
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      return chart.data.lineBarsData.first.color!;
    }

    testWidgets('variation positive et variation nulle : MÊME couleur (gain)',
        (tester) async {
      final positive = await mainColorFor(tester, 250.0);
      final zero = await mainColorFor(tester, 0.0);
      expect(zero, positive);
    });

    testWidgets('variation négative : couleur DIFFÉRENTE (perte)',
        (tester) async {
      final positive = await mainColorFor(tester, 250.0);
      final negative = await mainColorFor(tester, -250.0);
      expect(negative, isNot(positive));
    });

    testWidgets(
        'periodChange null : couleur de GAIN (et non de perte) — régression du '
        'graphe figé en rouge en mode réel', (tester) async {
      final positive = await mainColorFor(tester, 250.0);
      final negative = await mainColorFor(tester, -250.0);
      final unknown = await mainColorFor(tester, null);

      expect(unknown, positive);
      expect(unknown, isNot(negative));
    });
  });

  // ---------------------------------------------------------------------------
  // Série « Capital investi » : fonction EN ESCALIER (constante entre deux
  // mouvements, saut au mouvement) — jamais lissée (retour du 29/07).
  // ---------------------------------------------------------------------------

  testWidgets(
      'la série capital investi est en escalier et NON lissée, contrairement '
      'à la courbe de valeur', (tester) async {
    final dates = [
      DateTime(2026, 6, 1),
      DateTime(2026, 6, 2),
      DateTime(2026, 6, 3),
    ];
    const values = [100.0, 110.0, 120.0];
    const contributions = [
      FlSpot(0, 100),
      FlSpot(1, 100),
      FlSpot(2, 120),
    ];

    await tester.pumpWidget(_host(ValuationLineChart(
      dates: dates,
      values: values,
      contributionsSpots: contributions,
      selectedPeriod: ChartPeriod.month1,
      periodChange: 20.0,
    )));
    await tester.pumpAndSettle();

    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.data.lineBarsData, hasLength(2));

    final contributionsBar = chart.data.lineBarsData[1];
    expect(contributionsBar.isStepLineChart, isTrue);
    expect(contributionsBar.isCurved, isFalse);
    // « forward » : le palier tient jusqu'au mouvement suivant, la marche n'est
    // pas cassée en son milieu (à une date où rien ne s'est produit).
    expect(
      contributionsBar.lineChartStepData.stepDirection,
      LineChartStepData.stepDirectionForward,
    );
  });

  group('échelle Y — le capital investi n\'écrase pas la courbe de valeur', () {
    // Cas mesuré à l'écran (30/07, périodes J/1M/3M) : la valeur varie de
    // quelques centaines d'euros pendant que son écart au capital investi en
    // fait plusieurs milliers. L'axe étant calculé sur l'union des deux séries,
    // la courbe de valeur était confinée dans ~7 % de la hauteur : plate.
    final dates = List<DateTime>.generate(20, (i) => DateTime(2026, 6, 1 + i, 18));
    final squashedValues =
        List<double>.generate(20, (i) => 61000.0 + (i.isEven ? 0 : 400));
    final farContributions =
        List<FlSpot>.generate(20, (i) => FlSpot(i.toDouble(), 50000));

    test('règle pure : écart énorme → la ligne ne partage pas l\'échelle', () {
      expect(
        ValuationLineChart.contributionsFitOnValueScale(
          valueMin: 61000,
          valueMax: 61400,
          contributionsMin: 50000,
          contributionsMax: 50000,
        ),
        isFalse,
      );
    });

    test('règle pure : écart modéré → la ligne reste tracée', () {
      // Amplitude valeur 400 €, capital 200 € sous le bas : union 600 ≤ 1,5×400.
      expect(
        ValuationLineChart.contributionsFitOnValueScale(
          valueMin: 61000,
          valueMax: 61400,
          contributionsMin: 60800,
          contributionsMax: 60800,
        ),
        isTrue,
      );
    });

    test(
        'règle pure : courbe de valeur PLATE → la ligne est gardée (rien à '
        'écraser, cas du compte cash)', () {
      expect(
        ValuationLineChart.contributionsFitOnValueScale(
          valueMin: 61000,
          valueMax: 61000,
          contributionsMin: 50000,
          contributionsMax: 50000,
        ),
        isTrue,
      );
    });

    test(
        'cas 1A : valeur ample, capital nettement plus bas → TRACÉE (l\'ancien '
        'critère en proportion la masquait à quelques euros près)', () {
      // Valeur 52 000 → 61 000 (amplitude 9 000), capital 47 000 → 50 000.
      // Union 14 000 : la valeur garde 9/14 de la hauteur, soit ~128 px sur un
      // graphe de 200 — parfaitement lisible. L'ancien seuil (union ≤ 1,5 ×
      // amplitude, ici 14 000 > 13 500) l'écartait pourtant.
      expect(
        ValuationLineChart.contributionsFitOnValueScale(
          valueMin: 52000,
          valueMax: 61000,
          contributionsMin: 47000,
          contributionsMax: 50000,
          plotHeightPx: 200,
        ),
        isTrue,
      );
    });

    test(
        'la MÊME géométrie se décide différemment selon la hauteur allouée '
        '(le critère est en pixels, pas en proportion)', () {
      // La valeur garde 1/5 de la hauteur : 40 px sur un graphe de 200 (limite
      // atteinte, tracée), 24 px sur un graphe de 120 (illisible, écartée).
      const geometry = (
        valueMin: 60000.0,
        valueMax: 61000.0,
        contributionsMin: 56000.0,
        contributionsMax: 56000.0,
      );
      expect(
        ValuationLineChart.contributionsFitOnValueScale(
          valueMin: geometry.valueMin,
          valueMax: geometry.valueMax,
          contributionsMin: geometry.contributionsMin,
          contributionsMax: geometry.contributionsMax,
          plotHeightPx: 200,
        ),
        isTrue,
      );
      expect(
        ValuationLineChart.contributionsFitOnValueScale(
          valueMin: geometry.valueMin,
          valueMax: geometry.valueMax,
          contributionsMin: geometry.contributionsMin,
          contributionsMax: geometry.contributionsMax,
          plotHeightPx: 120,
        ),
        isFalse,
      );
    });

    testWidgets(
        'écart énorme : une seule série tracée, bornes Y calées sur la valeur',
        (tester) async {
      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: squashedValues,
        contributionsSpots: farContributions,
        selectedPeriod: ChartPeriod.month1,
        periodChange: 400.0,
      )));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData, hasLength(1),
          reason: 'le capital investi ne doit pas être tracé ici');
      // L'axe reste dans le voisinage de la valeur (marge de 10 %), très
      // au-dessus du capital investi à 50 000 €.
      expect(chart.data.minY, greaterThan(60000));
      expect(chart.data.maxY, lessThan(62000));
    });

    testWidgets('écart énorme : le niveau du capital est donné en toutes lettres',
        (tester) async {
      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: squashedValues,
        contributionsSpots: farContributions,
        selectedPeriod: ChartPeriod.month1,
        periodChange: 400.0,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('Capital investi'), findsOneWidget);
      expect(find.textContaining('hors de l\'échelle'), findsOneWidget);
    });

    testWidgets(
        'capital NON tracé mais ayant BOUGÉ : la note donne les deux bornes '
        '(la marche n\'est plus visible)', (tester) async {
      final moving = List<FlSpot>.generate(
          20, (i) => FlSpot(i.toDouble(), i < 10 ? 47000 : 50000));

      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: squashedValues,
        contributionsSpots: moving,
        selectedPeriod: ChartPeriod.month1,
        periodChange: 400.0,
      )));
      await tester.pumpAndSettle();

      final note = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .firstWhere((t) => t.contains('Capital investi'));
      expect(note, contains('47'));
      expect(note, contains('50'));
    });

    testWidgets('écart modéré : la ligne et sa légende restent affichées',
        (tester) async {
      final close =
          List<FlSpot>.generate(20, (i) => FlSpot(i.toDouble(), 60800));

      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: squashedValues,
        contributionsSpots: close,
        selectedPeriod: ChartPeriod.month1,
        periodChange: 400.0,
      )));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData, hasLength(2));
      expect(find.textContaining('hors de l\'échelle'), findsNothing);
    });
  });

  group('bascule manuelle du capital investi', () {
    // Le seuil de la règle automatique est un ARBITRAGE, pas une mesure : la
    // bascule donne le dernier mot à l'utilisateur, dans les deux sens.
    final dates = List<DateTime>.generate(20, (i) => DateTime(2026, 6, 1 + i, 18));
    final squashedValues =
        List<double>.generate(20, (i) => 61000.0 + (i.isEven ? 0 : 400));
    final farContributions =
        List<FlSpot>.generate(20, (i) => FlSpot(i.toDouble(), 50000));
    final closeContributions =
        List<FlSpot>.generate(20, (i) => FlSpot(i.toDouble(), 60800));

    testWidgets(
        'un tap sur la note ramène la ligne écartée par la règle (et étire '
        'l\'axe en conséquence)', (tester) async {
      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: squashedValues,
        contributionsSpots: farContributions,
        selectedPeriod: ChartPeriod.month1,
        periodChange: 400.0,
      )));
      await tester.pumpAndSettle();

      expect(tester.widget<LineChart>(find.byType(LineChart)).data.lineBarsData,
          hasLength(1));

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();

      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData, hasLength(2),
          reason: 'le choix explicite doit primer sur la règle');
      expect(chart.data.minY, lessThan(50000),
          reason: 'l\'axe doit descendre jusqu\'au capital investi');
    });

    testWidgets(
        'un tap sur la pastille masque une ligne pourtant à l\'échelle, et la '
        'note dit « masqué » et non « hors de l\'échelle »', (tester) async {
      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: squashedValues,
        contributionsSpots: closeContributions,
        selectedPeriod: ChartPeriod.month1,
        periodChange: 400.0,
      )));
      await tester.pumpAndSettle();

      expect(tester.widget<LineChart>(find.byType(LineChart)).data.lineBarsData,
          hasLength(2));

      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pumpAndSettle();

      expect(tester.widget<LineChart>(find.byType(LineChart)).data.lineBarsData,
          hasLength(1));
      expect(find.textContaining('masqué'), findsOneWidget);
      expect(find.textContaining('hors de l\'échelle'), findsNothing,
          reason: 'ce serait faux : c\'est l\'utilisateur qui l\'a repliée');
    });

    testWidgets('la bascule est réversible', (tester) async {
      await tester.pumpWidget(_host(ValuationLineChart(
        dates: dates,
        values: squashedValues,
        contributionsSpots: farContributions,
        selectedPeriod: ChartPeriod.month1,
        periodChange: 400.0,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pumpAndSettle();

      expect(tester.widget<LineChart>(find.byType(LineChart)).data.lineBarsData,
          hasLength(1));
      expect(find.textContaining('masqué'), findsOneWidget);
    });
  });
}

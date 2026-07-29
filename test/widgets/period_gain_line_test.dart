// test/widgets/period_gain_line_test.dart
//
// Ligne « performance sur la période affichée », extraite de TotalValueCard le
// 29/07 et déplacée SOUS le graphique : elle dépend du sélecteur de période ET
// du sélecteur de mode, qui vivent dans la section graphique. Ces tests
// reprennent la couverture historique de total_value_card_test.dart pour la
// partie période (signe, pourcentages, annualisation, aide, overflow), et
// couvrent le préfixe de portée temporelle du lot d'épuration UI du 29/07
// (netOfContributions, remplace l'ancien paramètre `caption`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/widgets/charts/period_gain_line.dart';

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: SizedBox(width: 360, child: child),
      ),
    );

void main() {
  testWidgets('amount null : rien n\'est rendu', (tester) async {
    await tester.pumpWidget(_host(const PeriodGainLine(
      selectedPeriod: ChartPeriod.month1,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.trending_up), findsNothing);
    expect(find.byIcon(Icons.trending_down), findsNothing);
  });

  testWidgets('variation positive → icône trending_up', (tester) async {
    await tester.pumpWidget(_host(const PeriodGainLine(
      amount: 150.50,
      percent: 3.1,
      selectedPeriod: ChartPeriod.month1,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.trending_up), findsOneWidget);
    expect(find.byIcon(Icons.trending_down), findsNothing);
    expect(find.textContaining(RegExp(r'\+150,50\s€')), findsOneWidget);
    expect(find.textContaining(RegExp(r'\+3,1\s%')), findsOneWidget);
  });

  testWidgets('variation négative → icône trending_down', (tester) async {
    await tester.pumpWidget(_host(const PeriodGainLine(
      amount: -200.0,
      percent: -4.8,
      selectedPeriod: ChartPeriod.month3,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.trending_down), findsOneWidget);
    expect(find.byIcon(Icons.trending_up), findsNothing);
    expect(find.textContaining(RegExp(r'-200,00\s€')), findsOneWidget);
    expect(find.textContaining(RegExp(r'-4,8\s%')), findsOneWidget);
  });

  testWidgets('percent null → « — » affiché', (tester) async {
    await tester.pumpWidget(_host(const PeriodGainLine(
      amount: 50.0,
      selectedPeriod: ChartPeriod.month1,
    )));
    await tester.pumpAndSettle();

    // Microcopie FR : « N/A » → tiret cadratin (l10n.notAvailable).
    expect(find.textContaining('—'), findsOneWidget);
  });

  testWidgets(
    'percentAnnualized == null (défaut) : un seul pourcentage, sans '
    'parenthèses',
    (tester) async {
      await tester.pumpWidget(_host(const PeriodGainLine(
        amount: 150.50,
        percent: 9.07,
        selectedPeriod: ChartPeriod.max,
      )));
      await tester.pumpAndSettle();

      // Formatters.formatPercentFr arrondit à 1 décimale par défaut.
      expect(find.textContaining(RegExp(r'\+9,1\s%')), findsOneWidget);
      expect(find.textContaining('/an'), findsNothing);
    },
  );

  testWidgets(
    'percentAnnualized non-null : les deux pourcentages (cumulé + annualisé '
    'entre parenthèses) sont affichés',
    (tester) async {
      await tester.pumpWidget(_host(const PeriodGainLine(
        amount: 150.50,
        percent: 183.4,
        selectedPeriod: ChartPeriod.max,
        percentAnnualized: 9.07,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining(RegExp(r'\+183,4\s%')), findsOneWidget);
      expect(find.textContaining(RegExp(r'\(\+9,1\s%/an\)')), findsOneWidget);
    },
  );

  testWidgets(
    'netOfContributions par défaut (mode performance) : période en fin de '
    'ligne, pas de préfixe de portée',
    (tester) async {
      await tester.pumpWidget(_host(const PeriodGainLine(
        amount: 150.50,
        percent: 9.07,
        selectedPeriod: ChartPeriod.year1,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('1A'), findsOneWidget);
      expect(find.textContaining('hors apports'), findsNothing);
    },
  );

  testWidgets(
    'netOfContributions=true, période normale : préfixe « Sur {période}, '
    'hors apports » EN TÊTE de ligne',
    (tester) async {
      await tester.pumpWidget(_host(const PeriodGainLine(
        amount: 608.04,
        percent: 29.7,
        selectedPeriod: ChartPeriod.year5,
        netOfContributions: true,
      )));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          RegExp(r'Sur 5A, hors apports · \+608,04\s€ · \+29,7\s%'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'netOfContributions=true, période Max : préfixe « Depuis l\'origine, '
    'hors apports » (pas le jeton "Max" brut)',
    (tester) async {
      await tester.pumpWidget(_host(const PeriodGainLine(
        amount: 608.04,
        percent: 29.7,
        selectedPeriod: ChartPeriod.max,
        netOfContributions: true,
      )));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          RegExp(r"Depuis l'origine, hors apports · \+608,04\s€ · \+29,7\s%"),
        ),
        findsOneWidget,
      );
      // Pas de "Max" isolé en tête — le préfixe l'a entièrement remplacé.
      expect(find.textContaining('Sur Max'), findsNothing);
    },
  );

  testWidgets('onInfoPressed null (défaut) : aucune icône d\'aide', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const PeriodGainLine(
      amount: 150.50,
      percent: 9.07,
      selectedPeriod: ChartPeriod.max,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.info_outline), findsNothing);
  });

  testWidgets(
    'onInfoPressed fourni : icône d\'aide affichée et tap déclenche le callback',
    (tester) async {
      var pressed = false;
      await tester.pumpWidget(_host(PeriodGainLine(
        amount: 150.50,
        percent: 9.07,
        selectedPeriod: ChartPeriod.max,
        onInfoPressed: () => pressed = true,
      )));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.info_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();

      expect(pressed, isTrue);
    },
  );

  testWidgets(
    'aucun overflow sur largeur réduite avec percentAnnualized ET préfixe de '
    'portée (ligne la plus longue possible, mitigation maxLines: 2)',
    (tester) async {
      await tester.pumpWidget(_host(const PeriodGainLine(
        amount: -123456.78,
        percent: -1234567.89,
        selectedPeriod: ChartPeriod.max,
        percentAnnualized: -55.55,
        netOfContributions: true,
      )));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}

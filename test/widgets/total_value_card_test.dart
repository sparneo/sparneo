// test/widgets/total_value_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/widgets/total_value_card.dart';

// TotalValueCard utilise AppLocalizations (variationOverPeriod, notAvailable) :
// on configure les delegates pour éviter le null-check en test.
Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: SizedBox(width: 360, child: child),
      ),
    );

void main() {
  testWidgets('affiche la valeur totale formatée', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 12345.67,
      selectedPeriodLabel: '1M',
      title: 'Valeur totale',
    )));
    await tester.pumpAndSettle();

    // Format FR : « 12 345,67 € » (espaces insécables — \s les matche).
    expect(find.textContaining(RegExp(r'12\s345,67\s€')), findsOneWidget);
    expect(find.text('Valeur totale'), findsOneWidget);
  });

  testWidgets('sans periodChange, pas d\'encadré variation', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 1000.00,
      selectedPeriodLabel: '1M',
      title: 'Total',
    )));
    await tester.pumpAndSettle();

    // Aucun icône trending_up ni trending_down
    expect(find.byIcon(Icons.trending_up), findsNothing);
    expect(find.byIcon(Icons.trending_down), findsNothing);
  });

  testWidgets('variation positive → icône trending_up', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 5000.00,
      periodChange: 150.50,
      periodChangePercent: 3.1,
      selectedPeriodLabel: '1M',
      title: 'Total',
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.trending_up), findsOneWidget);
    expect(find.byIcon(Icons.trending_down), findsNothing);
    expect(find.textContaining(RegExp(r'\+150,50\s€')), findsOneWidget);
    expect(find.textContaining(RegExp(r'\+3,1\s%')), findsOneWidget);
  });

  testWidgets('variation négative → icône trending_down', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 4000.00,
      periodChange: -200.0,
      periodChangePercent: -4.8,
      selectedPeriodLabel: '3M',
      title: 'Total',
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.trending_down), findsOneWidget);
    expect(find.byIcon(Icons.trending_up), findsNothing);
    expect(find.textContaining(RegExp(r'-200,00\s€')), findsOneWidget);
    expect(find.textContaining(RegExp(r'-4,8\s%')), findsOneWidget);
  });

  testWidgets('periodChangePercent null → "N/D" affiché', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 1000.00,
      periodChange: 50.0,
      selectedPeriodLabel: '1M',
      title: 'Total',
    )));
    await tester.pumpAndSettle();

    // Selon l10n.notAvailable — le widget affiche « — » quand percent est null
    // (microcopie FR : « N/A » → tiret cadratin).
    expect(find.textContaining('—'), findsOneWidget);
  });

  testWidgets('aucun overflow sur largeur réduite', (tester) async {
    await tester.pumpWidget(_host(TotalValueCard(
      totalValue: 999999.99,
      periodChange: -123456.78,
      periodChangePercent: -55.5,
      selectedPeriodLabel: '10A',
      title: 'Valeur totale du portefeuille',
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'aucun overflow sur largeur réduite avec percentAnnualized (ligne plus '
    'longue, mitigation maxLines: 2)',
    (tester) async {
      await tester.pumpWidget(_host(const TotalValueCard(
        totalValue: 999999.99,
        periodChange: -123456.78,
        periodChangePercent: -1234567.89,
        selectedPeriodLabel: 'Max',
        title: 'Valeur totale du portefeuille',
        percentAnnualized: -55.55,
      )));
      await tester.pumpAndSettle();
      // Aucune exception FlutterError (dont RenderFlex overflowed) levée
      // pendant le pump — vérifie que le passage à maxLines: 2 absorbe la
      // ligne combinée cumulé+annualisé sans overflow VERTICAL ni HORIZONTAL.
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'percentAnnualized == null (défaut) : un seul pourcentage, sans '
    'parenthèses',
    (tester) async {
      await tester.pumpWidget(_host(const TotalValueCard(
        totalValue: 5000.00,
        periodChange: 150.50,
        periodChangePercent: 9.07,
        selectedPeriodLabel: 'Max',
        title: 'Total',
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
      await tester.pumpWidget(_host(const TotalValueCard(
        totalValue: 5000.00,
        periodChange: 150.50,
        periodChangePercent: 183.4,
        selectedPeriodLabel: 'Max',
        title: 'Total',
        percentAnnualized: 9.07,
      )));
      await tester.pumpAndSettle();

      // Le texte combiné contient le cumulé ET l'annualisé entre parenthèses
      // (cf. l10n.chartPercentWithAnnualized : "{percent} ({annualized}/an)").
      expect(find.textContaining(RegExp(r'\+183,4\s%')), findsOneWidget);
      expect(find.textContaining('/an'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\(\+9,1\s%/an\)')), findsOneWidget);
    },
  );

  testWidgets(
    'onInfoPressed null (défaut) : aucune icône d\'aide affichée',
    (tester) async {
      await tester.pumpWidget(_host(const TotalValueCard(
        totalValue: 5000.00,
        periodChange: 150.50,
        periodChangePercent: 9.07,
        selectedPeriodLabel: 'Max',
        title: 'Total',
      )));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.info_outline), findsNothing);
    },
  );

  testWidgets(
    'onInfoPressed fourni : icône d\'aide affichée et tap déclenche le callback',
    (tester) async {
      var pressed = false;
      await tester.pumpWidget(_host(TotalValueCard(
        totalValue: 5000.00,
        periodChange: 150.50,
        periodChangePercent: 9.07,
        selectedPeriodLabel: 'Max',
        title: 'Total',
        onInfoPressed: () => pressed = true,
      )));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.info_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();

      expect(pressed, isTrue);
    },
  );
}

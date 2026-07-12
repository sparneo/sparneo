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
}

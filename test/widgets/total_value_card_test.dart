// test/widgets/total_value_card_test.dart
//
// Depuis le 29/07, TotalValueCard ne porte plus QUE les chiffres indépendants
// de tout réglage d'écran : la valeur totale et le GAIN TOTAL depuis l'origine.
// La performance sur la période affichée (Modified Dietz en mode réel), qui
// dépend du sélecteur de période ET du sélecteur de mode, a migré au contact
// du graphique — ses tests vivent désormais dans period_gain_line_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/widgets/total_value_card.dart';

// TotalValueCard utilise AppLocalizations : on configure les delegates pour
// éviter le null-check en test.
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
      title: 'Valeur totale',
    )));
    await tester.pumpAndSettle();

    // Format FR : « 12 345,67 € » (espaces insécables — \s les matche).
    expect(find.textContaining(RegExp(r'12\s345,67\s€')), findsOneWidget);
    expect(find.text('Valeur totale'), findsOneWidget);
  });

  testWidgets('sans gainAmount : aucune ligne de gain', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 1000.00,
      title: 'Total',
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('Gains totaux'), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsNothing);
  });

  testWidgets('gain positif : montant signé et pourcentage affichés', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 5000.00,
      title: 'Total',
      gainAmount: 618.37,
      gainPercent: 19.8,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'\+618,37\s€')), findsOneWidget);
    expect(find.textContaining(RegExp(r'\+19,8\s%')), findsOneWidget);
  });

  testWidgets('gain négatif : montant signé négatif', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 4000.00,
      title: 'Total',
      gainAmount: -250.10,
      gainPercent: -5.9,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'-250,10\s€')), findsOneWidget);
    expect(find.textContaining(RegExp(r'-5,9\s%')), findsOneWidget);
  });

  testWidgets(
    'gainPercent null : le montant seul est affiché, sans « — » parasite',
    (tester) async {
      await tester.pumpWidget(_host(const TotalValueCard(
        totalValue: 1000.00,
        title: 'Total',
        gainAmount: 50.0,
      )));
      await tester.pumpAndSettle();

      // l10n.chartRealTotalGainAmountOnly : pas de placeholder de pourcentage
      // (capital non significatif ⇒ on n'invente pas de %).
      expect(find.textContaining(RegExp(r'\+50,00\s€')), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
    },
  );

  testWidgets('onGainInfoPressed null (défaut) : aucune icône d\'aide', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 5000.00,
      title: 'Total',
      gainAmount: 150.50,
      gainPercent: 9.07,
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.info_outline), findsNothing);
  });

  testWidgets(
    'onGainInfoPressed fourni : icône d\'aide affichée et tap déclenche le '
    'callback',
    (tester) async {
      var pressed = false;
      await tester.pumpWidget(_host(TotalValueCard(
        totalValue: 5000.00,
        title: 'Total',
        gainAmount: 150.50,
        gainPercent: 9.07,
        onGainInfoPressed: () => pressed = true,
      )));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.info_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();

      expect(pressed, isTrue);
    },
  );

  group('puce « partiel » (gainExcludedCount)', () {
    testWidgets(
      'gainExcludedCount à 0 (défaut) : aucune puce, rendu inchangé',
      (tester) async {
        await tester.pumpWidget(_host(const TotalValueCard(
          totalValue: 5000.00,
          title: 'Total',
          gainAmount: 150.50,
          gainPercent: 9.07,
        )));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.chartPartialGainBadgeLabel), findsNothing);
      },
    );

    testWidgets(
      'gainExcludedCount > 0 : la puce « partiel » est affichée à côté du '
      'gain',
      (tester) async {
        await tester.pumpWidget(_host(const TotalValueCard(
          totalValue: 5000.00,
          title: 'Total',
          gainAmount: 150.50,
          gainPercent: 9.07,
          gainExcludedCount: 2,
        )));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.chartPartialGainBadgeLabel), findsOneWidget);
      },
    );

    testWidgets(
      'gainExcludedCount > 0 mais onGainInfoPressed null : la puce reste '
      'affichée (elle ne dépend PAS de l\'icône d\'aide — c\'est le point '
      'non négociable du correctif : la réserve ne doit jamais exister '
      'uniquement derrière la popup)',
      (tester) async {
        await tester.pumpWidget(_host(const TotalValueCard(
          totalValue: 5000.00,
          title: 'Total',
          gainAmount: 150.50,
          gainExcludedCount: 1,
        )));
        await tester.pumpAndSettle();

        final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
        expect(find.text(l10n.chartPartialGainBadgeLabel), findsOneWidget);
        expect(find.byIcon(Icons.info_outline), findsNothing);
      },
    );
  });

  testWidgets('aucun overflow sur largeur réduite', (tester) async {
    await tester.pumpWidget(_host(const TotalValueCard(
      totalValue: 999999.99,
      title: 'Valeur totale du portefeuille',
      gainAmount: -123456.78,
      gainPercent: -1234567.89,
    )));
    await tester.pumpAndSettle();

    // Aucune exception FlutterError (dont RenderFlex overflowed) : maxLines: 2
    // absorbe la ligne de gain la plus longue possible.
    expect(tester.takeException(), isNull);
  });
}

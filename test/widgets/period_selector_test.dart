// test/widgets/period_selector_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';
import 'package:portfolio_tracker/widgets/charts/period_selector.dart';

// Locale fixée en FR : on configure les delegates pour éviter le null-check
// en test (AppLocalizations.of(context)! sinon en échec sans delegates).
Widget _host(ChartPeriod selected, ValueChanged<ChartPeriod> onSelected) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: PeriodSelector(
            selectedPeriod: selected,
            onSelected: onSelected,
          ),
        ),
      ),
    );

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('fr'));
  });

  testWidgets('affiche les labels localisés des périodes visibles',
      (tester) async {
    await tester.pumpWidget(_host(ChartPeriod.month1, (_) {}));
    await tester.pumpAndSettle();

    for (final period in visibleChartPeriods) {
      expect(find.text(period.localizedLabel(l10n)), findsOneWidget);
    }

    // Les périodes hors du sous-ensemble visible ne sont pas rendues.
    final hidden = ChartPeriod.values
        .where((p) => !visibleChartPeriods.contains(p));
    for (final period in hidden) {
      expect(find.text(period.localizedLabel(l10n)), findsNothing);
    }
  });

  testWidgets('la période sélectionnée est marquée selected', (tester) async {
    // month1 fait partie du sous-ensemble visible.
    await tester.pumpWidget(_host(ChartPeriod.month1, (_) {}));
    await tester.pumpAndSettle();

    // On cherche le ChoiceChip correspondant à la période active
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
    final selectedChips =
        chips.where((c) => c.selected).map((c) => (c.label as Text).data);
    expect(selectedChips, contains(ChartPeriod.month1.localizedLabel(l10n)));
  });

  testWidgets('tap sur une période appelle onSelected', (tester) async {
    ChartPeriod? tapped;
    await tester.pumpWidget(
        _host(ChartPeriod.month1, (p) => tapped = p));
    await tester.pumpAndSettle();

    await tester.tap(find.text(ChartPeriod.year1.localizedLabel(l10n)));
    expect(tapped, ChartPeriod.year1);
  });

  testWidgets('aucun overflow avec une largeur réduite', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: SizedBox(
          width: 200, // contrainte étroite → scroll horizontal
          child: PeriodSelector(
            selectedPeriod: ChartPeriod.month1,
            onSelected: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('height fourni encapsule dans un SizedBox', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: PeriodSelector(
            selectedPeriod: ChartPeriod.month1,
            onSelected: (_) {},
            height: 32,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Le SizedBox de hauteur 32 est présent
    final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
    expect(sizedBoxes.any((b) => b.height == 32), isTrue);
  });
}

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/widgets/allocation_pie_chart.dart';
import 'package:portfolio_tracker/widgets/indicator.dart';

Widget _host(List<AllocationSlice> slices) => MaterialApp(
      home: Scaffold(
        // Largeur/hauteur réalistes d'un téléphone pour exposer un éventuel overflow.
        body: Center(
          child: SizedBox(
            width: 360,
            child: AllocationPieChart(
              slices: slices,
              othersLabel: 'Autres',
              noDataLabel: 'Aucune donnée',
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('many slices render without overflow and group into "Autres"',
      (tester) async {
    final slices = List.generate(
      20,
      // Libellés longs (cas réel des pièces) pour exposer un débordement latéral.
      (i) => AllocationSlice('Napoléon 20 Francs Coq lot $i', (20 - i).toDouble()),
    );

    await tester.pumpWidget(_host(slices));
    await tester.pumpAndSettle();

    // Le bug d'origine produisait un RenderFlex overflow (exception capturée).
    expect(tester.takeException(), isNull);

    // Les petites parts sont regroupées : la légende reste bornée (≤ maxSlices).
    expect(find.textContaining('Autres'), findsOneWidget);
  });

  testWidgets('group is centered (pie not glued to the left edge)', (tester) async {
    // Libellés courts : la légende doit se réduire à son contenu, donc le
    // groupe (camembert + légende) est plus étroit que l'espace dispo et centré.
    final slices = [
      const AllocationSlice('Or', 16),
      const AllocationSlice('Argent', 14),
      const AllocationSlice('Platine', 13),
    ];

    await tester.pumpWidget(_host(slices));
    await tester.pumpAndSettle();

    final chartBox = tester.getRect(find.byType(AllocationPieChart));
    final pieBox = tester.getRect(find.byType(PieChart));
    final leftMargin = pieBox.left - chartBox.left;
    // Bord droit du groupe = le libellé le plus large de la légende.
    final legendRight = find
        .byType(Indicator)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)).right)
        .reduce((a, b) => a > b ? a : b);
    final rightMargin = chartBox.right - legendRight;

    // Le camembert a une vraie marge à gauche (pas collé au bord)…
    expect(leftMargin, greaterThan(20),
        reason: 'pie should be centered, not glued to the left edge');
    // …et le groupe est globalement centré (marges gauche/droite comparables).
    expect((leftMargin - rightMargin).abs(), lessThan(40),
        reason: 'left/right margins should be roughly symmetric');
  });

  testWidgets('very long labels do not push the pie off-screen (left)',
      (tester) async {
    final slices = [
      const AllocationSlice(
          'Pièce or commémorative édition limitée 2024 très longue', 60),
      const AllocationSlice('Autre pièce au nom également interminable', 40),
    ];

    await tester.pumpWidget(_host(slices));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // Le camembert ne doit jamais sortir par la gauche (marge >= 0).
    final chartBox = tester.getRect(find.byType(AllocationPieChart));
    final pieBox = tester.getRect(find.byType(PieChart));
    expect(pieBox.left, greaterThanOrEqualTo(chartBox.left - 0.5),
        reason: 'pie must not overflow off the left edge');
    // Le groupe reste dans la largeur disponible.
    expect(pieBox.left, greaterThanOrEqualTo(chartBox.left));
  });

  testWidgets('few slices show each label, no "Autres" bucket', (tester) async {
    final slices = [
      const AllocationSlice('Or', 700),
      const AllocationSlice('Actions', 300),
    ];

    await tester.pumpWidget(_host(slices));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Or'), findsOneWidget);
    expect(find.textContaining('Autres'), findsNothing);
  });

  testWidgets('empty / zero total shows the no-data label', (tester) async {
    await tester.pumpWidget(_host([const AllocationSlice('x', 0)]));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Aucune donnée'), findsOneWidget);
  });
}

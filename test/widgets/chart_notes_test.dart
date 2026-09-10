// test/widgets/chart_notes_test.dart
//
// Bloc de notes sous le graphe — la partie que ce lot a rendue conditionnelle
// à plusieurs entrées à la fois : la liste NOMMÉE des positions héritées (sa
// troncature, son conseil d'usage) et le choix entre les deux formulations de
// l'avertissement de couverture. Ces branches ne dépendent d'aucun contrôleur :
// on les monte ici directement, plutôt que de les atteindre à travers une vue
// entière où il faudrait fabriquer un patrimoine pour chaque cas.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/widgets/charts/chart_notes.dart';
import 'package:portfolio_tracker/widgets/charts/inline_links_caption.dart';

Future<AppLocalizations> _fr() =>
    AppLocalizations.delegate.load(const Locale('fr'));

Future<void> _pump(
  WidgetTester tester, {
  required bool useRealCurve,
  int realExcludedLegacyCount = 0,
  int realCurveApproxSymbolsCount = 0,
  double? realCurveCoverage,
  bool autoFallbackToPositions = false,
  List<InlineLinkSpec> links = const [],
  String? hint,
  bool suppressCoverageNotes = false,
  bool realCurveAvailable = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: ChartNotes(
          selectedPeriod: ChartPeriod.month1,
          useRealCurve: useRealCurve,
          periodGainAmount: 12.0,
          periodGainPercent: 1.0,
          realExcludedLegacyCount: realExcludedLegacyCount,
          realCurveApproxSymbolsCount: realCurveApproxSymbolsCount,
          realCurveCoverage: realCurveCoverage,
          autoFallbackToPositions: autoFallbackToPositions,
          realExcludedLegacyLinks: links,
          realExcludedLegacyHint: hint,
          suppressCoverageNotes: suppressCoverageNotes,
          realCurveAvailable: realCurveAvailable,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<InlineLinkSpec> _links(int n) => [
      for (var i = 0; i < n; i++)
        InlineLinkSpec(label: 'L$i', onTap: () {}),
    ];

void main() {
  group('ChartNotes — liste nommée des positions héritées', () {
    testWidgets('aucun nom fourni : repli sur la caption purement chiffrée',
        (tester) async {
      await _pump(tester, useRealCurve: true, realExcludedLegacyCount: 2);

      final l10n = await _fr();
      expect(find.text(l10n.chartRealExcludedLegacyCaption(2)), findsOneWidget);
      expect(find.byType(InlineLinksCaption), findsNothing);
    });

    testWidgets(
        'noms fournis : caption cliquable, conseil d\'usage en suffixe, et '
        'AUCUNE trace de l\'ancienne phrase chiffrée', (tester) async {
      await _pump(
        tester,
        useRealCurve: true,
        realExcludedLegacyCount: 2,
        links: _links(2),
        hint: 'Touchez.',
      );

      final l10n = await _fr();
      final caption = tester.widget<InlineLinksCaption>(
        find.byType(InlineLinksCaption),
      );
      expect(caption.prefix, l10n.chartRealExcludedLegacyNamedPrefix(2));
      expect(caption.links.map((l) => l.label), ['L0', 'L1']);
      expect(caption.suffix, 'Touchez.');
      expect(find.text(l10n.chartRealExcludedLegacyCaption(2)), findsNothing);
    });

    testWidgets(
        'au-delà de trois entrées : troncature à trois + « et N autres », pour '
        'ne pas transformer une caption en inventaire', (tester) async {
      await _pump(
        tester,
        useRealCurve: true,
        realExcludedLegacyCount: 5,
        links: _links(5),
      );

      final l10n = await _fr();
      final caption = tester.widget<InlineLinksCaption>(
        find.byType(InlineLinksCaption),
      );
      expect(caption.links, hasLength(ChartNotes.kMaxNamedLegacyLinks));
      expect(caption.links.map((l) => l.label), ['L0', 'L1', 'L2']);
      // Le compteur du préfixe reste le TOTAL (5), jamais le nombre affiché :
      // c'est le chiffre honnête, la troncature ne concerne que la place.
      expect(caption.prefix, l10n.chartRealExcludedLegacyNamedPrefix(5));
      expect(caption.suffix, '${l10n.chartRealExcludedLegacyMore(2)}.');
    });

    testWidgets(
        'aucune position exclue : ni caption chiffrée ni liste, même avec des '
        'liens passés par erreur', (tester) async {
      await _pump(
        tester,
        useRealCurve: true,
        realExcludedLegacyCount: 0,
        links: _links(2),
      );
      expect(find.byType(InlineLinksCaption), findsNothing);
    });
  });

  group('ChartNotes — les deux formulations de l\'avertissement de couverture',
      () {
    testWidgets(
        'cause DÉJÀ nommée au-dessus (positions héritées) : variante courte, '
        'sans répéter ce que la liste vient d\'énumérer', (tester) async {
      await _pump(
        tester,
        useRealCurve: true,
        realExcludedLegacyCount: 1,
        links: _links(1),
        realCurveCoverage: 0.43,
      );

      final l10n = await _fr();
      expect(find.text(l10n.chartRealCoverageWarningShort(43)), findsOneWidget);
      expect(find.text(l10n.chartRealCoverageWarning(43)), findsNothing);
    });

    testWidgets(
        'cause NON nommée (couverture basse sans position héritée ni valeur '
        'approchée) : variante complète — sinon un pourcentage nu, sans le '
        'moindre indice', (tester) async {
      await _pump(tester, useRealCurve: true, realCurveCoverage: 0.43);

      final l10n = await _fr();
      expect(find.text(l10n.chartRealCoverageWarning(43)), findsOneWidget);
      expect(find.text(l10n.chartRealCoverageWarningShort(43)), findsNothing);
    });

    testWidgets(
        'valeurs approchées seules : elles nomment déjà la cause, variante '
        'courte', (tester) async {
      await _pump(
        tester,
        useRealCurve: true,
        realCurveApproxSymbolsCount: 2,
        realCurveCoverage: 0.43,
      );

      final l10n = await _fr();
      expect(find.text(l10n.chartRealCoverageWarningShort(43)), findsOneWidget);
    });

    testWidgets('couverture suffisante : aucun avertissement', (tester) async {
      await _pump(tester, useRealCurve: true, realCurveCoverage: 0.95);

      final l10n = await _fr();
      expect(find.text(l10n.chartRealCoverageWarning(95)), findsNothing);
      expect(find.text(l10n.chartRealCoverageWarningShort(95)), findsNothing);
    });
  });

  group('ChartNotes — repli automatique sur « Vos positions »', () {
    testWidgets(
        'la liste nommée est rendue AVANT la note de repli : on dit ce qui '
        'manque, puis seulement pourquoi le mode a changé', (tester) async {
      await _pump(
        tester,
        useRealCurve: false,
        autoFallbackToPositions: true,
        realExcludedLegacyCount: 1,
        links: _links(1),
        realCurveCoverage: 0.43,
      );

      final l10n = await _fr();
      expect(find.byType(InlineLinksCaption), findsOneWidget);
      expect(
        find.text(l10n.chartRealCoverageFallbackCaption(43)),
        findsOneWidget,
      );

      // Ordre de rendu : la liste précède la note de repli dans l'arbre.
      final captionY = tester
          .getTopLeft(find.byType(InlineLinksCaption))
          .dy;
      final fallbackY = tester
          .getTopLeft(find.text(l10n.chartRealCoverageFallbackCaption(43)))
          .dy;
      expect(captionY, lessThan(fallbackY));
    });

    testWidgets(
        'mode 1 CHOISI par l\'utilisateur (pas de repli automatique) : la '
        'liste nommée reste affichée (positions héritées à déclarer), mais '
        'pas la note de repli — qui ne concerne QUE la bascule automatique',
        (tester) async {
      await _pump(
        tester,
        useRealCurve: false,
        realExcludedLegacyCount: 1,
        links: _links(1),
        realCurveCoverage: 0.43,
      );

      final l10n = await _fr();
      final caption = tester.widget<InlineLinksCaption>(
        find.byType(InlineLinksCaption),
      );
      // Courbe réelle DISPONIBLE (realCurveAvailable par défaut) mais mode 1
      // affiché : « cette courbe » désignerait à tort l'évolution réelle
      // absente de l'écran — préfixe qui la NOMME plutôt que de la désigner.
      expect(caption.prefix, l10n.chartRealExcludedLegacyOtherModePrefix(1));
      expect(
        find.text(l10n.chartRealCoverageFallbackCaption(43)),
        findsNothing,
      );
    });
  });

  group('ChartNotes — mode 1 sans AUCUNE courbe réelle (realCurveAvailable)',
      () {
    testWidgets(
        'compte/patrimoine 100 % hérité : la liste nommée est rendue avec le '
        'préfixe DÉDIÉ (« pas d\'évolution réelle à reconstruire »), jamais '
        'celui qui prétend l\'exclure d\'une courbe qui n\'existe pas',
        (tester) async {
      await _pump(
        tester,
        useRealCurve: false,
        realExcludedLegacyCount: 1,
        links: _links(1),
        realCurveAvailable: false,
      );

      final l10n = await _fr();
      final caption = tester.widget<InlineLinksCaption>(
        find.byType(InlineLinksCaption),
      );
      expect(caption.prefix, l10n.chartRealExcludedLegacyNoCurvePrefix(1));
      expect(
        caption.prefix,
        isNot(l10n.chartRealExcludedLegacyNamedPrefix(1)),
      );
    });

    testWidgets('variante plurielle (plusieurs positions)', (tester) async {
      await _pump(
        tester,
        useRealCurve: false,
        realExcludedLegacyCount: 3,
        links: _links(3),
        realCurveAvailable: false,
      );

      final l10n = await _fr();
      final caption = tester.widget<InlineLinksCaption>(
        find.byType(InlineLinksCaption),
      );
      expect(caption.prefix, l10n.chartRealExcludedLegacyNoCurvePrefix(3));
    });

    testWidgets(
        'realCurveAvailable vrai (défaut) avec mode 1 affiché : ni le '
        'préfixe "cette courbe" (faux : la courbe à l\'écran les INCLUT) ni '
        'le préfixe "pas d\'évolution réelle" (faux : elle existe) — la '
        'variante qui nomme explicitement l\'évolution réelle', (tester) async {
      await _pump(
        tester,
        useRealCurve: false,
        realExcludedLegacyCount: 1,
        links: _links(1),
      );

      final l10n = await _fr();
      final caption = tester.widget<InlineLinksCaption>(
        find.byType(InlineLinksCaption),
      );
      expect(caption.prefix, l10n.chartRealExcludedLegacyOtherModePrefix(1));
      expect(caption.prefix, isNot(l10n.chartRealExcludedLegacyNamedPrefix(1)));
      expect(
        caption.prefix,
        isNot(l10n.chartRealExcludedLegacyNoCurvePrefix(1)),
      );
    });
  });

  testWidgets(
    'suppressCoverageNotes (rechargement d\'historique en cours) : liste et '
    'notes de couverture masquées, le gain de période reste',
    (tester) async {
      await _pump(
        tester,
        useRealCurve: true,
        realExcludedLegacyCount: 2,
        links: _links(2),
        realCurveApproxSymbolsCount: 1,
        realCurveCoverage: 0.43,
        suppressCoverageNotes: true,
      );

      final l10n = await _fr();
      expect(find.byType(InlineLinksCaption), findsNothing);
      expect(find.text(l10n.chartRealExcludedLegacyCaption(2)), findsNothing);
      expect(find.text(l10n.chartRealCoverageWarningShort(43)), findsNothing);
      expect(find.text(l10n.chartRealCoverageWarning(43)), findsNothing);
      // L'avertissement de valeurs approchées, lui, ne compare rien à la
      // valorisation courante : il n'a aucune raison de clignoter, il reste.
      expect(find.text(l10n.chartApproxValuesWarning(1)), findsOneWidget);
    },
  );
}

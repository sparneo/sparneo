// La carte de position porte DEUX chiffres de variation qui répondent à deux
// questions différentes : la plus-value latente (depuis le PRU) et la variation
// sur la période sélectionnée (mouvement du cours sur la fenêtre). Avant ce
// lot, la PV masquait purement et simplement la seconde dès qu'un PRU existait.
//
// Non-régression gardée ici : les deux coexistent, chacune avec SON signe et SA
// couleur, la période toujours préfixée du libellé qui la rend attribuable.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/widgets/position_card.dart';

Position _position({double? averageBuyPrice}) => Position(
      accountId: 'acc_1',
      asset: Asset(
        symbol: 'CW8',
        name: 'Amundi MSCI World',
        type: AssetType.etf,
        currency: 'EUR',
      ),
      quantity: '100',
      averageBuyPrice: averageBuyPrice,
    );

Future<void> _pump(
  WidgetTester tester, {
  required Position position,
  required double currentPrice,
  double? periodChangePercent,
  String? periodLabel,
  double width = 400,
}) {
  return tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('fr'),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: PositionCard(
            position: position,
            currentPrice: currentPrice,
            periodChangePercent: periodChangePercent,
            periodLabel: periodLabel,
          ),
        ),
      ),
    ),
  ));
}

/// Spans colorés du bloc de variation (le `Text.rich`), aplatis en couples
/// (texte, couleur) — c'est la seule façon de vérifier qu'un chiffre porte bien
/// SA couleur et non celle de son voisin.
List<(String, Color?)> _changeSpans(WidgetTester tester) {
  final richTexts = tester.widgetList<Text>(find.byType(Text)).where(
        (t) => t.textSpan != null,
      );
  final out = <(String, Color?)>[];
  for (final t in richTexts) {
    final root = t.textSpan! as TextSpan;
    for (final child in root.children ?? const <InlineSpan>[]) {
      final span = child as TextSpan;
      out.add((span.text ?? '', span.style?.color));
    }
  }
  return out;
}

void main() {
  testWidgets(
      'PV et variation de période coexistent, chacune avec la couleur de SON '
      'signe (PV en hausse + période en baisse)', (tester) async {
    await _pump(
      tester,
      // PRU 100 → cours 112 : PV +12 %.
      position: _position(averageBuyPrice: 100),
      currentPrice: 112,
      periodChangePercent: -1.4,
      periodLabel: '1M',
    );

    final context = tester.element(find.byType(PositionCard));
    final gainColor = AppColors.gainLoss(context, true);
    final lossColor = AppColors.gainLoss(context, false);
    expect(gainColor, isNot(lossColor), reason: 'thème sans distinction');

    final spans = _changeSpans(tester);
    final pv = spans.firstWhere((s) => s.$1.contains('PV'));
    final period = spans.firstWhere((s) => s.$1.startsWith('1M'));

    // Espace INSÉCABLE avant le %, comme partout dans l'app (cf.
    // `Formatters.formatPercentFr`) : le littéral doit la porter aussi.
    expect(pv.$1, contains('+12,0\u00A0%'));
    expect(pv.$2, gainColor);
    expect(period.$1, contains('-1,4\u00A0%'));
    expect(period.$2, lossColor,
        reason: 'la période baisse : sa couleur ne doit pas suivre la PV');
  });

  testWidgets(
      'sans PRU, seule la variation de période s\'affiche (et reste préfixée)',
      (tester) async {
    await _pump(
      tester,
      position: _position(),
      currentPrice: 112,
      periodChangePercent: 2.5,
      periodLabel: 'Max',
    );

    final spans = _changeSpans(tester);
    expect(spans.where((s) => s.$1.contains('PV')), isEmpty);
    expect(spans.any((s) => s.$1 == 'Max +2,5\u00A0%'), isTrue,
        reason: 'un pourcentage nu serait inattribuable');
  });

  testWidgets(
      'sans libellé de période, la carte n\'affiche QUE la PV (appelant qui ne '
      'gère pas de période)', (tester) async {
    await _pump(
      tester,
      position: _position(averageBuyPrice: 100),
      currentPrice: 112,
      periodChangePercent: -1.4,
    );

    final spans = _changeSpans(tester);
    expect(spans.any((s) => s.$1.contains('PV')), isTrue);
    expect(spans.where((s) => s.$1.contains('1,4')), isEmpty);
  });

  testWidgets('les deux chiffres ne débordent pas sur une carte étroite',
      (tester) async {
    await _pump(
      tester,
      position: _position(averageBuyPrice: 100),
      currentPrice: 112,
      periodChangePercent: -1.4,
      periodLabel: '1M',
      width: 280,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

// Non-régression : le prix unitaire de la tuile « Mes positions » doit
// s'afficher SANS PERTE (quantité × prix affiché = valeur affichée), et ne
// doit pas faire déborder la carte quand le prix s'allonge.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/widgets/position_card.dart';

Position _position({required String quantity, String currency = 'EUR'}) => Position(
      accountId: 'acc_1',
      asset: Asset(
        symbol: 'CW8',
        name: 'Amundi MSCI World',
        type: AssetType.etf,
        currency: currency,
      ),
      quantity: quantity,
    );

Future<void> _pump(
  WidgetTester tester, {
  required Position position,
  required double currentPrice,
  double width = 400,
}) {
  return tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: PositionCard(
            position: position,
            currentPrice: currentPrice,
          ),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('un prix à 3 décimales s\'affiche sans perte (33,495 €)', (tester) async {
    await _pump(
      tester,
      position: _position(quantity: '522'),
      currentPrice: 33.495,
    );

    expect(find.textContaining('33,495'), findsOneWidget);
  });

  testWidgets('un prix rond garde 2 décimales (pas 33,0600 €)', (tester) async {
    await _pump(
      tester,
      position: _position(quantity: '1955'),
      currentPrice: 33.06,
    );

    // formatMoney sépare le symbole par une espace insécable (pas une
    // espace ordinaire) : on ne teste que le nombre, pas le suffixe.
    expect(find.textContaining('33,06'), findsOneWidget);
    expect(find.textContaining('33,0600'), findsNothing);
  });

  testWidgets('la quantité fractionnaire n\'est pas arrondie', (tester) async {
    await _pump(
      tester,
      position: _position(quantity: '0.1234567'),
      currentPrice: 50000.0,
    );

    // La quantité est affichée telle que fournie par le contrôleur (Decimal
    // canonique en amont) : ce widget ne doit ajouter aucun arrondi.
    expect(find.textContaining('0.1234567'), findsOneWidget);
  });

  testWidgets(
      'pas de débordement (RenderFlex overflow) sur largeur réduite avec '
      'prix et quantité longs', (tester) async {
    // Cas plausible le plus long : grosse quantité fractionnaire (crypto,
    // jusqu'à 6 décimales comme ailleurs dans le projet, cf.
    // `_formatCanonicalNumber` de `statement_import_service.dart`) à prix
    // unitaire lui aussi précis à 6 décimales (jeton à faible valeur). Un
    // titre cher ET une grosse quantité en même temps n'est pas réaliste
    // (le total exploserait indépendamment de ce correctif).
    await _pump(
      tester,
      position: _position(quantity: '123456.789012'),
      currentPrice: 0.123456,
      width: 280, // largeur de tuile réduite plausible (mobile étroit)
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}

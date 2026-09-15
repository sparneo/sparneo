// Non-régression : la réserve de design PRU/`-USD` du chantier B16, levée au lot
// 2 (conception interne). Pour un actif CRYPTO résolu à un ticker `<code>-USD`
// (`Asset.ledgerCode` non-null, étage 4 de la cascade/`quoteAliases`), le PRU
// dérivé du journal est TOUJOURS en devise du COMPTE (EUR) — JAMAIS un prix de
// marché natif en USD, contrairement à un titre classique acheté en USD
// (courtier hors crypto, `ledgerCode == null`). Comparer directement ce PRU à
// une cotation live USD SANS convertir cette dernière au préalable produit une
// plus-value latente fausse ; c'est le piège que corrige `PositionCard` (miroir
// du correctif `PositionDetailPage._pruAlreadyInAccountCurrency`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/widgets/position_card.dart';

Position _position({
  required double? averageBuyPrice,
  String? ledgerCode,
  String currency = 'USD',
}) =>
    Position(
      accountId: 'acc_1',
      asset: Asset(
        symbol: ledgerCode != null ? '$ledgerCode-USD' : 'AAPL',
        name: ledgerCode ?? 'AAPL',
        currency: currency,
        ledgerCode: ledgerCode,
      ),
      quantity: '1',
      averageBuyPrice: averageBuyPrice,
    );

Future<void> _pump(
  WidgetTester tester, {
  required Position position,
  required double currentPrice,
  required double usdToEurRate,
}) {
  return tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          child: PositionCard(
            position: position,
            currentPrice: currentPrice,
            usdToEurRate: usdToEurRate,
          ),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets(
      'titre classique USD (ledgerCode null) : PRU natif USD, comparé '
      'directement au cours — comportement HISTORIQUE inchangé (pas de '
      'régression du correctif crypto)', (tester) async {
    await _pump(
      tester,
      position: _position(averageBuyPrice: 100, ledgerCode: null),
      currentPrice: 110,
      // Le taux ne doit PAS influencer un pourcentage dont les deux termes
      // sont dans la MÊME devise (USD/USD) — volontairement extrême (0,5)
      // pour détecter toute régression qui le ferait entrer en jeu.
      usdToEurRate: 0.5,
    );

    // Le préfixe localisé (« PV »/« UG ») dépend de la locale de test — on ne
    // vérifie que le NOMBRE (format FR, indépendant de la locale : cf.
    // `Formatters.formatPercentFr`), seul objet de ce correctif. Espace
    // INSÉCABLE (U+00A0) avant `%`, PAS une espace normale — cf.
    // `formatPercentFr`.
    expect(find.textContaining('+10,0 %'), findsOneWidget);
  });

  testWidgets(
      'actif crypto résolu -USD (ledgerCode non-null) : PRU DÉJÀ en EUR, '
      'seul le cours live est converti avant comparaison', (tester) async {
    await _pump(
      tester,
      // PRU = 50 (déjà EUR, cf. finalizeCryptoExchanges : V_eur/quantité).
      position: _position(averageBuyPrice: 50, ledgerCode: 'BTC'),
      // Cours live natif USD.
      currentPrice: 60,
      usdToEurRate: 0.9,
    );

    // Correct : (60×0,9 − 50) / 50 × 100 = +8,0 %.
    expect(find.textContaining('+8,0 %'), findsOneWidget);
    // AVANT le correctif : (60 − 50) / 50 × 100 = +20,0 % (cours USD brut
    // comparé à un PRU en réalité EUR) — jamais affiché.
    expect(find.textContaining('+20,0 %'), findsNothing);
  });
}

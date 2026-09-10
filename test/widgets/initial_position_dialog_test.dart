// test/widgets/initial_position_dialog_test.dart
//
// Dialogue « Définir la position initiale » — extrait de position_detail_page
// pour servir aussi la note des positions héritées de l'écran compte.
//
// Ce qui est vérifié ici est ce que l'extraction a ajouté : le
// PRÉREMPLISSAGE. Déclarer l'opération d'origine d'une position héritée doit
// REPRODUIRE ce que l'utilisateur détient — quantité ET base de coût déjà
// saisie. Un champ laissé vide, et la reprojection du ledger (qui REMPLACE la
// quantité stockée par la projection du journal) changerait la position au
// lieu de l'expliquer ; un PRU non repris serait purement et simplement perdu,
// le mouvement déclaré devenant la seule source du PRU projeté.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/widgets/initial_position_dialog.dart';

/// Monte le dialogue et renvoie le résultat de sa fermeture.
Future<InitialPositionOutcome?> _showDialogUnderTest(
  WidgetTester tester, {
  String? initialQuantity,
  String? initialUnitPrice,
  String? symbol,
}) async {
  InitialPositionOutcome? outcome;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                outcome = await showDialog<InitialPositionOutcome>(
                  context: context,
                  builder: (_) => InitialPositionDialog(
                    currency: 'EUR',
                    symbol: symbol,
                    initialQuantity: initialQuantity,
                    initialUnitPrice: initialUnitPrice,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return outcome;
}

void main() {
  testWidgets(
    'préremplissage : quantité détenue et PRU connu sont proposés tels quels '
    'et acceptés sans correction',
    (tester) async {
      await _showDialogUnderTest(
        tester,
        symbol: 'BBB',
        initialQuantity: '5',
        initialUnitPrice: '42.0',
      );

      final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
      // Titre nommé : on sait quelle ligne on déclare (le dialogue peut être
      // ouvert depuis la note de l'écran compte, loin de la fiche du titre).
      expect(find.text(l10n.setInitialPositionTitleFor('BBB')), findsOneWidget);
      expect(find.text('5'), findsOneWidget);
      expect(find.text('42.0'), findsOneWidget);

      // Les valeurs préremplies passent les validateurs telles quelles
      // (quantité > 0, PRU numérique) : le dialogue se ferme sans un mot.
      // Ce qui en RESSORT est vérifié par le test suivant.
      await tester.tap(find.text(l10n.validate));
      await tester.pumpAndSettle();
      expect(find.byType(InitialPositionDialog), findsNothing);
    },
  );

  testWidgets(
    'le préremplissage reste ÉDITABLE : la valeur corrigée est celle qui sort',
    (tester) async {
      InitialPositionOutcome? captured;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    captured = await showDialog<InitialPositionOutcome>(
                      context: context,
                      builder: (_) => const InitialPositionDialog(
                        currency: 'EUR',
                        symbol: 'BBB',
                        initialQuantity: '5',
                        initialUnitPrice: '42.0',
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
      // Virgule décimale FR : normalisée en point à la sortie (contrat
      // inchangé depuis la version privée du dialogue).
      await tester.enterText(find.byType(TextFormField).first, '7,5');
      await tester.tap(find.text(l10n.validate));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.quantity, '7.5');
      expect(captured!.unitPrice, '42.0');
      expect(captured!.note, isNull);
    },
  );

  testWidgets(
    'sans préremplissage (fiche position) : champs vides et titre générique',
    (tester) async {
      await _showDialogUnderTest(tester);

      final l10n = await AppLocalizations.delegate.load(const Locale('fr'));
      expect(find.text(l10n.setInitialPositionTitle), findsOneWidget);

      // Quantité vide ⇒ le formulaire refuse la validation (garde d'origine).
      await tester.tap(find.text(l10n.validate));
      await tester.pumpAndSettle();
      expect(find.byType(InitialPositionDialog), findsOneWidget);
      expect(find.text(l10n.invalidQuantity), findsOneWidget);
    },
  );
}

// test/utils/app_snackbar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';

/// Hôte minimal : expose un contexte sous un [ScaffoldMessenger] pour appeler
/// [showAppSnackBar] à la main. Pas de delegates l10n — l'utilitaire ne
/// localise rien, il reçoit un message déjà traduit.
Widget _host(void Function(BuildContext) onReady) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => onReady(context),
        child: const Text('go'),
      ),
    ),
  ),
);

void main() {
  tearDown(resetUndoWindowForTesting);

  testWidgets(
    'un snackbar ordinaire évince le précédent (comportement conservé)',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      await tester.tap(find.text('go'));
      await tester.pump();

      SnackBarClosedReason? reason;
      showAppSnackBar(ctx, 'premier').closed.then((r) => reason = r);
      await tester.pumpAndSettle();
      expect(find.text('premier'), findsOneWidget);

      showAppSnackBar(ctx, 'second');
      await tester.pumpAndSettle();

      // Le premier a bien été masqué au profit du second, immédiatement.
      expect(reason, SnackBarClosedReason.hide);
      expect(find.text('premier'), findsNothing);
      expect(find.text('second'), findsOneWidget);
    },
  );

  testWidgets(
    'MIN-3 : un 2e snackbar n\'écourte pas une fenêtre d\'annulation ouverte',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      await tester.tap(find.text('go'));
      await tester.pump();

      SnackBarClosedReason? reason;
      showAppSnackBar(
        ctx,
        'compte supprimé',
        undoWindow: true,
        action: SnackBarAction(label: 'Annuler', onPressed: () {}),
      ).closed.then((r) => reason = r);
      await tester.pumpAndSettle();
      expect(find.text('compte supprimé'), findsOneWidget);

      // Un message quelconque survient pendant la fenêtre d'annulation.
      showAppSnackBar(ctx, 'cotations mises à jour');
      await tester.pumpAndSettle();

      // Cœur de la régression : la fenêtre reste ouverte ET atteignable — le
      // snackbar de suppression est toujours à l'écran, son action « Annuler »
      // cliquable, et aucun commit différé n'a été déclenché.
      expect(reason, isNull);
      expect(find.text('compte supprimé'), findsOneWidget);
      expect(find.text('Annuler'), findsOneWidget);
      expect(find.text('cotations mises à jour'), findsNothing);

      // À l'expiration : fermeture par timeout (donc commit), puis le message
      // en attente prend la place.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(reason, SnackBarClosedReason.timeout);
      expect(find.text('cotations mises à jour'), findsOneWidget);
    },
  );

  testWidgets('« Annuler » ferme la fenêtre avec reason = action', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(_host((c) => ctx = c));
    await tester.tap(find.text('go'));
    await tester.pump();

    SnackBarClosedReason? reason;
    var undone = false;
    showAppSnackBar(
      ctx,
      'compte supprimé',
      undoWindow: true,
      action: SnackBarAction(label: 'Annuler', onPressed: () => undone = true),
    ).closed.then((r) => reason = r);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();

    expect(undone, isTrue);
    expect(reason, SnackBarClosedReason.action);
  });

  testWidgets(
    'la protection est libérée une fois la fenêtre fermée',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(_host((c) => ctx = c));
      await tester.tap(find.text('go'));
      await tester.pump();

      showAppSnackBar(
        ctx,
        'compte supprimé',
        undoWindow: true,
        action: SnackBarAction(label: 'Annuler', onPressed: () {}),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      // Plus aucune fenêtre ouverte : l'éviction ordinaire reprend, sinon les
      // snackbars s'empileraient pour le reste de la session.
      SnackBarClosedReason? reason;
      showAppSnackBar(ctx, 'premier').closed.then((r) => reason = r);
      await tester.pumpAndSettle();
      showAppSnackBar(ctx, 'second');
      await tester.pumpAndSettle();

      expect(reason, SnackBarClosedReason.hide);
      expect(find.text('second'), findsOneWidget);
    },
  );
}

// lib/widgets/common/help_dialog.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';

/// Popup d'aide générique persistante — [AlertDialog] + [SelectableText] +
/// bouton [l10n.close], calquée sur `_showSymbolHelp` (account_view.dart).
///
/// Motif à préférer à un [Tooltip] pour tout texte pédagogique de plusieurs
/// paragraphes : sur mobile un Tooltip ne s'ouvre qu'en appui LONG (non
/// devinable) et se referme trop vite pour être lu. L'appelant fournit son
/// propre déclencheur (typiquement une icône ⓘ cliquable) qui invoque cette
/// fonction ; `context` doit encore être monté au moment de l'appel (à
/// vérifier côté appelant si l'action peut survenir après un `await`).
void showHelpDialog(
  BuildContext context, {
  required String title,
  required String body,
}) {
  final l10n = AppLocalizations.of(context)!;
  showDialog(
    context: context,
    builder: (helpContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(body)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(helpContext),
          child: Text(l10n.close),
        ),
      ],
    ),
  );
}

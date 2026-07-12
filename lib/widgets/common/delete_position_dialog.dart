// lib/widgets/common/delete_position_dialog.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

/// Confirmation « D2 » de suppression d'une position, partagée par les deux
/// points d'entrée : le balayage (Dismissible dans AccountView) et l'action
/// explicite de la barre de la page de détail (PositionDetailPage).
///
/// Récupère d'abord le nombre de mouvements du journal pour avertir que la
/// suppression de la position efface aussi ces N mouvements (avertissement
/// distinct de la confirmation simple quand le journal est vide). Retourne
/// `true` si l'utilisateur confirme, `false` sinon (annulation ou démontage).
Future<bool> confirmDeletePosition({
  required BuildContext context,
  required TransactionStorage txStorage,
  required String accountId,
  required String symbol,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final journalCount = (await txStorage.getBySymbol(accountId, symbol)).length;
  if (!context.mounted) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.deletePositionTitle),
      content: Text(
        journalCount > 0
            ? l10n.deletePositionWithJournalConfirm(journalCount)
            : l10n.deletePositionConfirm(symbol),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          child: Text(l10n.delete),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

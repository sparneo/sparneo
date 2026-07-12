// lib/widgets/common/delete_account_dialog.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';

/// Confirmation de suppression d'un compte, partagée par les points d'entrée :
/// le balayage (Dismissible de la liste du patrimoine), l'action de la barre de
/// [AccountView] (comptes d'investissement) et l'action du dialogue d'édition
/// du solde (comptes cash).
///
/// Applique d'abord la garde « dernier compte » ([totalAccountCount] ≤ 1 →
/// avertissement, aucune suppression) ; sinon affiche la confirmation
/// destructrice. Retourne `true` si l'utilisateur confirme, `false` sinon
/// (garde, annulation ou démontage).
Future<bool> confirmDeleteAccount({
  required BuildContext context,
  required String accountName,
  required int totalAccountCount,
}) async {
  final l10n = AppLocalizations.of(context)!;

  if (totalAccountCount <= 1) {
    showAppSnackBar(
      context,
      l10n.cannotDeleteLastAccount,
      type: SnackType.warning,
    );
    return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.deleteAccountTitle),
      content: Text(l10n.deleteAccountConfirm(accountName)),
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

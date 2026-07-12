// lib/widgets/cash_balance_edit_dialog.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';

/// Résultat du dialogue d'édition du solde cash. Un pop `null` (annulation)
/// reste distinct des deux cas ci-dessous.
sealed class CashBalanceEditResult {
  const CashBalanceEditResult();
}

/// L'utilisateur a validé un nouveau solde.
class CashBalanceUpdated extends CashBalanceEditResult {
  final double balance;
  const CashBalanceUpdated(this.balance);
}

/// L'utilisateur a demandé la suppression du compte depuis le dialogue. La
/// confirmation (et la garde « dernier compte ») reste à la charge de
/// l'appelant via `confirmDeleteAccount` — le dialogue n'exprime qu'une
/// intention.
class CashBalanceDeleteRequested extends CashBalanceEditResult {
  const CashBalanceDeleteRequested();
}

class CashBalanceEditDialog extends StatefulWidget {
  final double currentBalance;
  final String currency;

  const CashBalanceEditDialog({
    super.key,
    required this.currentBalance,
    required this.currency,
  });

  @override
  State<CashBalanceEditDialog> createState() => _CashBalanceEditDialogState();
}

class _CashBalanceEditDialogState extends State<CashBalanceEditDialog> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.currentBalance.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitBalance() {
    final amount = double.tryParse(_controller.text);
    if (amount != null) {
      Navigator.pop(context, CashBalanceUpdated(amount));
    } else {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.invalidAmount)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.editBalanceTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            decoration: InputDecoration(
              prefixText: '${widget.currency} ',
              border: const OutlineInputBorder(),
              hintText: '0.00',
            ),
            onSubmitted: (_) => _submitBalance(),
          ),
          const SizedBox(height: 8),
          // Action destructrice secondaire, distincte des boutons Annuler/
          // Valider : la surface d'édition du compte cash tient lieu d'« écran
          // propre » où loger la suppression explicite (le compte cash n'a pas
          // de page de détail). La confirmation vient après, côté appelant.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  Navigator.pop(context, const CashBalanceDeleteRequested()),
              icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              label: Text(
                l10n.deleteAccountTitle,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: _submitBalance,
          child: Text(l10n.validate),
        ),
      ],
    );
  }
}

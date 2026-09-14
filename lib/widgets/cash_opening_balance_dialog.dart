// lib/widgets/cash_opening_balance_dialog.dart
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/utils/formatters.dart';

/// Résultat du dialogue de solde espèces initial : montant SIGNÉ (négatif =
/// découvert déclaré), date et note optionnelle.
class CashOpeningBalanceOutcome {
  final String amount;
  final DateTime date;
  final String? note;

  const CashOpeningBalanceOutcome({
    required this.amount,
    required this.date,
    required this.note,
  });
}

/// Dialogue de saisie / édition d'un `openingBalance` ESPÈCES (solde initial
/// cash) : montant signé, date (souvent antidatée) et note optionnelle.
///
/// EXTRAIT de `account_view.dart` (B18, conception interne) pour être PARTAGÉ
/// entre deux appelants :
///  - CRÉATION (`existing` null) : « Définir le solde espèces initial… » sur
///    un compte titres ([account_view.dart]), formulaire vierge, date par
///    défaut aujourd'hui.
///  - ÉDITION (`existing` non-null) : le journal d'un compte cash
///    ([account_journal_page.dart]) rouvre ce même dialogue sur
///    l'`openingBalance` espèces déjà émis à la création du compte, pour
///    permettre de l'antidater/corriger — montant/date/note pré-remplis,
///    titre adapté ([AppLocalizations.editInitialCashBalanceTitle]).
class CashOpeningBalanceDialog extends StatefulWidget {
  final String currency;

  /// Transaction existante à pré-remplir (montant/date/note) en mode
  /// édition ; `null` en mode création (formulaire vierge).
  final AssetTransaction? existing;

  const CashOpeningBalanceDialog({
    super.key,
    required this.currency,
    this.existing,
  });

  @override
  State<CashOpeningBalanceDialog> createState() =>
      _CashOpeningBalanceDialogState();
}

class _CashOpeningBalanceDialogState extends State<CashOpeningBalanceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _amountCtrl = TextEditingController(text: existing?.amount ?? '');
    _noteCtrl = TextEditingController(text: existing?.note ?? '');
    _date = existing?.date ?? DateTime.now();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1970), // aligné sur le dialogue de création (B18)
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final note = _noteCtrl.text.trim();
    Navigator.of(context).pop(
      CashOpeningBalanceOutcome(
        amount: _amountCtrl.text.trim().replaceAll(',', '.'),
        date: _date,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(
        widget.existing != null
            ? l10n.editInitialCashBalanceTitle
            : l10n.setInitialCashBalanceTitle,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Montant SIGNÉ (négatif = découvert déclaré, cf. design §3).
                TextFormField(
                  controller: _amountCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.cashOpeningBalanceAmountLabel,
                    suffixText:
                        Formatters.formatCurrencySymbol(widget.currency),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim().replaceAll(',', '.');
                    if (Decimal.tryParse(t) == null) return l10n.invalidValue;
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // Date éditable (un solde initial est souvent antidaté).
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.transactionDate,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: const Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(_formatDate(_date)),
                  ),
                ),
                const SizedBox(height: 12),

                // Note optionnelle.
                TextFormField(
                  controller: _noteCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.optionalNoteLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.validate),
        ),
      ],
    );
  }
}

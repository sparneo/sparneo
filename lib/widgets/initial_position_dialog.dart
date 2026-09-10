// lib/widgets/initial_position_dialog.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/formatters.dart';

/// Résultat du dialogue de position initiale : quantité (normalisée), PRU
/// optionnel (null = base de coût inconnue), date et note optionnelle.
@immutable
class InitialPositionOutcome {
  final String quantity;
  final String? unitPrice;
  final DateTime date;
  final String? note;

  const InitialPositionOutcome({
    required this.quantity,
    required this.unitPrice,
    required this.date,
    required this.note,
  });
}

/// Dialogue « Définir la position initiale » — saisie de l'unique mouvement
/// DÉCLARATIF (`openingBalance` TITRE) qui donne son acte de naissance à une
/// position détenue sans journal.
///
/// EXTRAIT de `position_detail_page.dart` (où il était privé) pour servir le
/// second point d'entrée ouvert par ce lot : la note des positions héritées de
/// l'écran COMPTE, où toucher un symbole doit ouvrir CE dialogue et pas un
/// autre. Deux copies auraient divergé sur ce qui compte ici — la sémantique
/// du mouvement émis.
///
/// ⚠️ L'appelant DOIT garantir que le journal du couple (compte, symbole) est
/// VIDE : l'`openingBalance` s'AJOUTE à la projection (cf.
/// `LedgerService.reprojectSymbolWithin`, qui rejoue le journal entier). Sur
/// un journal vide, la quantité déclarée devient exactement la quantité
/// projetée — aucun double comptage ; sur un journal existant, elle s'y
/// empilerait.
class InitialPositionDialog extends StatefulWidget {
  /// Devise de COTATION de l'actif (celle du PRU affiché en suffixe).
  final String currency;

  /// Symbole concerné, affiché dans le titre quand il est fourni. `null` =
  /// dialogue ouvert depuis la fiche de la position elle-même, où le titre
  /// générique suffit (le symbole est déjà partout à l'écran).
  final String? symbol;

  /// Quantité proposée à l'ouverture. PRÉREMPLIE avec la quantité DÉTENUE
  /// quand on répare une position héritée : la déclaration doit reproduire ce
  /// que l'utilisateur détient, sinon la reprojection changerait sa position
  /// au lieu de l'expliquer. Reste ÉDITABLE — c'est bien l'occasion de
  /// corriger un chiffre faux.
  final String? initialQuantity;

  /// PRU proposé à l'ouverture (base de coût déjà connue de la position).
  /// `null` = champ vide, base de coût inconnue.
  final String? initialUnitPrice;

  const InitialPositionDialog({
    super.key,
    required this.currency,
    this.symbol,
    this.initialQuantity,
    this.initialUnitPrice,
  });

  @override
  State<InitialPositionDialog> createState() => _InitialPositionDialogState();
}

class _InitialPositionDialogState extends State<InitialPositionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _pruCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: widget.initialQuantity ?? '');
    _pruCtrl = TextEditingController(text: widget.initialUnitPrice ?? '');
    _noteCtrl = TextEditingController();
    _date = DateTime.now();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _pruCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final pru = _pruCtrl.text.trim();
    final note = _noteCtrl.text.trim();
    Navigator.of(context).pop(
      InitialPositionOutcome(
        quantity: _qtyCtrl.text.trim().replaceAll(',', '.'),
        unitPrice: pru.isEmpty ? null : pru.replaceAll(',', '.'),
        date: _date,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final symbol = widget.symbol;

    return AlertDialog(
      title: Text(
        symbol == null
            ? l10n.setInitialPositionTitle
            : l10n.setInitialPositionTitleFor(symbol),
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
                // Quantité (requise, > 0).
                TextFormField(
                  controller: _qtyCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.quantityLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final t = (v ?? '').trim().replaceAll(',', '.');
                    final n = double.tryParse(t);
                    if (n == null || n <= 0) return l10n.invalidQuantity;
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // PRU OPTIONNEL (seule occasion de poser une base de coût).
                TextFormField(
                  controller: _pruCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.averageBuyPriceLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    helperText: l10n.optionalHint,
                    suffixText:
                        Formatters.formatCurrencySymbol(widget.currency),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null; // PRU facultatif
                    if (double.tryParse(t.replaceAll(',', '.')) == null) {
                      return l10n.invalidValue;
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // Date éditable (une position initiale est souvent antidatée).
                //
                // DÉFAUT À AUJOURD'HUI, VOLONTAIREMENT, et non à une date
                // devinée : la seule date que l'app pourrait inventer serait
                // fausse, et une fausse date d'acquisition contamine la courbe
                // réelle ET le capital investi (l'entrée de titres y est
                // valorisée AU COURS DU JOUR déclaré). Le champ est laissé en
                // évidence, avec sa consigne : c'est à l'utilisateur, seul à
                // la connaître, de la corriger.
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

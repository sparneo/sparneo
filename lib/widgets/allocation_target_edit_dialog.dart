// lib/widgets/allocation_target_edit_dialog.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/logic/allocation.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';

/// Dialog d'édition des cibles d'allocation par type d'actif.
///
/// Retourne un [AllocationTarget] si l'utilisateur valide, null s'il annule.
/// Le bouton « Effacer » retourne [AllocationTarget.empty] via [_clearSentinel].
class AllocationTargetEditDialog extends StatefulWidget {
  final AllocationTarget current;

  /// Pourcentages actuellement détenus par catégorie (facultatif).
  ///
  /// Map keyée comme les cibles : `AssetType.name` pour un type d'actif, plus
  /// [kCashAllocationKey] pour les liquidités. S'il est fourni, une petite
  /// indication « actuel : Y % » est affichée à côté de chaque champ (cash
  /// compris) pour aider l'utilisateur à comparer sa cible à la répartition
  /// réelle. Si null, aucune indication supplémentaire.
  final Map<String, double>? currentPercents;

  const AllocationTargetEditDialog({
    super.key,
    required this.current,
    this.currentPercents,
  });

  @override
  State<AllocationTargetEditDialog> createState() =>
      _AllocationTargetEditDialogState();
}

class _AllocationTargetEditDialogState
    extends State<AllocationTargetEditDialog> {
  // Un contrôleur par catégorie, keyé par String comme les cibles :
  // `AssetType.name` pour chaque type d'actif, plus [kCashAllocationKey] pour
  // les liquidités.
  late final Map<String, TextEditingController> _controllers;
  String? _sumError;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final type in AssetType.values)
        type.name: TextEditingController(
          text: _formatInitial(widget.current.targetFor(type)),
        ),
      // Champ « Liquidités » (cash) : catégorie synthétique de premier rang.
      kCashAllocationKey: TextEditingController(
        text: _formatInitial(widget.current.targetForCash()),
      ),
    };
    // Écoute sur chaque champ pour effacer l'erreur au fil de la saisie et
    // rafraîchir le compteur de somme en temps réel.
    for (final ctrl in _controllers.values) {
      ctrl.addListener(_onFieldChanged);
    }
  }

  @override
  void dispose() {
    for (final ctrl in _controllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  String _formatInitial(double? value) {
    if (value == null || value == 0) return '';
    return _formatPercent(value);
  }

  // Déclenché à chaque frappe : rafraîchit le compteur de somme en direct
  // (affiché dans build()) et efface l'erreur de soumission le cas échéant.
  void _onFieldChanged() {
    setState(() => _sumError = null);
  }

  Map<String, double> _parseValues() {
    final result = <String, double>{};
    for (final entry in _controllers.entries) {
      final raw = entry.value.text.trim().replaceAll(',', '.');
      if (raw.isEmpty) continue;
      final value = double.tryParse(raw);
      // entry.key est déjà la clé cible (AssetType.name ou kCashAllocationKey),
      // donc le cash saisi entre dans la somme et dans la validation ≤ 100 %.
      if (value != null && value > 0) result[entry.key] = value;
    }
    return result;
  }

  /// Somme courante des cibles saisies, robuste aux champs vides/invalides
  /// (un champ vide ou non numérique compte pour 0).
  double get _currentSum =>
      _parseValues().values.fold(0.0, (sum, value) => sum + value);

  /// Formate un pourcentage sans décimale inutile (ex. 40.0 → "40",
  /// 33.5 → "33.5"), en arrondissant les artefacts de virgule flottante.
  String _formatPercent(double value) {
    final rounded = double.parse(value.toStringAsFixed(2));
    return rounded == rounded.truncateToDouble()
        ? rounded.toInt().toString()
        : rounded.toString();
  }

  /// Construit un champ de saisie de cible pour la catégorie [key]
  /// (`AssetType.name` ou [kCashAllocationKey]), avec en regard le pourcentage
  /// actuellement détenu si `currentPercents` le fournit pour cette clé.
  Widget _fieldRow({
    required String key,
    required String label,
    required AppLocalizations l10n,
    required ThemeData theme,
  }) {
    final field = TextField(
      controller: _controllers[key],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        suffixText: '%',
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
    final currentPercent = widget.currentPercents?[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: currentPercent == null
          ? field
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: field),
                const SizedBox(width: 8),
                Text(
                  l10n.allocationTargetCurrent(_formatPercent(currentPercent)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }

  void _submit() {
    final l10n = AppLocalizations.of(context)!;
    final values = _parseValues();
    if (!AllocationCalculator.isTargetSumValid(values)) {
      setState(() => _sumError = l10n.allocationTargetSumError);
      return;
    }
    Navigator.of(context).pop(AllocationTarget(targets: values));
  }

  Future<void> _confirmClear() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.allocationTargetClearConfirmTitle),
        content: Text(l10n.allocationTargetClearConfirmContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      Navigator.of(context).pop(const AllocationTarget.empty());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final sum = _currentSum;
    final sumOverLimit = sum > 100;

    return AlertDialog(
      title: Text(l10n.allocationTargetDialogTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.allocationTargetDialogSubtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              // Compteur de somme en direct : mis à jour à chaque frappe via
              // les listeners posés sur les contrôleurs (cf. _onFieldChanged).
              Text(
                sumOverLimit
                    ? l10n.allocationTargetSumOverflow(_formatPercent(sum))
                    : l10n.allocationTargetSum(_formatPercent(sum)),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: sumOverLimit
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              // Un champ par type d'actif, avec en regard le pourcentage
              // actuellement détenu si `currentPercents` a été fourni.
              ...AssetType.values.map(
                (type) => _fieldRow(
                  key: type.name,
                  label: type.localizedLabel(l10n),
                  l10n: l10n,
                  theme: theme,
                ),
              ),
              // Champ « Liquidités » (cash) EN PLUS des types d'actif : même
              // traitement (somme, validation, « actuel : Y % ») via la clé
              // kCashAllocationKey.
              _fieldRow(
                key: kCashAllocationKey,
                label: l10n.allocationCashCategory,
                l10n: l10n,
                theme: theme,
              ),
              if (_sumError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _sumError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      // Actions dans un Wrap (et non un Row+Spacer) pour placer « Effacer » à
      // gauche et « Annuler / Enregistrer » à droite quand tout tient sur une
      // ligne, MAIS passer à la ligne proprement quand la largeur manque (ex.
      // libellés FR longs sur téléphone 360 dp) au lieu de déborder. Le Row+
      // Spacer forçait une ligne unique et débordait.
      actions: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: _confirmClear,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              child: Text(l10n.reset),
            ),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: Text(l10n.cancel),
                ),
                FilledButton(onPressed: _submit, child: Text(l10n.save)),
              ],
            ),
          ],
        ),
      ],
      actionsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }
}

// lib/widgets/charts/period_selector.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';

/// Sélecteur de période, partagé par WalletView, AccountView et
/// PositionDetailPage.
///
/// Les chips non sélectionnés n'ont pas de fond (style Material 3 par défaut :
/// transparent + contour) ; seul le chip actif est rempli avec `primary`. Cela
/// garantit un rendu identique et correct dans les thèmes clair comme sombre,
/// sans couleur codée en dur.
///
/// - [selectedPeriod] : période actuellement active.
/// - [onSelected]     : callback déclenché quand l'utilisateur change de période.
/// - [height]         : hauteur facultative du SizedBox englobant (32 pour
///                      account_view / position_detail ; null pour wallet_view).
/// - [selectedLabelBold]     : mettre le libellé en gras quand sélectionné.
/// - [unselectedLabelColor]  : surcharge éventuelle de la couleur du texte des
///                             chips non sélectionnés (défaut : onSurfaceVariant).
class PeriodSelector extends StatelessWidget {
  final ChartPeriod selectedPeriod;
  final ValueChanged<ChartPeriod> onSelected;

  // Paramètres de mise en page
  final double? height;
  final bool selectedLabelBold;
  final Color? unselectedLabelColor;
  final EdgeInsets chipPadding;

  const PeriodSelector({
    super.key,
    required this.selectedPeriod,
    required this.onSelected,
    this.height,
    this.selectedLabelBold = false,
    this.unselectedLabelColor,
    this.chipPadding =
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    Widget row = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: visibleChartPeriods.map((period) {
          final isSelected = selectedPeriod == period;

          // Chip sélectionné : toujours onPrimary — en thème sombre, primary
          // est un bleu clair, du blanc dessus contrasterait mal. Chip non
          // sélectionné : la surcharge éventuelle du parent, sinon le token
          // atténué du thème.
          final Color labelColor = isSelected
              ? theme.colorScheme.onPrimary
              : (unselectedLabelColor ?? theme.colorScheme.onSurfaceVariant);

          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: ChoiceChip(
              label: Text(
                period.localizedLabel(l10n),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: (isSelected && selectedLabelBold)
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
              selected: isSelected,
              onSelected: (selected) {
                if (selected) onSelected(period);
              },
              selectedColor: theme.colorScheme.primary,
              labelStyle: TextStyle(
                color: labelColor,
                fontSize: 10,
              ),
              // Pas de fond explicite : les chips non sélectionnés utilisent le
              // défaut Material 3 (transparent + contour), thème-adaptatif.
              padding: chipPadding,
              // Cible tactile ≥ 40dp (padding vertical généreux ci-dessus +
              // tap target Material par défaut, non réduit en shrinkWrap).
            ),
          );
        }).toList(),
      ),
    );

    if (height != null) {
      return SizedBox(height: height, child: row);
    }
    return row;
  }
}

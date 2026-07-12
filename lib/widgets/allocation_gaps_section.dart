// lib/widgets/allocation_gaps_section.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/logic/allocation.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';

/// Section compacte affichant les écarts entre allocation réelle et cibles.
///
/// Toujours rendue : elle porte l'action d'édition des cibles ([onEditTargets],
/// via l'icône ⚙ de l'en-tête), seul point d'entrée pour en définir. Quand
/// [gaps] est vide (aucune cible), elle affiche un état vide invitant à en
/// créer plutôt que de disparaître — sinon l'éditeur deviendrait inaccessible.
class AllocationGapsSection extends StatelessWidget {
  final List<AllocationGap> gaps;

  /// Ouvre l'éditeur de cibles d'allocation (déclenché par l'icône ⚙).
  final VoidCallback onEditTargets;

  const AllocationGapsSection({
    super.key,
    required this.gaps,
    required this.onEditTargets,
  });

  // Couleurs sémantiques selon l'amplitude de l'écart absolu :
  //   |delta| ≤ 2 pts → vert (dans la tolérance)
  //   2 < |delta| ≤ 5 pts → orange (attention, pas de variante dark-safe dédiée)
  //   |delta| > 5 pts → rouge (hors cible)
  Color _deltaColor(BuildContext context, double delta) {
    final abs = delta.abs();
    if (abs <= 2.0) return AppColors.gainLoss(context, true);
    if (abs <= 5.0) return Colors.orange.shade700;
    return AppColors.gainLoss(context, false);
  }

  String _sign(double delta) => delta >= 0 ? '+' : '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    final valueStyle = theme.textTheme.bodySmall;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // En-tête de section : titre + édition des cibles (toujours accessible,
        // y compris quand aucune cible n'est encore définie).
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                l10n.allocationGapsSectionTitle,
                style: theme.textTheme.titleSmall,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.tune, size: 20),
              tooltip: l10n.allocationTargetEditTooltip,
              onPressed: onEditTargets,
            ),
          ],
        ),

        // État vide : aucune cible → invite à en définir (l'éditeur est le ⚙).
        if (gaps.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l10n.allocationTargetsEmptyHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else ...[
          const SizedBox(height: 8),

          // Tableau compact : libellé | réel% | cible% | delta coloré
          Table(
          columnWidths: const {
            0: FlexColumnWidth(2.5), // Type d'actif
            1: FlexColumnWidth(1.5), // Réel
            2: FlexColumnWidth(1.5), // Cible
            3: FlexColumnWidth(1.5), // Écart
          },
          children: [
            // Ligne d'en-tête
            TableRow(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.dividerColor,
                    width: 0.5,
                  ),
                ),
              ),
              children: [
                _headerCell('', labelStyle),
                _headerCell(l10n.allocationGapReal, labelStyle,
                    align: TextAlign.right),
                _headerCell(l10n.allocationGapTarget, labelStyle,
                    align: TextAlign.right),
                _headerCell(l10n.allocationGapDelta, labelStyle,
                    align: TextAlign.right),
              ],
            ),
            // Lignes de données
            ...gaps.map((gap) {
              final deltaColor = _deltaColor(context, gap.delta);
              return TableRow(
                children: [
                  // type == null ⇒ catégorie synthétique « liquidités » (cash).
                  _dataCell(
                    gap.type?.localizedLabel(l10n) ?? l10n.allocationCashCategory,
                    valueStyle,
                  ),
                  _dataCell(
                    '${gap.realPercent.toStringAsFixed(1)}%',
                    valueStyle,
                    align: TextAlign.right,
                  ),
                  _dataCell(
                    '${gap.targetPercent.toStringAsFixed(1)}%',
                    valueStyle,
                    align: TextAlign.right,
                  ),
                  _dataCell(
                    '${_sign(gap.delta)}${gap.delta.toStringAsFixed(1)} pt',
                    valueStyle?.copyWith(
                      color: deltaColor,
                      fontWeight: FontWeight.w600,
                    ),
                    align: TextAlign.right,
                  ),
                ],
              );
            }),
          ],
        ),
        ],
      ],
    );
  }

  Widget _headerCell(String text, TextStyle? style,
      {TextAlign align = TextAlign.left}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Text(text, style: style, textAlign: align),
    );
  }

  Widget _dataCell(String text, TextStyle? style,
      {TextAlign align = TextAlign.left}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
      child: Text(text, style: style, textAlign: align),
    );
  }
}

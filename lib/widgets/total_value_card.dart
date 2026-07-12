// lib/widgets/total_value_card.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/formatters.dart';

/// Carte affichant la valeur totale d'un portefeuille ou d'un compte,
/// avec la variation de période optionnelle.
///
/// Paramètres :
/// - [totalValue]         : valeur totale en EUR.
/// - [periodChange]       : variation absolue (null = pas d'encadré variation).
/// - [periodChangePercent]: variation relative en % (null = "N/D").
/// - [selectedPeriodLabel]: libellé de la période pour le titre de l'encadré.
/// - [titleKey]           : clé de localisation du titre de la carte
///                          (l10n.totalValue ou l10n.totalValueAccount selon la vue).
/// - [titleWidget]        : alternative à [titleKey] si le titre vient du caller.
///
/// La carte est identique entre wallet_view et account_view ; la seule
/// différence est le texte du titre (l10n.totalValue vs l10n.totalValueAccount).
class TotalValueCard extends StatelessWidget {
  final double totalValue;
  final double? periodChange;
  final double? periodChangePercent;
  final String selectedPeriodLabel;
  final String title;

  const TotalValueCard({
    super.key,
    required this.totalValue,
    required this.selectedPeriodLabel,
    required this.title,
    this.periodChange,
    this.periodChangePercent,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isPositive = periodChange != null ? periodChange! >= 0 : true;
    final changeColor = AppColors.gainLoss(context, isPositive);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            Text(
              Formatters.formatEur(totalValue),
              style: Theme.of(
                context,
              ).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (periodChange != null) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPositive ? Icons.trending_up : Icons.trending_down,
                    color: changeColor,
                    size: 15,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '${Formatters.formatEurSigned(periodChange!)} · '
                      '${periodChangePercent != null ? Formatters.formatPercentFr(periodChangePercent!) : l10n.notAvailable} · '
                      '$selectedPeriodLabel',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: changeColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

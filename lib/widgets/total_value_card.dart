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
/// - [percentAnnualized]  : mode réel uniquement (B7 annualisation) — quand
///                          non-null, c'est un SECOND pourcentage (rendement
///                          ANNUALISÉ, fenêtre ≥ 1 an, cf. [HistoryAggregator.
///                          computeRealGains]) affiché ENTRE PARENTHÈSES à la
///                          suite de [periodChangePercent] (le cumulé, jamais
///                          remplacé), via `l10n.chartPercentWithAnnualized`.
///                          `null` par défaut = un seul pourcentage affiché,
///                          comportement STRICTEMENT inchangé en mode
///                          performance (mode 1, jamais annualisé).
/// - [onInfoPressed]      : mode réel uniquement — callback ouvrant une popup
///                          pédagogique (explique Modified Dietz / annualisation
///                          à l'utilisateur) via une icône ⓘ discrète ajoutée
///                          en fin de ligne de variation. `null` par défaut =
///                          pas d'icône, ligne strictement inchangée (un
///                          [Tooltip] ne convenait pas : il ne s'ouvre qu'en
///                          appui long sur mobile et se referme trop vite pour
///                          un texte de plusieurs paragraphes).
///
/// La carte est identique entre wallet_view et account_view ; la seule
/// différence est le texte du titre (l10n.totalValue vs l10n.totalValueAccount).
class TotalValueCard extends StatelessWidget {
  final double totalValue;
  final double? periodChange;
  final double? periodChangePercent;
  final String selectedPeriodLabel;
  final String title;
  final double? percentAnnualized;
  final VoidCallback? onInfoPressed;

  const TotalValueCard({
    super.key,
    required this.totalValue,
    required this.selectedPeriodLabel,
    required this.title,
    this.periodChange,
    this.periodChangePercent,
    this.percentAnnualized,
    this.onInfoPressed,
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
              Builder(
                builder: (_) {
                  final percentText = periodChangePercent != null
                      ? (percentAnnualized != null
                          ? l10n.chartPercentWithAnnualized(
                              Formatters.formatPercentFr(periodChangePercent!),
                              Formatters.formatPercentFr(percentAnnualized!),
                            )
                          : Formatters.formatPercentFr(periodChangePercent!))
                      : l10n.notAvailable;
                  return Row(
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
                          '$percentText · '
                          '$selectedPeriodLabel',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: changeColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // Icône d'aide discrète (ⓘ), affordance cliquable —
                      // remplace un ancien Tooltip (pattern popup, cf.
                      // total_value_card.dart doc de tête). Couleur NEUTRE
                      // (onSurfaceVariant) volontairement : c'est une aide,
                      // pas une donnée gain/perte. InkWell + Padding serré
                      // plutôt qu'IconButton : son padding par défaut (8, cible
                      // 48x48) déséquilibrerait cette ligne compacte à côté de
                      // l'icône trending_up/down (15px) et forcerait l'ellipsis
                      // du texte plus tôt sur écran étroit.
                      if (onInfoPressed != null) ...[
                        const SizedBox(width: 2),
                        Tooltip(
                          message: l10n.chartHelpTooltip,
                          child: InkWell(
                            onTap: onInfoPressed,
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.info_outline,
                                size: 15,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

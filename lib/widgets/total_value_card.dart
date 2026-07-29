// lib/widgets/total_value_card.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/formatters.dart';

/// Carte affichant la valeur totale d'un portefeuille ou d'un compte, et son
/// gain TOTAL depuis l'origine.
///
/// La carte ne porte QUE des chiffres indépendants de tout réglage d'écran
/// (réorganisation du 29/07) : la performance sur la période affichée, elle,
/// dépend du sélecteur de période ET du sélecteur de mode, et vit donc au
/// contact du graphique ([PeriodGainLine]) — l'afficher ici, loin de ce qui
/// la pilote, la faisait passer pour une caractéristique du compte.
///
/// Paramètres :
/// - [totalValue]         : valeur totale en EUR.
/// - [title]              : titre de la carte (l10n.totalValue ou
///                          l10n.totalValueAccount selon la vue).
/// - [gainAmount]/[gainPercent] : gain TOTAL depuis l'origine (base coût,
///                          frais inclus — cf.
///                          [HistoryAggregator.computeRealTotalGain]), affiché
///                          juste sous [totalValue]. C'est la question
///                          prioritaire de l'utilisateur (« ai-je gagné de
///                          l'argent, au final ? »), d'où sa place en premier
///                          plan. `null` = pas de ligne de gain.
/// - [onGainInfoPressed]  : ouvre la popup pédagogique via une icône ⓘ.
///                          `null` = pas d'icône.
/// - [gainExcludedCount]  : nombre de titres EXCLUS de [gainAmount] faute de
///                          base de coût connue (cf. [HistoryAggregator.
///                          computeRealTotalGain], exposé par les
///                          contrôleurs via `realNoBasisSymbols.length`).
///                          `> 0` ⇒ une puce « partiel » discrète s'affiche à
///                          côté du montant, TOUJOURS visible (contrairement
///                          à l'ancien avertissement, elle ne dépend d'aucun
///                          mode de courbe) — la réserve ne doit jamais
///                          exister uniquement derrière la popup d'aide, qui,
///                          elle, en détaille la liste. Défaut à `0` :
///                          préserve le rendu antérieur (aucune puce).
///
/// La carte est identique entre wallet_view et account_view ; la seule
/// différence est le texte du titre.
class TotalValueCard extends StatelessWidget {
  final double totalValue;
  final String title;
  final double? gainAmount;
  final double? gainPercent;
  final VoidCallback? onGainInfoPressed;
  final int gainExcludedCount;

  /// Texte optionnel affiché en 3e ligne, discrète, sous le gain total
  /// (épuration UI, lot 3) — utilisé par AccountView (régime compte-titres)
  /// pour expliciter la part « dont espèces » du total, DÉJÀ incluse dans
  /// [totalValue] (ce n'est pas un montant supplémentaire). Déjà mis en forme
  /// par l'appelant (montant + libellé) : la carte se contente de l'afficher
  /// tel quel. `null` = pas de ligne (défaut, préserve le rendu antérieur —
  /// notamment dans wallet_view).
  final String? cashLine;

  const TotalValueCard({
    super.key,
    required this.totalValue,
    required this.title,
    this.gainAmount,
    this.gainPercent,
    this.onGainInfoPressed,
    this.gainExcludedCount = 0,
    this.cashLine,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

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
            if (gainAmount != null) ...[
              const SizedBox(height: 6),
              Builder(
                builder: (_) {
                  final isPositive = gainAmount! >= 0;
                  final gainColor = AppColors.gainLoss(context, isPositive);
                  final text = gainPercent != null
                      ? l10n.chartRealTotalGain(
                          Formatters.formatEurSigned(gainAmount!),
                          Formatters.formatPercentFr(gainPercent!),
                        )
                      : l10n.chartRealTotalGainAmountOnly(
                          Formatters.formatEurSigned(gainAmount!),
                        );
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: gainColor,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                      // Puce « partiel » — TOUJOURS rendue dès que des titres
                      // sont exclus du calcul, indépendamment de
                      // [onGainInfoPressed] : c'est le marqueur non
                      // négociable (cf. doc de [gainExcludedCount]), la
                      // popup n'en porte que le détail.
                      if (gainExcludedCount > 0) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: l10n.chartNoBasisWarning(
                            gainExcludedCount,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              l10n.chartPartialGainBadgeLabel,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                      // Icône d'aide NEUTRE (onSurfaceVariant) : affordance,
                      // pas une donnée gain/perte.
                      if (onGainInfoPressed != null) ...[
                        const SizedBox(width: 2),
                        Tooltip(
                          message: l10n.chartHelpTooltip,
                          child: InkWell(
                            onTap: onGainInfoPressed,
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.info_outline,
                                size: 16,
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
            if (cashLine != null) ...[
              const SizedBox(height: 4),
              Text(
                cashLine!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

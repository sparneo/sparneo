// lib/widgets/charts/period_gain_line.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';

/// Ligne « performance sur la période affichée », rendue SOUS le graphique.
///
/// POURQUOI ici et non dans [TotalValueCard] (déplacement du 29/07) : ce
/// chiffre dépend de DEUX contrôles qui vivent dans la section graphique — le
/// sélecteur de période (J/1M/…/Max) et le sélecteur de mode (« Vos
/// positions » / « Évolution réelle »). Le montrer en haut de l'écran, loin
/// de ce qui le pilote, laissait croire à une caractéristique du compte au
/// même titre que sa valeur ; collé au graphe, il se lit comme sa légende
/// chiffrée. La carte de valeur ne porte plus que ce qui ne dépend d'aucun
/// réglage : la valeur totale et le gain total depuis l'origine.
///
/// Paramètres :
/// - [amount]           : gain absolu sur la période (null = rien n'est rendu).
/// - [percent]          : `%` associé (null = « — », cf. `l10n.notAvailable`).
/// - [selectedPeriod]   : période affichée (J/1M/…/Max) — sert à la fois de
///                        libellé (mode performance) et de portée temporelle
///                        (mode réel, cf. [netOfContributions]).
/// - [percentAnnualized]: mode réel uniquement (B7) — SECOND `%` (rendement
///                        annualisé, fenêtre ≥ 18 mois) affiché ENTRE
///                        PARENTHÈSES à la suite de [percent], jamais à sa
///                        place. `null` = un seul pourcentage.
/// - [netOfContributions] : épuration UI (29/07) — remplace l'ancienne légende
///                        Dietz (`chartPeriodGainCaption`, affichée AU-DESSUS
///                        de la ligne et redondante avec la légende « Capital
///                        investi » du graphe). `true` (mode réel) préfixe la
///                        ligne par sa PORTÉE — « Sur 5A, hors apports » ou,
///                        période [ChartPeriod.max], « Depuis l'origine, hors
///                        apports » (le gain de période y COÏNCIDE avec le
///                        gain total, invariant testé — ce préfixe l'explique
///                        au lieu de le laisser passer pour un bug) — le
///                        jeton de période passe alors DEVANT au lieu de
///                        traîner derrière. `false` (mode performance,
///                        défaut) : format inchangé, [selectedPeriod] reste en
///                        fin de ligne.
/// - [onInfoPressed]    : ouvre la popup pédagogique via une icône ⓘ discrète.
///                        `null` = pas d'icône. Un [Tooltip] seul ne
///                        conviendrait pas (appui long indevinable sur mobile,
///                        refermeture trop rapide pour plusieurs paragraphes).
class PeriodGainLine extends StatelessWidget {
  final double? amount;
  final double? percent;
  final ChartPeriod selectedPeriod;
  final double? percentAnnualized;
  final bool netOfContributions;
  final VoidCallback? onInfoPressed;

  const PeriodGainLine({
    super.key,
    required this.selectedPeriod,
    this.amount,
    this.percent,
    this.percentAnnualized,
    this.netOfContributions = false,
    this.onInfoPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (amount == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final isPositive = amount! >= 0;
    final changeColor = AppColors.gainLoss(context, isPositive);

    final percentText = percent != null
        ? (percentAnnualized != null
            ? l10n.chartPercentWithAnnualized(
                Formatters.formatPercentFr(percent!),
                Formatters.formatPercentFr(percentAnnualized!),
              )
            : Formatters.formatPercentFr(percent!))
        : l10n.notAvailable;

    // Mode réel (Modified Dietz) : le jeton de période devient un PRÉFIXE de
    // portée temporelle (« Sur 5A, hors apports » / « Depuis l'origine, hors
    // apports » sur Max) — remplace l'ancienne légende Dietz affichée
    // au-dessus de la ligne. Mode performance (défaut) : format inchangé,
    // période en fin de ligne.
    final lineText = netOfContributions
        ? '${selectedPeriod == ChartPeriod.max ? l10n.chartPeriodGainScopeMax : l10n.chartPeriodGainScope(selectedPeriod.localizedLabel(l10n))} · '
            '${Formatters.formatEurSigned(amount!)} · '
            '$percentText'
        : '${Formatters.formatEurSigned(amount!)} · '
            '$percentText · '
            '${selectedPeriod.localizedLabel(l10n)}';

    // Plus de légende au-dessus (ex-caption Dietz, désormais intégrée au
    // préfixe de [lineText]) : un seul Row suffit, plus besoin du Column
    // englobant.
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
            lineText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: changeColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // Icône d'aide NEUTRE (onSurfaceVariant) : c'est une affordance,
        // pas une donnée gain/perte. InkWell + padding serré plutôt
        // qu'IconButton, dont le padding par défaut (cible 48×48)
        // déséquilibrerait cette ligne compacte face à l'icône
        // trending_up/down (15 px) et forcerait l'ellipsis plus tôt.
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
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

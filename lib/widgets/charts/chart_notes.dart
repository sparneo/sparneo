// lib/widgets/charts/chart_notes.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/widgets/charts/period_gain_line.dart';

/// Bloc de notes rendu SOUS le graphe (période + mode), extrait le 29/07
/// (épuration UI) après constat que [wallet_view.dart] et [account_view.dart]
/// dupliquaient ce bloc À LA MAIN — mêmes conditions, mêmes clés l10n, mêmes
/// espacements — et avaient déjà DIVERGÉ à cause de ça (carte + hauteur
/// variable d'un côté du conteneur graphe, rien de tel de l'autre). Centralise
/// [PeriodGainLine] + les captions conditionnelles pour que tout futur
/// ajustement (microcopie, gating) ne se fasse plus qu'à un seul endroit.
///
/// Principe directeur du lot (revue UX) : un texte affiché en permanence ne
/// porte aucune information. Les trois captions gérées ici sont donc :
/// - la ligne de gain de période : toujours affichée si [periodGainAmount]
///   n'est pas null (déjà géré par [PeriodGainLine] lui-même) ;
/// - l'avertissement d'exclusion (positions saisies sans historique) :
///   CONDITIONNEL — seulement si [realExcludedLegacyCount] > 0 — et CHIFFRÉ.
///   Un compte cash (sans position par construction) n'a donc plus jamais
///   cette ligne, alors que l'ancienne caption inconditionnelle l'affichait
///   à tort ;
/// - l'avertissement de valeurs approchées : déjà conditionnel avant ce lot,
///   inchangé (ne qualifie pas un mode, qualifie la courbe elle-même) ;
/// - la caption du mode « Vos positions » : réduite à sa seule clause
///   discriminante (l'exposé de méthode complet a migré dans la popup
///   d'aide ouverte par l'icône ⓘ du sélecteur de mode, cf. les vues
///   appelantes — hors périmètre de ce widget, qui ne porte que ce qui vit
///   SOUS le graphe).
class ChartNotes extends StatelessWidget {
  /// Gain de période DÉJÀ résolu par l'appelant selon le mode actif (réel ou
  /// performance) — même valeur que celle passée au graphe pour sa
  /// coloration, cf. `periodChange` des vues appelantes.
  final double? periodGainAmount;
  final double? periodGainPercent;

  /// Période sélectionnée (J/1M/…/Max) — pilote le préfixe de portée en mode
  /// réel (cf. [PeriodGainLine.netOfContributions]).
  final ChartPeriod selectedPeriod;

  /// Mode réel effectivement actif ([useRealCurve] des contrôleurs, DÉJÀ
  /// gardé par `hasRealCurve` côté appelant) : bascule entre les captions
  /// « Évolution réelle » et « Vos positions ».
  final bool useRealCurve;

  /// Rendement annualisé (mode réel, fenêtre ≥ 1 an) — appliqué internement
  /// SEULEMENT si [useRealCurve], comme l'ancien `caption` gaté à la main
  /// dans chaque vue.
  final double? periodGainPercentAnnualized;

  /// Ouvre la popup d'aide « gain sur la période » — appliqué internement
  /// SEULEMENT si [useRealCurve] (mode performance : pas d'icône, la caption
  /// courte suffit).
  final VoidCallback? onPeriodGainInfoPressed;

  /// Nombre de positions détenues sans AUCUN mouvement journalisé, donc
  /// exclues de la courbe réelle — cf. `AccountController.
  /// realExcludedLegacyCount` / `WalletController.realExcludedLegacyCount`.
  /// `0` = aucune caption d'exclusion (notamment tout compte cash).
  final int realExcludedLegacyCount;

  /// Nombre de titres valorisés au dernier cours connu faute d'historique —
  /// cf. `realCurveApproxSymbols.length` des contrôleurs.
  final int realCurveApproxSymbolsCount;

  const ChartNotes({
    super.key,
    required this.selectedPeriod,
    required this.useRealCurve,
    this.periodGainAmount,
    this.periodGainPercent,
    this.periodGainPercentAnnualized,
    this.onPeriodGainInfoPressed,
    this.realExcludedLegacyCount = 0,
    this.realCurveApproxSymbolsCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final warningStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PeriodGainLine(
          amount: periodGainAmount,
          percent: periodGainPercent,
          selectedPeriod: selectedPeriod,
          percentAnnualized: useRealCurve ? periodGainPercentAnnualized : null,
          netOfContributions: useRealCurve,
          onInfoPressed: useRealCurve ? onPeriodGainInfoPressed : null,
        ),
        if (useRealCurve) ...[
          // Conditionnelle ET chiffrée (épuration UI du 29/07) : remplace
          // l'ancienne phrase inconditionnelle « Les positions saisies sans
          // historique n'y figurent pas », qui s'affichait à tort même sur un
          // compte cash (aucune position par construction → count == 0 ici).
          if (realExcludedLegacyCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              l10n.chartRealExcludedLegacyCaption(realExcludedLegacyCount),
              style: captionStyle,
            ),
          ],
          if (realCurveApproxSymbolsCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              l10n.chartApproxValuesWarning(realCurveApproxSymbolsCount),
              style: warningStyle,
            ),
          ],
        ] else ...[
          // Mode 1 « Vos positions » : seule la clause discriminante reste à
          // l'écran (rétroprojection à quantités constantes, pas l'historique
          // réel) — l'exposé de méthode complet a migré dans la popup
          // ouverte par l'icône ⓘ du sélecteur de mode (vues appelantes).
          const SizedBox(height: 8),
          Text(l10n.chartModePerformanceCaption, style: captionStyle),
        ],
      ],
    );
  }
}

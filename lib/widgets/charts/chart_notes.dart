// lib/widgets/charts/chart_notes.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/logic/chart_mode_policy.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/charts/inline_links_caption.dart';
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
///   CONDITIONNEL — seulement si [realExcludedLegacyCount] > 0 —, CHIFFRÉ et,
///   depuis que les appelants savent les nommer ([realExcludedLegacyLinks]),
///   NOMMÉ et cliquable : chaque écran cite ce qui se trouve un niveau en
///   dessous, là où l'on peut agir (le patrimoine cite ses comptes, le compte
///   ses titres). Un compte cash (sans position par construction) n'a donc
///   plus jamais cette ligne, alors que l'ancienne caption inconditionnelle
///   l'affichait à tort. Rendue en mode 1 COMME en mode 2 (cf.
///   [realCurveAvailable]) : un compte, ou un patrimoine, 100 % hérité n'a
///   AUCUNE courbe réelle à proposer, mais c'est justement là que cette liste
///   compte le plus ;
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

  /// Revenus (dividendes/intérêts/frais) d'un compte NON ancré, EUR signés —
  /// cf. `realUnanchoredRevenueEur` des contrôleurs. Comptés dans le gain
  /// total mais ABSENTS de la courbe (aucune timeline cash construite pour un
  /// compte non ancré). `0.0` = pas de note (cas courant). Nommer cet écart
  /// résiduel connu carte ↔ courbe plutôt que le laisser inexpliqué.
  final double realUnanchoredRevenueEur;

  /// COUVERTURE de la courbe réelle : part de la valorisation COURANTE
  /// (patrimoine ou compte) que représente son dernier point — cf.
  /// `realCurveCoverage` des contrôleurs. `null` = inconnue (pas de courbe
  /// réelle, ou valorisation courante nulle) : aucune note.
  final double? realCurveCoverage;

  /// Vrai si la POLITIQUE a basculé d'elle-même sur « Vos positions » (aucun
  /// choix persisté de l'utilisateur pour cette portée ET couverture sous le
  /// seuil). Passé EXPLICITEMENT par l'appelant plutôt que recalculé ici : la
  /// vue seule connaît le choix persisté de sa portée, et ce widget n'a pas à
  /// rejouer une décision déjà prise.
  final bool autoFallbackToPositions;

  /// Entrées NOMMÉES et CLIQUABLES des positions héritées — noms de comptes sur
  /// l'écran patrimoine, symboles sur l'écran compte. Vide (défaut) ⇒ on
  /// retombe sur la caption purement chiffrée
  /// ([AppLocalizations.chartRealExcludedLegacyCaption]).
  ///
  /// Liste COMPLÈTE : la troncature (« et N autres ») est faite ICI, à un seul
  /// endroit, pour que les deux écrans se replient de la même façon sur un
  /// mobile étroit. L'appelant fournit les callbacks — ce widget ne navigue ni
  /// n'ouvre jamais rien lui-même.
  final List<InlineLinkSpec> realExcludedLegacyLinks;

  /// Phrase ajoutée après la liste nommée (« Touchez un titre pour déclarer sa
  /// position initiale. »). `null` = rien : sur l'écran patrimoine, ouvrir un
  /// compte en touchant son nom n'a pas besoin d'être expliqué.
  final String? realExcludedLegacyHint;

  /// Masque les notes qui comparent la courbe à la valorisation COURANTE
  /// (liste nommée, avertissement et note de repli de couverture) — à poser
  /// pendant `isLoadingHistory`.
  ///
  /// POURQUOI : ces notes croisent DEUX sources écrites à des instants
  /// différents. Pendant un rechargement d'historique, la valorisation
  /// courante est déjà la nouvelle tandis que `realChartValues` est encore
  /// l'ANCIENNE — le ratio est alors un artefact, et la note de repli
  /// clignotait le temps du calcul. Le gain de période et l'avertissement de
  /// valeurs approchées, eux, ne comparent rien : ils restent affichés.
  final bool suppressCoverageNotes;

  /// Faux quand AUCUNE courbe réelle n'existe (`hasRealCurve` des
  /// contrôleurs) — typiquement un compte, ou un patrimoine, 100 % hérité
  /// (aucun titre journalisé nulle part). Change uniquement le PRÉFIXE de la
  /// note des positions héritées : « … ne figurent pas dans cette courbe » est
  /// faux quand il n'y a pas de courbe du tout à en manquer — cf.
  /// [_buildLegacyNote]. Par défaut `true` (comportement historique,
  /// inchangé) : seuls les appelants qui savent distinguer les deux cas
  /// (account_view, wallet_view, via `hasRealCurve`) passent `false`.
  final bool realCurveAvailable;

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
    this.realUnanchoredRevenueEur = 0.0,
    this.realCurveCoverage,
    this.autoFallbackToPositions = false,
    this.realExcludedLegacyLinks = const [],
    this.realExcludedLegacyHint,
    this.suppressCoverageNotes = false,
    this.realCurveAvailable = true,
  });

  /// Nombre maximal d'entrées NOMMÉES dans la caption ; au-delà, le reste est
  /// résumé en « et N autres ». Trois : au-delà, la phrase déborde de deux
  /// lignes sur un mobile étroit à police système agrandie, et l'utilisateur
  /// n'a de toute façon plus une LISTE mais un inventaire — à ce stade,
  /// l'écran du dessous fait mieux le travail.
  static const int kMaxNamedLegacyLinks = 3;

  /// Vrai si une note RENDUE AU-DESSUS de l'avertissement de couverture a déjà
  /// dit ce qui manque à la courbe — la liste (nommée ou chiffrée) des
  /// positions héritées, ou l'avertissement de valeurs approchées. Pilote le
  /// choix entre la formulation complète et sa variante purement chiffrée.
  bool get _causeAlreadyNamed =>
      realExcludedLegacyCount > 0 || realCurveApproxSymbolsCount > 0;

  /// Couverture arrondie à l'entier, prête à afficher. Bornée à [0, 100] :
  /// un dernier point négatif (cash débiteur) ou un ratio > 1 (écart de
  /// source de prix) ne doit pas produire un pourcentage absurde.
  int get _coveragePercent =>
      ((realCurveCoverage ?? 0) * 100).round().clamp(0, 100);

  /// Note des positions héritées : NOMMÉE et cliquable si l'appelant a fourni
  /// des entrées, purement chiffrée sinon (repli sur la caption historique),
  /// rien du tout si aucune position n'est exclue.
  ///
  /// Renvoie une LISTE de widgets (espacement compris) plutôt qu'un widget
  /// unique : les deux branches du `build` l'insèrent par `...`, à des places
  /// différentes, sans ajouter de `SizedBox` fantôme quand il n'y a rien.
  List<Widget> _buildLegacyNote(AppLocalizations l10n, TextStyle? captionStyle) {
    if (suppressCoverageNotes || realExcludedLegacyCount <= 0) return const [];

    if (realExcludedLegacyLinks.isEmpty) {
      // Aucun nom disponible (appelant non migré) : la caption d'origine.
      return [
        const SizedBox(height: 8),
        Text(
          l10n.chartRealExcludedLegacyCaption(realExcludedLegacyCount),
          style: captionStyle,
        ),
      ];
    }

    final shown = realExcludedLegacyLinks.length <= kMaxNamedLegacyLinks
        ? realExcludedLegacyLinks
        : realExcludedLegacyLinks.sublist(0, kMaxNamedLegacyLinks);
    final hidden = realExcludedLegacyLinks.length - shown.length;

    // « et N autres » puis, seulement sur l'écran compte, le mode d'emploi du
    // tap. Assemblés en UNE phrase de suffixe : deux `Text` empilés auraient
    // fait deux notes là où il n'y a qu'une idée.
    final parts = <String>[
      if (hidden > 0) '${l10n.chartRealExcludedLegacyMore(hidden)}.',
      ?realExcludedLegacyHint,
    ];

    // Trois états, trois préfixes — « cette courbe » ne peut désigner QUE la
    // courbe à l'écran :
    // - pas de courbe réelle du tout (realCurveAvailable faux) : rien à
    //   désigner par « cette courbe », d'où le préfixe dédié qui l'annonce ;
    // - courbe réelle affichée (useRealCurve) : c'est bien elle qui exclut
    //   ces positions, « cette courbe » est exact ;
    // - courbe réelle DISPONIBLE mais mode 1 affiché (repli automatique ou
    //   choix explicite) : la courbe à l'écran est « Vos positions », qui les
    //   INCLUT — « cette courbe » désignerait alors, à tort, l'évolution
    //   réelle absente de l'écran. Il faut la nommer explicitement.
    final String prefix;
    if (!realCurveAvailable) {
      prefix = l10n.chartRealExcludedLegacyNoCurvePrefix(
        realExcludedLegacyCount,
      );
    } else if (useRealCurve) {
      prefix = l10n.chartRealExcludedLegacyNamedPrefix(realExcludedLegacyCount);
    } else {
      prefix = l10n.chartRealExcludedLegacyOtherModePrefix(
        realExcludedLegacyCount,
      );
    }

    return [
      const SizedBox(height: 8),
      InlineLinksCaption(
        prefix: prefix,
        links: shown,
        suffix: parts.isEmpty ? null : parts.join(' '),
        style: captionStyle,
      ),
    ];
  }

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
          // Positions héritées : CONDITIONNELLE (épuration UI du 29/07 —
          // l'ancienne phrase inconditionnelle s'affichait jusque sur un
          // compte cash, sans position par construction), et désormais NOMMÉE.
          //
          // EN PREMIER, avant l'avertissement de couverture : on dit d'abord
          // CE QUI manque et où le corriger, puis seulement COMBIEN ça pèse.
          // L'ordre inverse ouvrait sur un pourcentage nu.
          ..._buildLegacyNote(l10n, captionStyle),
          if (realCurveApproxSymbolsCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              l10n.chartApproxValuesWarning(realCurveApproxSymbolsCount),
              style: warningStyle,
            ),
          ],
          // Reconstruction matériellement incomplète, alors que c'est bien
          // elle qui est à l'écran : le chiffre affiché n'est qu'une fraction
          // de la valorisation courante. Dit en style AVERTISSEMENT (comme
          // [chartApproxValuesWarning]), sans un mot sur le mode par défaut —
          // ici l'utilisateur a la courbe réelle sous les yeux, qu'il l'ait
          // demandée ou que la couverture ait été jugée suffisante puis ne le
          // soit plus. NE REMPLACE PAS la note d'exclusion, qui NOMME les
          // positions absentes : celle-ci en chiffre l'EFFET.
          //
          // DEUX FORMULATIONS, une seule idée : dès qu'une note ci-dessus a
          // déjà nommé ce qui manque (liste des positions héritées, ou titres
          // au dernier cours connu), on n'en garde que le CHIFFRE. Répéter
          // « il y manque des positions sans historique » sous une liste qui
          // vient de les énumérer, c'était deux notes pour une information.
          if (!suppressCoverageNotes &&
              isRealCurveIncomplete(realCurveCoverage)) ...[
            const SizedBox(height: 4),
            Text(
              _causeAlreadyNamed
                  ? l10n.chartRealCoverageWarningShort(_coveragePercent)
                  : l10n.chartRealCoverageWarning(_coveragePercent),
              style: warningStyle,
            ),
          ],
          // Écart résiduel connu carte ↔ courbe : les revenus d'un compte non
          // ancré comptent dans le gain total mais n'apparaissent pas ici.
          // Nommé (avec son montant) plutôt que subi. Seuil au demi-centime
          // pour ne pas afficher un « +0,00 € » né d'un arrondi.
          if (realUnanchoredRevenueEur.abs() >= 0.005) ...[
            const SizedBox(height: 4),
            Text(
              l10n.chartRealUnanchoredRevenueCaption(
                Formatters.formatEurSigned(realUnanchoredRevenueEur),
              ),
              style: captionStyle,
            ),
          ],
        ] else ...[
          // Mode 1 « Vos positions » : seule la clause discriminante reste à
          // l'écran (rétroprojection à quantités constantes, pas l'historique
          // réel) — l'exposé de méthode complet a migré dans la popup
          // ouverte par l'icône ⓘ du sélecteur de mode (vues appelantes).
          const SizedBox(height: 8),
          Text(l10n.chartModePerformanceCaption, style: captionStyle),
          // Liste NOMMÉE des positions héritées : rendue DÈS QUE des positions
          // héritées existent ([_buildLegacyNote] est déjà conditionnel sur ce
          // compte), que le mode 1 soit affiché par bascule AUTOMATIQUE, par
          // choix explicite de l'utilisateur, ou parce qu'il n'existe tout
          // simplement AUCUNE courbe réelle à proposer ([realCurveAvailable]
          // faux — compte, ou patrimoine, 100 % hérité). C'est précisément ce
          // dernier cas que ce lot corrige : sans courbe réelle du tout à
          // montrer, cette liste est la SEULE indication de ce qu'il y a à
          // déclarer pour un jour en obtenir une.
          ..._buildLegacyNote(l10n, captionStyle),
          // Note de repli CHIFFRÉE : seulement quand la bascule est
          // AUTOMATIQUE (sans elle, l'écran s'ouvrirait sur le mode secondaire
          // sans que rien n'explique pourquoi le mode par défaut a été
          // écarté). Ne dit plus que la bascule et son chiffre — le conseil
          // « complétez le journal » qu'elle portait faisait doublon avec la
          // liste juste au-dessus, qui non seulement le dit mais y mène.
          if (autoFallbackToPositions &&
              realCurveCoverage != null &&
              !suppressCoverageNotes) ...[
            const SizedBox(height: 4),
            Text(
              l10n.chartRealCoverageFallbackCaption(_coveragePercent),
              style: captionStyle,
            ),
          ],
        ],
      ],
    );
  }
}

// lib/widgets/position_card.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/common/stale_data_badge.dart';

class PositionCard extends StatelessWidget {
  final Position position;
  final double? currentPrice;
  final double? periodChange;
  final double? periodChangePercent;
  final VoidCallback? onTap;
  final double usdToEurRate;

  /// Libellé court de la période sélectionnée (« 1M », « 1A », « Max »… — celui
  /// même du sélecteur, cf. [ChartPeriod.label]), préfixé au pourcentage de
  /// période. Sans lui, deux pourcentages voisins seraient indiscernables.
  /// `null` (défaut) : la variation de période n'est pas affichée.
  final String? periodLabel;

  /// Date de mise en cache du cours (null = cotation en direct). Affiche un
  /// badge « Cours du JJ/MM » quand la donnée provient du cache.
  final DateTime? lastUpdated;

  const PositionCard({
    super.key,
    required this.position,
    this.currentPrice,
    this.periodChange,
    this.periodChangePercent,
    this.onTap,
    this.usdToEurRate = 0.92,
    this.lastUpdated,
    this.periodLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final price = currentPrice ?? 0;

    // ⭐ Plus-value latente vs PRU (prioritaire sur la variation période si défini).
    final pru = position.averageBuyPrice;
    final hasGain = pru != null && pru != 0 && currentPrice != null;
    final double? gainPercent = hasGain
        ? (currentPrice! - pru) / pru * 100
        : null;

    // Variation de PÉRIODE, affichée À CÔTÉ de la PV et non à sa place : les
    // deux répondent à des questions différentes (« où j'en suis depuis mes
    // achats » / « ce que le titre a fait sur la fenêtre choisie »). Elle n'est
    // volontairement PAS liée au sélecteur de mode du graphe : ce pourcentage
    // est le mouvement du COURS (cf. `computeIndividualPeriodChanges`), donc
    // identique dans les deux modes — l'y accrocher ferait croire que le mode
    // change les chiffres des positions. Seul le [periodChange] en euros, lui,
    // serait mode-dépendant (il suppose la quantité d'aujourd'hui sur toute la
    // fenêtre) : c'est pourquoi la carte n'affiche que le pourcentage.
    final double? periodPercent = periodLabel != null
        ? periodChangePercent
        : null;

    // Le pictogramme suit la PV quand elle existe (chiffre principal), sinon la
    // variation de période — jamais un mélange des deux signes.
    final isPositive = gainPercent != null
        ? gainPercent >= 0
        : (periodPercent != null
              ? periodPercent >= 0
              : (periodChange != null && periodChange! >= 0));

    final changeColor = AppColors.gainLoss(context, isPositive);

    final qtyNum = double.tryParse(position.quantity) ?? 0;
    double totalValueEur = price * qtyNum;

    if (position.asset.currency.toUpperCase() == 'USD') {
      totalValueEur = totalValueEur * usdToEurRate;
    }

    // InkWell placé À L'INTÉRIEUR de la Card (pattern identique à ListTile) :
    // l'effet d'encre est clippé aux coins arrondis.
    return Card(
      // ⭐ RÉDUIRE LES MARGES HORIZONTALES POUR AUGMENTER LA LARGEUR
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        // Curseur « main » explicite : un InkWell dans une Card ne résout pas
        // son curseur par défaut en `click` (il retombe sur `basic`) — on le
        // force donc quand la carte est cliquable.
        mouseCursor: onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.avatarColor(
                  position.symbol,
                ).withValues(alpha: 0.12),
                child: Text(
                  position.symbol.substring(0, 1),
                  style: TextStyle(
                    color: AppColors.avatarColor(position.symbol),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // LIGNE 1 : NOM + TOTAL
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // ⭐ RÉDUIRE LA LARGEUR DU NOM AVEC FLEX
                        Expanded(
                          flex: 2, // ⭐ Moins de place pour le nom
                          child: Text(
                            position.displayName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),

                        const SizedBox(width: 8),

                        // ⭐ PLUS DE PLACE POUR LE TOTAL
                        Text(
                          Formatters.formatEur(totalValueEur),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 4),

                    // LIGNE 2 : QUANTITÉ x PRIX UNITAIRE + VARIATION
                    //
                    // Les DEUX côtés sont flexibles, avec plus de poids à droite
                    // (3 contre 2) : depuis que la variation porte deux chiffres
                    // au lieu d'un, sa largeur naturelle pouvait dépasser la
                    // carte sur mobile étroit — un bloc non contraint débordait
                    // alors (mesuré : 80 px sur une carte de 280). Sous
                    // pression, chaque côté se réduit au lieu que la ligne
                    // déborde ; les chiffres passent à la ligne plutôt que
                    // d'être tronqués, la quantité s'abrège.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ⭐ ESPACE APRÈS LA QUANTITÉ
                        // Flexible + ellipsis : le prix sans perte (cf.
                        // formatPriceLossless) peut être plus long qu'un prix
                        // arrondi à 2 décimales, ne pas laisser cette ligne
                        // déborder la carte sur un écran étroit.
                        Flexible(
                          flex: 2,
                          child: Text(
                            '${position.quantity} x ${_formatPriceWithConversion(price)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),

                        // Variation : plus-value latente (PV) et/ou variation
                        // sur la période sélectionnée, chacune COLORÉE PAR SON
                        // PROPRE SIGNE (une PV en hausse peut coexister avec un
                        // mois en baisse — une couleur unique mentirait).
                        // `Text.rich` plutôt que deux widgets : un seul flux de
                        // texte, donc pas de retour à la ligne entre le nombre
                        // et son signe sur écran étroit.
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 3,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                isPositive
                                    ? Icons.trending_up
                                    : Icons.trending_down,
                                color: changeColor,
                                size: 12,
                              ),
                              const SizedBox(width: 2),
                              Flexible(
                                child: _changeText(
                                  context,
                                  l10n,
                                  gainPercent: gainPercent,
                                  periodPercent: periodPercent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // Badge « non coté » : actif en repli ISIN (titre délisté),
                    // jamais interrogé sur la source de marché.
                    if (!position.asset.quotable) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _NotQuotedBadge(),
                      ),
                    ],
                    if (lastUpdated != null) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: StaleDataBadge(asOf: lastUpdated),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// « PV +12,3 % · 1M −1,4 % » — l'un, l'autre, ou les deux.
  ///
  /// Le préfixe de période (« 1M », « Max »…) est indispensable : sans lui deux
  /// pourcentages côte à côte seraient impossibles à attribuer.
  Widget _changeText(
    BuildContext context,
    AppLocalizations l10n, {
    required double? gainPercent,
    required double? periodPercent,
  }) {
    const style = TextStyle(fontSize: 12, fontWeight: FontWeight.w500);

    if (gainPercent == null && periodPercent == null) {
      return Text(
        l10n.notAvailable,
        style: style.copyWith(color: AppColors.gainLoss(context, true)),
      );
    }

    return Text.rich(
      textAlign: TextAlign.end,
      TextSpan(
        style: style,
        children: [
          if (gainPercent != null)
            TextSpan(
              text: l10n.unrealizedGainShort(
                Formatters.formatPercentFr(gainPercent),
              ),
              style: TextStyle(
                color: AppColors.gainLoss(context, gainPercent >= 0),
              ),
            ),
          if (gainPercent != null && periodPercent != null)
            TextSpan(
              text: ' · ',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          if (periodPercent != null)
            TextSpan(
              text:
                  '$periodLabel ${Formatters.formatPercentFr(periodPercent)}',
              style: TextStyle(
                color: AppColors.gainLoss(context, periodPercent >= 0),
              ),
            ),
        ],
      ),
    );
  }

  String _formatPriceWithConversion(double price) {
    // Sans perte : la valeur totale à droite est calculée sur le prix réel,
    // le prix unitaire affiché doit donc l'être aussi pour rester
    // recalculable de tête (quantité × prix affiché = valeur affichée).
    return Formatters.formatPriceWithConversionLossless(
      price,
      position.asset.currency,
      usdToEurRate,
    );
  }
}

/// Petite puce « Non coté » signalant un actif en repli ISIN (titre délisté),
/// jamais interrogé sur la source de marché. Même gabarit visuel discret que
/// [StaleDataBadge].
class _NotQuotedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            l10n.positionNotQuotedBadge,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

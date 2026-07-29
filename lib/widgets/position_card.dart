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

    final isPositive = gainPercent != null
        ? gainPercent >= 0
        : (periodChangePercent != null
              ? periodChangePercent! >= 0
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // ⭐ ESPACE APRÈS LA QUANTITÉ
                        // Flexible + ellipsis : le prix sans perte (cf.
                        // formatPriceLossless) peut être plus long qu'un prix
                        // arrondi à 2 décimales, ne pas laisser cette ligne
                        // déborder la carte sur un écran étroit.
                        Flexible(
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

                        // Variation : plus-value latente (PV) si PRU défini,
                        // sinon variation sur la période sélectionnée.
                        Row(
                          children: [
                            Icon(
                              isPositive
                                  ? Icons.trending_up
                                  : Icons.trending_down,
                              color: changeColor,
                              size: 12,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              gainPercent != null
                                  ? l10n.unrealizedGainShort(
                                      Formatters.formatPercentFr(gainPercent),
                                    )
                                  : (periodChangePercent != null
                                        ? Formatters.formatPercentFr(
                                            periodChangePercent!,
                                          )
                                        : l10n.notAvailable),
                              style: TextStyle(
                                color: changeColor,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
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

// lib/widgets/allocation_pie_chart.dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/widgets/indicator.dart';

/// Une part d'allocation (un actif ou un compte) : un libellé et une valeur.
class AllocationSlice {
  final String label;
  final double value;
  const AllocationSlice(this.label, this.value);
}

/// Camembert d'allocation réutilisable, **robuste au nombre de parts**.
///
/// Au-delà de [maxSlices], les plus petites parts sont regroupées dans une part
/// « Autres » : le camembert reste lisible et la légende est bornée à quelques
/// lignes (l'ancienne version débordait — en hauteur via une `Column` contrainte
/// non scrollable, et latéralement car la légende remplissait toute la largeur,
/// collant le camembert au bord gauche). Ici la légende prend la taille de son
/// contenu et le groupe est centré.
class AllocationPieChart extends StatelessWidget {
  final List<AllocationSlice> slices;
  final String othersLabel;
  final String noDataLabel;
  final int maxSlices;
  final double height;

  const AllocationPieChart({
    super.key,
    required this.slices,
    required this.othersLabel,
    required this.noDataLabel,
    this.maxSlices = 7,
    this.height = 170,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final total = slices.fold<double>(0, (sum, s) => sum + (s.value > 0 ? s.value : 0));
    if (total <= 0) {
      return SizedBox(
        height: 80,
        child: Center(
          child: Text(noDataLabel,
              style: TextStyle(
                  color: colorScheme.onSurfaceVariant, fontSize: 12)),
        ),
      );
    }

    // Tri décroissant puis regroupement des plus petites parts dans « Autres ».
    final sorted = [...slices.where((s) => s.value > 0)]
      ..sort((a, b) => b.value.compareTo(a.value));

    final List<AllocationSlice> shown;
    if (sorted.length > maxSlices) {
      final kept = sorted.take(maxSlices - 1).toList();
      final othersValue =
          sorted.skip(maxSlices - 1).fold<double>(0, (sum, s) => sum + s.value);
      shown = [...kept, AllocationSlice(othersLabel, othersValue)];
    } else {
      shown = sorted;
    }

    final colors = [
      colorScheme.primary,
      colorScheme.secondary,
      colorScheme.tertiary,
      colorScheme.primaryContainer,
      colorScheme.secondaryContainer,
      colorScheme.tertiaryContainer,
      colorScheme.primary.withValues(alpha: 0.8),
      colorScheme.secondary.withValues(alpha: 0.8),
    ];

    const pieSize = 100.0;
    const gap = 36.0;

    final pie = SizedBox(
      width: pieSize,
      height: pieSize,
      child: PieChart(
        PieChartData(
          startDegreeOffset: 180,
          sectionsSpace: 2,
          centerSpaceRadius: 30,
          sections: shown.asMap().entries.map((entry) {
            final color = colors[entry.key % colors.length];
            final value = entry.value.value;
            final percentage = value / total * 100;
            return PieChartSectionData(
              color: color,
              value: value,
              // On masque l'étiquette des parts trop fines pour éviter le
              // chevauchement illisible.
              title: percentage >= 5 ? '${percentage.toStringAsFixed(0)}%' : '',
              radius: 45,
              titleStyle: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color.computeLuminance() < 0.5 ? Colors.white : Colors.black87,
                shadows: const [Shadow(color: Colors.black26, blurRadius: 2)],
              ),
            );
          }).toList(),
        ),
      ),
    );

    // La largeur de la légende est calculée à partir de la place réellement
    // disponible : le groupe (camembert + légende) reste ainsi centré et ne
    // déborde jamais de l'écran, quel que soit le parent ou la longueur des
    // libellés (ellipsés au-delà).
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
        // Largeur MAXIMALE de la légende (pas une largeur fixe) : la légende
        // prend la taille de son contenu et se tronque au-delà. Le groupe reste
        // ainsi compact et centré au lieu de remplir tout l'espace.
        final legendMaxWidth = (available - pieSize - gap).clamp(80.0, double.infinity);

        // Longueur de libellé tolérée par la place disponible. On tronque le
        // NOM à la source : la largeur intrinsèque de la légende reste bornée,
        // donc le groupe ne dépasse jamais de l'écran (le simple `ellipsis` ne
        // suffit pas, car la largeur intrinsèque d'un texte sur une ligne reste
        // sa largeur complète et fait déborder le `Row` non extensible).
        // ~8 px/caractère (majorant) à 12 pt, moins ~20 px (pastille + écart) et
        // ~5 caractères réservés au suffixe « NN % ».
        final maxLabelChars = (((legendMaxWidth - 20) / 8).floor() - 5).clamp(6, 60);
        String truncate(String s) => s.length <= maxLabelChars
            ? s
            : '${s.substring(0, maxLabelChars - 1).trimRight()}…';

        return SizedBox(
          height: height,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                pie,
                const SizedBox(width: gap),
                // La légende prend la taille de son contenu (≤ legendMaxWidth) :
                // le groupe reste donc compact et réellement centré. Le
                // regroupement « Autres » garantit au plus [maxSlices] lignes,
                // qui tiennent dans [height] sans défilement.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: legendMaxWidth),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: shown.asMap().entries.map((entry) {
                      final color = colors[entry.key % colors.length];
                      final percentage = entry.value.value / total * 100;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Indicator(
                          color: color,
                          text: '${truncate(entry.value.label)}  ${percentage.toStringAsFixed(0)}%',
                          isSquare: false,
                          size: 12,
                          textColor: theme.textTheme.bodyMedium?.color ?? colorScheme.onSurface,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

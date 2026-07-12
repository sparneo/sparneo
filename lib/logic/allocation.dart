// lib/logic/allocation.dart
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';

/// Représente l'allocation réelle d'une catégorie.
///
/// [type] identifie la catégorie : un [AssetType] pour un type d'actif, ou
/// `null` pour la catégorie synthétique « liquidités » (cash, cf.
/// [kCashAllocationKey]). Le cash n'étant pas un AssetType, cette nullabilité
/// est le pivot qui en fait une catégorie de premier rang sans polluer l'enum.
class AssetTypeAllocation {
  /// `null` = catégorie « liquidités » (cash).
  final AssetType? type;

  /// Valeur totale en EUR pour cette catégorie.
  final double value;

  /// Pourcentage dans le patrimoine total (0–100). 0.0 si total == 0.
  final double percent;

  /// True si cette allocation représente les liquidités (cash).
  bool get isCash => type == null;

  const AssetTypeAllocation({
    required this.type,
    required this.value,
    required this.percent,
  });
}

/// Écart entre l'allocation réelle et la cible pour une catégorie.
class AllocationGap {
  /// `null` = catégorie « liquidités » (cash).
  final AssetType? type;

  /// Pourcentage réel (0–100).
  final double realPercent;

  /// Pourcentage cible (0–100).
  final double targetPercent;

  /// True si cet écart concerne les liquidités (cash).
  bool get isCash => type == null;

  /// delta = réel − cible (négatif = sous-pondéré, positif = sur-pondéré).
  double get delta => realPercent - targetPercent;

  const AllocationGap({
    required this.type,
    required this.realPercent,
    required this.targetPercent,
  });
}

/// Fonctions pures de calcul d'allocation.
/// Aucune dépendance UI, aucun I/O : testable en isolation totale.
class AllocationCalculator {
  AllocationCalculator._();

  // --- Allocation réelle ---

  /// Calcule l'allocation réelle par catégorie à partir des positions
  /// valorisées [positions] et du solde de liquidités [cashValue].
  ///
  /// - Les positions sont regroupées par [AssetType] (numérateur = valeur des
  ///   positions du type, dénominateur = [totalValue]).
  /// - Le cash (somme des soldes des comptes cash, en EUR, fournie via
  ///   [cashValue]) forme une catégorie synthétique de premier rang
  ///   (`type == null`, cf. [kCashAllocationKey]), avec le MÊME dénominateur.
  ///   Ainsi la somme des pourcentages (types + cash) ≈ 100 %, alors qu'avant
  ///   le cash n'était compté qu'au dénominateur (types seuls < 100 %).
  ///
  /// [totalValue] est le patrimoine total (positions + cash) en EUR ; il doit
  /// inclure [cashValue] pour que les pourcentages somment à ~100 %.
  ///
  /// Retourne la liste des catégories présentes dans l'ordre décroissant de
  /// valeur. Les catégories de valeur nulle ou négative sont exclues (cash
  /// compris : pas de tranche cash si [cashValue] ≤ 0).
  static List<AssetTypeAllocation> computeRealAllocations({
    required List<PositionWithMarketData> positions,
    required double totalValue,
    required double usdToEurRate,
    double cashValue = 0.0,
  }) {
    if (totalValue <= 0) return [];

    // Agrégation des valeurs par type
    final Map<AssetType, double> valueByType = {};

    for (final pos in positions) {
      double value = (pos.currentPrice ?? 0) * (double.tryParse(pos.quantity) ?? 0);
      // Conversion USD → EUR identique à celle du contrôleur
      if (pos.asset.currency.toUpperCase() == 'USD') {
        value = value * usdToEurRate;
      }
      if (value <= 0) continue;
      valueByType[pos.type] = (valueByType[pos.type] ?? 0) + value;
    }

    // Construction des allocations par type
    final result = valueByType.entries
        .where((e) => e.value > 0)
        .map((e) => AssetTypeAllocation(
              type: e.key,
              value: e.value,
              percent: e.value / totalValue * 100,
            ))
        .toList();

    // Catégorie synthétique « liquidités » (cash), si présente.
    if (cashValue > 0) {
      result.add(AssetTypeAllocation(
        type: null,
        value: cashValue,
        percent: cashValue / totalValue * 100,
      ));
    }

    return result..sort((a, b) => b.value.compareTo(a.value));
  }

  // --- Écarts ---

  /// Calcule les écarts entre l'allocation réelle et les cibles définies.
  ///
  /// Seules les catégories ciblées dans [target] sont incluses dans le
  /// résultat. Une catégorie ciblée mais absente du réel donne realPercent = 0.
  /// La catégorie « liquidités » (cash, clé [kCashAllocationKey]) est traitée
  /// comme un type à part entière : elle produit un [AllocationGap] avec
  /// `type == null` comparant le cash réel à la cible cash.
  ///
  /// [realAllocations] est le résultat de [computeRealAllocations].
  static List<AllocationGap> computeGaps({
    required AllocationTarget target,
    required List<AssetTypeAllocation> realAllocations,
  }) {
    if (target.isEmpty) return [];

    // Index des allocations réelles par catégorie pour accès O(1).
    // La clé null correspond à la catégorie « liquidités » (cash).
    final realByType = <AssetType?, double>{
      for (final a in realAllocations) a.type: a.percent,
    };

    final gaps = <AllocationGap>[];
    for (final entry in target.targets.entries) {
      // La clé cash produit un gap synthétique (type == null).
      if (entry.key == kCashAllocationKey) {
        gaps.add(AllocationGap(
          type: null,
          realPercent: realByType[null] ?? 0.0,
          targetPercent: entry.value,
        ));
        continue;
      }

      // Ignore les entrées dont la clé ne correspond pas à un AssetType connu.
      final AssetType? type = AssetType.values.cast<AssetType?>().firstWhere(
        (t) => t?.name == entry.key,
        orElse: () => null,
      );
      if (type == null) continue;

      gaps.add(AllocationGap(
        type: type,
        realPercent: realByType[type] ?? 0.0,
        targetPercent: entry.value,
      ));
    }

    // Tri : écart absolu décroissant, puis clé de catégorie (déterministe).
    // Le cash trie sur [kCashAllocationKey] pour rester stable.
    gaps.sort((a, b) {
      final cmp = b.delta.abs().compareTo(a.delta.abs());
      if (cmp != 0) return cmp;
      final ka = a.type?.name ?? kCashAllocationKey;
      final kb = b.type?.name ?? kCashAllocationKey;
      return ka.compareTo(kb);
    });

    return gaps;
  }

  // --- Validation ---

  /// Retourne true si la somme des valeurs de [targets] est ≤ 100.
  static bool isTargetSumValid(Map<String, double> targets) {
    final sum = targets.values.fold(0.0, (s, v) => s + v);
    return sum <= 100.0 + 1e-9; // tolérance flottante
  }
}

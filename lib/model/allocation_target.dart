// lib/model/allocation_target.dart
import 'package:portfolio_tracker/model/asset.dart';

/// Clé réservée désignant la catégorie synthétique « liquidités » (cash) dans
/// les maps d'allocation (cibles, réel, écarts).
///
/// Le cash N'EST PAS un [AssetType] : c'est un solde de compte
/// (`Account.cashBalance`). On le représente néanmoins comme une catégorie de
/// premier rang au moyen de cette clé String, qui cohabite avec les
/// `AssetType.name` dans la même map. Elle est choisie hors de l'espace des
/// noms d'AssetType (etf/stock/bond/crypto/fund/preciousMetal/other) : aucune
/// collision possible.
const String kCashAllocationKey = 'cash';

/// Cibles d'allocation par type d'actif pour un wallet donné.
///
/// [targets] est une map AssetType.name → pourcentage cible (0–100).
/// La somme peut être inférieure à 100 : le reliquat est implicitement
/// « non ciblé ». Elle ne peut pas dépasser 100.
class AllocationTarget {
  /// Map AssetType.name (String) → pourcentage cible (double 0–100).
  /// Utiliser la clé String au lieu de l'enum directement garantit la
  /// tolérance ascendante lors de la désérialisation (valeur inconnue ignorée).
  final Map<String, double> targets;

  const AllocationTarget({required this.targets});

  /// Crée une cible vide (aucun type ciblé).
  const AllocationTarget.empty() : targets = const {};

  // --- Accesseurs pratiques ---

  /// Retourne le pourcentage cible pour [type], ou null si non ciblé.
  double? targetFor(AssetType type) => targets[type.name];

  /// Retourne le pourcentage cible pour la catégorie « liquidités » (cash),
  /// ou null si non ciblée. Stocké sous [kCashAllocationKey] dans [targets].
  double? targetForCash() => targets[kCashAllocationKey];

  /// Somme de tous les pourcentages cibles.
  double get totalPercent =>
      targets.values.fold(0.0, (sum, v) => sum + v);

  /// True si aucune cible n'est définie.
  bool get isEmpty => targets.isEmpty;

  // --- Sérialisation JSON (style Wallet.fromJson : tolérant) ---

  factory AllocationTarget.fromJson(Map<String, dynamic> json) {
    final rawTargets = json['targets'];
    if (rawTargets == null || rawTargets is! Map) {
      return const AllocationTarget.empty();
    }

    final parsed = <String, double>{};
    for (final entry in rawTargets.entries) {
      final key = entry.key?.toString();
      // Ignore les clés inconnues (AssetType inconnu ou null).
      if (key == null) continue;
      final value = (entry.value as num?)?.toDouble();
      if (value != null && value >= 0) parsed[key] = value;
    }
    return AllocationTarget(targets: parsed);
  }

  Map<String, dynamic> toJson() {
    return {'targets': targets};
  }

  /// Retourne une copie avec les cibles [updated] substituées.
  AllocationTarget copyWith({Map<String, double>? targets}) {
    return AllocationTarget(targets: targets ?? this.targets);
  }
}

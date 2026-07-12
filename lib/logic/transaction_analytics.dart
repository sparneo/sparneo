// lib/logic/transaction_analytics.dart
//
// Analyse descriptive mono-devise d'un journal de transactions.
//
// HYPOTHÈSE : toutes les transactions passées portent le même symbole et la
// même devise. Aucune conversion FX n'est effectuée ici — c'est de l'analyse
// descriptive de coût moyen pondéré au sens comptable (PRU FIFO non utilisé,
// méthode WAC / coût moyen pondéré glissant).
//
// NOTE sur les dividendes : les dividendes constituent un revenu (flux de
// trésorerie), pas une plus-value de cession. Ils sont donc délibérément exclus
// du calcul du PRU et de la plus-value réalisée (traitement fiscal distinct).
//
// NOTE sur la survente : si le journal enregistre une vente supérieure à la
// quantité détenue selon le journal (stock négatif), la base de coût est bornée
// à 0 (ne descend jamais en-dessous). Ce cas est anormal — il résulte d'un
// journal incomplet — et est documenté ici plutôt que levé comme exception pour
// ne pas bloquer l'affichage.

import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';

/// Résultat immuable de l'analyse d'un journal de transactions.
class TransactionAnalytics {
  /// Quantité nette détenue selon le journal (achats − ventes, borné à 0).
  final double netQuantity;

  /// Prix de revient unitaire calculé (coût moyen pondéré glissant).
  /// [null] si [netQuantity] ≤ 0 (plus rien en portefeuille selon le journal).
  final double? suggestedAveragePrice;

  /// Plus-value réalisée cumulée sur les ventes enregistrées dans le journal.
  /// (produit de cession net de frais − base de coût des titres cédés).
  final double realizedGain;

  const TransactionAnalytics({
    required this.netQuantity,
    required this.suggestedAveragePrice,
    required this.realizedGain,
  });
}

/// Calcule le PRU (coût moyen pondéré), la plus-value réalisée cumulée et la
/// quantité nette à partir d'une liste de [AssetTransaction].
///
/// RÉIMPLÉMENTÉ par-dessus le moteur de projection exact ([replayLedger] dans
/// position_projection.dart) : il n'existe QU'UN SEUL rejeu du journal dans
/// l'application (invariant anti-divergence). Cette fonction ne fait qu'adapter
/// le résultat commun vers les types `double` attendus par l'UI d'affichage —
/// la quantité et la base de coût restent calculées en arithmétique exacte
/// (Decimal / Rational) puis converties ici.
///
/// Les transactions sont triées en interne par date croissante puis par id
/// croissant — ne pas supposer l'ordre d'entrée.
///
/// Affectent le PRU / la quantité : [TransactionKind.buy],
/// [TransactionKind.sell], [TransactionKind.openingBalance] (entrée
/// déclarative) et [TransactionKind.adjustment] (delta signé qty + coût).
/// Seul [TransactionKind.sell] génère une plus-value réalisée (openingBalance
/// et adjustment ne sont pas des cessions). Les dividendes
/// ([TransactionKind.dividend]) et mouvements cash ([TransactionKind.deposit],
/// [TransactionKind.withdrawal]) sont ignorés.
TransactionAnalytics computeTransactionAnalytics(
    List<AssetTransaction> txs) {
  final r = replayLedger(txs);
  return TransactionAnalytics(
    netQuantity: r.quantity.toDouble(),
    suggestedAveragePrice: r.averagePrice,
    realizedGain: r.realizedGain,
  );
}

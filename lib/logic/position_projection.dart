// lib/logic/position_projection.dart
//
// Moteur de projection B* : la POSITION (quantité + PRU) est une PROJECTION
// DÉRIVÉE du journal de mouvements, jamais une donnée figée. Ce fichier est
// l'UNIQUE rejeu du journal de l'application (invariant anti-divergence) :
//   - [projectPosition] : projection exacte (quantité en Decimal) pour le
//     projecteur atomique (LedgerService) qui persiste la ligne positions.
//   - [computeTransactionAnalytics] (transaction_analytics.dart) est
//     RÉIMPLÉMENTÉ par-dessus ce moteur : il ne fait qu'adapter le résultat
//     commun ([replayLedger]) vers ses types `double` d'affichage.
//
// ARITHMÉTIQUE : la quantité est calculée en [Decimal] (exact — pas de dérive
// binaire type 0.1 + 0.2). La base de coût est maintenue en [Rational] (exact,
// y compris la division WAC lors des ventes) ; elle n'est convertie en `double`
// qu'au tout dernier moment pour le PRU (contrat public `double?`).
//
// CAS TRAITÉS (projection TITRE, identiques à computeTransactionAnalytics) :
// buy / sell / openingBalance / adjustment. dividend / deposit / withdrawal /
// interest / charge sont ignorés par la projection titre.
// TRI : date croissante puis id croissant. CLAMP : quantité et coût ne
// descendent jamais sous zéro (survente / ajustement négatif au-delà du stock).
//
// ─────────────────────────────────────────────────────────────────────────────
// INVARIANT DE PARTITION DES CHAMPS (anti-double-comptage — modèle B*, lot cash)
// ─────────────────────────────────────────────────────────────────────────────
// Le journal porte DEUX projections dérivées disjointes, qui ne partagent AUCUN
// champ numérique :
//
//   ┌───────────────────┬──────────────────────────┬─────────────────────────┐
//   │ Projection        │ Lit                      │ Ignore                  │
//   ├───────────────────┼──────────────────────────┼─────────────────────────┤
//   │ TITRE (qty/coût)  │ quantity, unitPrice, fee │ amount, settlementCur.  │
//   │ CASH (Σ amount)   │ amount, settlementCur.   │ fee, quantity, unitPrice│
//   └───────────────────┴──────────────────────────┴─────────────────────────┘
//
// Aucun champ n'étant lu par les deux moteurs, le double comptage est IMPOSSIBLE
// par construction (le piège classique — un moteur cash calculant `amount − fee`
// double-déduirait les frais : PROSCRIT). [amount] est l'effet net signé sur les
// espèces DU COMPTE, dans la DEVISE DE RÈGLEMENT (`settlementCurrency ?? currency`
// — PAS la cotation), frais et taxes DÉJÀ inclus. quantity/unitPrice/fee restent
// en devise de COTATION (PRU comparé au cours Yahoo). Le moteur cash est
// AGNOSTIQUE AU SIGNE : il somme, il ne réinterprète jamais (un rebate `charge`
// positif ou une correction négative ne doit rien casser) ; et AGNOSTIQUE AU
// CHANGE : le taux liant cotation et règlement est un fait passé figé dans
// [amount], jamais recalculé (rejeu déterministe, zéro réseau — design §8).
//
// Corollaire (garanti côté saisie / émission) :
//   - amount d'un openingBalance/adjustment TITRE (symbol != null) = null →
//     déclarer/corriger un lot ne bouge PAS le cash (Σ amount : null = 0).
//   - amount des variantes ESPÈCES (symbol == null) = signé → porte le solde /
//     le delta de trésorerie.
//
// PAS DE CLAMP À 0 SUR LE CASH (contrairement à la quantité titre) : un solde
// espèces négatif reste VRAI (journal partiel, marge / SRD) — le masquer
// détruirait la conservation. Divergence assumée et documentée.

import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:rational/rational.dart';

import 'package:portfolio_tracker/model/asset_transaction.dart';

/// Projection dérivée d'une position à partir de son journal.
class PositionProjection {
  /// Quantité nette EXACTE détenue selon le journal (achats − ventes, bornée à
  /// 0). Exposée en [Decimal] pour une persistance sans perte (String
  /// canonique via `quantity.toString()`).
  final Decimal quantity;

  /// PRU (coût moyen pondéré) dérivé, ou `null` si [quantity] ≤ 0 (plus rien en
  /// portefeuille selon le journal — pas de base de coût définie).
  final double? averagePrice;

  const PositionProjection(this.quantity, this.averagePrice);
}

/// Résultat brut du rejeu du journal — SOURCE UNIQUE partagée par
/// [projectPosition] et [computeTransactionAnalytics].
///
/// [quantity] et [cost] sont exacts ([Decimal] / [Rational]) ; [realizedGain]
/// est en `double` (la plus-value réalisée est un flux d'affichage, jamais
/// persisté comme référence de position).
class LedgerReplayResult {
  final Decimal quantity;
  final Rational cost; // base de coût totale des titres détenus (frais inclus)
  final double realizedGain;

  /// Projection CASH : `Σ amount` signé, groupé PAR DEVISE DE RÈGLEMENT (clé =
  /// `settlementCurrency ?? currency` de chaque mouvement — celle du COMPTE, PAS
  /// la cotation ; cf. design §8). Exact ([Decimal] — l'addition est fermée sur
  /// les décimaux, aucune conversion `double`). Calculée dans le MÊME passage que
  /// la projection titre (invariant « un seul rejeu du journal ») mais lit
  /// UNIQUEMENT [AssetTransaction.amount] (partition stricte — cf. en-tête).
  ///
  /// Agnostique au signe (somme brute), SANS clamp à 0. Une devise absente de
  /// la map = aucun mouvement dans cette devise (≡ 0). Ne JAMAIS sommer des
  /// devises hétérogènes : chacune a son propre total.
  ///
  /// NB : sur une liste filtrée par symbole ([getBySymbol]), ce total ne
  /// représente que la contribution cash de CE symbole ; le solde espèces d'un
  /// COMPTE se calcule en rejouant TOUT le journal du compte ([getByAccount]).
  final Map<String, Decimal> cashByCurrency;

  const LedgerReplayResult(
    this.quantity,
    this.cost,
    this.realizedGain, {
    this.cashByCurrency = const {},
  });

  /// PRU dérivé (base de coût / quantité), ou `null` si quantité ≤ 0 OU si la
  /// base de coût est nulle (aucune info de prix — ex. position initiale
  /// déclarée sans PRU, ou titre reçu à titre gratuit). Un PRU de 0 n'a aucun
  /// sens et afficherait une plus-value latente fictive de +100 % : on rend
  /// `null` (pas de PRU connu), comportement identique à l'avant-B* où une
  /// position sans PRU avait `averageBuyPrice == null`.
  double? get averagePrice => quantity > Decimal.zero && cost > Rational.zero
      ? (cost / quantity.toRational()).toDouble()
      : null;
}

/// Parse une chaîne décimale en [Decimal] EXACT. Tolère la virgule décimale
/// (format FR) et les espaces/tabulations parasites (données legacy non
/// trimées, ex. `AssetTransaction.fromJson` qui ne trim pas) ; `null`, vide ou
/// non-parsable → [Decimal.zero].
///
/// IMPORTANT : contrairement à `double.tryParse`, `Decimal.tryParse` ne trim
/// PAS lui-même — un `" 10"` non trimé donnerait silencieusement
/// [Decimal.zero] (régression : position à 0 titre, PRU null) sans le
/// `.trim()` explicite ci-dessous.
Decimal _parseDecimal(String? s) {
  if (s == null || s.isEmpty) return Decimal.zero;
  final normalized = s.replaceAll(',', '.').trim();
  return Decimal.tryParse(normalized) ?? Decimal.zero;
}

/// Rejoue le journal EN UN SEUL passage (unique switch sur [TransactionKind]).
///
/// Maintient simultanément : la quantité exacte ([Decimal]), la base de coût
/// exacte ([Rational], division WAC comprise) et la plus-value réalisée
/// (`double`). C'est le cœur anti-divergence : tout autre calcul dérivé
/// (projection de position, analytics d'affichage) passe par ici.
LedgerReplayResult replayLedger(List<AssetTransaction> txs) {
  var runningQty = Decimal.zero; // quantité détenue courante (exacte)
  var runningCost = Rational.zero; // base de coût totale (exacte)
  var realized = 0.0; // plus-value réalisée cumulée
  final cash = <String, Decimal>{}; // Σ amount signé, par devise (exact)

  if (txs.isEmpty) {
    return LedgerReplayResult(runningQty, runningCost, realized);
  }

  // Tri chronologique stable : date croissante, puis id croissant (les id sont
  // des timestamps microseconde — ordre de création). Identique à l'ancien
  // computeTransactionAnalytics.
  final sorted = List<AssetTransaction>.from(txs)
    ..sort((a, b) {
      final cmp = a.date.compareTo(b.date);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });

  for (final tx in sorted) {
    // PROJECTION CASH (partition stricte : lit UNIQUEMENT amount). Kind-agnostic
    // et sign-agnostic : Σ amount par devise, null = 0, aucun clamp. Placée HORS
    // du switch titre car uniforme sur tous les kinds — un openingBalance /
    // adjustment TITRE a amount=null (contribue 0), une variante espèces porte
    // son amount signé, buy/sell/dividend/deposit/withdrawal/interest/charge
    // portent leur effet net. Ne JAMAIS soustraire fee ici (déjà inclus).
    final amt = _parseDecimal(tx.amount);
    if (tx.amount != null && tx.amount!.trim().isNotEmpty) {
      // Bucket = devise de RÈGLEMENT (settlementCurrency), pas de cotation :
      // `amount` porte l'effet net sur les espèces DU COMPTE (design §8, option
      // A). Fallback `?? currency` = mono-devise legacy (règlement == cotation).
      // Le taux de change est un fait passé DÉJÀ figé dans `amount` — jamais
      // recalculé ici (rejeu déterministe, zéro réseau).
      final settlement = tx.settlementCurrency ?? tx.currency;
      cash[settlement] = (cash[settlement] ?? Decimal.zero) + amt;
    }

    switch (tx.kind) {
      case TransactionKind.buy:
        final q = _parseDecimal(tx.quantity);
        final p = _parseDecimal(tx.unitPrice);
        final f = _parseDecimal(tx.fee);
        // Les frais d'achat s'ajoutent à la base de coût (méthode WAC standard).
        runningQty += q;
        runningCost += (q * p + f).toRational();

      case TransactionKind.sell:
        final q = _parseDecimal(tx.quantity);
        final p = _parseDecimal(tx.unitPrice);
        final f = _parseDecimal(tx.fee);
        final proceeds = q * p - f;

        // Base de coût des titres cédés : PRU courant × quantité effective
        // (bornée au stock détenu — on ne cède pas plus qu'enregistré).
        var costBasisSold = Rational.zero;
        if (runningQty > Decimal.zero) {
          final qEff = q > runningQty ? runningQty : q;
          costBasisSold = runningCost * (qEff.toRational() / runningQty.toRational());
        }

        realized += (proceeds.toRational() - costBasisSold).toDouble();
        // Clamp ≥ 0 : ni stock ni base de coût négatifs en cas de survente.
        runningQty -= q;
        if (runningQty < Decimal.zero) runningQty = Decimal.zero;
        runningCost -= costBasisSold;
        if (runningCost < Rational.zero) runningCost = Rational.zero;

      case TransactionKind.openingBalance:
        // Position initiale déclarative : entrée type achat sans frais. Coût 0
        // si unitPrice absent (base de coût inconnue). Aucune plus-value.
        final q = _parseDecimal(tx.quantity);
        final p = _parseDecimal(tx.unitPrice);
        runningQty += q;
        runningCost += (q * p).toRational();

      case TransactionKind.adjustment:
        // Correction / inventaire : delta SIGNÉ de quantité et de coût
        // (Δcoût = q_signé × unitPrice). Pas une cession → aucune plus-value.
        // Clamp ≥ 0 sur quantité ET coût (cohérent avec la survente).
        final q = _parseDecimal(tx.quantity);
        final p = _parseDecimal(tx.unitPrice);
        runningQty += q;
        if (runningQty < Decimal.zero) runningQty = Decimal.zero;
        runningCost += (q * p).toRational();
        if (runningCost < Rational.zero) runningCost = Rational.zero;

      case TransactionKind.dividend:
        // Revenu de détention, pas une cession : n'affecte pas la position
        // titre (son effet cash est capté par la projection CASH ci-dessus).
        break;

      case TransactionKind.deposit:
      case TransactionKind.withdrawal:
      case TransactionKind.interest:
      case TransactionKind.charge:
        // Mouvements CASH purs : aucun effet sur la projection titre (leur
        // effet est capté par la projection CASH ci-dessus). Switch SANS
        // `default` : ajouter un kind force sa prise en compte explicite ici.
        break;
    }
  }

  return LedgerReplayResult(
    runningQty,
    runningCost,
    realized,
    cashByCurrency: cash,
  );
}

/// Projette une position (quantité exacte + PRU) depuis son journal.
///
/// Mêmes cas, même tri et même clamp que [computeTransactionAnalytics] — les
/// deux partagent [replayLedger] (invariant : un seul rejeu du journal).
PositionProjection projectPosition(List<AssetTransaction> txs) {
  final r = replayLedger(txs);
  return PositionProjection(r.quantity, r.averagePrice);
}

/// Vrai si le journal [txs] contient au moins un mouvement d'ANCRAGE ESPÈCES.
///
/// Sert à décider « Espèces suivies » vs « non suivies » (opt-in naturel, sans
/// réglage) : un compte ne portant que des `buy` produirait un solde espèces
/// dérivé négatif, faux et anxiogène. On n'expose donc le cash dérivé que si un
/// mouvement d'ancrage atteste que l'utilisateur suit réellement sa trésorerie.
///
/// Mouvements d'ancrage (cf. design cash-ledger §3) : `deposit`, `withdrawal`,
/// `interest`, `charge`, et `openingBalance` ESPÈCES (`symbol == null`).
/// Volontairement EXCLU : `adjustment` espèces — une simple correction ne
/// constitue pas, à elle seule, la preuve d'un suivi de trésorerie (aligné sur
/// la liste figée de la spec ; un adjustment suit toujours un ancrage réel).
///
/// Décision d'affichage pure : n'influe NI sur le calcul du cash dérivé (qui
/// reste `Σ amount`, cf. [replayLedger]) NI sur sa persistance (cache
/// reconstructible) — seulement sur sa mise en avant côté UI.
bool journalHasCashAnchor(List<AssetTransaction> txs) {
  for (final tx in txs) {
    switch (tx.kind) {
      case TransactionKind.deposit:
      case TransactionKind.withdrawal:
      case TransactionKind.interest:
      case TransactionKind.charge:
        return true;
      case TransactionKind.openingBalance:
        if (tx.symbol == null) return true;
      case TransactionKind.buy:
      case TransactionKind.sell:
      case TransactionKind.dividend:
      case TransactionKind.adjustment:
        break;
    }
  }
  return false;
}

/// Vrai si la (quantité, PRU) DÉCLARÉE correspond à la projection [proj] du
/// journal — critère d'ADOPTION AUTOMATIQUE à la restauration d'une
/// sauvegarde (cf. `AccountStorage.importRawData`).
///
/// Principe : quand la déclaration est PROUVÉE égale à la projection,
/// l'adoption (pose de `derived_at` + réécriture canonique) est
/// numériquement un no-op — exactement ce que ferait l'action manuelle
/// « Réconcilier » (D3, cas journal non vide), sans le dialogue, qui n'existe
/// que parce que la réconciliation PEUT changer les valeurs. En cas de doute
/// → `false` : la position reste legacy, déclarations intactes — jamais de
/// perte de données.
///
/// QUANTITÉ : égalité [Decimal] EXACTE via `Decimal.tryParse` (virgule
/// normalisée, trim), JAMAIS le repli « garbage → 0 » de `_parseDecimal` :
/// une quantité illisible coïncidant avec une projection nulle serait
/// adoptée puis réécrite « 0 » (destruction silencieuse). Non parsable ⇒
/// `false`.
///
/// PRU : deux `null` ⇒ égaux ; un seul `null` ⇒ différents (adopter
/// effacerait ou inventerait une base de coût déclarée) ; sinon
/// `|a−b| ≤ 1e-6·max(1,|a|,|b|)`. Le PRU est un `double` d'affichage qu'un
/// export peut avoir arrondi (jeu de démo : 6 décimales) ; la tolérance ne
/// persiste jamais d'approximation puisque l'adoption réécrit la projection
/// exacte.
bool declaredMatchesProjection(
  PositionProjection proj, {
  required String? declaredQuantity,
  required double? declaredAveragePrice,
}) {
  if (declaredQuantity == null) return false;
  final qty = Decimal.tryParse(declaredQuantity.replaceAll(',', '.').trim());
  if (qty == null || qty != proj.quantity) return false;
  final a = declaredAveragePrice;
  final b = proj.averagePrice;
  if (a == null || b == null) return a == null && b == null;
  final tol = 1e-6 * [1.0, a.abs(), b.abs()].reduce(math.max);
  return (a - b).abs() <= tol;
}

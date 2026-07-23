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
// buy / sell / openingBalance / adjustment / transferOut. dividend / deposit /
// withdrawal / interest / charge sont ignorés par la projection titre.
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

/// Point de rupture du rejeu du journal — état APRÈS UN mouvement, dans
/// l'ordre chronologique (cf. [replayLedger], paramètre `onStep`).
///
/// Sert de brique pure aux timelines en escalier (mode 2 « évolution réelle
/// du patrimoine », B7) : ne réimplémente AUCUNE arithmétique, ne fait que
/// RESTITUER l'état déjà calculé par le fold unique de [replayLedger] (cf.
/// design §11.3 — l'émission est ajoutée SANS toucher au switch ni aux
/// clamps, invariant « un seul rejeu » préservé).
class LedgerStep {
  final DateTime date;
  final String? symbol;
  final TransactionKind kind;

  /// Delta de quantité EFFECTIVEMENT appliqué par ce mouvement, APRÈS clamp
  /// (= `runningQty` après − `runningQty` avant CE mouvement). Une survente
  /// (ex. `transferOut` de 10 alors que 6 sont détenus) émet `-6`, PAS `-10` —
  /// c'est l'effet réel sur le patrimoine, pas la déclaration brute (design
  /// §11.2 M2).
  final Decimal deltaQty;

  /// Quantité détenue après ce mouvement (post-clamp).
  final Decimal qtyAfter;

  /// Devise de RÈGLEMENT de ce mouvement (`settlementCurrency ?? currency` —
  /// cf. [AssetTransaction.settlementCurrency]).
  final String settlementCurrency;

  /// Effet net signé sur le cash de [settlementCurrency] pour CE mouvement
  /// (= `amount` parsé ; `0` si `amount` absent/vide).
  final Decimal deltaCash;

  /// État cash par devise après ce mouvement — COPIE DÉFENSIVE immuable. La
  /// map interne du fold ([replayLedger]) est mutée en place à chaque
  /// itération : sans cette copie, tous les steps émis aliaseraient l'état
  /// FINAL du rejeu (piège §11.3 m2).
  final Map<String, Decimal> cashAfter;

  const LedgerStep({
    required this.date,
    required this.symbol,
    required this.kind,
    required this.deltaQty,
    required this.qtyAfter,
    required this.settlementCurrency,
    required this.deltaCash,
    required this.cashAfter,
  });
}

/// Rejoue le journal EN UN SEUL passage (unique switch sur [TransactionKind]).
///
/// Maintient simultanément : la quantité exacte ([Decimal]), la base de coût
/// exacte ([Rational], division WAC comprise) et la plus-value réalisée
/// (`double`). C'est le cœur anti-divergence : tout autre calcul dérivé
/// (projection de position, analytics d'affichage) passe par ici.
///
/// [onStep], si fourni, est appelé UNE FOIS PAR MOUVEMENT rejoué (ordre
/// chronologique), APRÈS application au running state — [LedgerStep.qtyAfter]
/// et [LedgerStep.cashAfter] reflètent donc le clamp déjà appliqué. Callback
/// pur d'observation : ne modifie NI le switch NI les clamps existants, donc
/// `onStep == null` laisse le comportement et la valeur de retour STRICTEMENT
/// identiques à avant son introduction (aucune régression — cf. design §11.3).
LedgerReplayResult replayLedger(
  List<AssetTransaction> txs, {
  void Function(LedgerStep step)? onStep,
}) {
  var runningQty = Decimal.zero; // quantité détenue courante (exacte)
  var runningCost = Rational.zero; // base de coût totale (exacte)
  var realized = 0.0; // plus-value réalisée cumulée
  final cash = <String, Decimal>{}; // Σ amount signé, par devise (exact)

  if (txs.isEmpty) {
    return LedgerReplayResult(runningQty, runningCost, realized);
  }

  // Tri chronologique CANONIQUE : date croissante, puis séquence de fichier
  // (`meta['seq']`) pour les mouvements importés — départage intraday FIABLE —,
  // sinon repli sur id (saisies manuelles). Voir
  // [AssetTransaction.compareChronological] : trier sur id SEUL rendait l'ordre
  // intraday arbitraire (id aléatoire à l'import) et faisait disparaître des
  // titres sur les allers-retours d'un même jour via le clamp anti-survente.
  final sorted = List<AssetTransaction>.from(txs)
    ..sort(AssetTransaction.compareChronological);

  for (final tx in sorted) {
    // PROJECTION CASH (partition stricte : lit UNIQUEMENT amount). Kind-agnostic
    // et sign-agnostic : Σ amount par devise, null = 0, aucun clamp. Placée HORS
    // du switch titre car uniforme sur tous les kinds — un openingBalance /
    // adjustment TITRE a amount=null (contribue 0), une variante espèces porte
    // son amount signé, buy/sell/dividend/deposit/withdrawal/interest/charge
    // portent leur effet net. Ne JAMAIS soustraire fee ici (déjà inclus).
    final amt = _parseDecimal(tx.amount);
    // Bucket = devise de RÈGLEMENT (settlementCurrency), pas de cotation :
    // `amount` porte l'effet net sur les espèces DU COMPTE (design §8, option
    // A). Fallback `?? currency` = mono-devise legacy (règlement == cotation).
    // Le taux de change est un fait passé DÉJÀ figé dans `amount` — jamais
    // recalculé ici (rejeu déterministe, zéro réseau). Calculé
    // inconditionnellement (coût négligeable) pour être réutilisable par
    // [onStep] même sur un mouvement sans `amount` (ex. buy/sell titre).
    final settlement = tx.settlementCurrency ?? tx.currency;
    if (tx.amount != null && tx.amount!.trim().isNotEmpty) {
      cash[settlement] = (cash[settlement] ?? Decimal.zero) + amt;
    }

    // Capture AVANT le switch — sert uniquement à calculer le delta EFFECTIF
    // (post-clamp) pour [onStep] ; ne participe à AUCUN calcul du switch.
    final qtyBeforeStep = runningQty;

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

      case TransactionKind.transferOut:
        // SORTIE DE TITRES SANS CESSION (transfert PEA→CTO, virement sortant).
        // Emporte la base de coût AU PRORATA du WAC courant — donc le PRU des
        // titres RESTANTS est inchangé (mêmes facteurs qty et coût), comme la
        // jambe coût d'une vente — MAIS ne réalise AUCUNE plus-value (un
        // transfert n'est pas une cession) et n'a AUCUN effet cash (amount=null,
        // capté à 0 par la projection CASH ci-dessus). Clamp ≥ 0 identique à la
        // survente : ni stock ni base de coût négatifs si le journal est partiel.
        final q = _parseDecimal(tx.quantity);
        var costBasisRemoved = Rational.zero;
        if (runningQty > Decimal.zero) {
          final qEff = q > runningQty ? runningQty : q;
          costBasisRemoved =
              runningCost * (qEff.toRational() / runningQty.toRational());
        }
        runningQty -= q;
        if (runningQty < Decimal.zero) runningQty = Decimal.zero;
        runningCost -= costBasisRemoved;
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

    if (onStep != null) {
      final hasAmount = tx.amount != null && tx.amount!.trim().isNotEmpty;
      onStep(LedgerStep(
        date: tx.date,
        symbol: tx.symbol,
        kind: tx.kind,
        deltaQty: runningQty - qtyBeforeStep,
        qtyAfter: runningQty,
        settlementCurrency: settlement,
        deltaCash: hasAmount ? amt : Decimal.zero,
        cashAfter: Map<String, Decimal>.unmodifiable(cash),
      ));
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

// ─────────────────────────────────────────────────────────────────────────────
// TIMELINES EN ESCALIER (mode 2 « évolution réelle du patrimoine », B7 —
// design doc 18 §2/§11.3) : constructeurs PURS bâtis SUR [replayLedger] +
// `onStep`, ZÉRO logique arithmétique par kind ajoutée ici. Un seul rejeu du
// journal (invariant de tête de fichier) alimente ces deux escaliers.
// ─────────────────────────────────────────────────────────────────────────────

/// Normalise une [DateTime] en DATE-ONLY UTC (tronque heure/minute/seconde et
/// fuseau) — indispensable pour coalescer les breakpoints du journal (horaire
/// variable) avec des séries de prix journalières (design §11.5 m3 : sans
/// cette normalisation, des décalages ±1 jour apparaissent aux frontières).
DateTime _dateOnlyUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Recherche dichotomique du dernier index `i` tel que `dateAt(i) <= target`
/// (les dates doivent être triées croissantes). `-1` si [target] est
/// antérieur à toutes ([length] == 0 y compris).
int _lastIndexAtOrBefore(
  int length,
  DateTime Function(int i) dateAt,
  DateTime target,
) {
  var lo = 0;
  var hi = length - 1;
  var ans = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (!dateAt(mid).isAfter(target)) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}

/// Escalier de quantité détenue, COALESCÉ PAR DATE (date-only UTC — dernier
/// état de clôture du jour). Trié par date croissante. Vide si [txs] est vide.
///
/// Coalescence : [replayLedger] appelle `onStep` dans l'ordre chronologique
/// canonique ([AssetTransaction.compareChronological]) — pour une même date,
/// la dernière écriture dans la map l'emporte, ce qui restitue exactement le
/// bon état de clôture (un aller-retour intraday se referme, cf. design §11.3).
List<({DateTime date, Decimal qtyAfter})> buildQuantityTimeline(
  List<AssetTransaction> txs,
) {
  if (txs.isEmpty) return const [];
  final byDate = <DateTime, Decimal>{};
  replayLedger(
    txs,
    onStep: (step) => byDate[_dateOnlyUtc(step.date)] = step.qtyAfter,
  );
  final dates = byDate.keys.toList()..sort();
  return [for (final d in dates) (date: d, qtyAfter: byDate[d]!)];
}

/// Escalier de cash PAR DEVISE DE RÈGLEMENT, coalescé par date (mêmes règles
/// que [buildQuantityTimeline]). Rejoue TOUT le journal fourni (typiquement le
/// journal complet d'un COMPTE — le cash n'a de sens qu'à cette granularité,
/// cf. tête de fichier [LedgerReplayResult.cashByCurrency]).
List<({DateTime date, Map<String, Decimal> cashAfter})> buildCashTimeline(
  List<AssetTransaction> txs,
) {
  if (txs.isEmpty) return const [];
  final byDate = <DateTime, Map<String, Decimal>>{};
  replayLedger(
    txs,
    onStep: (step) => byDate[_dateOnlyUtc(step.date)] = step.cashAfter,
  );
  final dates = byDate.keys.toList()..sort();
  return [for (final d in dates) (date: d, cashAfter: byDate[d]!)];
}

/// Quantité détenue à la date [d] selon l'escalier [timeline] (recherche
/// dichotomique du dernier palier ≤ [d], en date-only UTC). [Decimal.zero]
/// avant le premier palier ou si [timeline] est vide.
Decimal quantityAt(
  List<({DateTime date, Decimal qtyAfter})> timeline,
  DateTime d,
) {
  final target = _dateOnlyUtc(d);
  final idx =
      _lastIndexAtOrBefore(timeline.length, (i) => timeline[i].date, target);
  return idx < 0 ? Decimal.zero : timeline[idx].qtyAfter;
}

/// Cash par devise à la date [d] selon l'escalier [timeline] (même recherche
/// que [quantityAt]). Map VIDE avant le premier palier ou si [timeline] est
/// vide (aucun mouvement cash connu à cette date ≡ toutes devises à 0).
Map<String, Decimal> cashAt(
  List<({DateTime date, Map<String, Decimal> cashAfter})> timeline,
  DateTime d,
) {
  final target = _dateOnlyUtc(d);
  final idx =
      _lastIndexAtOrBefore(timeline.length, (i) => timeline[i].date, target);
  return idx < 0 ? const {} : timeline[idx].cashAfter;
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
      case TransactionKind.transferOut:
        break;
    }
  }
  return false;
}

/// Vrai si le PRU (prix de revient unitaire) d'une position est éditable
/// directement (action « Corriger le PRU… »), selon sa nature (modèle B*) :
///
///   - LEGACY ([isLegacy] vrai, `derived_at` NULL) : toujours éditable — un tel
///     journal est garanti vide (tout mouvement journalisé aurait posé
///     `derived_at` via la reprojection du ledger), donc rien à corrompre.
///   - JOURNALISÉE (`derived_at` non NULL) : éditable seulement si son journal
///     [txs] n'est PAS vide (un journal vide correspond à l'action « définir
///     la position initiale », distincte) ET ne contient AUCUN vrai trade
///     (`buy`/`sell`). Sur un vrai trade, le PRU est une moyenne pondérée
///     dérivée : l'écraser à la main serait faux.
bool canEditPru({required bool isLegacy, required List<AssetTransaction> txs}) {
  if (isLegacy) return true;
  if (txs.isEmpty) return false;
  return !txs.any(
    (t) => t.kind == TransactionKind.buy || t.kind == TransactionKind.sell,
  );
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

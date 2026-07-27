// lib/logic/history_aggregator.dart

import 'dart:math';

import 'package:decimal/decimal.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/utils/logger.dart';

/// Normalise une [DateTime] en DATE-ONLY UTC — RÉPLIQUE volontaire de
/// l'utilitaire privé homonyme de `position_projection.dart` (inaccessible
/// depuis ce fichier : underscore = privé à la LIBRARY, pas au dossier).
/// Sert uniquement à coalescer les breakpoints de [HistoryAggregator.
/// buildExternalFlowsCurve] par jour, exactement comme
/// [buildQuantityTimeline]/[buildCashTimeline] le font pour leurs propres
/// escaliers. Ne PAS appliquer à [AssetHistoricalData.dates] (déjà
/// journalier, cf. design §11.5 m3).
DateTime _dateOnlyUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Résultat de [HistoryAggregator.aggregateGlobalHistoricalData].
typedef GlobalAggregationResult = ({
  List<DateTime> chartDates,
  List<double> chartValues,
  double? periodStartValue,
  double? periodEndValue,
  double? periodChange,
  double? periodChangePercent,
});

/// Résultat de [HistoryAggregator.aggregateHistoricalData].
typedef AccountAggregationResult = ({
  List<DateTime> dates,
  List<double> values,
  double? startValue,
  double? endValue,
  double? change,
  double? changePercent,
});

/// Résultat de [HistoryAggregator.computeAccountsPeriodChanges].
typedef AccountsPeriodChangesResult = ({
  Map<String, double> accountPeriodChanges,
  Map<String, double> accountPeriodChangePercents,
});

/// Résultat de [HistoryAggregator.computeRealGains] — le gain sur la
/// PÉRIODE affichée SEUL (B7 lot correction financière) : performance de
/// MARCHÉ pendant la fenêtre, isolée des flux externes (apports/retraits/
/// entrées-sorties de titres). Le gain TOTAL (état courant, base coût,
/// indépendant de la fenêtre) est un calcul SÉPARÉ — voir [RealTotalGain] /
/// [HistoryAggregator.computeRealTotalGain] — les deux ne sont PAS
/// substituables (méthodes différentes : flux valorisés au jour du flux ici,
/// base de coût là-bas ; l'écart entre les deux est assumé, cf. design
/// doc 18, décision « divergence assumée »).
/// Tous les champs sont `double?` : `null` = non calculable (garde-fous
/// documentés sur [HistoryAggregator.computeRealGains]), jamais un zéro
/// arbitraire qui laisserait croire à une absence de gain.
class RealGains {
  const RealGains({
    this.periodGain,
    this.periodGainPercent,
    this.isAnnualized = false,
  });

  /// Instance neutre — tous les champs `null` (cf. gardes de
  /// [HistoryAggregator.computeRealGains] : tailles incohérentes/vides/
  /// fenêtre < 2 points).
  static const RealGains empty = RealGains();

  final double? periodGain;

  /// Valeur À AFFICHER — cumulée (Modified Dietz brut) OU annualisée selon
  /// [isAnnualized] (cf. [HistoryAggregator.computeRealGains], règle des
  /// 2 ans). JAMAIS deux champs distincts : l'appelant n'a qu'un seul nombre
  /// à formater, [isAnnualized] ne fait qu'ajouter le suffixe « /an » côté UI.
  final double? periodGainPercent;

  /// `true` si [periodGainPercent] a été ANNUALISÉ (fenêtre ≥ 2 ans, cf.
  /// [HistoryAggregator.computeRealGains]) — l'UI doit alors suffixer « /an ».
  /// `false` par défaut : cumulé tel quel (fenêtre courte, ou garde `1+r<=0`/
  /// `years<=0` déclenchée).
  final bool isAnnualized;
}

/// Résultat de [HistoryAggregator.computeRealTotalGain] — gain TOTAL en
/// ÉTAT COURANT (voie b, base coût), INDÉPENDANT de la fenêtre affichée :
/// contrairement à [RealGains.periodGain] (dérivé de la courbe §11.4), ce
/// calcul ne rejoue aucune courbe datée — il agrège directement la
/// plus-value latente des positions, la plus-value réalisée des ventes et
/// les revenus (dividendes/intérêts/frais) depuis l'origine du journal.
class RealTotalGain {
  const RealTotalGain({
    this.totalGain,
    this.totalGainPercent,
    this.noBasisSymbols = const {},
  });

  /// Instance neutre — aucun symbole en base connue, gains `null`.
  static const RealTotalGain empty = RealTotalGain();

  final double? totalGain;
  final double? totalGainPercent;

  /// Symboles dont la base de coût (PRU) est inconnue — EXCLUS du calcul
  /// (numérateur ET dénominateur, cf. [HistoryAggregator.computeRealTotalGain])
  /// plutôt que silencieusement comptés pour zéro. Destiné à un avertissement
  /// UI (« performance partielle », design §Lot C).
  final Set<String> noBasisSymbols;
}

/// Agrégation de données historiques. Toutes les méthodes sont statiques et
/// pures : aucun accès à l'état d'un widget, aucun I/O.
class HistoryAggregator {
  HistoryAggregator._(); // classe non instanciable

  // ---------------------------------------------------------------------------
  // Recherche de l'index le plus proche — DEUX variantes aux comportements
  // distincts aux bornes. NE PAS fusionner : wallet_view et account_view
  // utilisent chacun leur propre variante.
  // ---------------------------------------------------------------------------

  /// Version de wallet_view : AVEC gardes aux bornes.
  ///
  /// Si [target] est avant la première date, retourne 0.
  /// Si [target] est après la dernière date, retourne [dates.length - 1].
  /// Sinon, retourne l'indice de la date la plus proche.
  static int findNearestIndexBounded(List<DateTime> dates, DateTime target) {
    if (dates.isEmpty) return -1;
    if (target.isBefore(dates.first)) return 0;
    if (target.isAfter(dates.last)) return dates.length - 1;

    int closestIndex = 0;
    DateTime closestDate = dates[0];

    for (int i = 0; i < dates.length; i++) {
      final diff = dates[i].difference(target).abs();
      final closestDiff = closestDate.difference(target).abs();

      if (diff < closestDiff) {
        closestDate = dates[i];
        closestIndex = i;
      }
    }
    return closestIndex;
  }

  /// Version de account_view : SANS gardes aux bornes.
  ///
  /// Retourne toujours l'indice de la date la plus proche, même si [target]
  /// est avant la première ou après la dernière date.
  /// Comportement aux bornes identique à findNearestIndexBounded pour les
  /// dates dans la plage, mais sans le clamp précoce pour les dates hors plage.
  static int findNearestIndexUnbounded(List<DateTime> dates, DateTime target) {
    if (dates.isEmpty) return -1;

    int closestIndex = 0;
    DateTime closestDate = dates[0];

    for (int i = 0; i < dates.length; i++) {
      if (dates[i].difference(target).abs().compareTo(closestDate.difference(target).abs()) < 0) {
        closestDate = dates[i];
        closestIndex = i;
      }
    }

    return closestIndex;
  }

  // ---------------------------------------------------------------------------
  // Agrégation globale (wallet_view : _aggregateGlobalHistoricalData)
  // ---------------------------------------------------------------------------

  /// Agrège les données historiques de tous les symboles du patrimoine en une
  /// seule série temporelle EUR.
  ///
  /// - [symbolToData] : map symbole → données historiques.
  /// - [allPositionsData] : toutes les positions avec données de marché.
  /// - [cashBalances] : map accountId → solde cash EN EUR (constant sur toutes
  ///   les dates).
  /// - [usdToEurRate] : taux de change USD→EUR courant.
  ///
  /// Retourne un [GlobalAggregationResult]. Si aucune date historique n'est
  /// disponible, chartDates et chartValues sont vides et les valeurs de période
  /// sont null.
  static GlobalAggregationResult aggregateGlobalHistoricalData({
    required Map<String, AssetHistoricalData?> symbolToData,
    required List<PositionWithMarketData> allPositionsData,
    required Map<String, double> cashBalances,
    required double usdToEurRate,
  }) {
    final allDates = <DateTime>{};
    for (final data in symbolToData.values) {
      if (data != null && !data.isEmpty) {
        allDates.addAll(data.dates);
      }
    }

    if (allDates.isEmpty) {
      return (
        chartDates: <DateTime>[],
        chartValues: <double>[],
        periodStartValue: null,
        periodEndValue: null,
        periodChange: null,
        periodChangePercent: null,
      );
    }

    final sortedDates = allDates.toList()..sort();
    final dateValues = <DateTime, double>{};

    for (final targetDate in sortedDates) {
      double totalValueEur = 0;

      // Ajouter les soldes cash (constants pour chaque date)
      for (final cashBalance in cashBalances.values) {
        totalValueEur += cashBalance;
      }

      for (final positionData in allPositionsData) {
        final symbol = positionData.symbol;
        final historicalData = symbolToData[symbol];

        if (historicalData != null && !historicalData.isEmpty) {
          final index = findNearestIndexBounded(historicalData.dates, targetDate);

          if (index != -1) {
            final quantity = double.tryParse(positionData.quantity) ?? 0;
            double price = historicalData.prices[index].toDouble();

            if (positionData.asset.currency.toUpperCase() == 'USD') {
              price = price * usdToEurRate;
            }

            totalValueEur += price * quantity;
          }
        }
      }

      dateValues[targetDate] = totalValueEur;
    }

    final chartDates = dateValues.keys.toList()..sort();
    final chartValues = chartDates.map((date) => dateValues[date] ?? 0).toList();

    double? periodStartValue;
    double? periodEndValue;
    double? periodChange;
    double? periodChangePercent;

    if (chartValues.isNotEmpty) {
      periodStartValue = chartValues.first;
      periodEndValue = chartValues.last;
      periodChange = periodEndValue - periodStartValue;
      periodChangePercent = periodStartValue != 0
          ? (periodChange / periodStartValue) * 100
          : 0.0;
    }

    return (
      chartDates: chartDates,
      chartValues: chartValues,
      periodStartValue: periodStartValue,
      periodEndValue: periodEndValue,
      periodChange: periodChange,
      periodChangePercent: periodChangePercent,
    );
  }

  // ---------------------------------------------------------------------------
  // Reconstruction réelle (mode 2 — B7, design doc 18) : PURE, sans I/O.
  // ---------------------------------------------------------------------------

  /// Reconstruit la valeur du patrimoine (EUR) DATE PAR DATE depuis le journal
  /// — mode 2 « évolution réelle », par opposition à [aggregateGlobalHistoricalData]
  /// (mode 1) qui rétroprojette les quantités et le cash ACTUELS sur le passé.
  ///
  /// Pour chaque date de [gridDates] : `Σ_symbole qtyDétenue(sym,D) × prix(sym,D)
  /// × fx + Σ_compte cashProjeté(compte,D) × fx` (design §1). Les timelines
  /// ([buildQuantityTimeline]/[buildCashTimeline]) sont bâties UNE SEULE FOIS
  /// hors de la boucle des dates (perf — O(dates × symboles × log n)).
  ///
  /// - [txsBySymbol] : journal PAR SYMBOLE, positions JOURNALISÉES uniquement
  ///   (`derived_at` non NULL) — les positions legacy (journal garanti vide,
  ///   cf. `position_projection.dart`) s'évaporeraient silencieusement du
  ///   calcul ; leur exclusion est actée en amont par l'appelant (design §11.1
  ///   / §11.6, décision produit B1 : mode 2 les exclut explicitement).
  /// - [txsByAccount] : journal COMPLET par compte (tous symboles + cash pur),
  ///   nécessaire pour projeter le cash — un symbole seul ne suffit pas (le
  ///   cash n'a de sens qu'à la granularité du compte, cf.
  ///   `position_projection.dart:100-102`).
  /// - Gating [journalHasCashAnchor] (design §11.2 M1) : le cash d'un compte
  ///   n'est injecté QUE s'il porte un mouvement d'ancrage — sinon un compte
  ///   ne portant que des `buy` produirait un cash négatif FICTIF.
  /// - Un symbole sans donnée de prix (`symbolToData[sym]` null/vide) contribue
  ///   `0` pour l'instant : le repli « dernier cours connu » (titres délistés)
  ///   est le Lot 2 (design §4), PAS ce lot — point d'extension volontairement
  ///   laissé ici (voir le commentaire dans la boucle).
  /// - Change : taux COURANT (v1 assumée, design §6) — USD converti via
  ///   [usdToEurRate], toute autre devise non-EUR inchangée (même compromis
  ///   que le mode 1, qui ne gère que l'USD).
  ///
  /// Prix EUR d'UN symbole à UNE date — helper PARTAGÉ entre
  /// [reconstructRealNetWorth] (prix « aujourd'hui-relatif » de chaque
  /// symbole détenu) et [buildExternalFlowsCurve] (prix AU JOUR DU FLUX pour
  /// valoriser une entrée/sortie de titres, design §11.4). Recherche du prix
  /// via [findNearestIndexBounded] (même variante que le reste du mode 2,
  /// clampée aux bornes de [data]) ; conversion USD→EUR via [usdToEurRate] si
  /// [asset] cote en USD. `0.0` si [data] est `null`/vide (pas d'historique
  /// exploitable pour ce symbole à cette date — cf. repli « dernier cours »,
  /// géré en amont par l'appelant via [buildLastPriceFallback], PAS ici).
  static double priceEurAt(
    AssetHistoricalData? data,
    Asset? asset,
    DateTime d,
    double usdToEurRate,
  ) {
    if (data == null || data.isEmpty) return 0.0;
    final idx = findNearestIndexBounded(data.dates, d);
    if (idx == -1) return 0.0;
    var price = data.prices[idx].toDouble();
    if (asset != null && asset.isUsd) {
      price *= usdToEurRate;
    }
    return price;
  }

  static ({List<DateTime> dates, List<double> values}) reconstructRealNetWorth({
    required Map<String, List<AssetTransaction>> txsBySymbol,
    required Map<String, List<AssetTransaction>> txsByAccount,
    required Map<String, AssetHistoricalData?> symbolToData,
    required Map<String, Asset> assetBySymbol,
    required double usdToEurRate,
    required List<DateTime> gridDates,
  }) {
    if (gridDates.isEmpty) {
      return (dates: <DateTime>[], values: <double>[]);
    }

    // Timelines titres : une par symbole, pré-construites hors boucle.
    final qtyTimelines = <String, List<({DateTime date, Decimal qtyAfter})>>{};
    for (final entry in txsBySymbol.entries) {
      qtyTimelines[entry.key] = buildQuantityTimeline(entry.value);
    }

    // Timelines cash : une par compte ANCRÉ seulement (gating M1) — un compte
    // non ancré est simplement absent de la map, donc ignoré dans la boucle.
    final cashTimelines =
        <String, List<({DateTime date, Map<String, Decimal> cashAfter})>>{};
    for (final entry in txsByAccount.entries) {
      if (journalHasCashAnchor(entry.value)) {
        cashTimelines[entry.key] = buildCashTimeline(entry.value);
      }
    }

    final values = <double>[];
    for (final d in gridDates) {
      double totalEur = 0;

      // Titres.
      for (final symbol in txsBySymbol.keys) {
        final qty = quantityAt(qtyTimelines[symbol]!, d);
        if (qty <= Decimal.zero) continue; // soldé à cette date (§8.5)

        // priceEurAt renvoie 0.0 si data null/vide (pas d'historique
        // exploitable pour ce symbole à cette date) — comportement IDENTIQUE
        // au `continue` précédent (ni l'un ni l'autre n'ajoutent de valeur),
        // itéré en un seul appel plutôt qu'un lookup inline dupliqué avec
        // buildExternalFlowsCurve. Repli « dernier cours connu » (titres
        // délistés) reste géré en amont par l'appelant via
        // [buildLastPriceFallback], pas ici.
        final price = priceEurAt(
          symbolToData[symbol],
          assetBySymbol[symbol],
          d,
          usdToEurRate,
        );
        totalEur += price * qty.toDouble();
      }

      // Cash (gating M1 déjà appliqué à la construction des timelines).
      for (final cashTimeline in cashTimelines.values) {
        final byCurrency = cashAt(cashTimeline, d);
        for (final entry in byCurrency.entries) {
          final amount = entry.value.toDouble();
          totalEur +=
              entry.key.toUpperCase() == 'USD' ? amount * usdToEurRate : amount;
        }
      }

      values.add(totalEur);
    }

    return (dates: gridDates, values: values);
  }

  // ---------------------------------------------------------------------------
  // Repli « dernier cours » + composition cash pur (mode 2, B7 Lot 2 — design
  // doc 18 §4/§11.5 m1). PUR, sans I/O — extrait de wallet_controller pour
  // rester testable unitairement (le reste du Lot 2 est de la glue réseau).
  // ---------------------------------------------------------------------------

  /// Synthétise une [AssetHistoricalData] PLATE (deux points, prix constant) au
  /// « dernier cours connu » pour un symbole SANS historique de prix (titre
  /// délisté/irrésolu, ou fetch en échec) mais DÉTENU à au moins une date de
  /// [gridDates] — sans ce repli, [reconstructRealNetWorth] contribuerait `0`
  /// pour ce symbole alors qu'il pesait réellement dans le patrimoine (design
  /// §4 : jamais d'exclusion silencieuse).
  ///
  /// Source du dernier cours : [AssetTransaction.unitPrice] du dernier
  /// `buy`/`sell` de ce symbole (ordre chronologique CANONIQUE,
  /// [AssetTransaction.compareChronological]), à défaut `0`. C'est un PRU, pas
  /// un cours de marché — biais assumé et à SIGNALER (repli « approché »,
  /// design §11.5 m1) : l'appelant doit flagger [symbol] dans
  /// `realCurveApproxSymbols` quand ce repli est utilisé (retour non-null).
  ///
  /// Retourne `null` si [symbol] n'est jamais détenu sur la fenêtre (pas
  /// besoin de repli — le symbole contribue légitimement `0` partout, aucun
  /// signal « approché » à afficher) ou si [gridDates] est vide.
  static AssetHistoricalData? buildLastPriceFallback({
    required String symbol,
    required List<AssetTransaction> txs,
    required List<DateTime> gridDates,
  }) {
    if (gridDates.isEmpty) return null;

    final timeline = buildQuantityTimeline(txs);
    final heldOnWindow =
        gridDates.any((d) => quantityAt(timeline, d) > Decimal.zero);
    if (!heldOnWindow) return null;

    final priced = txs
        .where(
          (t) =>
              (t.kind == TransactionKind.buy ||
                  t.kind == TransactionKind.sell) &&
              t.unitPrice != null &&
              t.unitPrice!.trim().isNotEmpty,
        )
        .toList()
      ..sort(AssetTransaction.compareChronological);
    final lastPrice = priced.isEmpty
        ? 0.0
        : double.tryParse(priced.last.unitPrice!.replaceAll(',', '.').trim()) ??
              0.0;

    return AssetHistoricalData(
      symbol: symbol,
      dates: [gridDates.first, gridDates.last],
      prices: [lastPrice, lastPrice],
    );
  }

  /// Ajoute un cash PUR (comptes `AccountType.cash`, sans journal — hors
  /// périmètre de [reconstructRealNetWorth]) en CONSTANTE à chaque valeur
  /// d'une série mode 2 déjà composée. Fonction À PART : le cash DÉRIVÉ des
  /// comptes non-cash est DÉJÀ dans [values] (calculé par
  /// [reconstructRealNetWorth] via `txsByAccount`, gating M1 inclus) — ne
  /// JAMAIS le recalculer/rajouter ici, sous peine de double-comptage (design
  /// Lot 2 §4, piège documenté en tête de `position_projection.dart`).
  static List<double> addConstantPureCash(
    List<double> values,
    double pureCashEur,
  ) {
    if (pureCashEur == 0) return values;
    return [for (final v in values) v + pureCashEur];
  }

  // ---------------------------------------------------------------------------
  // Courbe des apports nets (mode 2, B7 Lot 3b — design doc 18 §7.2/§11.4) :
  // superposée à la courbe de valeur, l'écart vertical visualise le gain.
  // ---------------------------------------------------------------------------

  /// Courbe des APPORTS NETS CUMULÉS (versements − retraits d'espèces)
  /// dérivée du journal, en EUR, échantillonnée sur [gridDates] (alignée
  /// index-par-index avec elle, même contrat que [reconstructRealNetWorth]).
  ///
  /// Seuls les mouvements `deposit`/`withdrawal` de tous les comptes de
  /// [txsByAccount] comptent — décision produit actée (design §7.2/§11.4) :
  /// apports = cash PUR, pas la base flux complète de la décomposition
  /// flux/perf (qui inclurait aussi `openingBalance`/`transferOut`/
  /// `adjustment`). `amount` est déjà SIGNÉ (dépôt > 0, retrait < 0) : on
  /// somme, exactement le cumul voulu.
  ///
  /// Réutilise les briques du cœur pur DÉJÀ testées, sans réécrire de fold :
  /// [buildCashTimeline] sur le sous-ensemble filtré (coalescé par date de
  /// règlement, même sémantique que le cash projeté de
  /// [reconstructRealNetWorth]), puis [cashAt] par date de la grille.
  ///
  /// Change : même compromis v1 que le reste du mode 2 (§6) — USD converti via
  /// [usdToEurRate] au taux COURANT, toute autre devise non-EUR inchangée
  /// (1:1). `0.0` avant le premier flux (aucune poche connue, [cashAt] renvoie
  /// une map vide).
  ///
  /// Le cash PUR (comptes `AccountType.cash`, sans journal) est HORS
  /// périmètre ici — à composer en aval par l'appelant via
  /// [addConstantPureCash], exactement comme pour la courbe de valeur (même
  /// constante, pour qu'elle s'annule dans l'écart valeur−apports).
  static List<double> buildContributionsCurve({
    required Map<String, List<AssetTransaction>> txsByAccount,
    required List<DateTime> gridDates,
    required double usdToEurRate,
  }) {
    if (gridDates.isEmpty) return <double>[];

    final flows = <AssetTransaction>[
      for (final txs in txsByAccount.values)
        for (final tx in txs)
          if (tx.kind == TransactionKind.deposit ||
              tx.kind == TransactionKind.withdrawal)
            tx,
    ];

    final timeline = buildCashTimeline(flows);

    final values = <double>[];
    for (final d in gridDates) {
      final byCurrency = cashAt(timeline, d);
      double totalEur = 0;
      for (final entry in byCurrency.entries) {
        final amount = entry.value.toDouble();
        totalEur +=
            entry.key.toUpperCase() == 'USD' ? amount * usdToEurRate : amount;
      }
      values.add(totalEur);
    }

    return values;
  }

  // ---------------------------------------------------------------------------
  // Courbe des flux externes complets (B7 correction financière, design §11.4)
  // : superposée à la courbe de valeur (remplace [buildContributionsCurve] à
  // cet usage — cf. wallet_controller/account_controller), ET base du calcul
  // Modified Dietz de [computeRealGains]. PUR, sans I/O.
  // ---------------------------------------------------------------------------

  /// Courbe des FLUX EXTERNES CUMULÉS (design §11.4), en EUR, échantillonnée
  /// sur [gridDates] (alignée index-par-index, même contrat que
  /// [reconstructRealNetWorth]). Remplace [buildContributionsCurve] pour la
  /// courbe superposée ET pour [computeRealGains] : contrairement à cette
  /// dernière (cash pur uniquement), elle capture TOUS les flux qui entrent/
  /// sortent du patrimoine SANS être une performance de marché — dépôts/
  /// retraits d'espèces ET entrées/sorties de titres à un prix figé (position
  /// initiale déclarée, ajustement/correction, sortie sans cession), chacune
  /// valorisée au COURS DU JOUR DU FLUX (pas le cours actuel).
  ///
  /// Deux briques sommées index-par-index (partition stricte, cf. en-tête
  /// `position_projection.dart` — chaque mouvement ne contribue QU'À une
  /// seule des deux, jamais aux deux ni à aucune) :
  ///
  /// (a) FLUX CASH : [deposit]/[withdrawal] (tous), et [openingBalance]/
  /// [adjustment] à `symbol == null` (variante ESPÈCES). EXCLUS : `dividend`/
  /// `interest`/`charge` (performance, pas capital) et `buy`/`sell` (la jambe
  /// cash n'est qu'un TRANSFERT INTERNE vers la jambe titre, contribution
  /// nette 0 — la sommer serait un double-comptage avec (b)). Réutilise
  /// [buildCashTimeline]/[cashAt], même sémantique que
  /// [buildContributionsCurve].
  ///
  /// (b) FLUX TITRE : pour chaque symbole, [replayLedger] avec `onStep` —
  /// seuls [openingBalance]/[adjustment]/[transferOut] À `symbol != null`
  /// contribuent, valorisés à `step.deltaQty × prix(sym, step.date)`
  /// ([priceEurAt] sur [symbolToData], DÉJÀ post-repli « dernier cours » —
  /// c'est la responsabilité de l'appelant, cf. [buildLastPriceFallback]).
  /// `deltaQty` est le delta EFFECTIF post-clamp (cf. [LedgerStep]) : un
  /// `transferOut` partiellement clampé (stock insuffisant) contribue son
  /// effet RÉEL, pas la quantité déclarée. `buy`/`sell` sont EXCLUS ici aussi
  /// (même raison qu'en (a) : transfert interne, contribution nette 0 — seuls
  /// les FRAIS d'un achat/vente pèsent, et ils pèsent déjà dans [values] via
  /// la base de coût/le prix, jamais dans cette courbe de flux).
  ///
  /// Les contributions titre sont accumulées PAR DATE (date-only UTC, comme
  /// [buildQuantityTimeline]) puis PREFIX-SOMMÉES en breakpoints triés, avant
  /// échantillonnage sur [gridDates] par dichotomie (dernier breakpoint ≤ d,
  /// `0.0` avant le premier). Analogue à [quantityAt]/[cashAt], mais sur un
  /// CUMUL de flux (`double`) plutôt qu'un ÉTAT (quantité/cash) — d'où une
  /// implémentation locale ([_lastFlowAtOrBefore]) plutôt qu'une réutilisation
  /// directe des primitives de `position_projection.dart` (types différents).
  ///
  /// Anti-double-comptage (invariant central, cf. en-tête
  /// `position_projection.dart`) : `openingBalance` TITRE a `amount == null`
  /// (jamais capté par (a)) ; `openingBalance` ESPÈCES a `deltaQty == 0`
  /// (jamais capté par (b)) ; `buy`/`sell` contribuent `0` des deux côtés. Un
  /// prix manquant (résiduel malgré le repli) donne une valorisation `0` en
  /// (b) — vue IDENTIQUEMENT par [reconstructRealNetWorth] (même
  /// `symbolToData`), l'écart valeur/flux reste donc net de cet aléa.
  ///
  /// Change : même compromis v1 que le reste du mode 2 (§6) — USD converti via
  /// [usdToEurRate] au taux COURANT.
  static List<double> buildExternalFlowsCurve({
    required Map<String, List<AssetTransaction>> txsBySymbol,
    required Map<String, List<AssetTransaction>> txsByAccount,
    required Map<String, AssetHistoricalData?> symbolToData,
    required Map<String, Asset> assetBySymbol,
    required double usdToEurRate,
    required List<DateTime> gridDates,
  }) {
    if (gridDates.isEmpty) return <double>[];

    // (a) Flux CASH — sous-ensemble filtré, mêmes briques que
    // buildContributionsCurve : deposit/withdrawal (tous) + openingBalance/
    // adjustment ESPÈCES (symbol == null) SEULEMENT.
    final cashFlows = <AssetTransaction>[
      for (final txs in txsByAccount.values)
        for (final tx in txs)
          if (tx.kind == TransactionKind.deposit ||
              tx.kind == TransactionKind.withdrawal ||
              ((tx.kind == TransactionKind.openingBalance ||
                      tx.kind == TransactionKind.adjustment) &&
                  tx.symbol == null))
            tx,
    ];
    final cashTimeline = buildCashTimeline(cashFlows);

    // (b) Flux TITRE — accumulation par date-only UTC, un seul rejeu par
    // symbole (réutilise le fold unique de replayLedger, aucune arithmétique
    // dupliquée).
    final byDate = <DateTime, double>{};
    for (final entry in txsBySymbol.entries) {
      final symbol = entry.key;
      final data = symbolToData[symbol];
      final asset = assetBySymbol[symbol];
      replayLedger(
        entry.value,
        onStep: (step) {
          if (step.symbol == null) return; // partition : jambe cash, cf. (a)
          final isFlowKind = step.kind == TransactionKind.openingBalance ||
              step.kind == TransactionKind.adjustment ||
              step.kind == TransactionKind.transferOut;
          if (!isFlowKind) return; // buy/sell : transfert interne, 0 ici

          final price = priceEurAt(data, asset, step.date, usdToEurRate);
          final contrib = step.deltaQty.toDouble() * price;
          final day = _dateOnlyUtc(step.date);
          byDate[day] = (byDate[day] ?? 0.0) + contrib;
        },
      );
    }

    final sortedDays = byDate.keys.toList()..sort();
    var running = 0.0;
    final breakpoints = <({DateTime date, double cumulative})>[];
    for (final day in sortedDays) {
      running += byDate[day]!;
      breakpoints.add((date: day, cumulative: running));
    }

    final values = <double>[];
    for (final d in gridDates) {
      final byCurrency = cashAt(cashTimeline, d);
      double cashEur = 0;
      for (final e in byCurrency.entries) {
        cashEur += e.key.toUpperCase() == 'USD'
            ? e.value.toDouble() * usdToEurRate
            : e.value.toDouble();
      }
      values.add(cashEur + _lastFlowAtOrBefore(breakpoints, d));
    }

    return values;
  }

  /// Dichotomie « dernier breakpoint ≤ [target] » sur un CUMUL de flux
  /// (`double`) — équivalent local de [quantityAt]/[cashAt] pour un payload
  /// `double` plutôt qu'un `Decimal`/`Map<String, Decimal>` (types
  /// incompatibles avec ces primitives, d'où la réimplémentation MINIMALE
  /// ci-dessous, même algorithme que la dichotomie privée de
  /// `position_projection.dart`). `0.0` avant le premier breakpoint ou si
  /// [breakpoints] est vide (aucun flux titre connu ≡ contribution nulle).
  static double _lastFlowAtOrBefore(
    List<({DateTime date, double cumulative})> breakpoints,
    DateTime target,
  ) {
    final t = _dateOnlyUtc(target);
    var lo = 0;
    var hi = breakpoints.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (!breakpoints[mid].date.isAfter(t)) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans < 0 ? 0.0 : breakpoints[ans].cumulative;
  }

  // ---------------------------------------------------------------------------
  // Gains mode réel — PÉRIODE (B7 correction financière, design §7.3/§11.4) :
  // PUR, sans I/O — dérivé de [reconstructRealNetWorth]/
  // [buildExternalFlowsCurve], déjà alignées index-par-index sur la même
  // grille de dates par construction (contrat des deux fonctions ci-dessus).
  // Le gain TOTAL (état courant) est un calcul SÉPARÉ : [computeRealTotalGain].
  // ---------------------------------------------------------------------------

  /// Calcule le gain sur la PÉRIODE affichée du mode 2 « évolution réelle » à
  /// partir de [values] (valeur du patrimoine/compte, date par date),
  /// [externalFlows] (flux externes CUMULÉS depuis l'origine du journal,
  /// [buildExternalFlowsCurve], même grille) et [gridDates] (nécessaire à la
  /// pondération temporelle Modified Dietz) — voir [RealGains].
  ///
  /// POURQUOI c'est correct (invariant central) : par construction du journal,
  /// `valeur = flux_externes_cumulés + gains_cumulés`, donc à toute date
  /// `gap = V − F = gains_cumulés`. Le « % naïf » `(V[fin]−V[début]) /
  /// V[début]` est VOLONTAIREMENT masqué ailleurs (cf. wallet_view) car il
  /// mélange flux et performance ; ici on isole la performance PURE en
  /// travaillant sur `gap` plutôt que sur `V` :
  /// `periodGain = gap[fin] − gap[début]` = gains RÉALISÉS PENDANT la fenêtre
  /// affichée (les flux de la fenêtre s'annulent dans la soustraction — c'est
  /// tout l'intérêt de passer par `gap`), soit explicitement
  /// `(V[fin]−V[début]) − (F[fin]−F[début])`.
  ///
  /// `%` en MODIFIED DIETZ (standard de mesure de performance en présence de
  /// flux intermédiaires) : `periodGainPercent = periodGain / denom × 100`
  /// (convention ×100 partagée avec le reste de l'app, cf. `periodChangePercent`
  /// — [Formatters.formatPercentFr] n'échelonne rien), avec
  /// `denom = V[début] + Σ_{i≥1} w_i·(F[i]−F[i−1])` et `w_i = (t[fin]−t[i]) /
  /// (t[fin]−t[début])` — un flux survenu tôt dans la fenêtre pèse presque
  /// PLEINEMENT au dénominateur (il a eu le temps de fructifier, poids proche
  /// de 1), un flux survenu juste avant la fin pèse presque RIEN (poids proche
  /// de 0) : un gros dépôt en fin de fenêtre ne gonfle donc pas artificiellement
  /// le `%` (contrairement à un simple `periodGain / V[début]`).
  ///
  /// Le cash PUR (comptes 100 % cash, ajouté en CONSTANTE identique à [values]
  /// ET [externalFlows] par l'appelant, cf. [addConstantPureCash]) s'annule
  /// dans `gap` à toute date — `periodGain` en est donc rigoureusement
  /// indépendant. Le dénominateur Modified Dietz en dépend (comme `V[début]`
  /// pour un `%` classique), ce qui reste cohérent : c'est un dénominateur de
  /// valeur absolue, pas un écart.
  ///
  /// Gardes (tout `null` plutôt qu'un chiffre trompeur) :
  /// - [values]/[externalFlows]/[gridDates] de longueurs DIFFÉRENTES → séries
  ///   incohérentes (grille rompue, ne devrait jamais arriver par
  ///   construction des appelants) : on refuse de deviner, tout `null`.
  /// - `N < 2` → pas de fenêtre, rien à comparer : tout `null`.
  /// - `N == 0` → tout `null`.
  /// - `denom <= 0` → `periodGainPercent` `null` (division par zéro/valeur non
  ///   significative), `periodGain` reste, lui, calculé.
  /// - Fenêtre à durée nulle (`t[fin] == t[début]`, ne devrait pas arriver
  ///   avec `N >= 2` sur une grille de dates distinctes) → pondération
  ///   Modified Dietz ignorée (`denom = V[début]` seul), même garde-fou que
  ///   `totalSpan <= 0`.
  ///
  /// ANNUALISATION (≥ 2 ans, cf. [RealGains.isAnnualized]) — POURQUOI : le
  /// Modified Dietz ci-dessus est conçu pour mesurer une performance sur une
  /// fenêtre COURTE (mois/trimestre/année), où rapporter le gain au capital
  /// MOYEN pondéré dans le temps reste lisible. Sur « Max » d'un patrimoine
  /// construit progressivement depuis 10+ ans, ce capital moyen (ex. ~20 k€)
  /// est très inférieur au capital final (ex. ~66 k€) — le `%` cumulé qui en
  /// résulte (ex. +183 %) est mathématiquement correct mais illisible et
  /// contredit visuellement le « Gains totaux » affiché juste à côté (calcul
  /// différent, cf. [computeRealTotalGain]). Ramené à l'année (ex. +9,1 %/an),
  /// le même chiffre redevient comparable à un indice — c'est la lecture que
  /// l'utilisateur attend sur une fenêtre longue.
  ///
  /// Règle basée sur la DURÉE RÉELLE de [gridDates] (`spanDays`), JAMAIS sur
  /// le libellé de période sélectionné : un journal ne couvrant que 6 mois
  /// affiché sous le filtre « Max » doit rester cumulé — l'annualiser
  /// extrapolerait un rendement annuel à partir de 6 mois d'historique, une
  /// fausse précision. Seuil `spanDays >= 730` (2 ans, borne INCLUSE) :
  /// en-deçà, la fenêtre reste assez courte pour que le cumulé se lise sans
  /// besoin de ramener à l'année.
  ///
  /// Formule standard (rendement composé annuel) : `years = spanDays /
  /// 365.25` ; `r = periodGainPercent / 100` ; `annualized = ((1+r)^(1/years)
  /// − 1) × 100`.
  ///
  /// Garde `1 + r <= 0` (perte cumulée ≥ 100 %) : la racine `1/years`-ième
  /// d'un nombre négatif ou nul n'a pas de sens mathématique réel — on GARDE
  /// le `%` cumulé tel quel et [RealGains.isAnnualized] reste `false` (pas de
  /// suffixe « /an » sur un chiffre qui n'est PAS annualisé). Idem si
  /// `years <= 0` (fenêtre dégénérée, ne devrait pas arriver avec `N >= 2`
  /// sur des dates distinctes, mais on reste défensif plutôt que de diviser
  /// par zéro/produire un NaN silencieux).
  static RealGains computeRealGains({
    required List<double> values,
    required List<double> externalFlows,
    required List<DateTime> gridDates,
  }) {
    if (values.length != externalFlows.length ||
        values.length != gridDates.length) {
      return RealGains.empty;
    }
    final n = values.length;
    if (n < 2) return RealGains.empty; // pas de fenêtre (n==0 inclus)

    final periodGain =
        (values[n - 1] - values[0]) - (externalFlows[n - 1] - externalFlows[0]);

    final t0 = gridDates.first;
    final tn = gridDates.last;
    final totalSpanMs = tn.difference(t0).inMilliseconds.toDouble();

    var denom = values[0];
    if (totalSpanMs > 0) {
      for (var i = 1; i < n; i++) {
        final w =
            tn.difference(gridDates[i]).inMilliseconds.toDouble() / totalSpanMs;
        denom += w * (externalFlows[i] - externalFlows[i - 1]);
      }
    }
    // ×100 : convention PARTAGÉE avec le reste de l'app (periodChangePercent,
    // unrealizedGainPercent…) — consommée telle quelle par
    // Formatters.formatPercentFr, qui n'applique AUCUNE mise à l'échelle.
    final cumulativePercent = denom > 0 ? periodGain / denom * 100 : null;

    // Annualisation (≥ 2 ans, cf. commentaire ci-dessus) — n'agit que sur le
    // `%` : periodGain (montant absolu) n'a jamais de notion « par an ».
    var periodGainPercent = cumulativePercent;
    var isAnnualized = false;
    if (cumulativePercent != null) {
      final spanDays = tn.difference(t0).inMilliseconds / 86400000.0;
      if (spanDays >= 730) {
        final years = spanDays / 365.25;
        final r = cumulativePercent / 100;
        if (years > 0 && 1 + r > 0) {
          periodGainPercent = (pow(1 + r, 1 / years) - 1) * 100;
          isAnnualized = true;
        }
        // Sinon (years <= 0 ou 1+r <= 0) : cumulativePercent conservé tel
        // quel, isAnnualized reste false (cf. garde documentée ci-dessus).
      }
    }

    return RealGains(
      periodGain: periodGain,
      periodGainPercent: periodGainPercent,
      isAnnualized: isAnnualized,
    );
  }

  // ---------------------------------------------------------------------------
  // Gains mode réel — TOTAL (B7 correction financière, design §7.3, décision
  // « voie b ») : ÉTAT COURANT, base coût, INDÉPENDANT de la fenêtre/grille —
  // PAS dérivé de [reconstructRealNetWorth]/[buildExternalFlowsCurve]. PUR,
  // sans I/O — [replayLedger] est le SEUL rejeu du journal (invariant
  // anti-divergence, cf. `position_projection.dart`), le non-réalisé lit
  // directement les positions déjà valorisées par l'appelant.
  // ---------------------------------------------------------------------------

  /// Calcule le gain TOTAL en ÉTAT COURANT du mode 2 « évolution réelle » —
  /// voir [RealTotalGain]. Trois termes sommés (EUR) :
  ///
  /// 1. NON-RÉALISÉ : `Σ pos.unrealizedGain × fx` sur [positions] — une
  ///    position sans PRU connu (`unrealizedGain == null`, y compris un
  ///    `openingBalance` TITRE sans `unitPrice`) est EXCLUE des DEUX termes
  ///    (numérateur ET capital, cf. plus bas) et ajoutée à
  ///    [RealTotalGain.noBasisSymbols] — jamais silencieusement comptée pour
  ///    zéro (ce serait une plus-value fictive). `fx` = devise de COTATION de
  ///    la position ([Asset.isUsd]), comme le reste du mode 2.
  /// 2. RÉALISÉ : `Σ replayLedger(txsBySymbol[sym]).realizedGain × fx` — la
  ///    plus-value bookée sur les VENTES, quel que soit l'état actuel du
  ///    symbole (y compris un titre totalement soldé, absent de [positions]).
  ///    `fx` = devise de cotation reprise de [positions] si une position
  ///    existe pour ce symbole, sinon de la première transaction du journal
  ///    (même repli que les contrôleurs pour un titre soldé sans position
  ///    résiduelle).
  /// 3. REVENUS : `Σ amount` des mouvements `dividend`/`interest`/`charge` de
  ///    TOUS les comptes de [txsByAccount] (partition STRICTE — aucun autre
  ///    kind, cf. en-tête `position_projection.dart`) — `amount` déjà SIGNÉ
  ///    (`charge` négatif sauf rebate). `fx` = devise de RÈGLEMENT
  ///    (`settlementCurrency ?? currency`), PAS la cotation (c'est un
  ///    mouvement cash).
  ///
  /// `%` : `capital = valeurIncluse − totalGain`, où `valeurIncluse = Σ
  /// pos.totalValue × fx` (valeur de marché actuelle, PAS le coût — sur les
  /// SEULES positions à PRU connu, mêmes exclusions qu'au terme 1). `capital`
  /// est donc DÉFINITIONNEL : il garantit `valeurIncluse = capital +
  /// totalGain` PAR CONSTRUCTION (invariant testé), pas une vraie « valeur
  /// investie » indépendante. `totalGainPercent = totalGain / capital × 100`
  /// (même convention ×100 que [computeRealGains.periodGainPercent]), `null`
  /// si `capital <= 0`.
  ///
  /// ⚠️ Périmètre : [positions] ne porte PAS le cash pur du patrimoine (le
  /// wallet l'ajoute séparément à l'affichage, cf. `TotalValueCard`) — cette
  /// fonction ne le voit donc jamais, ni dans `valeurIncluse` ni dans
  /// `capital`. `transferOut` n'a AUCUN traitement spécial ici : le fold de
  /// [replayLedger] a déjà retiré sa base de coût au prorata (contribution
  /// nette 0, ni PV réalisée ni cash) — cohérent avec la sortie de titres
  /// sans cession qu'il modélise.
  static RealTotalGain computeRealTotalGain({
    required List<PositionWithMarketData> positions,
    required Map<String, List<AssetTransaction>> txsBySymbol,
    required Map<String, List<AssetTransaction>> txsByAccount,
    required double usdToEurRate,
    double cashEur = 0.0,
  }) {
    final noBasisSymbols = <String>{};
    var totalGain = 0.0;
    // Le CASH fait partie de la valeur détenue, donc du capital investi
    // (`capital = valeur − gains`). L'OMETTRE amputerait le dénominateur du
    // `%` de tout le cash non investi et SURÉVALUERAIT la performance (ex.
    // 10 000 € versés, 5 000 € en titres valant 6 000 € : sans le cash,
    // capital = 5 000 → +20 % au lieu de +10 %). Le cash n'a jamais de base de
    // coût ambiguë : sa valeur EST son capital, il n'apporte aucun gain
    // (les intérêts/frais sont déjà comptés en revenus ci-dessous).
    var valueIncluded = cashEur;

    // (1) Non-réalisé — positions à PRU connu seulement.
    for (final pos in positions) {
      final unrealized = pos.unrealizedGain;
      if (unrealized == null) {
        noBasisSymbols.add(pos.symbol);
        continue;
      }
      final fx = pos.asset.isUsd ? usdToEurRate : 1.0;
      totalGain += unrealized * fx;
      valueIncluded += pos.totalValue * fx;
    }

    // Devise de cotation par symbole : position ACTUELLE si elle existe
    // (autoritative), sinon repli 1ʳᵉ transaction du journal (titre soldé
    // sans position résiduelle — même motif que les contrôleurs).
    final currencyBySymbol = <String, String>{
      for (final p in positions) p.symbol: p.asset.currency,
    };

    // (2) Réalisé — rejeu PAR SYMBOLE, indépendant de l'état courant.
    for (final entry in txsBySymbol.entries) {
      if (entry.value.isEmpty) continue;
      final symbol = entry.key;
      final realized = replayLedger(entry.value).realizedGain;
      final currency = currencyBySymbol[symbol] ?? entry.value.first.currency;
      final fx = currency.toUpperCase() == 'USD' ? usdToEurRate : 1.0;
      totalGain += realized * fx;
    }

    // (3) Revenus — partition stricte dividend/interest/charge, fx règlement.
    for (final txs in txsByAccount.values) {
      for (final tx in txs) {
        if (tx.kind != TransactionKind.dividend &&
            tx.kind != TransactionKind.interest &&
            tx.kind != TransactionKind.charge) {
          continue;
        }
        final amt =
            double.tryParse((tx.amount ?? '').replaceAll(',', '.').trim()) ??
                0.0;
        final settlement = tx.settlementCurrency ?? tx.currency;
        final fx = settlement.toUpperCase() == 'USD' ? usdToEurRate : 1.0;
        totalGain += amt * fx;
      }
    }

    final capital = valueIncluded - totalGain;
    // ×100 : même convention que periodGainPercent ci-dessus (cf. commentaire
    // de computeRealGains) — Formatters.formatPercentFr n'échelonne rien.
    final totalGainPercent = capital > 0 ? totalGain / capital * 100 : null;

    return RealTotalGain(
      totalGain: totalGain,
      totalGainPercent: totalGainPercent,
      noBasisSymbols: noBasisSymbols,
    );
  }

  // ---------------------------------------------------------------------------
  // Variations par compte (wallet_view : _computeAccountsPeriodChanges)
  // ---------------------------------------------------------------------------

  /// Calcule les variations de période pour chaque compte à partir de la map
  /// d'historique DÉJÀ récupérée (plus aucun appel réseau ici).
  ///
  /// Les comptes cash reçoivent une variation de 0 (solde statique).
  static AccountsPeriodChangesResult computeAccountsPeriodChanges({
    required List<Account> accounts,
    required Map<String, List<PositionWithMarketData>> accountPositions,
    required Map<String, AssetHistoricalData?> symbolToData,
    required double usdToEurRate,
  }) {
    final accountPeriodChanges = <String, double>{};
    final accountPeriodChangePercents = <String, double>{};

    for (final account in accounts) {
      // COMPTES CASH : Pas de variation historique (solde statique)
      if (account.type == AccountType.cash) {
        accountPeriodChanges[account.id] = 0;
        accountPeriodChangePercents[account.id] = 0;
        continue;
      }

      final positions = accountPositions[account.id] ?? [];

      if (positions.isEmpty) {
        accountPeriodChanges[account.id] = 0;
        accountPeriodChangePercents[account.id] = 0;
        continue;
      }

      double startValue = 0;
      double endValue = 0;

      for (final pos in positions) {
        final hData = symbolToData[pos.symbol];
        if (hData != null && !hData.isEmpty) {
          final qty = double.tryParse(pos.quantity) ?? 0;

          double startPrice = hData.prices.first.toDouble();
          double endPrice = hData.prices.last.toDouble();

          if (pos.asset.currency.toUpperCase() == 'USD') {
            startPrice *= usdToEurRate;
            endPrice *= usdToEurRate;
          }

          startValue += startPrice * qty;
          endValue += endPrice * qty;
        }
      }

      final change = endValue - startValue;
      final changePercent = startValue != 0 ? (change / startValue) * 100 : 0.0;

      accountPeriodChanges[account.id] = change;
      accountPeriodChangePercents[account.id] = changePercent;
    }

    return (
      accountPeriodChanges: accountPeriodChanges,
      accountPeriodChangePercents: accountPeriodChangePercents,
    );
  }

  // ---------------------------------------------------------------------------
  // Agrégation par compte (account_view : _aggregateHistoricalData)
  // ---------------------------------------------------------------------------

  /// Agrège les données historiques de toutes les positions d'un compte.
  ///
  /// [results] et [currentPositions] sont appairés par index (results[i]
  /// correspond à currentPositions[i]). Les positions sans donnée historique
  /// (null/empty) sont ignorées sans décaler les autres index.
  ///
  /// ⚠️ Utilise [findNearestIndexUnbounded] (variante sans gardes aux bornes),
  /// conformément à l'implémentation originale de account_view.
  static AccountAggregationResult aggregateHistoricalData({
    required List<AssetHistoricalData?> results,
    required List<PositionWithMarketData> currentPositions,
    required double usdToEurRate,
  }) {
    final maxLen = min(results.length, currentPositions.length);

    // Retourne le résultat historique valide pour une position donnée, ou null.
    AssetHistoricalData? validResultAt(int i) {
      final data = results[i];
      if (data != null && !data.isEmpty) return data;
      return null;
    }

    final hasAnyValidResult = List<int>.generate(maxLen, (i) => i)
        .any((i) => validResultAt(i) != null);

    if (!hasAnyValidResult) {
      return (
        dates: <DateTime>[],
        values: <double>[],
        startValue: null,
        endValue: null,
        change: null,
        changePercent: null,
      );
    }

    // Collecter toutes les dates uniques
    final allDates = <DateTime>{};
    for (int i = 0; i < maxLen; i++) {
      final result = validResultAt(i);
      if (result == null) continue;
      allDates.addAll(result.dates);
    }

    final sortedDates = allDates.toList()..sort();

    // Pré-calculer un index date→prix pour chaque position (évite la recherche
    // linéaire répétée). null pour les positions sans donnée historique.
    final dateToPriceMaps = <Map<DateTime, double>?>[];
    for (int i = 0; i < maxLen; i++) {
      final result = validResultAt(i);
      if (result == null) {
        dateToPriceMaps.add(null);
        continue;
      }
      final map = <DateTime, double>{};
      for (int j = 0; j < result.dates.length; j++) {
        map[result.dates[j]] = result.prices[j].toDouble();
      }
      dateToPriceMaps.add(map);
    }

    final dateValues = <DateTime, double>{};

    for (final date in sortedDates) {
      double totalValueEur = 0;

      for (int i = 0; i < maxLen; i++) {
        final result = validResultAt(i);
        if (result == null) continue; // Position sans donnée historique

        final positionData = currentPositions[i];
        final position = positionData.position;
        final quantity = double.tryParse(position.quantity) ?? 0;

        // Recherche directe dans le map pré-calculé
        double? price = dateToPriceMaps[i]![date];

        // Si pas de prix exact, chercher le plus proche
        if (price == null) {
          final nearestIdx = findNearestIndexUnbounded(result.dates, date);
          if (nearestIdx == -1) continue;
          price = result.prices[nearestIdx].toDouble();
        }

        if (position.asset.currency.toUpperCase() == 'USD') {
          price = price * usdToEurRate;
        }

        totalValueEur += price * quantity;
      }

      dateValues[date] = totalValueEur;
    }

    final chartDates = dateValues.keys.toList()..sort();
    final chartValues = chartDates.map((d) => dateValues[d] ?? 0).toList();

    double? startValue, endValue, change, changePercent;
    if (chartValues.isNotEmpty) {
      startValue = chartValues.first;
      endValue = chartValues.last;
      change = endValue - startValue;
      changePercent = startValue != 0 ? (change / startValue) * 100 : 0.0;
    }

    return (
      dates: chartDates,
      values: chartValues,
      startValue: startValue,
      endValue: endValue,
      change: change,
      changePercent: changePercent,
    );
  }

  // ---------------------------------------------------------------------------
  // Variations individuelles (account_view : _computeIndividualPeriodChanges)
  // ---------------------------------------------------------------------------

  /// Calcule les variations individuelles de chaque position.
  ///
  /// Retourne une nouvelle liste de [PositionWithMarketData] (ne mute pas
  /// l'état). [results] et [currentPositions] sont appairés par index.
  ///
  /// ⚠️ [copyWith] de [PositionWithMarketData] utilise ?? et ne peut pas
  /// remettre un champ à null — la sémantique est conservée à l'identique.
  static List<PositionWithMarketData> computeIndividualPeriodChanges({
    required List<AssetHistoricalData?> results,
    required List<PositionWithMarketData> currentPositions,
    required double usdToEurRate,
  }) {
    if (results.length != currentPositions.length) {
      AppLogger.warning(
        'Mismatch: ${currentPositions.length} positions vs ${results.length} résultats historiques',
      );
      // On ne traite que les indices communs
    }

    final maxLen = min(results.length, currentPositions.length);

    return List<PositionWithMarketData>.generate(currentPositions.length, (i) {
      final positionData = currentPositions[i];

      if (i >= maxLen) return positionData; // Pas de donnée historique dispo

      final historicalData = results[i];

      if (historicalData != null && !historicalData.isEmpty) {
        final startPrice = historicalData.prices.first.toDouble();
        final endPrice = historicalData.prices.last.toDouble();
        final quantity = double.tryParse(positionData.quantity) ?? 0;
        final isUsd = positionData.asset.currency.toUpperCase() == 'USD';

        final startPriceEur = isUsd ? startPrice * usdToEurRate : startPrice;
        final endPriceEur = isUsd ? endPrice * usdToEurRate : endPrice;

        final periodChange = (endPriceEur - startPriceEur) * quantity;
        final startValue = startPriceEur * quantity;
        final periodChangePercent = startValue != 0
            ? ((endPriceEur - startPriceEur) / startPriceEur * 100)
            : 0.0;

        return positionData.copyWith(
          periodChange: periodChange,
          periodChangePercent: periodChangePercent,
        );
      }

      return positionData;
    });
  }
}

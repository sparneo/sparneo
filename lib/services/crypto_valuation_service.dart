// lib/services/crypto_valuation_service.dart
//
// Moteur de valorisation du modèle (b), ÉTAGE 1 « fichier » (chantier B16, lot 2
// — conception interne). Couche I/O (réseau via `ExchangeRateService`, AUCUNE
// écriture) : résout les [UnvaluedExchange] produits par
// `CryptoLedgerNormalizer.planCryptoImport` en montants EUR, pour que
// `CryptoLedgerNormalizer.finalizeCryptoExchanges` (PUR) puisse ensuite émettre
// les mouvements `sell`/`buy`/`adjustment` correspondants. L'étage 2 « cours
// en-app » (Binance, cotations historiques) reste HORS PÉRIMÈTRE de ce lot (lot
// 4).
//
// CASCADE (conception interne) — pour CHAQUE [UnvaluedExchange]
// :
//   1. Valeur USD retenue = jambe PAYÉE (`usdPaid`) si parseable, sinon jambe
//      REÇUE (`usdReceived`) ; aucune des deux lisible → arbitrage manuel
//      (`unreadable`), la série FX n'est même pas interrogée pour cette ligne.
//   2. Si les DEUX jambes sont lisibles, écart relatif calculé
//      (`(|usdReçu|−|usdPayé|)/|usdPayé|`) ; `|écart| > 10 %` → arbitrage
//      manuel (`spread`) — une divergence de cet ordre signale une donnée
//      douteuse, pas un spread de marché normal.
//   3. FX : UNE SEULE récupération pour l'ENSEMBLE des lignes valorisables
//      (min/max de leurs dates), via `ExchangeRateService.getDailyRatesToEur`
//      — LÈVE [ExchangeRateUnavailable] en cas d'échec, PROPAGÉE TELLE QUELLE
//      (jamais interceptée ici) : c'est à L'APPELANT
//      (`AccountController._previewCryptoImport`) de décider du repli global
//      en arbitrage manuel, jamais à cette couche (B4 : aucune coercition).
//   4. `V_eur = V_usd × rate(jour, repli dernier jour ouvré ANTÉRIEUR — jamais
//      d'interpolation)`, en [Decimal] exact.
//
// Ce fichier NE JOURNALISE RIEN : il produit une table
// `importKey → CryptoValuation` (étage 1 uniquement, `source:'statement'`) et
// la liste des entrées restées en arbitrage manuel (avec motif, pour
// l'affichage) — c'est `CryptoLedgerNormalizer.finalizeCryptoExchanges` (PUR)
// qui transforme ces valorisations en mouvements réels.

import 'package:decimal/decimal.dart';

import 'package:portfolio_tracker/model/crypto_import_plan.dart'
    show UnvaluedExchange, CryptoValuation;
import 'package:portfolio_tracker/services/exchange_rate_service.dart';

/// Motif pour lequel un [UnvaluedExchange] reste en arbitrage manuel après
/// tentative de résolution étage 1 (conception interne) — clé stable i18n-able,
/// JAMAIS un message déjà traduit (même politique que
/// `ImportedMovement.rejectReason`).
enum CryptoValuationManualReason {
  /// Aucune jambe USD lisible (ni `usdPaid` ni `usdReceived` parseable — ex.
  /// le littéral `-` du N2 Kraken sur les deux colonnes).
  unreadable('unreadable'),

  /// Les deux jambes sont lisibles mais divergent de plus de 10 % — donnée
  /// douteuse (conception interne), jamais traitée comme un spread de marché
  /// ordinaire.
  spread('spread'),

  /// La série FX historique (frankfurter) est indisponible pour la période
  /// demandée (échec réseau/HTTP/parsing, ou aucun jour ouvré antérieur
  /// trouvé dans la fenêtre élargie) — aucune coercition, TOUT échange
  /// concerné part en arbitrage manuel plutôt que d'inventer un taux.
  fxUnavailable('fxUnavailable'),

  /// La clé de dédup ([UnvaluedExchange.importKey]) est PARTAGÉE par ≥ 2
  /// entrées de ce lot (B-1, revue adversariale lot 2) — dustsweeping N→1
  /// dégénéré à `amountusd` partiellement illisible, ou dépôt en nature
  /// multi-jambes sous le même `refid` (`CryptoLedgerNormalizer.
  /// _processExchangeGroup`/`_processDepositOrWithdrawal`, repli « une entrée
  /// par jambe »). [CryptoLedgerNormalizer.finalizeCryptoExchanges] itère sur
  /// les ENTRÉES et appliquerait à CHACUNE l'UNIQUE valorisation retenue dans
  /// la map pour cette clé : jambes émises au mauvais montant, clés
  /// dupliquées en base. Ces entrées ne sont donc JAMAIS valorisées ici
  /// (aucune n'entre dans [CryptoValuationResolution.valuations]) — à
  /// ressaisir manuellement DANS LE JOURNAL (le champ de saisie EUR de
  /// l'aperçu est désactivé pour ce motif, cf. `statement_import_page.dart`).
  ambiguousGroup('ambiguousGroup'),

  /// L'une des deux jambes ([UnvaluedExchange.codePaidIsFiat]/
  /// [UnvaluedExchange.codeReceivedIsFiat]) est FIAT — typiquement une jambe
  /// ÉTRANGÈRE à la devise du compte (ex. `USD` sur un compte `EUR`,
  /// `CryptoLedgerNormalizer._processExchangeGroup` branche
  /// `fiatLegs.isEmpty`, B-A contre-vérification lot 2) : aucune conversion
  /// n'est disponible à cet étage (voie « jambe fiat étrangère = cash
  /// converti au taux historique » consignée comme cible FUTURE, hors
  /// périmètre de ce lot) — valoriser quand même fabriquerait une position
  /// crypto du CODE FIAT lui-même. Ces entrées ne sont donc JAMAIS
  /// valorisées ici (aucune n'entre dans [CryptoValuationResolution.
  /// valuations]) — à ressaisir manuellement DANS LE JOURNAL, exactement
  /// comme [ambiguousGroup] (le champ de saisie EUR de l'aperçu est
  /// désactivé pour ce motif aussi, cf. `statement_import_page.dart`).
  foreignFiat('foreignFiat');

  final String wire;
  const CryptoValuationManualReason(this.wire);
}

/// [UnvaluedExchange] resté en arbitrage manuel après résolution, enrichi du
/// motif — jamais reconstruit à la main : voir [UnvaluedExchange.copyWith]
/// côté appelant pour reporter [reason]/[valuationSpreadPct] sur l'objet
/// exposé à l'aperçu (`ImportPreview.unvaluedExchanges`).
class CryptoValuationManual {
  final UnvaluedExchange source;
  final CryptoValuationManualReason reason;

  /// Renseigné UNIQUEMENT quand les deux jambes étaient lisibles (reason ==
  /// [CryptoValuationManualReason.spread]) — `null` sinon.
  final String? valuationSpreadPct;

  const CryptoValuationManual({
    required this.source,
    required this.reason,
    this.valuationSpreadPct,
  });
}

/// Résultat de [CryptoValuationService.resolve] : la table des valorisations
/// résolues (clé = [UnvaluedExchange.importKey]) et la liste de celles restées
/// en arbitrage manuel (avec motif, pour l'affichage).
///
/// CORRECTIF B-1 (revue adversariale lot 2, BLOQUANT) : la forme dégénérée du
/// dustsweeping N→1 à `amountusd` partiellement illisible (et le dépôt en
/// nature multi-jambes, `CryptoLedgerNormalizer._processExchangeGroup`/
/// `_processDepositOrWithdrawal`) émet plusieurs [UnvaluedExchange] sous la
/// MÊME [UnvaluedExchange.importKey] — [valuations] étant une map PAR CLÉ,
/// seule la DERNIÈRE valorisation calculée pour cette clé y aurait survécu,
/// et [CryptoLedgerNormalizer.finalizeCryptoExchanges] (qui itère sur les
/// ENTRÉES, pas sur les clés) l'aurait appliquée à CHACUNE : jambes émises au
/// mauvais montant, clés dupliquées en base. [resolve] pré-scanne désormais
/// la multiplicité de [UnvaluedExchange.importKey] AVANT toute tentative de
/// valorisation : une clé partagée par ≥ 2 entrées n'entre JAMAIS dans
/// [valuations], ses entrées ressortent dans [manual] avec le motif dédié
/// [CryptoValuationManualReason.ambiguousGroup] — `finalizeCryptoExchanges`
/// porte une ceinture INDÉPENDANTE du même pré-scan (défense en profondeur).
class CryptoValuationResolution {
  final Map<String, CryptoValuation> valuations;
  final List<CryptoValuationManual> manual;

  const CryptoValuationResolution({
    this.valuations = const {},
    this.manual = const [],
  });
}

class CryptoValuationService {
  final ExchangeRateService _rateService;

  /// [exchangeService] injectable (fakes possibles en test, même patron que
  /// `AccountController`/`WalletController` pour `ExchangeRateService`) —
  /// défaut : le singleton partagé de l'application.
  CryptoValuationService({ExchangeRateService? exchangeService})
      : _rateService = exchangeService ?? ExchangeRateService();

  /// Écart relatif maximal toléré par défaut — repli SEULEMENT quand
  /// l'appelant ne fournit pas [CryptoLedgerSpec.maxLegValuationSpread] (M-1,
  /// revue adversariale : la valeur codée en dur d'origine, `0.10`, devient un
  /// simple défaut de compatibilité ; `AccountController` transmet désormais
  /// toujours la valeur du profil, Kraken valant déjà `0.10` — comportement
  /// inchangé pour ce profil).
  static const double _defaultMaxLegValuationSpread = 0.10;

  /// Résout [unvalued] en valorisations EUR (étage 1 « fichier »). Zéro appel
  /// réseau si AUCUNE ligne n'est valorisable après la cascade lisibilité/
  /// spread (ex. fichier sans colonne `amountusd`) — évite un appel FX inutile
  /// quand tout part de toute façon en arbitrage manuel.
  ///
  /// [maxLegValuationSpread] : écart relatif maximal toléré entre les deux
  /// jambes avant bascule en arbitrage manuel (motif `spread`) — provient de
  /// [CryptoLedgerSpec.maxLegValuationSpread] du profil courant (M-1, revue
  /// adversariale : n'est plus codé en dur ici).
  Future<CryptoValuationResolution> resolve(
    List<UnvaluedExchange> unvalued, {
    double maxLegValuationSpread = _defaultMaxLegValuationSpread,
  }) async {
    final spreadThreshold = Decimal.parse(maxLegValuationSpread.toString());
    final manual = <CryptoValuationManual>[];
    final candidates = <_ValuationCandidate>[];

    // B-1 (BLOQUANT, revue adversariale lot 2) : pré-scan de multiplicité des
    // `importKey` AVANT toute tentative de valorisation — voir le correctif
    // documenté sur [CryptoValuationResolution]. Une clé partagée par ≥ 2
    // entrées n'est JAMAIS valorisée, quelle que soit par ailleurs la
    // lisibilité de ses jambes USD.
    final keyCounts = <String, int>{};
    for (final u in unvalued) {
      keyCounts[u.importKey] = (keyCounts[u.importKey] ?? 0) + 1;
    }

    for (final u in unvalued) {
      if ((keyCounts[u.importKey] ?? 0) >= 2) {
        manual.add(CryptoValuationManual(
          source: u,
          reason: CryptoValuationManualReason.ambiguousGroup,
        ));
        continue;
      }

      // B-A (BLOQUANT, contre-vérification lot 2) : une jambe FIAT (payée OU
      // reçue) ne doit JAMAIS être valorisée comme un actif — voir le
      // commentaire de [CryptoValuationManualReason.foreignFiat]. Contrôle
      // AVANT toute lecture de `usdPaid`/`usdReceived` : ces colonnes portent
      // la valorisation USD de la jambe fiat elle-même (ex. `USD` valant
      // littéralement son propre montant), ce qui la rendrait « lisible » à
      // tort si on laissait la cascade normale la traiter.
      if (u.codePaidIsFiat || u.codeReceivedIsFiat) {
        manual.add(CryptoValuationManual(
          source: u,
          reason: CryptoValuationManualReason.foreignFiat,
        ));
        continue;
      }

      final usdPaid = _tryParseAbs(u.usdPaid);
      final usdReceived = _tryParseAbs(u.usdReceived);
      final selected = usdPaid ?? usdReceived;
      if (selected == null) {
        manual.add(CryptoValuationManual(
          source: u,
          reason: CryptoValuationManualReason.unreadable,
        ));
        continue;
      }

      String? spreadStr;
      if (usdPaid != null && usdReceived != null && usdPaid != Decimal.zero) {
        final spread = ((usdReceived - usdPaid) / usdPaid)
            .toDecimal(scaleOnInfinitePrecision: 6);
        spreadStr = spread.toString();
        if (spread.abs() > spreadThreshold) {
          manual.add(CryptoValuationManual(
            source: u,
            reason: CryptoValuationManualReason.spread,
            valuationSpreadPct: spreadStr,
          ));
          continue;
        }
      }

      candidates.add(_ValuationCandidate(
        source: u,
        valuationUsd: selected,
        spreadPct: spreadStr,
      ));
    }

    if (candidates.isEmpty) {
      return CryptoValuationResolution(manual: manual);
    }

    // Bornes ENGLOBANTES : UNE SEULE récupération FX pour TOUTES les lignes
    // valorisables de cet import (conception interne).
    var minDate = candidates.first.source.date;
    var maxDate = candidates.first.source.date;
    for (final c in candidates.skip(1)) {
      if (c.source.date.isBefore(minDate)) minDate = c.source.date;
      if (c.source.date.isAfter(maxDate)) maxDate = c.source.date;
    }

    // AUCUN try/catch ICI : une [ExchangeRateUnavailable] doit se propager
    // TELLE QUELLE à l'appelant (B4 — jamais de coercition à cette couche).
    final rates = await _rateService.getDailyRatesToEur(
      'USD',
      from: minDate,
      to: maxDate,
    );

    final valuations = <String, CryptoValuation>{};
    for (final c in candidates) {
      final entry = _lastRateOnOrBefore(rates, c.source.date);
      if (entry == null) {
        // Défensif : la fenêtre élargie de `getDailyRatesToEur` DEVRAIT
        // toujours couvrir un jour ouvré antérieur — si ce n'est
        // exceptionnellement pas le cas (série tronquée), même politique que
        // toute FX indisponible : arbitrage manuel, jamais un taux inventé.
        manual.add(CryptoValuationManual(
          source: c.source,
          reason: CryptoValuationManualReason.fxUnavailable,
          valuationSpreadPct: c.spreadPct,
        ));
        continue;
      }
      final rateDecimal = Decimal.parse(entry.value.toString());
      final amountEur = c.valuationUsd * rateDecimal;
      valuations[c.source.importKey] = CryptoValuation(
        amountEur: amountEur,
        valuationUsd: c.valuationUsd,
        fxRate: entry.value,
        fxDate: entry.key,
        spreadPct: c.spreadPct,
        source: 'statement',
      );
    }

    return CryptoValuationResolution(valuations: valuations, manual: manual);
  }

  Decimal? _tryParseAbs(String? raw) {
    if (raw == null) return null;
    final v = Decimal.tryParse(raw.trim());
    return v?.abs();
  }

  /// Dernier jour ouvré ≤ [date] PRÉSENT dans [rates] — JAMAIS d'interpolation
  /// (conception interne) : on cherche un jour EFFECTIVEMENT publié par frankfurter,
  /// en remontant jour par jour. `maxLookback` (15 j) couvre largement la marge
  /// d'élargissement de `getDailyRatesToEur` (10 j) avec une garde supplémentaire.
  MapEntry<DateTime, double>? _lastRateOnOrBefore(
    Map<DateTime, double> rates,
    DateTime date, {
    int maxLookback = 15,
  }) {
    var d = DateTime(date.year, date.month, date.day);
    for (var i = 0; i <= maxLookback; i++) {
      final v = rates[d];
      if (v != null) return MapEntry(d, v);
      d = d.subtract(const Duration(days: 1));
    }
    return null;
  }
}

class _ValuationCandidate {
  final UnvaluedExchange source;
  final Decimal valuationUsd;
  final String? spreadPct;

  const _ValuationCandidate({
    required this.source,
    required this.valuationUsd,
    this.spreadPct,
  });
}

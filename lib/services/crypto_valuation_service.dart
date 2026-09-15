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
// CASCADE (conception interne, étage 1-ter amendement drive lot 2 — pour
// CHAQUE [UnvaluedExchange] :
//   1. Valeur USD retenue = jambe PAYÉE (`usdPaid`) si parseable, sinon jambe
//      REÇUE (`usdReceived`) ; aucune des deux lisible → repli 1-ter (`2.`
//      ci-dessous) avant tout arbitrage manuel.
//   2. Si les DEUX jambes sont lisibles, écart relatif calculé
//      (`(|usdReçu|−|usdPayé|)/|usdPayé|`) ; `|écart| > 10 %` → repli 1-ter
//      avant tout arbitrage manuel — une divergence de cet ordre signale une
//      donnée douteuse, pas un spread de marché normal.
//   1-ter. ÉTAGE « jambe stablecoin dollar » (décision d'orchestration
//      mesurée sur le réel : 22 des 27 cas en écart excessif du drive manuel
//      portaient une jambe USDT/USDC) : quand l'étage 1 échoue pour motif
//      `unreadable` ou `spread` ET que l'une des deux jambes (code APRÈS
//      alias) figure dans `CryptoLedgerSpec.usdStableCodes` (liste de
//      CONFIANCE du profil, jamais une heuristique par nom), la quantité
//      NETTE de cette jambe (déjà positive) sert de valeur USD de repli,
//      `source:'stableLeg'`. Ne s'applique JAMAIS si l'étage 1 a réussi
//      (comportement inchangé), ni aux motifs `foreignFiat`/`ambiguousGroup`
//      (gardes intactes, traitées avant), ni à un dépôt en nature
//      (`kind != 'exchange'`, pas de contrepartie).
//   1-quater. ÉTAGE « jambe fiat ÉTRANGÈRE USD » (décision auteur,
//      voie (ii) du design B16 lot 2) : un échange PROPRE à exactement 2
//      jambes (garanti par construction dès qu'on atteint ce point — la clé
//      partagée est déjà écartée en `ambiguousGroup` juste avant, et un
//      groupe fiat↔fiat est déjà écarté en amont par le normalizer) dont
//      UNE jambe est crypto et L'AUTRE est fiat ÉTRANGÈRE (`codePaidIsFiat`/
//      `codeReceivedIsFiat`, exactement un des deux) EST valorisé
//      AUTOMATIQUEMENT — MAIS SEULEMENT si le code de la jambe fiat vaut
//      littéralement `USD` (seule devise câblée dans `ExchangeRateService` —
//      toute autre devise étrangère, ex. GBP, reste `foreignFiat`). La
//      quantité retenue est la QUANTITÉ NETTE de la jambe fiat elle-même
//      (`UnvaluedExchange.quantityPaid`/`quantityReceived`, calculée en
//      amont par le normalizer comme `amount − fee`), JAMAIS la colonne
//      `amountusd` (qui n'a de sens que pour une jambe CRYPTO). DOCTRINE
//      (M-1, revue adversariale) : contrairement à l'étage 1-ter ci-dessus
//      (jambe stablecoin, simple REPLI après échec de l'étage 1, dont la
//      quantité nette n'est jamais qu'une ESTIMATION substituée à une
//      valorisation USD absente ou douteuse), la jambe USD ici est retenue
//      SANS AUCUN recoupement avec `amountusd` — pour du vrai fiat, le net de
//      la jambe EST LE CASH RÉELLEMENT RÉGLÉ, pas une approximation : il n'y
//      a rien à recouper contre, la valeur EST la vérité-terrain. Émis
//      `source:'fiatLeg'` — modèle d'ÉMISSION DIFFÉRENT du crypto↔crypto au
//      lot ci-dessous (`finalizeCryptoExchanges` émet la SEULE jambe crypto
//      avec du cash RÉEL, jamais la paire sell/buy opposée N4 — voir son
//      en-tête de fichier) : AUCUNE position n'est jamais créée pour la
//      jambe fiat elle-même (B-A intact).
//   3. FX : UNE SEULE récupération pour l'ENSEMBLE des lignes valorisables
//      (min/max de leurs dates), via `ExchangeRateService.getDailyRatesToEur`
//      — LÈVE [ExchangeRateUnavailable] en cas d'échec, PROPAGÉE TELLE QUELLE
//      (jamais interceptée ici) : c'est à L'APPELANT
//      (`AccountController._previewCryptoImport`) de décider du repli global
//      en arbitrage manuel, jamais à cette couche (B4 : aucune coercition).
//   4. `V_eur = V_usd × rate(jour, repli dernier jour ouvré ANTÉRIEUR — jamais
//      d'interpolation)`, en [Decimal] exact.
//
// SUGGESTIONS (amendement drive lot 2 (suite) — pour une entrée qui reste
// manuelle au point 2. ci-dessus (motif `spread`, SANS repli 1-ter : aucune jambe
// stablecoin de confiance ne l'a sauvée), les DEUX valeurs USD du relevé sont
// converties en EUR avec la MÊME règle qu'au point 4. (même fenêtre FX, même
// repli de date) et exposées comme simples SUGGESTIONS sur
// `CryptoValuationManual`/`UnvaluedExchange` — l'utilisateur choisit l'une des
// deux en un clic côté UI au lieu de la calculer à la main, mais rien n'est
// JAMAIS appliqué automatiquement. Aucune suggestion pour les autres motifs
// (`unreadable`/`foreignFiat`/`ambiguousGroup`/`fxUnavailable`) : rien de fiable
// à en tirer.
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
  /// ÉTRANGÈRE à la devise du compte (ex. `GBP` sur un compte `EUR`,
  /// `CryptoLedgerNormalizer._processExchangeGroup` branche `fiatLegs.isEmpty`,
  /// B-A contre-vérification lot 2) : aucune conversion n'est disponible à cet
  /// étage — valoriser quand même fabriquerait une position crypto du CODE FIAT
  /// lui-même. DEPUIS l'amendement (voie (ii), étage 1-quater ci-dessus), le cas
  /// `USD` PROPRE (échange à exactement 2 jambes) n'atteint plus JAMAIS ce motif —
  /// il est résolu automatiquement (`source:'fiatLeg'`) ; SEULES restent ici les
  /// autres devises étrangères (aucune série FX câblée) et le cas dégénéré du
  /// dustsweeping N→1 à jambe fiat étrangère mêlée (déjà `ambiguousGroup` avant
  /// même d'atteindre ce contrôle, clé partagée). Ces entrées ne sont donc JAMAIS
  /// valorisées ici (aucune n'entre dans [CryptoValuationResolution.valuations]) —
  /// à ressaisir manuellement DANS LE JOURNAL, exactement comme [ambiguousGroup]
  /// (le champ de saisie EUR de l'aperçu est désactivé pour ce motif aussi, cf.
  /// `statement_import_page.dart`).
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

  /// Suggestions EUR (amendement drive lot 2 (suite) — voir le commentaire de
  /// [UnvaluedExchange.suggestedPaidEur]/[suggestedReceivedEur] pour la règle de
  /// calcul. Renseignées UNIQUEMENT quand [reason] vaut
  /// [CryptoValuationManualReason.spread] ET qu'un taux FX a pu être résolu pour la
  /// date de cet échange — `null` dans tous les autres cas (aucun autre motif n'a de
  /// valeur fiable à suggérer, cf. cascade du fichier de tête).
  final Decimal? suggestedPaidEur;
  final Decimal? suggestedReceivedEur;

  const CryptoValuationManual({
    required this.source,
    required this.reason,
    this.valuationSpreadPct,
    this.suggestedPaidEur,
    this.suggestedReceivedEur,
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
  /// jambes avant bascule en repli étage 1-ter / arbitrage manuel (motif
  /// `spread`) — provient de [CryptoLedgerSpec.maxLegValuationSpread] du
  /// profil courant (M-1, revue adversariale : n'est plus codé en dur ici).
  ///
  /// [usdStableCodes] : codes stablecoin dollar de CONFIANCE du profil
  /// courant (amendement drive lot 2 — provient de
  /// [CryptoLedgerSpec.usdStableCodes], vide par défaut (repli neutre,
  /// comportement inchangé pour un appelant qui ne le fournit pas).
  Future<CryptoValuationResolution> resolve(
    List<UnvaluedExchange> unvalued, {
    double maxLegValuationSpread = _defaultMaxLegValuationSpread,
    Set<String> usdStableCodes = const {},
  }) async {
    final spreadThreshold = Decimal.parse(maxLegValuationSpread.toString());
    final manual = <CryptoValuationManual>[];
    final candidates = <_ValuationCandidate>[];
    // Entrées motif `spread` SANS repli 1-ter (amendement drive lot 2 (suite) :
    // jamais valorisées automatiquement, mais partagent la MÊME fenêtre FX que
    // [candidates] ci-dessous pour calculer les DEUX suggestions EUR — voir le
    // commentaire « SUGGESTIONS » en tête de fichier.
    final spreadSuggestions = <_SpreadSuggestionCandidate>[];

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
      //
      // Étage 1-quater (amendement, voie (ii) — voir le commentaire de tête) : SEULE
      // exception à la garde ci-dessus — un échange PROPRE (2 jambes, garanti à ce
      // point par le pré-scan `ambiguousGroup` au-dessus) dont la jambe fiat vaut
      // littéralement `USD` est retenu comme candidat, avec la quantité NETTE de la
      // jambe fiat ELLE-MÊME (jamais `amountusd`, qui ne concerne que la jambe
      // crypto) comme valeur USD à convertir. Toute autre situation (devise étrangère
      // NON-USD, ou jambe fiat sans quantité exploitable — défensif) reste
      // `foreignFiat`, comme avant.
      if (u.codePaidIsFiat || u.codeReceivedIsFiat) {
        final fiatCode = u.codePaidIsFiat ? u.codePaid : u.codeReceived;
        final fiatQuantityRaw =
            u.codePaidIsFiat ? u.quantityPaid : u.quantityReceived;
        final fiatQuantity =
            fiatQuantityRaw == null ? null : Decimal.tryParse(fiatQuantityRaw)?.abs();
        if (u.kind == 'exchange' &&
            u.codePaidIsFiat != u.codeReceivedIsFiat &&
            fiatCode != null &&
            fiatCode.toUpperCase() == 'USD' &&
            fiatQuantity != null) {
          candidates.add(_ValuationCandidate(
            source: u,
            valuationUsd: fiatQuantity,
            valuationSource: 'fiatLeg',
          ));
          continue;
        }
        manual.add(CryptoValuationManual(
          source: u,
          reason: CryptoValuationManualReason.foreignFiat,
        ));
        continue;
      }

      // Étage 1-ter (amendement drive lot 2 : quantité NETTE d'une jambe stablecoin
      // dollar de CONFIANCE, calculée UNE FOIS ici et réutilisée comme repli par les
      // deux branches d'échec de l'étage 1 ci-dessous (`unreadable`/`spread`) —
      // jamais pour un dépôt en nature (pas de contrepartie à examiner). Les
      // quantités stockées sur [UnvaluedExchange] sont déjà des magnitudes NETTES
      // positives (cf. `CryptoLedgerNormalizer._processExchangeGroup`), directement
      // utilisables comme valeur USD.
      Decimal? stableLegUsd;
      if (u.kind == 'exchange') {
        if (u.codePaid != null &&
            usdStableCodes.contains(u.codePaid) &&
            u.quantityPaid != null) {
          stableLegUsd = Decimal.tryParse(u.quantityPaid!)?.abs();
        } else if (usdStableCodes.contains(u.codeReceived)) {
          stableLegUsd = Decimal.tryParse(u.quantityReceived)?.abs();
        }
      }

      final usdPaid = _tryParseAbs(u.usdPaid);
      final usdReceived = _tryParseAbs(u.usdReceived);
      final selected = usdPaid ?? usdReceived;
      if (selected == null) {
        if (stableLegUsd != null) {
          candidates.add(_ValuationCandidate(
            source: u,
            valuationUsd: stableLegUsd,
            valuationSource: 'stableLeg',
          ));
          continue;
        }
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
          if (stableLegUsd != null) {
            candidates.add(_ValuationCandidate(
              source: u,
              valuationUsd: stableLegUsd,
              spreadPct: spreadStr,
              valuationSource: 'stableLeg',
            ));
            continue;
          }
          // Amendement drive lot 2 (suite) : pas de repli 1-ter pour cette entrée —
          // reste manuelle, mais les DEUX valeurs USD sont retenues pour calcul de
          // suggestion EUR après récupération FX ci-dessous (pas encore de taux à ce
          // stade de la boucle).
          spreadSuggestions.add(_SpreadSuggestionCandidate(
            source: u,
            usdPaid: usdPaid,
            usdReceived: usdReceived,
            spreadPct: spreadStr,
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

    if (candidates.isEmpty && spreadSuggestions.isEmpty) {
      return CryptoValuationResolution(manual: manual);
    }

    // Bornes ENGLOBANTES : UNE SEULE récupération FX pour TOUTES les lignes
    // valorisables de cet import (conception interne) — [spreadSuggestions] partage
    // cette MÊME fenêtre/ce MÊME appel (amendement drive lot 2 (suite) : ses
    // entrées ne sont pas des candidates automatiques, mais leurs suggestions EUR
    // ont besoin du même taux, jamais d'un appel réseau supplémentaire.
    final valuableDates = [
      for (final c in candidates) c.source.date,
      for (final s in spreadSuggestions) s.source.date,
    ];
    var minDate = valuableDates.first;
    var maxDate = valuableDates.first;
    for (final d in valuableDates.skip(1)) {
      if (d.isBefore(minDate)) minDate = d;
      if (d.isAfter(maxDate)) maxDate = d;
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
        source: c.valuationSource,
      );
    }

    // Suggestions EUR (amendement drive lot 2 (suite) : même repli de date que
    // ci-dessus. Défensif si, exceptionnellement, aucun jour ouvré antérieur n'est
    // trouvé (série tronquée) — l'entrée reste manuelle motif `spread` mais SANS
    // suggestion plutôt qu'un taux inventé, jamais bascule vers `fxUnavailable` (une
    // suggestion manquante n'est pas une raison suffisante pour changer le motif :
    // la valorisation manuelle reste possible, seule l'aide au calcul manque).
    for (final s in spreadSuggestions) {
      final entry = _lastRateOnOrBefore(rates, s.source.date);
      Decimal? suggestedPaidEur;
      Decimal? suggestedReceivedEur;
      if (entry != null) {
        final rateDecimal = Decimal.parse(entry.value.toString());
        suggestedPaidEur = s.usdPaid * rateDecimal;
        suggestedReceivedEur = s.usdReceived * rateDecimal;
      }
      manual.add(CryptoValuationManual(
        source: s.source,
        reason: CryptoValuationManualReason.spread,
        valuationSpreadPct: s.spreadPct,
        suggestedPaidEur: suggestedPaidEur,
        suggestedReceivedEur: suggestedReceivedEur,
      ));
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

  /// `'statement'` (étage 1, défaut), `'stableLeg'` (étage 1-ter, repli « jambe
  /// stablecoin dollar », amendement drive lot 2 ou `'fiatLeg'` (étage 1-quater,
  /// jambe fiat étrangère USD, amendement voie (ii)) — reporté tel quel sur
  /// [CryptoValuation.source].
  final String valuationSource;

  const _ValuationCandidate({
    required this.source,
    required this.valuationUsd,
    this.spreadPct,
    this.valuationSource = 'statement',
  });
}

/// Entrée motif `spread` SANS repli 1-ter (amendement drive lot 2 (suite) —
/// jamais une candidate de valorisation AUTOMATIQUE, uniquement portée jusqu'à
/// la récupération FX pour calculer ses DEUX suggestions EUR (voir le
/// commentaire « SUGGESTIONS » en tête de fichier). [usdPaid]/ [usdReceived]
/// sont déjà des magnitudes POSITIVES (`_tryParseAbs`).
class _SpreadSuggestionCandidate {
  final UnvaluedExchange source;
  final Decimal usdPaid;
  final Decimal usdReceived;
  final String? spreadPct;

  const _SpreadSuggestionCandidate({
    required this.source,
    required this.usdPaid,
    required this.usdReceived,
    this.spreadPct,
  });
}

// lib/controllers/account_controller.dart
//
// Contrôleur de la vue compte : état + orchestration I/O.
// La présentation (dialogs, navigation, BuildContext) reste dans AccountView.
//
// INVARIANTS (design-vague3.md) :
//   1. Conversion USD uniquement : × usdToEurRate ssi asset.currency == 'USD'.
//      Les métaux précieux arrivent déjà en EUR — jamais re-convertis.
//   2. Pattern List.from(…) avant await conservé (protection contre les courses).
//   3. Les dialogs (_showAdd…, _editAccountName) restent en vue (dépendent du
//      BuildContext — risque R4).

import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/import_preview.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/crypto_valuation_service.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/utils/bounded_concurrency.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/logger.dart';

class AccountController extends ChangeNotifier {
  // ---------------------------------------------------------------------------
  // Services injectés (fakes possibles en test)
  // ---------------------------------------------------------------------------

  final AccountStorage _storage;
  final LedgerService _ledger;
  final MarketDataService _marketService;
  final ExchangeRateService _exchangeService;

  /// Moteur de valorisation étage 1 « fichier » des échanges crypto sans jambe
  /// fiat (chantier B16, lot 2, conception interne) — RÉUTILISE
  /// [_exchangeService] (même instance, même cache mémoire de la série FX
  /// historique) plutôt que d'en injecter un second, indépendant.
  final CryptoValuationService _cryptoValuationService;
  /// Lecture du journal (lot cash-ledger) : sert uniquement à décider l'opt-in
  /// d'affichage du cash dérivé (cf. [journalHasCashAnchor] dans
  /// [_loadDerivedCash]). Les mutations passent par [_ledger].
  final TransactionStorage _txStorage;

  // Garde contre les appels post-dispose (correctif B1)
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Notifie les listeners uniquement si le contrôleur n'a pas encore été
  /// disposé. Évite les FlutterError « used after being disposed » lors de
  /// continuations post-await après un dépilage de vue.
  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Paramètre d'initialisation
  // ---------------------------------------------------------------------------

  final String? initialAccountId;

  // ---------------------------------------------------------------------------
  // Constructeur
  // ---------------------------------------------------------------------------

  AccountController({
    required this.initialAccountId,
    AccountStorage? storage,
    LedgerService? ledgerService,
    MarketDataService? marketService,
    ExchangeRateService? exchangeService,
    CryptoValuationService? cryptoValuationService,
    TransactionStorage? transactionStorage,

    /// Taux USD→EUR pré-chargé (évite l'appel réseau en test).
    /// Si fourni, [loadExchangeRate] l'utilise directement sans interroger
    /// [ExchangeRateService].
    double? initialUsdToEurRate,
  }) : _storage = storage ?? AccountStorage(),
       _ledger = ledgerService ?? LedgerService(),
       _marketService = marketService ?? MarketDataService.shared,
       _exchangeService = exchangeService ?? ExchangeRateService(),
       _cryptoValuationService = cryptoValuationService ??
           CryptoValuationService(
             exchangeService: exchangeService ?? ExchangeRateService(),
           ),
       _txStorage = transactionStorage ?? TransactionStorage(),
       _usdToEurRate = initialUsdToEurRate ?? 0.92;

  // ---------------------------------------------------------------------------
  // État interne
  // ---------------------------------------------------------------------------

  List<PositionWithMarketData> _positionsData = [];
  String? _globalError;

  /// Positions masquées de la liste affichée en attente de confirmation de
  /// suppression (motif « suppression différée + Annuler »). Clé = symbole.
  /// Tant qu'une position y figure, elle est retirée de [positionsData] ET
  /// filtrée des rechargements ([_fetchAllPrices]) — mais NON supprimée du
  /// stockage. `commitDeletePosition` valide la suppression réelle ;
  /// `restorePosition` la réintègre. On garde l'objet complet (avec ses cours)
  /// pour restaurer sans nouvel appel réseau.
  final Map<String, PositionWithMarketData> _hiddenPositions = {};

  List<Account> _accounts = [];
  Account? _activeAccount;
  Wallet? _activeWallet;
  bool _isLoadingAccounts = true;

  /// D5 : vrai quand [initAccounts] a été appelé avec un [initialAccountId]
  /// introuvable (ni dans le stockage, ni — garde défensive — dans le wallet
  /// résolu). AUCUN repli silencieux sur un autre compte ne doit alors avoir
  /// lieu : [_activeAccount] reste `null` et la vue traduit cet état en écran
  /// « ce compte n'existe plus » plutôt que d'afficher, sans le dire, un
  /// compte QUELCONQUE à la place de celui demandé (bug constaté : bascule
  /// muette sur un compte cash, dont la section positions est masquée — « je
  /// reste sur une page de compte vide »). Remis à `false` en tête de chaque
  /// [initAccounts].
  bool _accountNotFound = false;

  /// Rafraîchissement non destructif en cours (distinct de [_isLoadingAccounts],
  /// qui n'est vrai qu'au tout premier chargement, données absentes). Pendant un
  /// [refresh] le contenu reste affiché ; la vue n'affiche qu'un indicateur
  /// discret plutôt qu'un spinner plein écran.
  bool _isRefreshing = false;

  ChartPeriod _selectedPeriod = ChartPeriod.month1;
  bool _isLoadingHistory = false;
  String? _historyError;
  List<DateTime> _chartDates = [];
  List<double> _chartValues = [];

  double? _periodChange;
  double? _periodChangePercent;

  // Mode 2 « évolution réelle » (B7, design conception interne) : reconstruction
  // datée depuis le journal du compte, calculée EN PARALLÈLE du mode 1 ci-dessus
  // (additif — n'écrit JAMAIS les champs mode 1). ALIGNÉE index-par-index sur
  // [_chartDates] (même grille, garantie par construction — cf.
  // _computeAccountRealCurve). PÉRIMÈTRE : titres du compte reconstruits depuis le
  // journal + CASH DÉRIVÉ du compte (projection B5 du même journal, gating d'ancrage
  // `journalHasCashAnchor` appliqué par `reconstructRealNetWorth`) — c'est la vraie
  // valeur du compte dans le temps, dont le point final coïncide avec la « Valeur
  // totale » affichée (qui inclut le cash). Diffère donc du mode 1 du compte
  // ([HistoryAggregator.aggregateHistoricalData], titres seuls sans cash) : le petit
  // écart au basculement est le solde espèces, assumé.
  List<double> _realChartValues = [];
  // Dernière couverture calculée HORS chargement (cf. [realCurveCoverage]) —
  // gèle le getter pendant un rechargement pour que le sélecteur de mode ne
  // bascule pas le temps du recalcul.
  double? _lastKnownCoverage;
  // Symboles dont la valeur, à au moins une date, provient d'un repli
  // « dernier cours connu » (pas un vrai historique de marché) — badge UI.
  Set<String> _realCurveApproxSymbols = {};
  // Positions ACTUELLEMENT détenues mais ABSENTES du journal (saisies à la
  // main, sans aucun mouvement associé) — donc EXCLUES de la reconstruction
  // ci-dessus (`currentPositions` dont le symbole n'est pas clé de
  // `txsBySymbol`, cf. [_computeAccountRealCurve]). Alimente l'avertissement
  // de complétude UI, désormais conditionnel, chiffré ET NOMMÉ (épuration UI,
  // remplace l'ancienne phrase inconditionnelle) : vide sur un compte cash,
  // qui n'a par construction aucune position.
  // NOMMÉES et non seulement comptées : l'écran compte, lui, sait AGIR sur un
  // titre (déclarer son opération d'origine, cf. [declareInitialPosition]) —
  // il cite donc les symboles. Ordre de [_positionsData] au moment du calcul,
  // stable d'un rendu à l'autre.
  List<String> _realExcludedLegacySymbols = const [];

  // Courbe des FLUX EXTERNES CUMULÉS du compte (B7 correction financière,
  // design §11.4 — ex-« apports nets », désormais [HistoryAggregator.
  // buildExternalFlowsCurve]) : ALIGNÉE index-par-index sur
  // [_chartDates]/[_realChartValues]. PÉRIMÈTRE du compte SEUL, pas de cash
  // pur (un compte titres n'a pas de pendant cash pur — contrairement au
  // wallet, cf. wallet_controller). Le NOM du champ est conservé pour limiter
  // le remue-ménage — seul le LABEL affiché change (« Capital investi »).
  List<double> _realContributionsValues = [];
  // Gain de PÉRIODE (B7 correction financière, design §7.3) : dérivé de
  // [_realChartValues]/[_realContributionsValues] via
  // [HistoryAggregator.computeRealGains] (Modified Dietz) — voir [RealGains].
  double? _realPeriodGain;
  double? _realPeriodGainPercent;
  // Rendement ANNUALISÉ, SECOND nombre affiché entre parenthèses aux côtés de
  // [_realPeriodGainPercent] dès que la fenêtre atteint 1 an — cf.
  // [RealGains.periodGainPercentAnnualized]. `null` = rien à afficher entre
  // parenthèses (fenêtre courte, ou garde de calcul déclenchée) ; ne
  // remplace JAMAIS [_realPeriodGainPercent] (TotalValueCard.percentAnnualized).
  double? _realPeriodGainPercentAnnualized;
  // Gain TOTAL (état courant, base coût, INDÉPENDANT de la fenêtre affichée)
  // via [HistoryAggregator.computeRealTotalGain] — voir [RealTotalGain].
  // Passe les positions DU COMPTE (legacy incluses si leur PRU est connu),
  // jamais gaté par la période sélectionnée.
  double? _realTotalGain;
  double? _realTotalGainPercent;
  // Sous-total `charge` SEUL, EN PLUS de `_realTotalGain` (n'en change rien) —
  // cf. [RealTotalGain.chargesTotal], destiné à la ligne « dont frais » du
  // popup d'aide.
  double? _realTotalGainCharges;
  // Symboles EXCLUS du calcul ci-dessus faute de PRU connu — cf.
  // [RealTotalGain.noBasisSymbols], destiné à l'avertissement UI (Lot C).
  Set<String> _realNoBasisSymbols = {};
  // Revenus d'un compte non ancré, comptés dans le gain total mais invisibles
  // dans la courbe — cf. [RealTotalGain.unanchoredRevenueEur], destiné à la
  // note explicative sous le graphe (ChartNotes).
  double _realUnanchoredRevenueEur = 0.0;

  double _usdToEurRate; // initialisé par le constructeur (0.92 par défaut)

  Map<String, double> _assetValues = {};
  bool _hasMultipleAssets = false;

  /// Solde espèces DÉRIVÉ du compte actif (String décimal exact, devise du
  /// compte), ou `null` si jamais projeté (aucun mouvement du tout dans le
  /// journal). Cache reconstructible (`accounts.derived_cash`) — cf.
  /// [AccountStorage.getAccountDerivedCash].
  String? _derivedCash;

  /// Opt-in d'affichage (design §3) : vrai si le journal du compte actif
  /// contient au moins un mouvement d'ANCRAGE espèces (deposit/withdrawal/
  /// interest/charge/openingBalance espèces). Piloté par
  /// [journalHasCashAnchor] — indépendant de la nullité de [_derivedCash] (un
  /// compte composé UNIQUEMENT de buy a déjà un derived_cash non-null, mais
  /// FAUX tant qu'aucun ancrage n'atteste un suivi réel de la trésorerie).
  bool _hasCashAnchor = false;

  /// Date du PREMIER mouvement du journal du compte actif, ou `null` si le
  /// journal est vide (compte 100 % legacy saisi à la main). Alimente
  /// [_gridFrom] — cf. [HistoryAggregator.applyGridFrom].
  DateTime? _firstTxDate;

  /// Borne gauche de la grille du graphique : la date du premier mouvement,
  /// mais UNIQUEMENT sur la période « Max ». Les autres périodes ont déjà une
  /// fenêtre bornée par leur propre durée (J/1M/…/5A) qu'il ne faut surtout
  /// pas rogner. `null` = grille complète, comportement d'origine.
  ///
  /// POURQUOI : la grille naît de l'historique de COTATION (Yahoo `range=max`
  /// pour cette période), qui remonte à l'introduction du support — d'où 22 ans
  /// de ligne plate à zéro devant un compte ouvert en 2023 (constaté le 29/07).
  DateTime? get _gridFrom =>
      _selectedPeriod == ChartPeriod.max ? _firstTxDate : null;

  /// Nombre de mouvements du compte actif dont la devise de RÈGLEMENT effective
  /// (`settlementCurrency ?? currency`) diffère de la devise du compte ET
  /// alimente un bucket cash NON NUL (lignes legacy d'avant le découplage
  /// cotation/règlement, ou futur multi-poches IBKR). Sert au garde-fou
  /// d'affichage (design §8.5) : le solde dérivé persisté ne couvre QUE la
  /// devise du compte ; ces mouvements en sont exclus. `0` = solde espèces
  /// complet dans la devise du compte (cas nominal après correction). Décision
  /// d'affichage pure — n'influe ni sur le cash dérivé ni sur sa persistance.
  int _foreignCashMovementCount = 0;

  /// Identifiant du DERNIER lot d'import confirmé avec succès (posé par
  /// [confirmStatementImport]), ou null tant qu'aucun import n'a été confirmé
  /// dans la vie de ce contrôleur. L'UI le lit via [lastImportBatchId] pour
  /// proposer « Annuler cet import » ([undoStatementImport]).
  String? _lastImportBatchId;

  /// Nombre de résidus de transferts internes non équilibrés (§5.1.5) dont la
  /// cascade de résolution [_resolveCryptoTicker] n'a, MALGRÉ TOUT, pas pu
  /// produire de symbole lors du DERNIER aperçu crypto — posé par
  /// [_previewCryptoImport] (I-2, revue adversariale). En pratique la cascade
  /// ne renvoie jamais de symbole vide (repli ultime `'crypto:<code>'` non
  /// coté) : ce compteur reste `0` dans tous les cas observés, mais existe
  /// pour honorer la garde « jamais ignoré en silence » plutôt que de
  /// dépendre d'une propriété non prouvée du code appelé. L'UI (hors
  /// périmètre de ce lot) peut l'afficher via
  /// [lastUnresolvedInternalTransferResidualCount].
  int _lastUnresolvedInternalTransferResidualCount = 0;

  // ---------------------------------------------------------------------------
  // Cache du DERNIER aperçu crypto (chantier B16, lot 2 — conception interne) : sert
  // exclusivement à [applyManualCryptoValuations], pour reconstruire l'aperçu après
  // une saisie manuelle SANS reparser le fichier (aucune I/O, aucun accès au journal
  // une seconde fois) — le plan PUR issu de
  // `CryptoLedgerNormalizer.planCryptoImport` ne change jamais, seule la table des
  // valorisations s'enrichit à chaque saisie. Remis à zéro en tête de
  // [previewStatementImport] (avant même de savoir si le profil est crypto) : un
  // nouvel aperçu — crypto ou non — invalide tout contexte précédent, pour ne jamais
  // appliquer une saisie manuelle à un plan obsolète (fichier différent, compte
  // différent, ré-import).
  // ---------------------------------------------------------------------------
  CryptoImportPlan? _lastCryptoPlan;
  Account? _lastCryptoAccount;
  String? _lastCryptoAccountId;
  BrokerProfile? _lastCryptoProfile;
  bool _lastCryptoFxUnavailable = false;

  /// Cache PERSISTANT de résolution ledgerCode→ticker (I-3, revue
  /// adversariale LOT 4), à travers TOUS les rebuilds successifs d'UN MÊME
  /// aperçu crypto ([_previewCryptoImport], puis chaque [applyManualCryptoValuations]/
  /// [revertCryptoValuationToManual] ultérieur) — sans lui, chaque
  /// reconstruction (ex. un clic sur « Repasser en saisie manuelle ») partait
  /// d'un cache VIDE et ré-interrogeait `symbolExists` en réseau pour TOUS
  /// les ledgerCode déjà résolus lors d'un appel précédent (jusqu'à 2 allers-
  /// retours par code, ~80 sur 40 codes distincts). Remis à zéro au même
  /// point que [_lastCryptoPlan] (nouvel aperçu = nouveau contexte).
  ///
  /// Alimenté via [_persistTickerCache] APRÈS chaque résolution — jamais
  /// directement passé comme `cache` mutable à [_resolveCryptoTicker] (voir
  /// cette méthode) : les résolutions marquées [_CryptoTickerResolution.
  /// networkFailure] en sont TOUJOURS exclues, pour qu'une panne PASSAGÈRE ne
  /// fige pas un actif en « non coté » pour le reste de la session — un
  /// prochain rebuild retente alors sa résolution au lieu de resservir cet
  /// échec.
  final Map<String, _CryptoTickerResolution> _lastCryptoTickerCache = {};

  /// I-2 (revue adversariale, LOT 4) : verrou UNIQUE de reconstruction
  /// d'aperçu crypto — [applyManualCryptoValuations]/
  /// [revertCryptoValuationToManual] se REFUSENT (retournent `null`, aperçu
  /// affiché INCHANGÉ) tant qu'un rebuild PRÉCÉDENT n'est pas terminé,
  /// plutôt que de laisser DEUX reconstructions concurrentes s'exécuter.
  /// SANS ce verrou : chaque rebuild lit/mute l'état PARTAGÉ du contrôleur
  /// (`_lastCryptoValuations`/`_lastCryptoManualReasons`) et calcule un
  /// [ImportPreview] de façon asynchrone (dédup au journal, résolution
  /// ticker) — si l'utilisateur enchaîne deux actions rapprochées sur DEUX
  /// lignes DIFFÉRENTES (chacune désactive seulement SON propre bouton côté
  /// UI, `_revertingValuationKeys`), le rebuild qui a COMMENCÉ en premier
  /// peut malgré tout se TERMINER en second : son résultat — calculé sur un
  /// instantané `_lastCryptoValuations` antérieur au retrait de la SECONDE
  /// ligne — écrase alors l'aperçu affiché avec une version où cette ligne
  /// est encore valorisée au cours du marché, alors que l'utilisateur a
  /// explicitement demandé l'arbitrage manuel pour elle. Un SEUL rebuild en
  /// vol à la fois élimine la course : plus rien à réordonner.
  bool _valuationRebuildInFlight = false;

  /// Fusionne [freshCache] (résultat d'UNE résolution, potentiellement
  /// enrichi de nouvelles entrées) dans [_lastCryptoTickerCache] — voir la
  /// doc de ce champ pour la garde `networkFailure` (I-3, revue adversariale
  /// LOT 4).
  void _persistTickerCache(Map<String, _CryptoTickerResolution> freshCache) {
    for (final entry in freshCache.entries) {
      if (!entry.value.networkFailure) {
        _lastCryptoTickerCache[entry.key] = entry.value;
      }
    }
  }

  /// Valorisations déjà résolues (étage 1 « fichier » + saisies manuelles
  /// cumulées d'un appel à l'autre) — clé = `UnvaluedExchange.importKey`, la
  /// même table que consomme `StatementImportService.finalizeCryptoExchanges`.
  final Map<String, CryptoValuation> _lastCryptoValuations = {};

  /// Motif ORIGINAL de chaque échange resté manuel (`unreadable`/`spread`/
  /// `fxUnavailable`), posé UNE SEULE FOIS par [_previewCryptoImport] (le motif ne
  /// dépend que des jambes du relevé, jamais d'une saisie manuelle ultérieure) —
  /// reporté tel quel par [applyManualCryptoValuations] sur les entrées qui restent
  /// manuelles après une saisie partielle. Porte aussi les suggestions EUR
  /// (`suggestedPaidEur`/`suggestedReceivedEur`, `null` sauf motif `spread` avec
  /// taux résolu — amendement drive lot 2 (suite) pour qu'elles survivent, elles
  /// aussi, à une ré-application partielle.
  final Map<
      String,
      ({
        String reason,
        String? spreadPct,
        String? suggestedPaidEur,
        String? suggestedReceivedEur,
      })> _lastCryptoManualReasons = {};

  // ---------------------------------------------------------------------------
  // Getters publics
  // ---------------------------------------------------------------------------

  List<PositionWithMarketData> get positionsData => _positionsData;
  String? get globalError => _globalError;
  int get lastUnresolvedInternalTransferResidualCount =>
      _lastUnresolvedInternalTransferResidualCount;
  List<Account> get accounts => _accounts;
  Account? get activeAccount => _activeAccount;
  Wallet? get activeWallet => _activeWallet;

  /// D5 : vrai si le compte demandé ([initialAccountId]) n'existe plus — la
  /// vue doit alors afficher l'état « ce compte n'existe plus » plutôt que le
  /// contenu normal (qui suppose [activeAccount] non-null).
  bool get accountNotFound => _accountNotFound;
  bool get isLoadingAccounts => _isLoadingAccounts;
  bool get isRefreshing => _isRefreshing;
  ChartPeriod get selectedPeriod => _selectedPeriod;
  bool get isLoadingHistory => _isLoadingHistory;
  String? get historyError => _historyError;
  List<DateTime> get chartDates => _chartDates;
  List<double> get chartValues => _chartValues;
  double? get periodChange => _periodChange;
  double? get periodChangePercent => _periodChangePercent;

  /// Série du mode 2 « évolution réelle » (titres seuls, cf. commentaire de
  /// [_realChartValues]), ALIGNÉE index-par-index sur [chartDates]. Vide tant
  /// qu'aucun calcul mode 2 n'a abouti (cf. [hasRealCurve]).
  List<double> get realChartValues => _realChartValues;

  /// Symboles dont la valeur mode 2 provient d'un repli « dernier cours
  /// connu » plutôt que d'un véritable historique de marché — destiné au
  /// badge « valeurs approchées ».
  Set<String> get realCurveApproxSymbols => _realCurveApproxSymbols;

  /// Symboles détenus sur le compte actif sans AUCUN mouvement journalisé,
  /// donc absents de [realChartValues] — cf. [_realExcludedLegacySymbols].
  /// Vide = rien n'est exclu (notamment tout compte cash, sans position par
  /// construction). C'est la liste que la note sous le graphe NOMME, et dont
  /// chaque entrée ouvre la déclaration de l'opération d'origine.
  ///
  /// PEUT être non vide alors que [hasRealCurve] est faux : un compte 100 %
  /// hérité (aucun titre journalisé) n'a pas de courbe réelle à montrer, mais
  /// c'est justement là que cette liste importe le plus — c'est tout ce qu'il
  /// y a à déclarer pour un jour en obtenir une.
  List<String> get realExcludedLegacySymbols =>
      List<String>.unmodifiable(_realExcludedLegacySymbols);

  /// Nombre de positions détenues sans AUCUN mouvement journalisé, donc
  /// absentes de [realChartValues]. `0` = rien n'est exclu.
  ///
  /// DÉRIVÉ de [realExcludedLegacySymbols] : un seul champ écrit, donc jamais
  /// un chiffre qui contredirait la liste affichée juste à côté.
  int get realExcludedLegacyCount => _realExcludedLegacySymbols.length;

  /// Vrai si une courbe mode 2 est disponible pour l'affichage.
  bool get hasRealCurve => _realChartValues.isNotEmpty;

  /// Valeur COURANTE du compte en EUR, telle que l'écran la met en avant
  /// (« Valeur totale ») : titres au dernier cours connu + espèces.
  ///
  /// Vit ICI et non dans la vue depuis l'ajout de [realCurveCoverage] : les
  /// deux en ont besoin, et deux calculs parallèles auraient fini par diverger
  /// sur la GARDE D'ANCRAGE ci-dessous — la subtilité qui compte.
  ///
  /// GARDE D'ANCRAGE, non négociable (invariant « faux négatif interdit », design
  /// cash-ledger §6.7 / partition conception interne) : sur un compte SANS
  /// mouvement d'espèces au journal, [derivedCash] vaut « ce que les achats ont
  /// coûté », soit un solde NÉGATIF FICTIF (le cache `accounts. derived_cash` est
  /// écrit inconditionnellement — sa non-nullité ne protège de rien, seul
  /// [hasCashAnchor] protège). Même garde que [WalletController._cashBalances] et
  /// que [reconstructRealNetWorth].
  double get currentTotalValueEur {
    final account = _activeAccount;
    if (account == null) return 0.0;
    final cashRate =
        account.currency.toUpperCase() == 'USD' ? _usdToEurRate : 1.0;

    if (account.type == AccountType.cash) {
      // Un livret n'a aucune position : sa valeur EST son solde espèces (dérivé du
      // journal si ancré, `cash_balance` legacy sinon — même règle que
      // WalletController.loadAllData, B8 conception interne).
      final cashRaw = _hasCashAnchor
          ? (double.tryParse(_derivedCash ?? '0') ?? 0.0)
          : (account.cashBalance ?? 0.0);
      return cashRaw * cashRate;
    }

    var total = 0.0;
    for (final positionData in _positionsData) {
      final price = positionData.currentPrice ?? 0;
      final qty = double.tryParse(positionData.quantity) ?? 0;
      var value = price * qty;
      if (positionData.asset.currency.toUpperCase() == 'USD') {
        value *= _usdToEurRate;
      }
      total += value;
    }
    // Cash dérivé du journal : fait partie de la valeur détenue du compte.
    if (_hasCashAnchor) {
      total += (double.tryParse(_derivedCash ?? '0') ?? 0.0) * cashRate;
    }
    return total;
  }

  /// COUVERTURE de la courbe réelle : part de la valeur COURANTE du compte
  /// que représente son dernier point (`realChartValues.last /
  /// currentTotalValueEur`). `null` sans courbe réelle, ou si la valeur
  /// courante est ≤ 0 (ratio dénué de sens). Alimente la politique de mode par
  /// défaut (`lib/logic/chart_mode_policy.dart`) et la note chiffrée sous le
  /// graphe.
  ///
  /// CE QUE PÈSE LE DERNIER POINT (vérifié dans [_computeAccountRealCurve]) —
  /// à la dernière date de la grille affichée (la plus récente, grilles
  /// triées) : les titres JOURNALISÉS du compte au dernier cours HISTORIQUE
  /// de la fenêtre, PLUS le cash dérivé du compte s'il est ancré (gating
  /// [journalHasCashAnchor] appliqué par [reconstructRealNetWorth]) — le même
  /// terme d'espèces, sous la même garde, que [currentTotalValueEur]. Il lui
  /// manque donc, face à la valeur courante : les positions HÉRITÉES (cf.
  /// [realExcludedLegacyCount]), un titre journalisé sans aucun cours
  /// exploitable, et l'écart de source de prix (dernier cours historique vs
  /// cotation live) que le seuil de la politique absorbe.
  ///
  /// Compte CASH ancré : le dernier point de la grille synthétique est
  /// `now` et vaut le solde dérivé courant — la couverture y est ~1, la garde
  /// n'y change donc rien (la vue y force de toute façon le mode réel).
  ///
  /// GEL pendant un rechargement ([_isLoadingHistory]) : `_realChartValues`
  /// est alors l'ANCIENNE courbe alors que `currentTotalValueEur` peut déjà
  /// refléter une NOUVELLE valorisation — recalculer ici donnerait un ratio
  /// incohérent, et donc un bascule intempestif du sélecteur de mode le temps
  /// du calcul. On fige alors la dernière valeur connue
  /// ([_lastKnownCoverage]) : le getter ne recalcule et ne met à jour ce cache
  /// QUE hors chargement.
  double? get realCurveCoverage {
    if (_isLoadingHistory) return _lastKnownCoverage;
    double? result;
    if (_realChartValues.isNotEmpty) {
      final total = currentTotalValueEur;
      if (total > 0) result = _realChartValues.last / total;
    }
    _lastKnownCoverage = result;
    return result;
  }

  /// Courbe des apports nets cumulés du compte (B7 Lot 3b), ALIGNÉE
  /// index-par-index sur [chartDates]/[realChartValues]. Vide tant qu'aucun
  /// calcul mode 2 n'a abouti.
  List<double> get realContributionsValues => _realContributionsValues;

  /// Gains sur la période affichée (mode réel), isolés des apports/retraits —
  /// cf. [HistoryAggregator.computeRealGains]. `null` tant qu'aucun calcul
  /// mode 2 n'a abouti, ou fenêtre < 2 points.
  double? get realPeriodGain => _realPeriodGain;
  double? get realPeriodGainPercent => _realPeriodGainPercent;

  /// Rendement ANNUALISÉ, à afficher EN PLUS de [realPeriodGainPercent] (pas
  /// à sa place) dès que la fenêtre atteint 1 an — cf.
  /// [HistoryAggregator.computeRealGains]/[RealGains.periodGainPercentAnnualized].
  /// `null` = rien à afficher entre parenthèses.
  double? get realPeriodGainPercentAnnualized => _realPeriodGainPercentAnnualized;

  /// Gains TOTAUX en état courant (base coût), INDÉPENDANTS de la période
  /// sélectionnée — cf. [HistoryAggregator.computeRealTotalGain]. `null` tant
  /// qu'aucun calcul mode 2 n'a abouti.
  double? get realTotalGain => _realTotalGain;
  double? get realTotalGainPercent => _realTotalGainPercent;

  /// Sous-total `charge` SEUL inclus dans [realTotalGain] (ne le modifie
  /// pas) — cf. [RealTotalGain.chargesTotal]. `null` tant qu'aucun calcul
  /// mode 2 n'a abouti, `0.0` si le journal ne comporte aucun mouvement
  /// `charge`.
  double? get realTotalGainCharges => _realTotalGainCharges;

  /// Symboles EXCLUS du calcul des gains totaux faute de PRU connu — cf.
  /// [HistoryAggregator.computeRealTotalGain].
  Set<String> get realNoBasisSymbols => _realNoBasisSymbols;

  /// Revenus (dividendes/intérêts/frais) d'un compte NON ancré, comptés dans
  /// [realTotalGain] mais absents de la courbe réelle — cf.
  /// [RealTotalGain.unanchoredRevenueEur]. `0.0` si aucun (cas courant).
  double get realUnanchoredRevenueEur => _realUnanchoredRevenueEur;

  double get usdToEurRate => _usdToEurRate;
  Map<String, double> get assetValues => _assetValues;
  bool get hasMultipleAssets => _hasMultipleAssets;
  String? get derivedCash => _derivedCash;
  bool get hasCashAnchor => _hasCashAnchor;
  int get foreignCashMovementCount => _foreignCashMovementCount;

  /// Identifiant du dernier lot d'import confirmé (cf. [_lastImportBatchId]),
  /// à passer à [undoStatementImport] pour annuler CET import précis. Null tant
  /// qu'aucun import n'a été confirmé.
  String? get lastImportBatchId => _lastImportBatchId;

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  /// Point d'entrée : charge wallets, comptes et positions.
  ///
  /// D5 : quand [initialAccountId] est fourni mais introuvable, AUCUN repli
  /// silencieux sur un autre compte — l'ancien `firstWhere(orElse: () =>
  /// allAccounts.first)`/`accounts.first` basculait la page sur un compte
  /// QUELCONQUE sans le dire (et sans lever l'exception `StateError` qu'une
  /// liste vide aurait produite, elle, avalée par le `catch` générique
  /// ci-dessous en un message d'erreur peu parlant). On pose à la place un
  /// état explicite ([accountNotFound]) que la vue traduit en écran dédié.
  Future<void> initAccounts() async {
    _isLoadingAccounts = true;
    _accountNotFound = false;
    _safeNotify();

    try {
      // 1. Charger tous les wallets
      var wallets = await _storage.getAllWallets();

      // Création d'un wallet par défaut si aucun n'existe
      if (wallets.isEmpty) {
        final defaultWallet = Wallet(
          id: Wallet.generateId(),
          name: 'Mon Patrimoine',
        );
        await _storage.saveWallet(defaultWallet);
        wallets = [defaultWallet];
      }

      // 2. Charger tous les comptes pour trouver celui avec initialAccountId
      final allAccounts = await _storage.getAllAccounts();

      // Déterminer le wallet actif et le compte actif.
      Account? targetAccount;
      if (initialAccountId != null) {
        final targetIndex = allAccounts.indexWhere(
          (a) => a.id == initialAccountId,
        );
        if (targetIndex < 0) {
          // Compte introuvable NULLE PART : état explicite, retour immédiat
          // (pas de _initService, qui suppose _activeAccount non-null).
          _accountNotFound = true;
          _activeAccount = null;
          _accounts = const [];
          _activeWallet = wallets.first;
          _isLoadingAccounts = false;
          _safeNotify();
          return;
        }
        targetAccount = allAccounts[targetIndex];
        // Utiliser le wallet du compte trouvé.
        final walletIndex = wallets.indexWhere(
          (w) => w.id == targetAccount!.walletId,
        );
        // Défensif : le wallet du compte trouvé devrait toujours figurer dans
        // `wallets` (même stockage, même lecture) — repli sur le premier
        // wallet plutôt qu'un `firstWhere` qui lèverait si l'invariant venait
        // à se rompre (pas de compte pour autant introuvable : c'est le
        // WALLET qui manquerait, cas distinct de D5).
        _activeWallet = walletIndex >= 0 ? wallets[walletIndex] : wallets.first;
      } else {
        _activeWallet = wallets.first;
      }

      // 3. Charger les comptes du wallet actif
      final accounts = allAccounts
          .where((a) => a.walletId == _activeWallet!.id)
          .toList();

      // 4. Sélectionner le compte actif
      _accounts = accounts;
      if (targetAccount != null) {
        final foundIndex = accounts.indexWhere(
          (a) => a.id == targetAccount!.id,
        );
        // `targetAccount` a été retenu ci-dessus PRÉCISÉMENT pour le wallet
        // qu'il désigne (`_activeWallet = wallets[walletIndex]` via son
        // propre `walletId`) : il figure donc TOUJOURS dans `accounts`, sauf
        // rupture de l'invariant défensif ci-dessus (wallet introuvable) — on
        // traite alors ce cas comme un compte introuvable plutôt que de
        // planter sur un `firstWhere` sans repli.
        if (foundIndex < 0) {
          _accountNotFound = true;
          _activeAccount = null;
          _isLoadingAccounts = false;
          _safeNotify();
          return;
        }
        _activeAccount = accounts[foundIndex];
      } else {
        _activeAccount = accounts.isNotEmpty ? accounts.first : null;
      }
      _isLoadingAccounts = false;
      _safeNotify();

      await _initService();
    } catch (e) {
      _globalError = e.toString();
      _isLoadingAccounts = false;
      _safeNotify();
    }
  }

  /// Charge le taux de change USD→EUR en parallèle de l'initialisation.
  Future<void> loadExchangeRate() async {
    final rate = await _exchangeService.getUsdToEurRate();
    _usdToEurRate = rate;
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // Chargement des prix et de l'historique
  // ---------------------------------------------------------------------------

  Future<void> _initService() async {
    if (_activeAccount == null) return;
    await _loadAllPrices();
    // AVANT l'historique (ordre inversé par B8, conception interne) : [_derivedCash]
    // alimente le CAPITAL du gain total mode 2 (`cashEur` de
    // [HistoryAggregator.computeRealTotalGain], cf. [_computeAccountRealCurve]) — le
    // charger après laissait ce capital à 0 au premier affichage, et rendrait un
    // compte cash journalisé (dont le cash EST toute la valeur) franchement faux.
    await _loadDerivedCash();
    await _loadAccountHistory();
  }

  /// Recharge le cash dérivé du compte actif ET l'opt-in d'affichage (lot
  /// cash-ledger). À appeler après TOUTE mutation de mouvement affectant le
  /// cash du compte (émission d'un solde initial / ajustement espèces) — même
  /// motif que [_reloadProjection] côté position (position_detail_page.dart).
  Future<void> _loadDerivedCash() async {
    final account = _activeAccount;
    if (account == null) return;
    final txs = await _txStorage.getByAccount(account.id);
    final derived = await _storage.getAccountDerivedCash(account.id);
    if (_disposed) return;
    _hasCashAnchor = journalHasCashAnchor(txs);
    _derivedCash = derived.cash;
    // Borne gauche de la période « Max » (cf. [_gridFrom]) : capturée ICI, où
    // le journal est déjà en main, car l'agrégation qui la consomme tourne
    // AVANT que la courbe réelle ne relise les mouvements.
    _firstTxDate = txs.isEmpty
        ? null
        : txs.map((t) => t.date).reduce((a, b) => a.isBefore(b) ? a : b);
    _foreignCashMovementCount = _countForeignCashMovements(txs, account.currency);
    _safeNotify();
  }

  /// Détecte les mouvements en devise de règlement ÉTRANGÈRE (≠ devise du
  /// compte) alimentant un bucket cash non nul, pour le garde-fou d'affichage
  /// (design §8.5). Détection par `cashByCurrency` (buckets nets non nuls hors
  /// devise du compte), puis comptage des mouvements y contribuant. Ne somme
  /// JAMAIS des devises hétérogènes (chaque bucket reste séparé).
  int _countForeignCashMovements(
    List<AssetTransaction> txs,
    String accountCurrency,
  ) {
    final acc = accountCurrency.toUpperCase();
    final byCurrency = replayLedger(txs).cashByCurrency;
    final foreignNonZero = <String>{
      for (final e in byCurrency.entries)
        if (e.key.toUpperCase() != acc && e.value != Decimal.zero) e.key,
    };
    if (foreignNonZero.isEmpty) return 0;
    var count = 0;
    for (final tx in txs) {
      if (tx.amount == null || tx.amount!.trim().isEmpty) continue;
      final settlement = tx.settlementCurrency ?? tx.currency;
      if (foreignNonZero.contains(settlement)) count++;
    }
    return count;
  }

  /// Charge toutes les positions du compte actif et leurs cours.
  /// Reste volontairement écrit ici plutôt que délégué à un service dédié :
  /// la boucle de cotation s'appuie sur les services injectés (_storage,
  /// _marketService), ce qui permet de les remplacer par des fakes en test.
  Future<List<PositionWithMarketData>> _fetchAllPrices() async {
    final positions = await _storage.getPositions(_activeAccount!.id);
    // On cote TOUTES les positions du stockage, y compris celles actuellement
    // masquées (suppression différée en attente). Le filtrage des masquées est
    // volontairement reporté à l'assignation finale de `_positionsData` (dans
    // `_loadAllPrices` / `refresh` / `_loadAccountHistory`), APRÈS le dernier
    // await : c'est le seul moment où `_hiddenPositions` reflète les mutations
    // synchrones (hide/restore) survenues pendant ce long fetch réseau. Filtrer
    // ici (avant l'await) rendrait l'ensemble obsolète et réintroduirait la
    // course « la masquée réapparaît / l'Annuler est perdu ». Le léger surcoût
    // (coter aussi les masquées) est accepté au profit de la correction.
    //
    // Concurrence BORNÉE (mapBounded) : autant de positions que le compte en
    // détient, potentiellement bien plus que la borne — sans elle, un compte
    // à beaucoup de titres partirait en rafale non bornée vers Yahoo (risque
    // de 429).
    final results = await mapBounded(
      positions,
      maxConcurrentMarketRequests,
      (position) async {
        // Actif NON COTÉ (repli ISIN / titre délisté) : jamais interrogé sur la
        // source de marché. Traité comme « sans cotation » — currentPrice null
        // → valorisé 0 en aval (position soldée = 0 par construction) ; PAS
        // d'errorMessage (ce n'est pas un échec, c'est un choix). Le badge
        // « non coté » de l'UI se déduit directement de asset.quotable.
        if (!position.asset.quotable) {
          // currentPrice 0 (pas null) : valorisation 0 ET `isLoading == false`
          // (l'actif n'est pas « en cours de chargement », il est délibérément
          // sans cotation).
          return PositionWithMarketData(position: position, currentPrice: 0);
        }
        final quote = await _marketService.getQuoteForAsset(position.asset);
        if (quote == null || quote.hasError) {
          return PositionWithMarketData(
            position: position,
            errorMessage: 'Erreur de cotation',
          );
        }

        // Backfill lazy du type : reclasse les positions à type auto-déduit au
        // fil des cotations, sans migration ni requête dédiée. Ne touche QUE les
        // actifs classiques non verrouillés dont Yahoo fournit un instrumentType
        // aboutissant à un type DIFFÉRENT. Exclusions volontaires :
        //  - `typeLocked` : choix manuel de l'utilisateur, jamais écrasé ;
        //  - `refSymbol != null` (métaux) : la quote porte le type du cours de
        //    référence (GC=F→FUTURE, ETC→EQUITY), non celui de la position ;
        //    de plus getQuoteForAsset ne propage pas instrumentType pour eux.
        // Écriture ciblée d'asset_json via updatePositionMetadata : jamais
        // savePosition (qui écraserait la projection quantité/PRU/derived_at).
        final effectivePosition =
            await _backfillAssetTypeIfNeeded(position, quote);

        return PositionWithMarketData(
          position: effectivePosition,
          currentPrice: quote.price?.toDouble(),
          change: quote.change?.toDouble(),
          changePercent: quote.changePercent?.toDouble(),
          currency: quote.currency,
          // asOf non-null = quote servie depuis le cache LOT 2 (dernier cours
          // connu) : la vue affiche alors un badge « Cours du JJ/MM ». En direct
          // asOf est null → lastUpdated reste null → aucun badge (le badge se
          // base sur la présence de la donnée, cf. StaleDataBadge). NE PAS
          // retomber sur DateTime.now() ici, sinon le badge s'afficherait sur
          // toutes les cotations live.
          lastUpdated: quote.asOf,
        );
      },
    );
    return results;
  }

  /// Reclasse le type d'une position à partir du fait de marché si — et
  /// seulement si — c'est sûr et utile. Retourne la position inchangée dans
  /// tous les cas où aucun reclassement n'est appliqué (voir les exclusions
  /// documentées à l'appel dans [_fetchAllPrices]). Persiste via
  /// [AccountStorage.updatePositionMetadata] (asset_json seul) pour ne jamais
  /// perturber la projection quantité/PRU/derived_at du journal.
  Future<Position> _backfillAssetTypeIfNeeded(
    Position position,
    AssetQuoteData quote,
  ) async {
    final asset = position.asset;
    if (asset.typeLocked ||
        asset.refSymbol != null ||
        quote.instrumentType == null) {
      return position;
    }
    final derived = AssetType.fromYahooInstrumentType(quote.instrumentType);
    if (derived == asset.type) return position;

    // Anti-course : [position] a été lu en début de _fetchAllPrices, possible-
    // ment plusieurs secondes plus tôt (attente réseau du Future.wait). Entre-
    // temps l'utilisateur a pu verrouiller le type à la main (choix manuel qui
    // fait autorité) ou le supprimer. On relit l'état frais juste avant
    // d'écrire et on re-vérifie les gardes sur CETTE valeur : sans ça, le
    // backfill réécrirait sa copie périmée (non verrouillée) et annulerait
    // silencieusement le verrou manuel. Fenêtre réduite de secondes à ms.
    final fresh = await _storage.getPosition(
      position.accountId,
      position.symbol,
    );
    if (fresh == null ||
        fresh.asset.typeLocked ||
        fresh.asset.refSymbol != null ||
        fresh.asset.type == derived) {
      return position;
    }

    final newAsset = fresh.asset.copyWith(type: derived);
    await _storage.updatePositionMetadata(
      position.accountId,
      position.symbol,
      asset: newAsset,
    );
    return position.copyWith(asset: newAsset);
  }

  Future<void> _loadAllPrices() async {
    if (_activeAccount == null) return;

    _globalError = null;

    try {
      final results = await _fetchAllPrices();
      // Invariant : _positionsData == (positions du stockage) − _hiddenPositions,
      // évalué APRÈS le dernier await (les hide/restore concurrents au fetch sont
      // ainsi pris en compte). _recomputeAssetValues opère sur cette liste finale
      // filtrée, jamais sur `results` brut → camembert/total cohérents.
      _positionsData = results
          .where((p) => !_hiddenPositions.containsKey(p.symbol))
          .toList();
      _recomputeAssetValues();
      _safeNotify();
    } catch (e) {
      _globalError = e.toString();
      _safeNotify();
    }
  }

  /// Recalcule [_assetValues] / [_hasMultipleAssets] à partir de
  /// [_positionsData] courant. Conversion EUR UNIQUEMENT pour les actifs en USD
  /// (invariant n°1). Appelé après chaque mutation de la liste affichée
  /// (chargement des cours, masquage/restauration d'une position).
  void _recomputeAssetValues() {
    final Map<String, double> assetValues = {};
    for (final posData in _positionsData) {
      final symbol = posData.symbol;
      final price = posData.currentPrice ?? 0;
      final qty = double.tryParse(posData.quantity) ?? 0;
      double value = price * qty;

      if (posData.asset.currency.toUpperCase() == 'USD') {
        value = value * _usdToEurRate;
      }

      assetValues[symbol] = (assetValues[symbol] ?? 0) + value;
    }
    _assetValues = assetValues;
    _hasMultipleAssets = assetValues.length > 1;
  }

  /// Rafraîchit les prix des positions.
  Future<void> refresh() async {
    if (_activeAccount == null) return;
    // Garde de ré-entrance : le pull-to-refresh (RefreshIndicator.onRefresh)
    // peut relancer refresh() alors qu'un refresh est déjà en vol → deux
    // _fetchAllPrices concurrents (papillotement + vecteur du Défaut 1). On ne
    // garde QUE contre un refresh concurrent : le tout premier chargement passe
    // par initAccounts/_isLoadingAccounts, non affecté ici.
    if (_isRefreshing) return;
    // Rafraîchissement NON destructif : on garde le contenu affiché et on
    // signale seulement un indicateur discret (isRefreshing), au lieu du
    // spinner plein écran réservé au premier chargement (isLoadingAccounts).
    _isRefreshing = true;
    _safeNotify();

    try {
      final results = await _fetchAllPrices();
      // Même invariant que _loadAllPrices : filtrage des masquées à
      // l'assignation finale, après le dernier await (cf. Défaut 1).
      _positionsData = results
          .where((p) => !_hiddenPositions.containsKey(p.symbol))
          .toList();
      _recomputeAssetValues();
      _safeNotify();
      // Rafraîchissement MANUEL explicite (pull-to-refresh) : vide le cache
      // mémoire des séries historiques AVANT de recharger l'historique, pour
      // que l'utilisateur obtienne bien une ronde réseau plutôt qu'une
      // réponse resservie (même si le TTL n'a pas expiré). Les rechargements
      // « structurels » (import, CRUD → _initService) ne le font PAS : la
      // série de prix d'un symbole ne dépend jamais du journal local,
      // resservir le cache y reste correct.
      _marketService.invalidateHistoryCache();
      await _loadAccountHistory();
    } catch (e) {
      _globalError = e.toString();
      _safeNotify();
    } finally {
      _isRefreshing = false;
      _safeNotify();
    }
  }

  // ---------------------------------------------------------------------------
  // Historique et période
  // ---------------------------------------------------------------------------

  Future<void> _loadAccountHistory() async {
    if (_positionsData.isEmpty) {
      // B8 (conception interne) : un compte CASH ANCRÉ n'a aucune position mais a bel
      // et bien une histoire — son journal. Il ne doit donc plus tomber dans le repli «
      // aucun historique du tout » : sa grille naît de
      // [HistoryAggregator.buildDateGrid] faute de toute série de prix où
      // s'échantillonner. Restreint aux comptes de type cash à dessein : un compte
      // TITRES sans position n'a pas de grille de prix non plus, mais son mode 2
      // porterait des titres soldés dont l'arbitrage de grille (prix vs synthétique)
      // n'est pas tranché — hors périmètre de ce lot. Tout autre compte sans position
      // (compte titres vide, compte cash LEGACY) garde le comportement d'avant B8, bit
      // pour bit.
      final account = _activeAccount;
      final cashTxs = (account != null && account.type == AccountType.cash)
          ? await _txStorage.getByAccount(account.id)
          : const <AssetTransaction>[];
      if (account != null && journalHasCashAnchor(cashTxs)) {
        await _loadCashAccountHistory(account, cashTxs);
        return;
      }

      _isLoadingHistory = false;
      _chartValues = [];
      _chartDates = [];
      _periodChange = null;
      _periodChangePercent = null;
      _realChartValues = [];
      _realCurveApproxSymbols = {};
      _realExcludedLegacySymbols = const [];
      _realContributionsValues = [];
      _resetRealGains();
      _safeNotify();
      return;
    }

    _isLoadingHistory = true;
    _historyError = null;
    _periodChange = null;
    _periodChangePercent = null;
    _safeNotify();

    try {
      // Capture locale avant les await (protection contre les courses — R3)
      final currentPositions = List<PositionWithMarketData>.from(
        _positionsData,
      );

      // Concurrence BORNÉE (mapBounded, cf. _fetchAllPrices) : ordre des
      // résultats préservé, indispensable ici — `results[i]` est appairé par
      // index à `currentPositions[i]` (agrégation + mode 2 plus bas).
      final results = await mapBounded(
        currentPositions,
        maxConcurrentMarketRequests,
        (positionData) => _marketService.getHistoricalDataForAsset(
          positionData.asset,
          days: _selectedPeriod.days,
        ),
      );

      // Calculs purs — pas de mutation d'état intermédiaire
      final aggregated = HistoryAggregator.aggregateHistoricalData(
        results: results,
        currentPositions: currentPositions,
        usdToEurRate: _usdToEurRate,
        gridFrom: _gridFrom,
      );
      final updatedPositions = HistoryAggregator.computeIndividualPeriodChanges(
        results: results,
        currentPositions: currentPositions,
        usdToEurRate: _usdToEurRate,
      );

      // Un seul notify cohérent
      _chartDates = aggregated.dates;
      _chartValues = aggregated.values;
      _periodChange = aggregated.change;
      _periodChangePercent = aggregated.changePercent;
      // Même invariant que _loadAllPrices / refresh : un hidePosition survenu
      // pendant les await d'historique ne doit pas être ré-injecté par cette
      // réassignation en bloc. On refiltre les masquées à l'assignation finale.
      _positionsData = updatedPositions
          .where((p) => !_hiddenPositions.containsKey(p.symbol))
          .toList();

      // Mode 2 « évolution réelle » (B7) : calculé EN PARALLÈLE du mode 1
      // ci-dessus, JAMAIS bloquant — une erreur ici (réseau, données
      // incohérentes) laisse simplement la courbe réelle absente
      // ([hasRealCurve] false) ; le mode 1 reste intact et affiché.
      try {
        await _computeAccountRealCurve(currentPositions, results);
      } catch (e, st) {
        AppLogger.warning(
          'Impossible de calculer la courbe réelle du compte (mode 2)',
          e,
          st,
        );
        _realChartValues = [];
        _realCurveApproxSymbols = {};
        _realExcludedLegacySymbols = const [];
        _realContributionsValues = [];
        _resetRealGains();
      }

      _isLoadingHistory = false;
      _safeNotify();
    } catch (e) {
      AppLogger.error('Erreur chargement historique: $e');
      _historyError = e.toString();
      _isLoadingHistory = false;
      _safeNotify();
    }
  }

  // --------------------------------------------------------------------------- B8
  // (conception interne) — compte CASH ANCRÉ : grille de dates SYNTHÉTIQUE +
  // escalier réel. Aucune position, donc aucune série de prix où s'échantillonner.
  // ---------------------------------------------------------------------------

  /// Budget de points de la grille synthétique (conception interne) : au-delà,
  /// [HistoryAggregator.buildDateGrid] sous-échantillonne à pas régulier plutôt que
  /// de produire un point par jour (« Max » sur 10 ans ≈ 3 650 points, coûteux au
  /// rendu `fl_chart`). Même valeur que côté patrimoine (`wallet_controller.dart`),
  /// volontairement dupliquée plutôt que partagée via un module tiers : les deux
  /// contrôleurs n'ont aucune dépendance l'un vers l'autre.
  static const int _syntheticGridMaxPoints = 400;

  /// Début de la période sélectionnée, ou `null` pour « Max » (pas de borne
  /// gauche de période : c'est le journal qui borne). `days < 0` = Max,
  /// `days == 0` = YTD (cf. [ChartPeriod]).
  DateTime? _selectedPeriodStart(DateTime now) {
    final days = _selectedPeriod.days;
    if (days < 0) return null;
    if (days == 0) return DateTime(now.year, 1, 1);
    return now.subtract(Duration(days: days));
  }

  /// Borne gauche de la grille synthétique (conception interne, règle 2) :
  /// `max(début de période, premier mouvement du journal)` — avant le premier
  /// mouvement la valeur est 0, pas une extrapolation, et
  /// [HistoryAggregator.buildDateGrid] ne connaît pas le journal.
  DateTime _syntheticGridFrom(List<AssetTransaction> txs, DateTime now) {
    final periodStart = _selectedPeriodStart(now);
    DateTime? firstMovement;
    for (final tx in txs) {
      if (firstMovement == null || tx.date.isBefore(firstMovement)) {
        firstMovement = tx.date;
      }
    }
    if (firstMovement == null) return periodStart ?? now;
    if (periodStart == null) return firstMovement;
    return periodStart.isAfter(firstMovement) ? periodStart : firstMovement;
  }

  /// Historique d'un compte CASH ANCRÉ (B8, conception interne) : aucune
  /// position, donc aucune grille de prix — la grille naît de
  /// [HistoryAggregator.buildDateGrid] et reste la SEULE du calcul (mode 1, mode
  /// 2 et courbe de flux la partagent : deux grilles concurrentes désaligneraient
  /// valeur et flux, conception interne, règle 3 / §8.3 MAJEUR).
  ///
  /// Le mode 1 y garde sa sémantique habituelle — rétroprojection de la valeur
  /// ACTUELLE, donc une courbe PLATE au solde dérivé du jour (variation de
  /// période nulle) ; c'est le mode 2 qui porte l'escalier réel du journal.
  ///
  /// [txs] est le journal DÉJÀ lu par [_loadAccountHistory] (test d'ancrage) —
  /// réutilisé ici pour borner la grille à gauche, sans relecture.
  Future<void> _loadCashAccountHistory(
    Account account,
    List<AssetTransaction> txs,
  ) async {
    _isLoadingHistory = true;
    _historyError = null;
    _periodChange = null;
    _periodChangePercent = null;
    _safeNotify();

    try {
      final now = DateTime.now();
      _chartDates = HistoryAggregator.buildDateGrid(
        from: _syntheticGridFrom(txs, now),
        to: now,
        maxPoints: _syntheticGridMaxPoints,
      );

      // Solde dérivé COURANT du compte, en EUR — lu au stockage plutôt que
      // dans [_derivedCash] pour ne dépendre d'aucun ordre d'appel.
      final derived = await _storage.getAccountDerivedCash(account.id);
      final cashEur = (double.tryParse(derived.cash ?? '0') ?? 0.0) *
          (account.currency.toUpperCase() == 'USD' ? _usdToEurRate : 1.0);
      _chartValues = [for (var i = 0; i < _chartDates.length; i++) cashEur];
      _periodChange = 0;
      _periodChangePercent = 0;

      // Mode 2 : aucune position ni série de prix à passer (le compte n'a
      // aucun titre). Même try/catch non bloquant que la branche nominale.
      try {
        await _computeAccountRealCurve(
          const <PositionWithMarketData>[],
          const <AssetHistoricalData?>[],
        );
      } catch (e, st) {
        AppLogger.warning(
          'Impossible de calculer la courbe réelle du compte (mode 2)',
          e,
          st,
        );
        _realChartValues = [];
        _realCurveApproxSymbols = {};
        _realExcludedLegacySymbols = const [];
        _realContributionsValues = [];
        _resetRealGains();
      }

      _isLoadingHistory = false;
      _safeNotify();
    } catch (e) {
      AppLogger.error('Erreur chargement historique (compte cash): $e');
      _historyError = e.toString();
      _isLoadingHistory = false;
      _safeNotify();
    }
  }

  /// Remet les champs de gains mode réel à `null` (+ [_realNoBasisSymbols]
  /// vidé) — à appeler PARTOUT où [_realChartValues]/[_realContributionsValues]
  /// sont réinitialisés (courbe réelle absente/périmée), pour ne jamais
  /// laisser un gain calculé sur une ancienne courbe affiché à côté d'une
  /// courbe vidée.
  void _resetRealGains() {
    _realPeriodGain = null;
    _realPeriodGainPercent = null;
    _realPeriodGainPercentAnnualized = null;
    _realTotalGain = null;
    _realTotalGainPercent = null;
    _realTotalGainCharges = null;
    _realNoBasisSymbols = {};
    _realUnanchoredRevenueEur = 0.0;
  }

  /// Calcule le mode 2 « évolution réelle » du COMPTE (B7, design conception
  /// interne) : reconstruction datée depuis le journal du compte actif, PÉRIMÈTRE
  /// TITRES SEULS (cf. commentaire de [_realChartValues] — aucun cash injecté, pour
  /// rester comparable au mode 1 du compte). Énumère TOUS les symboles du journal
  /// (y compris les titres soldés, absents de [currentPositions]), élargit le fetch
  /// d'historique au DELTA manquant, applique le repli « dernier cours » pour les
  /// symboles détenus sans historique.
  ///
  /// [currentPositions] et [results] sont APPAIRÉS PAR INDEX (même contrat que
  /// [HistoryAggregator.aggregateHistoricalData]) : `results[i]` est
  /// l'historique DÉJÀ récupéré par le mode 1 pour `currentPositions[i]` —
  /// réutilisé ici pour ne refetcher QUE le delta (symboles du journal absents
  /// de ces positions).
  ///
  /// Écrit UNIQUEMENT [_realChartValues]/[_realCurveApproxSymbols] — n'écrit
  /// JAMAIS les champs du mode 1. Toute exception se propage à l'appelant
  /// ([_loadAccountHistory]), qui l'absorbe dans un try/catch dédié.
  Future<void> _computeAccountRealCurve(
    List<PositionWithMarketData> currentPositions,
    List<AssetHistoricalData?> results,
  ) async {
    if (_activeAccount == null || _chartDates.isEmpty) {
      _realChartValues = [];
      _realCurveApproxSymbols = {};
      _realExcludedLegacySymbols = const [];
      _realContributionsValues = [];
      _resetRealGains();
      return;
    }

    final txs = await _txStorage.getByAccount(_activeAccount!.id);

    // Regroupe le journal du compte par symbole — inclut les titres VENDUS
    // (plus de position actuelle dans currentPositions) et exclut de facto
    // les positions legacy (journal garanti vide, cf. design §11.1/§11.6).
    final txsBySymbol = <String, List<AssetTransaction>>{};
    for (final tx in txs) {
      final sym = tx.symbol;
      if (sym == null) continue;
      txsBySymbol.putIfAbsent(sym, () => []).add(tx);
    }

    // Positions détenues mais SANS AUCUN mouvement journalisé : exclues de la
    // reconstruction (aucun historique pour les projeter) — comptées ICI,
    // avant les retours anticipés ci-dessous, pour rester cohérentes avec
    // `txsBySymbol` au même instant (cf. [_realExcludedLegacySymbols]).
    _realExcludedLegacySymbols = [
      for (final p in currentPositions)
        if (!txsBySymbol.containsKey(p.symbol)) p.symbol,
    ];

    // Aucun titre JOURNALISÉ (compte 100 % legacy, saisi à la main sans
    // mouvement) : le mode 2 serait une courbe plate à 0 (rien à reconstruire),
    // trompeuse en regard du mode 1 qui, lui, valorise ces positions. On
    // n'expose alors PAS de courbe réelle (`hasRealCurve` reste faux → aucun
    // bascule proposé), plutôt que d'afficher un zéro cassé.
    //
    // B8 (conception interne) : SAUF sur un compte CASH ANCRÉ, où l'absence de titre
    // est la NORME et où le journal porte au contraire toute l'histoire du compte.
    // La garde reste stricte pour un compte TITRES sans titre journalisé (le
    // raisonnement ci-dessus y vaut toujours).
    //
    // [_realExcludedLegacySymbols] N'EST PAS remis à vide ici (bug constaté à
    // l'écran, conception interne) : sur un compte 100 % hérité, c'est justement
    // CETTE liste — déjà calculée juste au-dessus — qui indique à l'utilisateur ce
    // qu'il a à déclarer, faute de courbe réelle à lui montrer à la place. Ne
    // réinitialiser que ce qui présuppose une reconstruction (courbe,
    // approximations, flux, gains).
    final isJournaledCashAccount =
        _activeAccount!.type == AccountType.cash && journalHasCashAnchor(txs);
    if (txsBySymbol.isEmpty && !isJournaledCashAccount) {
      _realChartValues = [];
      _realCurveApproxSymbols = {};
      _realContributionsValues = [];
      _resetRealGains();
      return;
    }

    // Map de prix DÉJÀ récupérée par le mode 1 (appairée par index).
    final maxLen = currentPositions.length < results.length
        ? currentPositions.length
        : results.length;
    final symbolToData = <String, AssetHistoricalData?>{
      for (int i = 0; i < maxLen; i++) currentPositions[i].symbol: results[i],
    };

    // Asset par symbole : position ACTUELLE si elle existe, sinon SYNTHÉTISÉ
    // (titre vendu sans position résiduelle — on tente quand même le fetch,
    // currency reprise d'un mouvement quelconque de ce symbole).
    final currentAssetBySymbol = <String, Asset>{
      for (final p in currentPositions) p.symbol: p.asset,
    };
    final assetBySymbol = <String, Asset>{};
    for (final sym in txsBySymbol.keys) {
      final current = currentAssetBySymbol[sym];
      assetBySymbol[sym] = current ??
          Asset(symbol: sym, currency: txsBySymbol[sym]!.first.currency);
    }

    // Fetch élargi : DELTA = symboles du journal absents de symbolToData,
    // MÊME fenêtre que le mode 1. Un actif non coté n'est jamais interrogé.
    // Concurrence BORNÉE (mapBounded) : ordre préservé, appairé par index à
    // `missingSymbols` juste en dessous.
    final missingSymbols =
        txsBySymbol.keys.where((s) => !symbolToData.containsKey(s)).toList();
    final fetched = await mapBounded(missingSymbols, maxConcurrentMarketRequests, (
      s,
    ) {
      final asset = assetBySymbol[s]!;
      if (!asset.quotable) return Future<AssetHistoricalData?>.value(null);
      return _marketService.getHistoricalDataForAsset(
        asset,
        days: _selectedPeriod.days,
      );
    });
    final fullSymbolToData = Map<String, AssetHistoricalData?>.from(
      symbolToData,
    );
    for (int i = 0; i < missingSymbols.length; i++) {
      fullSymbolToData[missingSymbols[i]] = fetched[i];
    }

    // Repli « dernier cours » pour tout symbole détenu sur la fenêtre sans
    // historique exploitable (délisté/irrésolu/fetch en échec).
    final approxSymbols = <String>{};
    for (final sym in txsBySymbol.keys) {
      final data = fullSymbolToData[sym];
      if (data != null && !data.isEmpty) continue;
      final fallback = HistoryAggregator.buildLastPriceFallback(
        symbol: sym,
        txs: txsBySymbol[sym]!,
        gridDates: _chartDates,
      );
      if (fallback == null) continue; // jamais détenu sur la fenêtre
      fullSymbolToData[sym] = fallback;
      approxSymbols.add(sym);
    }

    // Titres reconstruits + CASH DÉRIVÉ du compte : on passe le journal du
    // compte comme txsByAccount ⇒ reconstructRealNetWorth projette aussi le
    // solde espèces dans le temps (gating d'ancrage `journalHasCashAnchor`
    // appliqué en interne : un compte non ancré n'injecte aucun cash). Le point
    // final coïncide alors avec la « Valeur totale » du compte (cf. commentaire
    // de [_realChartValues]).
    final reconstructed = HistoryAggregator.reconstructRealNetWorth(
      txsBySymbol: txsBySymbol,
      txsByAccount: {_activeAccount!.id: txs},
      symbolToData: fullSymbolToData,
      assetBySymbol: assetBySymbol,
      usdToEurRate: _usdToEurRate,
      gridDates: _chartDates,
    );

    _realChartValues = reconstructed.values;
    _realCurveApproxSymbols = approxSymbols;

    // Courbe des flux externes complets du compte (design §11.4, ex-« apports
    // nets ») : pas de cash pur à composer ici (périmètre compte seul, cf.
    // commentaire de [_realContributionsValues]).
    _realContributionsValues = HistoryAggregator.buildExternalFlowsCurve(
      txsBySymbol: txsBySymbol,
      txsByAccount: {_activeAccount!.id: txs},
      symbolToData: fullSymbolToData,
      assetBySymbol: assetBySymbol,
      usdToEurRate: _usdToEurRate,
      gridDates: _chartDates,
    );

    // Gain de PÉRIODE (Modified Dietz) : DOIT être calculé APRÈS que les deux
    // courbes ci-dessus sont posées — [computeRealGains] les suppose déjà
    // alignées index-par-index (contrat de [_realChartValues]/
    // [_realContributionsValues]).
    final periodGains = HistoryAggregator.computeRealGains(
      values: _realChartValues,
      externalFlows: _realContributionsValues,
      gridDates: _chartDates,
    );
    _realPeriodGain = periodGains.periodGain;
    _realPeriodGainPercent = periodGains.periodGainPercent;
    _realPeriodGainPercentAnnualized = periodGains.periodGainPercentAnnualized;

    // Gain TOTAL (état courant, base coût) : calcul INDÉPENDANT des courbes
    // ci-dessus — positions DU COMPTE (legacy incluses si leur PRU est
    // connu), affiché quelle que soit la période sélectionnée.
    // Cash DÉRIVÉ du compte (devise de règlement du compte → EUR) : fait
    // partie de la valeur détenue, donc du capital investi. L'omettre
    // surévaluerait le `%` (cf. computeRealTotalGain).
    //
    // GARDE D'ANCRAGE (invariant « faux négatif interdit », design
    // cash-ledger §6.7) : sur un compte titres non ancré, [_derivedCash] est
    // un solde négatif FICTIF (cf. doc de [_hasCashAnchor]) — l'injecter en
    // `cashEur` amputait le capital du gain total, et faisait diverger les
    // chiffres du MÊME compte selon l'écran d'où on le regarde, le niveau
    // patrimoine passant lui une map déjà filtrée par l'ancrage
    // ([WalletController._cashBalances]).
    final derivedCashEur = _hasCashAnchor
        ? (double.tryParse(_derivedCash ?? '0') ?? 0.0) *
            (_activeAccount!.currency.toUpperCase() == 'USD'
                ? _usdToEurRate
                : 1.0)
        : 0.0;

    final totalGain = HistoryAggregator.computeRealTotalGain(
      positions: currentPositions,
      txsBySymbol: txsBySymbol,
      txsByAccount: {_activeAccount!.id: txs},
      usdToEurRate: _usdToEurRate,
      cashEur: derivedCashEur,
    );
    _realTotalGain = totalGain.totalGain;
    _realTotalGainPercent = totalGain.totalGainPercent;
    _realTotalGainCharges = totalGain.chargesTotal;
    _realNoBasisSymbols = totalGain.noBasisSymbols;
    _realUnanchoredRevenueEur = totalGain.unanchoredRevenueEur;
  }

  /// Appelé par la vue lorsque l'utilisateur sélectionne une nouvelle période.
  Future<void> onPeriodChanged(ChartPeriod period) async {
    if (_selectedPeriod != period) {
      _selectedPeriod = period;
      _safeNotify();
      await _loadAccountHistory();
    }
  }

  // ---------------------------------------------------------------------------
  // Actions sur les positions
  // ---------------------------------------------------------------------------

  /// Ajoute une position classique (actions, ETF, crypto…).
  ///
  /// Retourne null en cas de succès, ou un code d'erreur :
  ///   - 'noActiveAccount' : pas de compte actif - 'invalidQuantity' :
  ///   quantité nulle ou non parsable - 'assetNotFound' : le symbole est
  ///   introuvable sur le marché
  Future<String?> addNewPosition(
    String newSymbol,
    String quantity, [
    String? pruText,
  ]) async {
    if (_activeAccount == null) return 'noActiveAccount';

    final qtyNum = double.tryParse(quantity);
    if (qtyNum == null || qtyNum <= 0) return 'invalidQuantity';

    final quote = await _marketService.getQuoteWithMetadata(newSymbol);
    if (quote == null || quote.hasError) return 'assetNotFound';

    // Type déduit du seul fait de marché (`instrumentType` renvoyé par Yahoo).
    // `fromYahooInstrumentType(null)` renvoie déjà `other` quand le champ est
    // absent (mock de test, provider alternatif...) : plus besoin d'heuristique
    // par liste de symboles en dur, et on ne prétend jamais « action » par
    // défaut. `typeLocked` reste false : cette position auto-classée pourra être
    // reclassée par le backfill au fil des cotations. Le flux métal précieux a
    // son propre chemin verrouillé (voir addNewPreciousMetal).
    final asset = Asset(
      symbol: newSymbol,
      name: quote.name,
      currency: quote.currency ?? 'USD',
      exchange: quote.exchange,
      type: AssetType.fromYahooInstrumentType(quote.instrumentType),
    );

    // Parsing du PRU optionnel (null si vide ou invalide)
    final pru = (pruText == null || pruText.trim().isEmpty)
        ? null
        : double.tryParse(pruText.trim().replaceAll(',', '.'));

    final position = Position(
      accountId: _activeAccount!.id,
      asset: asset,
      quantity: quantity,
      averageBuyPrice: pru,
    );

    // I3 — ordre de création : on crée D'ABORD la ligne positions (métadonnée :
    // asset_json/custom_name) via savePosition, PUIS on émet la position
    // initiale déclarative. Le ledger reprojette alors quantité/PRU depuis ce
    // seul openingBalance (q/PRU finaux = projection) et horodate derived_at.
    // Inverser l'ordre laisserait le mouvement journalisé mais la position
    // invisible (reprojection = UPDATE ciblé, jamais un INSERT).
    await _storage.savePosition(_activeAccount!.id, position);
    await _ledger.emitOpeningBalance(
      accountId: _activeAccount!.id,
      symbol: newSymbol,
      quantity: quantity,
      unitPrice: pru?.toString(),
      currency: asset.currency,
      date: DateTime.now(),
      declarative: true,
    );
    await _initService();
    return null;
  }

  /// Ajoute une position métal précieux.
  ///
  /// Retourne null en cas de succès, ou un code d'erreur :
  ///   - 'noActiveAccount' : pas de compte actif - 'invalidQuantity' :
  ///   quantité nulle ou non parsable - 'assetNotFound' : le cours de
  ///   référence est introuvable
  Future<String?> addNewPreciousMetal({
    required String name,
    required String refSymbol,
    required MetalQuoteUnit unit,
    required double fineWeight,
    required double premiumPercent,
    required String quantity,
    String? pruText,
  }) async {
    if (_activeAccount == null) return 'noActiveAccount';

    final qtyNum = double.tryParse(quantity);
    if (qtyNum == null || qtyNum <= 0) return 'invalidQuantity';

    // Le cours de référence doit être résolvable (sinon erreur explicite)
    final quote = await _marketService.getQuoteWithMetadata(refSymbol);
    if (quote == null || quote.hasError) return 'assetNotFound';

    // Symbole unique de la position (clé de stockage) dérivé du nom
    final existing = (await _storage.getPositions(
      _activeAccount!.id,
    )).map((p) => p.symbol).toSet();
    final symbol = generateMetalSymbol(name, existing);

    final asset = Asset(
      symbol: symbol,
      name: name,
      type: AssetType.preciousMetal,
      // Choix explicite, non auto-détectable : verrouillé pour que le backfill
      // au rafraîchissement (qui cote le refSymbol GC=F/ETC → FUTURE/EQUITY) ne
      // reclasse jamais ce métal en other/stock.
      typeLocked: true,
      currency: 'EUR',
      refSymbol: refSymbol,
      refQuoteUnit: unit,
      fineWeightGrams: fineWeight,
      premiumPercent: premiumPercent,
    );

    final pru = (pruText == null || pruText.trim().isEmpty)
        ? null
        : double.tryParse(pruText.trim().replaceAll(',', '.'));

    final position = Position(
      accountId: _activeAccount!.id,
      asset: asset,
      quantity: quantity,
      averageBuyPrice: pru,
    );

    // I3 — même ordre que addNewPosition : ligne positions créée d'abord, puis
    // openingBalance déclaratif (devise EUR pour les métaux). q/PRU finaux =
    // projection du journal ; derived_at horodaté par le ledger.
    await _storage.savePosition(_activeAccount!.id, position);
    await _ledger.emitOpeningBalance(
      accountId: _activeAccount!.id,
      symbol: symbol,
      quantity: quantity,
      unitPrice: pru?.toString(),
      currency: asset.currency,
      date: DateTime.now(),
      declarative: true,
    );
    await _initService();
    return null;
  }

  /// Supprime la position identifiée par [symbol].
  ///
  /// En cas d'erreur de stockage, relance l'exception pour que la vue
  /// affiche un SnackBar d'erreur.
  Future<void> removePosition(String symbol) async {
    if (_activeAccount == null) return;

    // D2 — suppression atomique de la position ET de tout son journal (tous les
    // mouvements du même symbole). Un journal vide (position legacy) est un
    // no-op sur transactions ; la ligne positions est supprimée dans tous les cas.
    await _ledger.deletePositionWithJournal(_activeAccount!.id, symbol);
    await _initService();
  }

  /// Déclare l'OPÉRATION D'ORIGINE d'une position HÉRITÉE (détenue, journal
  /// entièrement vide) : émet un `openingBalance` TITRE déclaratif puis
  /// recharge le compte, de sorte que la position rejoigne la reconstruction
  /// « Évolution réelle » (elle n'est plus dans [realExcludedLegacySymbols]).
  ///
  /// POURQUOI `openingBalance` ET PAS `buy` — c'est LE point du lot :
  ///   - un `buy` porte `amount = -(q×p + frais)`, sommé tel quel par
  ///     [LedgerService.reprojectCashWithin] : déclarer aujourd'hui l'achat
  ///     d'un lot acquis il y a dix ans RETRANCHERAIT son coût du solde
  ///     espèces dérivé du compte, sans rien à l'écran pour l'expliquer. Un
  ///     `openingBalance` TITRE a `amount == null` PAR CONSTRUCTION (invariant
  ///     de partition des champs, `position_projection.dart`) : zéro effet
  ///     cash ;
  ///   - un `buy` entre dans le CAPITAL INVESTI comme flux d'espèces daté du
  ///     jour ; l'`openingBalance` y entre comme ENTRÉE DE TITRES valorisée au
  ///     cours du jour de l'opération, ce qui est exactement ce qui s'est
  ///     passé (les titres sont entrés dans le périmètre, l'argent non) ;
  ///   - c'est déjà la convention du projet pour toute position saisie à la
  ///     main : [addNewPosition] et [addNewPreciousMetal] émettent le même
  ///     mouvement. Déclarer l'origine d'une position héritée, c'est lui
  ///     donner l'acte de naissance que les positions récentes ont déjà.
  ///
  /// AUCUN DOUBLE COMPTAGE : [LedgerService.recordTransaction] reprojette le
  /// symbole par un UPDATE de `positions.quantity` avec la projection du
  /// journal ENTIER — la quantité déclarée REMPLACE la quantité détenue, elle
  /// ne s'y ajoute pas. Sur un journal vide, projeter le seul `openingBalance`
  /// redonne donc exactement la quantité saisie. ⚠️ Corollaire : n'appeler
  /// que sur une position au journal VIDE (l'appelant le garantit via
  /// [realExcludedLegacySymbols]) — sur un journal existant, l'openingBalance
  /// s'AJOUTERAIT à la projection.
  ///
  /// [unitPrice] optionnel (base de coût inconnue = PRU null, cf.
  /// [LedgerService.emitOpeningBalance]). [date] est celle de l'opération
  /// d'origine : plus elle est juste, plus la courbe réelle l'est.
  Future<void> declareInitialPosition({
    required String symbol,
    required String quantity,
    String? unitPrice,
    required DateTime date,
    String? note,
  }) async {
    final account = _activeAccount;
    if (account == null) return;
    final index = _positionsData.indexWhere((p) => p.symbol == symbol);
    if (index < 0) return;
    final position = _positionsData[index].position;

    await _ledger.emitOpeningBalance(
      accountId: account.id,
      symbol: symbol,
      quantity: quantity,
      unitPrice: unitPrice,
      // Devise de COTATION de l'actif (celle du PRU) — même contrat que
      // [addNewPosition], jamais la devise du compte.
      currency: position.asset.currency,
      date: date,
      declarative: true,
      note: note,
    );
    await _initService();
  }

  // ---------------------------------------------------------------------------
  // Suppression différée (masquer / restaurer / valider) — motif « Annuler »
  // ---------------------------------------------------------------------------

  /// Masque la position [symbol] de la liste affichée SANS toucher au stockage.
  /// L'objet complet (cours inclus) est mémorisé pour une éventuelle
  /// restauration. Synchrone : la liste est cohérente avant la reconstruction
  /// suivante (requis par [Dismissible], qui refuse un item resté dans l'arbre).
  /// Sans effet si la position est absente ou déjà masquée.
  void hidePosition(String symbol) {
    if (_hiddenPositions.containsKey(symbol)) return;
    final index = _positionsData.indexWhere((p) => p.symbol == symbol);
    if (index == -1) return;

    _hiddenPositions[symbol] = _positionsData[index];
    _positionsData = List<PositionWithMarketData>.from(_positionsData)
      ..removeAt(index);
    _recomputeAssetValues();
    _safeNotify();
  }

  /// Réintègre une position précédemment masquée (annulation). Sans effet si
  /// aucune position n'est masquée sous ce [symbol].
  void restorePosition(String symbol) {
    final restored = _hiddenPositions.remove(symbol);
    if (restored == null) return;

    _positionsData = List<PositionWithMarketData>.from(_positionsData)
      ..add(restored);
    _recomputeAssetValues();
    _safeNotify();
  }

  /// Valide la suppression réelle (stockage) d'une position masquée. Réutilise
  /// [removePosition] (suppression stockage + rechargement existants). Sans
  /// effet si la position n'est plus masquée (déjà validée ou restaurée), ce qui
  /// protège contre une double suppression.
  ///
  /// L'entrée masquée n'est retirée qu'APRÈS le succès du stockage : en cas
  /// d'échec elle reste disponible pour que l'appelant puisse restaurer la
  /// position (cohérence UI ↔ stockage). L'exception est relancée.
  Future<void> commitDeletePosition(String symbol) async {
    if (!_hiddenPositions.containsKey(symbol)) return;
    await removePosition(symbol);
    _hiddenPositions.remove(symbol);
  }

  /// Renomme le compte actif.
  ///
  /// Retourne null en cas de succès, 'noActiveAccount' si pas de compte actif.
  Future<String?> renameAccount(String newName) async {
    if (_activeAccount == null) return 'noActiveAccount';
    if (newName.trim() == _activeAccount!.name) return null;

    final updatedAccount = _activeAccount!.copyWith(name: newName.trim());
    await _storage.saveAccount(updatedAccount);

    _activeAccount = updatedAccount;
    _safeNotify();
    return null;
  }

  /// Met à jour la nature ([AccountKind]) du compte actif.
  ///
  /// Retourne null en cas de succès, 'noActiveAccount' si pas de compte actif.
  /// Ne persiste (et ne notifie) que si la valeur change réellement. L'appelant
  /// (UI) restreint les choix offerts aux natures de même mode de valorisation
  /// (titres), pour ne pas transformer un compte titres en cash/métaux.
  Future<String?> setAccountKind(AccountKind kind) async {
    if (_activeAccount == null) return 'noActiveAccount';
    if (kind == _activeAccount!.kind) return null;

    final updatedAccount = _activeAccount!.copyWith(kind: kind);
    await _storage.saveAccount(updatedAccount);

    _activeAccount = updatedAccount;
    _safeNotify();
    return null;
  }

  // ---------------------------------------------------------------------------
  // Actions de journal explicites sur le SOLDE ESPÈCES (lot cash-ledger)
  //
  // Analogues cash de emitOpeningBalance/emitAdjustment (positions) : le cash dérivé
  // (compte titres ANCRÉ comme compte cash ANCRÉ, conception interne) est en LECTURE
  // SEULE (corollaire D1/PRU) — toute correction passe par un acte de journal nommé,
  // jamais une édition directe (B8/conception interne : l'ancienne édition manuelle
  // du solde d'un compte cash a été retirée au lot 4).
  // ---------------------------------------------------------------------------

  /// « Définir le solde espèces initial… » — déclare une trésorerie
  /// préexistante SANS la falsifier en apport (`deposit`). [amount] est SIGNÉ
  /// (négatif = découvert déclaré). Retourne null en cas de succès,
  /// 'noActiveAccount' si pas de compte actif.
  Future<String?> emitCashOpeningBalance({
    required String amount,
    required DateTime date,
    String? note,
  }) async {
    final account = _activeAccount;
    if (account == null) return 'noActiveAccount';
    await _ledger.emitCashOpeningBalance(
      accountId: account.id,
      amount: amount,
      currency: account.currency,
      date: date,
      note: note,
    );
    await _loadDerivedCash();
    return null;
  }

  /// « Ajuster le solde espèces… » — corrige le solde dérivé (lecture seule)
  /// par un ajustement SIGNÉ (delta). Retourne null en cas de succès,
  /// 'noActiveAccount' si pas de compte actif.
  Future<String?> emitCashAdjustment({
    required String amount,
    required DateTime date,
    String? note,
  }) async {
    final account = _activeAccount;
    if (account == null) return 'noActiveAccount';
    await _ledger.emitCashAdjustment(
      accountId: account.id,
      amount: amount,
      currency: account.currency,
      date: date,
      note: note,
    );
    await _loadDerivedCash();
    return null;
  }

  // ---------------------------------------------------------------------------
  // Import de relevés courtiers (lot B4) — couche contrôleur
  //
  // Relie la couche de parsing PURE (StatementImportService, zéro I/O) à la
  // couche d'écriture atomique (LedgerService.importMovements). Le contrôleur
  // porte trois responsabilités que ni l'une ni l'autre couche ne peut
  // assumer seule : la résolution d'actif (ISIN/symbole → position existante),
  // la déduplication PAR COMPTE (lecture du journal existant) et le calcul du
  // delta projeté (rejeu en mémoire, aucune écriture). [confirmStatementImport]
  // ne fait QUE relayer à [LedgerService.importMovements] : la garde
  // anti-écrasement d'une position legacy reste entièrement de son ressort —
  // [previewStatementImport] ne fait qu'en SIGNALER le risque en amont
  // (`ImportPreview.legacySymbols`), jamais ne la duplique ni ne la contourne.
  // ---------------------------------------------------------------------------

  /// Prévisualise l'import d'un relevé [bytes] selon [profile], pour le compte
  /// [accountId] : AUCUNE écriture. Combine parsing/normalisation (couche
  /// pure), résolution d'actif MANUELLE/DIRECTE (ISIN prioritaire, repli sur
  /// le symbole mappé par le CSV), déduplication par compte et delta projeté
  /// (quantité/PRU par symbole + cash), en rejouant le journal existant en
  /// mémoire.
  ///
  /// Retourne un [ImportPreview] vide si [accountId] ne correspond à aucun
  /// compte connu du contrôleur (pas de compte actif ni de compte du même
  /// wallet portant cet id).
  /// Recherche les places candidates pour un [isin] auprès de la source de
  /// marché (relais vers [MarketDataService.searchByIsin]). Utilisé par
  /// l'assistant d'import pour auto-résoudre un nouvel actif identifié par
  /// ISIN. Retourne une liste VIDE en cas d'échec / ISIN introuvable (titre
  /// délisté), ce qui déclenche le repli « non coté » côté UI. La
  /// désambiguïsation (choix du symbole retenu) est faite par [IsinResolver].
  Future<List<IsinSearchHit>> searchIsin(String isin, {int quotesCount = 8}) =>
      _marketService.searchByIsin(isin, quotesCount: quotesCount);

  Future<ImportPreview> previewStatementImport(
    Uint8List bytes,
    BrokerProfile profile, {
    required String accountId,
  }) async {
    Account? account;
    for (final a in _accounts) {
      if (a.id == accountId) {
        account = a;
        break;
      }
    }
    account ??= _activeAccount;
    if (account == null) return const ImportPreview();

    // Invalide tout contexte crypto d'un aperçu PRÉCÉDENT (cf. doc de tête du
    // cache ci-dessus) — même sur le chemin titres : un utilisateur qui
    // enchaîne un import crypto puis un import titres dans la MÊME session de
    // contrôleur ne doit jamais laisser [applyManualCryptoValuations]
    // ressusciter le plan crypto abandonné.
    _lastCryptoPlan = null;
    _lastCryptoAccount = null;
    _lastCryptoAccountId = null;
    _lastCryptoProfile = null;
    _lastCryptoFxUnavailable = false;
    _lastCryptoValuations.clear();
    _lastCryptoManualReasons.clear();
    _lastCryptoTickerCache.clear();

    // ---- Pipeline CRYPTO (chantier B16, lot 1 — conception interne) : branche
    // DÉDIÉE, isolée du chemin titres ci-dessous. La cascade de résolution
    // ledgerCode→ticker fait de l'I/O réseau (`symbolExists`) que le chemin titres
    // (résolution ISIN, purement locale) n'a jamais eu à faire — d'où un contrôleur
    // qui apprend ICI, une fois, la distinction `profile.crypto`, plutôt que de la
    // disperser dans la logique existante.
    if (profile.crypto != null) {
      return _previewCryptoImport(bytes, profile, account: account, accountId: accountId);
    }

    final parsed = StatementImportService.parseWithLineNumbers(bytes, profile);
    final movements = StatementImportService.normalize(
      parsed.rows,
      profile,
      accountCurrency: account.currency,
      accountId: accountId,
      sourceLines: parsed.sourceLines,
    );

    final rejects = <ImportedMovement>[];
    final candidates = <ImportedMovement>[];
    for (final m in movements) {
      (m.isRejected ? rejects : candidates).add(m);
    }

    // ---- Déduplication PAR COMPTE (design §5) ----
    final existingJournal = await _txStorage.getByAccount(accountId);
    final existingImportKeys = existingJournal
        .map((t) => t.meta?['importKey'])
        .whereType<String>()
        .toSet();

    final duplicates = <ImportedMovement>[];
    final nonDuplicates = <ImportedMovement>[];
    for (final m in candidates) {
      final isDuplicate =
          m.importKey != null && existingImportKeys.contains(m.importKey);
      (isDuplicate ? duplicates : nonDuplicates).add(m);
    }

    // ---- Doublons PROBABLES d'espèces (cf. ImportPreview.probableDuplicates) --
    // L'identité d'un mouvement d'espèces dans la clé de dédup est son LIBELLÉ
    // (texte libre) : une reformulation côté courtier casse la dédup et
    // réimporte le même versement, gonflant la trésorerie en silence. On
    // rapproche donc les mouvements d'espèces restants sur (jour, kind, montant)
    // — indécidable avec certitude, le relevé ne portant aucune heure, d'où un
    // signalement à l'utilisateur plutôt qu'une décision automatique.
    //
    // Empreintes du journal existant CONSOMMABLES : un mouvement déjà journalisé
    // ne peut couvrir qu'UN entrant. Sans ce décompte, deux versements
    // réellement distincts de même montant le même jour seraient tous deux
    // signalés alors qu'un seul est en base.
    final existingCashPrints = <String, int>{};
    for (final t in existingJournal) {
      if (!_isCashMovementForMatching(t.kind, t.symbol)) continue;
      final print = _cashMatchPrint(t.kind, t.date, t.amount);
      if (print == null) continue;
      existingCashPrints.update(print, (v) => v + 1, ifAbsent: () => 1);
    }

    final probableDuplicates = <ImportedMovement>[];
    final toCreateCandidates = <ImportedMovement>[];
    for (final m in nonDuplicates) {
      final tx = m.transaction!;
      final print = _isCashMovementForMatching(tx.kind, tx.symbol)
          ? _cashMatchPrint(tx.kind, tx.date, tx.amount)
          : null;
      final remaining = print == null ? 0 : (existingCashPrints[print] ?? 0);
      if (remaining > 0) {
        existingCashPrints[print!] = remaining - 1;
        probableDuplicates.add(m);
      } else {
        toCreateCandidates.add(m);
      }
    }

    // ---- Résolution d'actif (§4, MVP manuel/direct) ----
    final existingPositions = await _storage.getPositions(accountId);
    final existingSymbols = <String>{};
    final positionByIsin = <String, Position>{};
    for (final p in existingPositions) {
      existingSymbols.add(p.symbol);
      final isin = p.asset.isin;
      if (isin != null && isin.isNotEmpty) positionByIsin[isin] = p;
    }

    final newAssets = <NewAssetCandidate>[];
    final newAssetSymbolsSeen = <String>{};
    final unresolvedIdentitiesSeen = <String>{};
    final resolved = <ImportedMovement>[];

    // ---- Pré-passage : quantité nette par identité NEUVE non résolue ----
    // Une identité neuve (aucune position dans le compte, symbole non mappé)
    // dont les mouvements titres du relevé projettent une quantité nette ≤ 0
    // est SOLDÉE : achetée puis intégralement revendue à l'intérieur du relevé.
    // On la journalisera en actif NON COTÉ (symbole = ISIN) SANS jamais
    // demander de symbole (elle se projette à 0 → masquée des positions
    // détenues, et n'a pas de ligne de delta « 0 → 0 » bruyante). Le net doit
    // être connu DÈS le premier mouvement de l'identité, d'où ce pré-passage
    // agrégeant TOUS ses mouvements titres avant la boucle de résolution.
    // Rejoue la même garde d'identité et la même résolution ISIN-first que la
    // boucle ci-dessous pour n'agréger QUE les mouvements y atteignant la
    // branche « non résolu » (finalSymbol == null).
    final unresolvedTxByKey = <String, List<AssetTransaction>>{};
    for (final m in toCreateCandidates) {
      final tx = m.transaction!;
      final hasIdentity =
          !tx.kind.isCashOnly && (m.isin != null || tx.symbol != null);
      if (!hasIdentity) continue;
      final matchByIsin = m.isin != null ? positionByIsin[m.isin] : null;
      final finalSymbol = matchByIsin?.symbol ?? tx.symbol;
      if (finalSymbol != null) continue;
      final key = m.isin ?? m.label!;
      (unresolvedTxByKey[key] ??= <AssetTransaction>[]).add(tx);
    }
    // Symboles (= ISIN) des identités soldées : leurs mouvements sont
    // journalisés mais EXCLUS des deltas titres (pas de ligne « 0 → 0 »).
    final soldeeSymbols = <String>{};

    for (final m in toCreateCandidates) {
      final tx = m.transaction!;
      // Un actif n'est requis que si le mouvement référence réellement un TITRE.
      // Deux garde-fous :
      //  - la NATURE d'abord : une opération d'espèces (dépôt, retrait, frais/
      //    TTF, virement reçu, remise de chèque…) n'est JAMAIS un actif, même si
      //    elle porte un ISIN (la TTF référence l'ISIN du titre taxé) ou un
      //    libellé ;
      //  - puis la présence d'une identité titre (ISIN ou symbole mappé). Le
      //    libellé SEUL ne suffit pas (toutes les lignes en ont un désormais).
      final hasIdentity =
          !tx.kind.isCashOnly && (m.isin != null || tx.symbol != null);
      if (!hasIdentity) {
        // Mouvement cash pur (deposit/withdrawal/interest/charge) : aucune
        // résolution d'actif requise.
        resolved.add(m);
        continue;
      }

      // Priorité ISIN (réutilise le symbole existant même si le CSV mappait
      // un symbole différent), repli sur le symbole mappé directement.
      final matchByIsin =
          m.isin != null ? positionByIsin[m.isin] : null;
      final finalSymbol = matchByIsin?.symbol ?? tx.symbol;

      if (finalSymbol == null) {
        final key = m.isin ?? m.label!;
        // Identité SOLDÉE (net ≤ 0) ET porteuse d'un ISIN (seul symbole non
        // coté STABLE — sans ISIN, aucune clé pérenne pour la position → on
        // garde la résolution UI). On la crée en actif non coté (symbole =
        // ISIN, quotable == false) avec un proposedSymbol renseigné : PLUS de
        // prompt de résolution. Le mouvement est réémis avec symbol = ISIN
        // (l'UI ne patchera plus ce mouvement — elle ne patche que les
        // NewAssetCandidate à proposedSymbol == null), pour ne JAMAIS
        // journaliser un titre orphelin.
        final net =
            projectPosition(unresolvedTxByKey[key] ?? const []).quantity;
        if (m.isin != null && net <= Decimal.zero) {
          final isin = m.isin!;
          if (unresolvedIdentitiesSeen.add(key)) {
            newAssets.add(NewAssetCandidate(
              isin: isin,
              label: m.label ?? key,
              proposedSymbol: isin,
              quotable: false,
              closedLine: true,
            ));
          }
          soldeeSymbols.add(isin);
          resolved.add(ImportedMovement.candidate(
            sourceRow: m.sourceRow,
            sourceRowIndex: m.sourceRowIndex,
            transaction: tx.copyWith(symbol: isin),
            isin: m.isin,
            label: m.label,
            resolvedSymbol: isin,
            importKey: m.importKey!,
          ));
          continue;
        }

        // Encore détenue (net > 0) ou identité sans ISIN : comportement
        // inchangé — à charge de l'UI de faire confirmer/saisir un symbole
        // avant confirmation (résolution en ligne hors MVP, cf. design §4.2).
        if (unresolvedIdentitiesSeen.add(key)) {
          newAssets.add(NewAssetCandidate(isin: m.isin, label: m.label ?? key));
        }
        resolved.add(m);
        continue;
      }

      if (!existingSymbols.contains(finalSymbol) &&
          newAssetSymbolsSeen.add(finalSymbol)) {
        // Symbole encore absent du compte ET déjà mappé par le CSV : création
        // directe d'un actif neuf portant l'ISIN (pas d'aller-retour UI ici).
        newAssets.add(NewAssetCandidate(
          isin: m.isin,
          label: m.label ?? finalSymbol,
          proposedSymbol: finalSymbol,
        ));
      }

      resolved.add(finalSymbol == tx.symbol
          ? m
          : ImportedMovement.candidate(
              sourceRow: m.sourceRow,
              sourceRowIndex: m.sourceRowIndex,
              transaction: tx.copyWith(symbol: finalSymbol),
              isin: m.isin,
              label: m.label,
              resolvedSymbol: finalSymbol,
              importKey: m.importKey!,
            ));
    }

    // ---- Delta projeté (§3 étape 5) : rejeu en mémoire, lecture seule ----
    final projectedDeltas = <ProjectedDelta>[];
    final legacySymbols = <String>[];
    final touchedSymbols = <String>{
      for (final m in resolved)
        if (m.transaction!.symbol != null) m.transaction!.symbol!,
    };

    for (final symbol in touchedSymbols) {
      // Identité soldée (net ≤ 0) : journalisée, mais aucun delta titre — sa
      // ligne « 0 → 0 » serait bruyante et trompeuse dans l'aperçu.
      if (soldeeSymbols.contains(symbol)) continue;
      final before =
          existingJournal.where((t) => t.symbol == symbol).toList();
      final incoming = resolved
          .where((m) => m.transaction!.symbol == symbol)
          .map((m) => m.transaction!)
          .toList();

      final beforeProj = projectPosition(before);
      final afterProj = projectPosition([...before, ...incoming]);

      projectedDeltas.add(ProjectedDelta(
        symbol: symbol,
        quantityBefore: beforeProj.quantity.toString(),
        quantityAfter: afterProj.quantity.toString(),
        averageBuyPriceBefore: beforeProj.averagePrice,
        averageBuyPriceAfter: afterProj.averagePrice,
      ));

      // Garde-fou legacy (§8.1, miroir en LECTURE SEULE de la garde de
      // LedgerService.importMovements) : position existante jamais projetée,
      // sans le moindre mouvement en journal.
      if (existingSymbols.contains(symbol) && before.isEmpty) {
        final derivedAt = await _storage.getPositionDerivedAt(accountId, symbol);
        if (derivedAt == null) legacySymbols.add(symbol);
      }
    }

    // Delta cash (symbol == null), dans la devise du compte cible.
    final cashCurrency = account.currency;
    final incomingAll = resolved.map((m) => m.transaction!).toList();
    final cashBefore =
        replayLedger(existingJournal).cashByCurrency[cashCurrency] ??
            Decimal.zero;
    final cashAfter = replayLedger([...existingJournal, ...incomingAll])
            .cashByCurrency[cashCurrency] ??
        Decimal.zero;
    projectedDeltas.add(ProjectedDelta(
      cashBefore: cashBefore.toDouble(),
      cashAfter: cashAfter.toDouble(),
    ));

    return ImportPreview(
      toCreate: resolved,
      duplicates: duplicates,
      probableDuplicates: probableDuplicates,
      rejects: rejects,
      newAssets: newAssets,
      projectedDeltas: projectedDeltas,
      legacySymbols: legacySymbols,
    );
  }

  // ---------------------------------------------------------------------------
  // Import de relevés CRYPTO (chantier B16, lot 1 — conception interne)
  //
  // Branche dédiée de `previewStatementImport`/`confirmStatementImport` :
  // un grand livre crypto n'a ni ISIN ni « doublon probable d'espèces » (sa
  // dédup est PAR CONSTRUCTION fiable, cf. `CryptoLedgerNormalizer`/doc
  // §5.1.9), mais introduit deux besoins absents du chemin titres —
  //   - une cascade de résolution ledgerCode→ticker faisant de l'I/O RÉSEAU
  //     (`MarketDataProvider.symbolExists`), mémoïsée PAR CODE pour la durée de CET
  //     appel (M-5, conception interne) ;
  //   - un mécanisme de REMPLACEMENT ciblé des agrégats mensuels de
  //     récompenses (§5.1.8b), orthogonal à la dédup par `importKey` normale.
  // ---------------------------------------------------------------------------

  /// Résolution d'un ticker de marché pour [code] (`ledgerCode`), mémoïsée dans
  /// [cache] par l'appelant — cascade à 5 étages (conception interne) : ①
  /// position existante du compte portant `asset.ledgerCode == code` (`quotable =
  /// false` si son `symbol` porte déjà la sentinelle non coté `'crypto:<code>'`
  /// de l'étage ⑤ — M-1, revue adversariale LOT 4 : sinon un jeton constaté non
  /// coté à un import ANTÉRIEUR redéclencherait un appel réseau garanti-404 à
  /// chaque ré-import) ; ② [CryptoLedgerSpec. quoteAliases] du profil ; ③
  /// `<code>-<devise du compte>` vérifié en réseau ; ④ `<code>-USD` vérifié,
  /// devise forcée USD ; ⑤ repli non coté (`quotable = false`, `symbol =
  /// 'crypto:<code>'`). `symbolExists` → `null` (panne réseau/inconnu) : les
  /// étages RÉSEAU suivants ne sont PAS tentés, l'actif part en non coté avec
  /// [_CryptoTickerResolution. networkFailure] = `true` — jamais assimilé à une
  /// invalidité constatée (conception interne).
  Future<_CryptoTickerResolution> _resolveCryptoTicker(
    String code, {
    required Map<String, String> quoteAliases,
    required Map<String, Position> positionByLedgerCode,
    required String accountCurrency,
    required Map<String, _CryptoTickerResolution> cache,
  }) async {
    final cached = cache[code];
    if (cached != null) return cached;

    _CryptoTickerResolution result;
    final existingPosition = positionByLedgerCode[code];
    if (existingPosition != null) {
      // M-1 (revue adversariale, LOT 4) : une position EXISTANTE peut
      // elle-même porter la sentinelle « non coté » `'crypto:<code>'` (étage
      // ⑤ ci-dessous, posée lors d'un import ANTÉRIEUR) — la retenir comme
      // `quotable` par défaut ferait tenter un appel réseau GARANTI-404 (ou,
      // pire côté étage 2, un `getHistoricalRange` sur un symbole qui n'a
      // jamais existé chez Yahoo) à CHAQUE ré-import de cet actif. Jamais
      // cotable dans ce cas précis, quotable normalement sinon (comportement
      // inchangé pour toute position portant un VRAI symbole de marché).
      result = _CryptoTickerResolution(
        symbol: existingPosition.symbol,
        quotable: !existingPosition.symbol.startsWith('crypto:'),
      );
    } else {
      final alias = quoteAliases[code];
      if (alias != null) {
        // B-3 (revue adversariale) : l'alias porte sa propre devise dans son
        // SUFFIXE (`<code>-<devise>`, ex. `FLR-USD`) — jusqu'ici cette
        // devise n'était JAMAIS reportée sur l'actif créé, qui héritait
        // silencieusement de la devise du COMPTE (étage 4 seul forçait
        // `currency`). Résultat : les 7 alias actuels se terminant en `-USD`
        // créaient un actif `currency:'EUR'` sur un compte EUR alors que sa
        // cotation Yahoo est en USD — sous-évaluation systématique et
        // permanente (~13 % au taux courant). Même correction que l'étage 4 :
        // ne forcer [currency] QUE si elle diffère de la devise du compte
        // (sinon `null`, pour ne rien changer au comportement quand
        // l'alias est déjà dans la devise du compte).
        final dash = alias.lastIndexOf('-');
        final aliasCurrency = dash > 0 ? alias.substring(dash + 1) : null;
        result = _CryptoTickerResolution(
          symbol: alias,
          currency: aliasCurrency != null &&
                  aliasCurrency.toUpperCase() != accountCurrency.toUpperCase()
              ? aliasCurrency
              : null,
        );
      } else {
        final candidateAccountCcy = '$code-$accountCurrency';
        final existsAccountCcy = await _marketService.symbolExists(candidateAccountCcy);
        if (existsAccountCcy == true) {
          result = _CryptoTickerResolution(symbol: candidateAccountCcy);
        } else if (existsAccountCcy == false) {
          final candidateUsd = '$code-USD';
          final existsUsd = await _marketService.symbolExists(candidateUsd);
          if (existsUsd == true) {
            result = _CryptoTickerResolution(symbol: candidateUsd, currency: 'USD');
          } else if (existsUsd == false) {
            result = _CryptoTickerResolution(
              symbol: 'crypto:$code',
              quotable: false,
            );
          } else {
            result = _CryptoTickerResolution(
              symbol: 'crypto:$code',
              quotable: false,
              networkFailure: true,
            );
          }
        } else {
          // Panne réseau au premier étage réseau : étages suivants NON
          // tentés (on ne conclut jamais « invalide » sur une panne).
          result = _CryptoTickerResolution(
            symbol: 'crypto:$code',
            quotable: false,
            networkFailure: true,
          );
        }
      }
    }
    cache[code] = result;
    return result;
  }

  /// `true` si deux contenus de mouvement crypto sont ÉQUIVALENTS (même
  /// `kind`/`quantity`/`unitPrice`/`amount`/`fee`/jour) — sert à distinguer un
  /// DOUBLON franc (même `importKey`, même contenu) d'une COLLISION à examiner (même
  /// `importKey`, contenu différent, conception interne).
  static bool _sameCryptoContent(AssetTransaction a, AssetTransaction b) {
    return a.kind == b.kind &&
        a.quantity == b.quantity &&
        a.unitPrice == b.unitPrice &&
        a.amount == b.amount &&
        a.fee == b.fee &&
        a.date.year == b.date.year &&
        a.date.month == b.date.month &&
        a.date.day == b.date.day &&
        // Un agrégat mensuel de récompenses peut voir son NOMBRE de lignes
        // source s'allonger à un ré-import (mois complété) sans que la
        // quantité NETTE change (arrondis qui s'annulent) — sans cette
        // comparaison, un tel ré-import serait à tort classé DOUBLON franc
        // (contenu jugé identique) plutôt que remplacement (revue
        // adversariale, mineur).
        a.meta?['aggregatedRows'] == b.meta?['aggregatedRows'];
  }

  /// Enrichit les `transferOut` de [plan] porteurs de `meta['valuationUsd']`
  /// (retrait crypto en nature à jambe USD lisible, cf.
  /// `CryptoLedgerNormalizer._processDepositOrWithdrawal`) d'un équivalent EUR
  /// INFORMATIF — demande auteur, drive B16 (« voir l'équivalent en cash [d'un
  /// retrait] »). Pose `meta['valueEur']`/`meta['fxRate']`/ `meta['fxDate']` (mêmes
  /// clés que la valorisation des échanges, cf.
  /// `CryptoLedgerNormalizer._valuationMeta`) sur les mouvements concernés, SANS
  /// toucher au reste du plan.
  ///
  /// Zéro appel réseau si AUCUN `transferOut` du plan ne porte
  /// `valuationUsd` (comportement bit-identique à avant cette méthode pour
  /// un relevé qui n'en produit pas, ou pour un profil non-crypto qui
  /// n'appelle jamais cette méthode).
  ///
  /// BEST-EFFORT STRICT (B4, jamais de coercition) : une série FX
  /// indisponible ([ExchangeRateUnavailable]) laisse [plan] STRICTEMENT
  /// INCHANGÉ — contrairement à la valorisation des échanges ci-dessous (qui
  /// bascule tout en arbitrage manuel avec bandeau dédié), un retrait en
  /// nature reste un mouvement COMPLET sans son équivalent EUR : la quantité
  /// et le journal ne doivent jamais dépendre de cet appel pour exister.
  /// Fenêtre FX INDÉPENDANTE de celle appelée par [_cryptoValuationService]
  /// (couche privée à ce service, non réutilisable telle quelle) — mais MÊME
  /// service/MÊME cache mémoire ([_exchangeService]), donc aucun coût réseau
  /// supplémentaire quand les deux fenêtres se recouvrent (cas courant : les
  /// dates d'un relevé Kraken sont contiguës).
  Future<CryptoImportPlan> _enrichCryptoWithdrawalsWithEurValuation(
    CryptoImportPlan plan,
  ) async {
    final targetIndexes = <int>[
      for (var i = 0; i < plan.movements.length; i++)
        if (plan.movements[i].transaction?.kind == TransactionKind.transferOut &&
            plan.movements[i].transaction!.meta?['valuationUsd'] != null)
          i,
    ];
    if (targetIndexes.isEmpty) return plan;

    var minDate = plan.movements[targetIndexes.first].transaction!.date;
    var maxDate = minDate;
    for (final i in targetIndexes.skip(1)) {
      final d = plan.movements[i].transaction!.date;
      if (d.isBefore(minDate)) minDate = d;
      if (d.isAfter(maxDate)) maxDate = d;
    }

    final Map<DateTime, double> rates;
    try {
      rates = await _exchangeService.getDailyRatesToEur(
        'USD',
        from: minDate,
        to: maxDate,
      );
    } on ExchangeRateUnavailable {
      return plan; // best-effort — voir doc de tête, jamais bloquant.
    }

    final updatedMovements = [...plan.movements];
    for (final i in targetIndexes) {
      final m = updatedMovements[i];
      final tx = m.transaction!;
      final usd = Decimal.tryParse(tx.meta!['valuationUsd'].toString());
      if (usd == null) continue; // défensif — jamais atteint en pratique.
      final entry = _lastFxRateOnOrBefore(rates, tx.date);
      if (entry == null) continue; // repli antérieur introuvable, best-effort.
      final rateDecimal = Decimal.parse(entry.value.toString());
      final valueEur = usd * rateDecimal;
      updatedMovements[i] = ImportedMovement.candidate(
        sourceRow: m.sourceRow,
        sourceRowIndex: m.sourceRowIndex,
        transaction: tx.copyWith(meta: {
          ...tx.meta!,
          'valueEur': valueEur.toString(),
          'fxRate': entry.value.toString(),
          'fxDate': _isoDayFx(entry.key),
        }),
        isin: m.isin,
        label: m.label,
        ledgerCode: m.ledgerCode,
        needsAssetResolution: m.needsAssetResolution,
        resolvedSymbol: m.resolvedSymbol,
        importKey: m.importKey!,
      );
    }

    return CryptoImportPlan(
      globalRejectReason: plan.globalRejectReason,
      movements: updatedMovements,
      unvaluedExchanges: plan.unvaluedExchanges,
      unbalancedInternalTransfers: plan.unbalancedInternalTransfers,
      chainRuptures: plan.chainRuptures,
      quantityGaps: plan.quantityGaps,
      aggregatedRewardSourceRows: plan.aggregatedRewardSourceRows,
    );
  }

  /// Dernier jour ouvré ≤ [date] PRÉSENT dans [rates] — JAMAIS d'interpolation
  /// (même politique que `CryptoValuationService._lastRateOnOrBefore`, dont
  /// c'est une duplication VOLONTAIRE et minime : méthode PRIVÉE à son
  /// fichier, inaccessible ici — cf. l'en-tête de `crypto_ledger_normalizer.
  /// dart` pour la même doctrine de duplication assumée).
  MapEntry<DateTime, double>? _lastFxRateOnOrBefore(
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

  static String _isoDayFx(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Deadline GLOBALE du bloc réseau de l'étage 2 « cours en-app »
  /// (`_resolveMarketHistoryValuations`, I-1 — revue adversariale LOT 4) :
  /// barres ET séries FX confondues. Avec `maxAttempts: 1` sur chaque appel
  /// (voir cette méthode), la latence réelle reste bornée par ce délai quel
  /// que soit le nombre de symboles/devises — jamais les ~4 min pires-cas
  /// d'un `retryWithBackoff` par défaut (3 tentatives × 10 s) multiplié par
  /// les vagues `mapBounded` sur ~40 symboles Binance.
  static const Duration _marketHistoryStageDeadline = Duration(seconds: 20);

  /// Étage 2 « cours en-app » (chantier B16, LOT 4, conception interne) — pour les
  /// [UnvaluedExchange] restés en arbitrage manuel au motif SEUL
  /// [CryptoValuationManualReason.unreadable] (aucune valorisation étage 1
  /// exploitable — Binance systématique faute de colonne, ou valeur illisible
  /// Kraken) : cherche la CLÔTURE JOURNALIÈRE de la JAMBE PAYÉE au jour UTC exact
  /// de l'opération (repli sur la jambe REÇUE si la payée n'est pas cotable — même
  /// hiérarchie que l'étage 1, §5.1.7b — et systématiquement la jambe reçue pour
  /// un `depositInKind`, forme dégénérée sans jambe payée), via
  /// [MarketDataService.getHistoricalRange] (§5.1.7d, extension recommandée —
  /// [MarketDataService.getHistoricalData] dégrade en hebdomadaire/mensuel au-delà
  /// de quelques années, inutilisable ici).
  ///
  /// Les AUTRES motifs (`spread`/`foreignFiat`/`ambiguousGroup`) — filtrés dès
  /// l'entrée de cette méthode — ne passent JAMAIS par cet étage : ils portent
  /// une ambiguïté que le cours du jour ne lève pas (conception interne, table
  /// des étages).
  ///
  /// JAMAIS BLOQUANT (B4) : toute défaillance — ticker introuvable/panne
  /// réseau lors de sa résolution, panne réseau Yahoo, pas de barre le jour
  /// exact, série FX historique indisponible pour la devise de cotation —
  /// laisse SIMPLEMENT l'entrée concernée sans valorisation à cet étage :
  /// elle retombe à l'étage 3 (arbitrage manuel), motif `unreadable`
  /// INCHANGÉ, jamais d'exception propagée à l'appelant.
  ///
  /// BORNE DE LATENCE RÉELLE (I-1, revue adversariale LOT 4) : chaque appel
  /// réseau de CET étage (barres ET séries FX) tente UNE SEULE fois
  /// (`maxAttempts: 1` — `retryWithBackoff` à 3 tentatives/10 s resterait
  /// jusqu'à ~31,5 s PAR symbole, inadapté à un best-effort dont l'échec est
  /// de toute façon absorbé par l'étage 3), et l'ENSEMBLE du bloc réseau
  /// (barres PUIS séries FX, chacune bornée en concurrence via [mapBounded]/
  /// [maxConcurrentMarketRequests]) est plafonné par [_marketHistoryStageDeadline]
  /// — passé ce délai, les symboles/devises dont la tâche n'a pas eu le temps
  /// de s'écrire dans les tables partagées restent simplement ABSENTS,
  /// résultats PARTIELS assumés, jamais d'attente indéfinie de l'aperçu.
  ///
  /// [quoteAliases]/[positionByLedgerCode]/[tickerCache] : mêmes paramètres
  /// que [_resolveCryptoTicker] — l'appelant ([_previewCryptoImport]) passe
  /// le MÊME [tickerCache] (et le même instantané de positions) à
  /// [_finishCryptoPreview] ensuite pour qu'un ledgerCode déjà résolu ICI ne
  /// soit jamais re-résolu en réseau pour finaliser le mouvement
  /// correspondant.
  ///
  /// [existingImportKeys] (M-2, revue adversariale LOT 4 : retour au
  /// comportement du lot 2) — clés `meta['importKey']` DÉJÀ présentes au
  /// journal du compte (mouvements CONFIRMÉS d'un import antérieur, jamais
  /// reparsés ici). Un échange dont la clé DÉRIVÉE (`#sell:`/`#buy:`/
  /// `#deposit:`, calculée exactement comme le fera `finalizeCryptoExchanges`)
  /// y figure déjà N'EST JAMAIS soumis à cet étage : le valoriser produirait
  /// un montant DIFFÉRENT de celui déjà en base pour la même clé, donc un
  /// rejet `cryptoImportKeyCollision` à la place d'une ligne « à valoriser »
  /// silencieuse — exactement le bruit que le lot 2 évitait déjà pour
  /// l'étage 1. La ligne reste éligible à l'arbitrage manuel normal (motif
  /// `unreadable` inchangé), où l'utilisateur peut « importer sans ces
  /// échanges » sans jamais toucher à l'existant.
  ///
  /// Retourne la table `importKey -> CryptoValuation` des entrées résolues à
  /// cet étage (`source: 'marketHistory'`) — à FUSIONNER par l'appelant dans
  /// la table de l'étage 1 AVANT `finalizeCryptoExchanges` ; ne mute jamais
  /// [manualEntries] ni aucun état du contrôleur.
  Future<Map<String, CryptoValuation>> _resolveMarketHistoryValuations(
    List<CryptoValuationManual> manualEntries, {
    required Map<String, String> quoteAliases,
    required Map<String, Position> positionByLedgerCode,
    required String accountCurrency,
    required Map<String, _CryptoTickerResolution> tickerCache,
    required Set<String> existingImportKeys,
  }) async {
    final candidates = [
      for (final m in manualEntries)
        if (m.reason == CryptoValuationManualReason.unreadable &&
            !_hasExistingJournalEntry(m.source, existingImportKeys))
          m,
    ];
    if (candidates.isEmpty) return const {};

    // ---- Résolution de la jambe à coter (payée d'abord, repli reçue) ----
    final quotable = <_MarketHistoryCandidate>[];
    for (final m in candidates) {
      final u = m.source;
      String? leg;
      _CryptoTickerResolution? resolved;

      if (u.codePaid != null && u.quantityPaid != null) {
        final r = await _resolveCryptoTicker(
          u.codePaid!,
          quoteAliases: quoteAliases,
          positionByLedgerCode: positionByLedgerCode,
          accountCurrency: accountCurrency,
          cache: tickerCache,
        );
        if (r.quotable) {
          leg = 'paid';
          resolved = r;
        }
      }
      if (resolved == null) {
        final r = await _resolveCryptoTicker(
          u.codeReceived,
          quoteAliases: quoteAliases,
          positionByLedgerCode: positionByLedgerCode,
          accountCurrency: accountCurrency,
          cache: tickerCache,
        );
        if (r.quotable) {
          leg = 'received';
          resolved = r;
        }
      }
      if (resolved == null || leg == null) {
        continue; // ni l'une ni l'autre jambe cotable — reste à l'étage 3.
      }
      quotable.add(
        _MarketHistoryCandidate(manual: m, leg: leg, symbol: resolved.symbol),
      );
    }
    if (quotable.isEmpty) return const {};

    // ---- Barres journalières, UNE requête par SYMBOLE (fenêtre englobant
    // toutes ses opérations), concurrence bornée. ----
    final bySymbol = <String, List<_MarketHistoryCandidate>>{};
    for (final c in quotable) {
      bySymbol.putIfAbsent(c.symbol, () => []).add(c);
    }

    // I-1 (revue adversariale, LOT 4) : `closesBySymbol`/`ratesByCurrency`
    // sont des tables PARTAGÉES écrites DIRECTEMENT par chaque tâche au fil
    // de l'eau (jamais assemblées seulement APRÈS un `mapBounded` complet) —
    // c'est ce qui rend le résultat PARTIEL exploitable si la deadline
    // globale ci-dessous expire pendant que certaines tâches sont encore en
    // vol : les entrées déjà écrites restent utilisables, les autres
    // symboles/devises retombent simplement à l'étage 3.
    final closesBySymbol = <String, Map<DateTime, num>>{};
    final ratesByCurrency = <String, Map<DateTime, double>>{};

    Future<void> fetchStage2Data() async {
      // ---- Barres ----
      await mapBounded<MapEntry<String, List<_MarketHistoryCandidate>>, void>(
        bySymbol.entries,
        maxConcurrentMarketRequests,
        (entry) async {
          var minDate = entry.value.first.manual.source.date;
          var maxDate = minDate;
          for (final c in entry.value.skip(1)) {
            final d = c.manual.source.date;
            if (d.isBefore(minDate)) minDate = d;
            if (d.isAfter(maxDate)) maxDate = d;
          }
          AssetHistoricalData? data;
          try {
            data = await _marketService.getHistoricalRange(
              entry.key,
              minDate,
              maxDate,
              // I-1 : UNE seule tentative à cet étage best-effort — voir la
              // doc de tête de cette méthode.
              maxAttempts: 1,
            );
          } catch (_) {
            // B4 — jamais bloquant : ce symbole reste simplement sans
            // cotation à cet étage, ses candidats retomberont à l'étage 3.
            data = null;
          }
          if (data == null || data.hasError) return;
          // Index jour UTC -> close — lookup au jour UTC EXACT, JAMAIS de
          // repli (une crypto cote tous les jours, contrairement à la série
          // FX ci-dessous).
          final byDay = <DateTime, num>{};
          final n = data.dates.length < data.prices.length
              ? data.dates.length
              : data.prices.length;
          for (var i = 0; i < n; i++) {
            final d = data.dates[i];
            byDay[DateTime.utc(d.year, d.month, d.day)] = data.prices[i];
          }
          closesBySymbol[entry.key] = byDay;
        },
      );

      // ---- Conversion EUR — devise du SUFFIXE du ticker : direct si
      // `-EUR`, sinon série FX historique frankfurter (même chemin que
      // l'étage 1, §5.1.7c), UNE requête par devise NON-EUR nécessaire,
      // elle aussi bornée en concurrence (I-1 : remplace l'ancienne boucle
      // SÉRIELLE, qui pouvait à elle seule dépasser la minute sur plusieurs
      // devises). ----
      final datesByCurrency = <String, List<DateTime>>{};
      for (final c in quotable) {
        if (!closesBySymbol.containsKey(c.symbol)) continue;
        final currency =
            (_quoteCurrencySuffix(c.symbol) ?? accountCurrency).toUpperCase();
        if (currency == 'EUR') continue;
        datesByCurrency.putIfAbsent(currency, () => []).add(c.manual.source.date);
      }

      await mapBounded<MapEntry<String, List<DateTime>>, void>(
        datesByCurrency.entries,
        maxConcurrentMarketRequests,
        (entry) async {
          var minDate = entry.value.first;
          var maxDate = minDate;
          for (final d in entry.value.skip(1)) {
            if (d.isBefore(minDate)) minDate = d;
            if (d.isAfter(maxDate)) maxDate = d;
          }
          try {
            ratesByCurrency[entry.key] =
                await _exchangeService.getDailyRatesToEur(
              entry.key,
              from: minDate,
              to: maxDate,
            );
          } on ExchangeRateUnavailable {
            // B4 — best-effort : cette devise reste simplement non résolue,
            // ses candidats retomberont à l'étage 3.
          }
        },
      );
    }

    try {
      await fetchStage2Data().timeout(_marketHistoryStageDeadline);
    } on TimeoutException {
      // I-1 : deadline GLOBALE dépassée — voir la doc de tête de cette
      // méthode. Les symboles/devises jamais écrits dans `closesBySymbol`/
      // `ratesByCurrency` restent simplement absents, traités plus bas
      // exactement comme un échec ordinaire (B4, jamais bloquant).
    }

    // ---- Valorisation finale ----
    final valuations = <String, CryptoValuation>{};
    for (final c in quotable) {
      final closes = closesBySymbol[c.symbol];
      if (closes == null) continue;
      final u = c.manual.source;
      final day = DateTime.utc(u.date.year, u.date.month, u.date.day);
      final close = closes[day];
      if (close == null) continue; // pas de barre CE jour exact — étage 3.

      final quantityRaw = c.leg == 'paid' ? u.quantityPaid : u.quantityReceived;
      final quantity =
          quantityRaw == null ? null : Decimal.tryParse(quantityRaw)?.abs();
      if (quantity == null) continue; // défensif — jamais atteint en pratique.

      final closeDecimal = Decimal.tryParse(close.toString());
      if (closeDecimal == null) continue; // défensif (donnée Yahoo dégénérée).

      final quoteCurrency =
          (_quoteCurrencySuffix(c.symbol) ?? accountCurrency).toUpperCase();

      Decimal amountEur;
      double? fxRate;
      DateTime? fxDate;
      if (quoteCurrency == 'EUR') {
        // Doc 20 §5.1.7d : cotation déjà en EUR — AUCUNE conversion FX.
        amountEur = closeDecimal * quantity;
      } else {
        final rates = ratesByCurrency[quoteCurrency];
        final entry =
            rates == null ? null : _lastFxRateOnOrBefore(rates, u.date);
        if (entry == null) continue; // FX indisponible — étage 3.
        fxRate = entry.value;
        fxDate = entry.key;
        amountEur =
            closeDecimal * quantity * Decimal.parse(entry.value.toString());
      }

      valuations[u.importKey] = CryptoValuation(
        amountEur: amountEur,
        fxRate: fxRate,
        fxDate: fxDate,
        source: 'marketHistory',
        quoteSymbol: c.symbol,
        quoteDate: day,
        quoteInterval: '1d',
        quoteLeg: c.leg,
      );
    }

    return valuations;
  }

  /// M-2 (revue adversariale, LOT 4 — retour au comportement du lot 2) :
  /// `true` si la clé DÉRIVÉE que `CryptoLedgerNormalizer.
  /// finalizeCryptoExchanges` calculerait pour [u] (`#sell:`/`#buy:` pour un
  /// échange à 2 jambes, `#deposit:` pour un dépôt en nature) figure DÉJÀ
  /// dans [existingImportKeys] (journal du compte, mouvements CONFIRMÉS d'un
  /// import antérieur) — voir la doc de [_resolveMarketHistoryValuations]
  /// pour le raisonnement complet. Calcul délibérément DUPLIQUÉ (plutôt que
  /// factorisé avec `finalizeCryptoExchanges`, PUR et sans accès au journal)
  /// : ce contrôle a lieu AVANT la valorisation elle-même, alors que
  /// `finalizeCryptoExchanges` n'agit qu'APRÈS.
  static bool _hasExistingJournalEntry(
    UnvaluedExchange u,
    Set<String> existingImportKeys,
  ) {
    if (u.kind == 'exchange') {
      if (u.codePaid != null &&
          existingImportKeys.contains('${u.importKey}#sell:${u.codePaid}')) {
        return true;
      }
      return existingImportKeys
          .contains('${u.importKey}#buy:${u.codeReceived}');
    }
    return existingImportKeys
        .contains('${u.importKey}#deposit:${u.codeReceived}');
  }

  /// Devise du SUFFIXE d'un ticker résolu (`'BTC-EUR'` → `'EUR'`,
  /// `'FLR-USD'` → `'USD'`) — `null` si aucun tiret (repli non coté
  /// `'crypto:<code>'`, jamais atteint ici : `quotable` l'exclut déjà en
  /// amont dans [_resolveMarketHistoryValuations]).
  String? _quoteCurrencySuffix(String symbol) {
    final dash = symbol.lastIndexOf('-');
    return dash > 0 && dash < symbol.length - 1
        ? symbol.substring(dash + 1)
        : null;
  }

  Future<ImportPreview> _previewCryptoImport(
    Uint8List bytes,
    BrokerProfile profile, {
    required Account account,
    required String accountId,
  }) async {
    final parsed = StatementImportService.parseWithLineNumbers(bytes, profile);
    var plan = StatementImportService.planCryptoImport(
      parsed.rows,
      profile,
      accountCurrency: account.currency,
      accountId: accountId,
      sourceLines: parsed.sourceLines,
    );

    if (plan.globalRejectReason != null) {
      return ImportPreview(globalRejectReason: plan.globalRejectReason);
    }

    // ---- Demande auteur, drive B16 (« l'équivalent en cash d'un retrait ») :
    // équivalent EUR informatif des `transferOut` porteurs de
    // `meta['valuationUsd']` (cf. `CryptoLedgerNormalizer.
    // _processDepositOrWithdrawal`) — INDÉPENDANT de la valorisation des échanges
    // ci-dessous (un relevé peut n'avoir AUCUN échange non valorisé et pourtant des
    // retraits en nature à équiper). Best-effort STRICT : FX indisponible → `plan`
    // REVIENT INCHANGÉ, l'import ne doit JAMAIS échouer pour ça (voir doc de la
    // méthode).
    plan = await _enrichCryptoWithdrawalsWithEurValuation(plan);

    // ---- LOT 2 : valorisation étage 1 « fichier » des échanges crypto sans jambe
    // fiat (conception interne). Zéro appel si le fichier n'en a aucun
    // (comportement bit-identique au lot 1 pour un relevé qui n'en produit pas).
    // Les mouvements finalisés (sell+buy / adjustment) rejoignent [plan.movements]
    // AVANT toute dédup/résolution de ticker — ils traversent ENSUITE exactement le
    // même pipeline que n'importe quel autre mouvement crypto (clés
    // `#sell:`/`#buy:`/`#deposit:` stables ⇒ ré-import idempotent, cf. la
    // conception interne). Les échanges restés en arbitrage manuel (spread
    // excessif, jambe(s) illisible(s), FX indisponible) sont réexposés dans
    // [unvaluedExchanges] enrichis d'un motif via [UnvaluedExchange.copyWith] —
    // jamais reconstruits à la main.
    //
    // Les valorisations résolues ET les motifs des entrées manuelles sont
    // aussi mis en CACHE sur le contrôleur (cf. doc de tête des champs
    // `_lastCrypto*`) : [applyManualCryptoValuations] (UI, saisie manuelle
    // d'un montant EUR) les réutilise pour reconstruire l'aperçu sans
    // reparser le fichier.
    var financeMovements = const <ImportedMovement>[];
    var unvaluedForPreview = plan.unvaluedExchanges;
    var cryptoFxUnavailable = false;
    // LOT 4 (conception interne) : instantané de positions éventuellement peuplé par
    // l'étage 2 ci-dessous — transmis à [_finishCryptoPreview] pour qu'un ledgerCode
    // déjà résolu ICI (en réseau) ne le soit jamais une seconde fois pour finaliser
    // le mouvement correspondant. Reste `null` si l'étage 2 n'a jamais tourné (pas
    // d'échange non valorisé, ou tous résolus dès l'étage 1) —
    // [_finishCryptoPreview] charge alors son propre instantané, comportement
    // HISTORIQUE inchangé.
    List<Position>? positionsForFinish;
    // I-3 (revue adversariale, LOT 4) : SEEDÉ depuis le cache PERSISTANT du
    // contrôleur (voir sa doc) plutôt que de repartir d'une map vide — un
    // ledgerCode déjà résolu lors d'un aperçu/rebuild PRÉCÉDENT de CE MÊME
    // import n'est jamais re-résolu en réseau. Jamais `null` désormais (à la
    // différence de l'ancien `tickerCacheForFinish` nullable) : même à vide,
    // ce cache reste le bon réceptacle où fusionner les résolutions de CET
    // appel avant de les persister en fin de méthode.
    final tickerCacheForFinish =
        Map<String, _CryptoTickerResolution>.of(_lastCryptoTickerCache);
    if (plan.unvaluedExchanges.isNotEmpty) {
      try {
        final resolution = await _cryptoValuationService.resolve(
          plan.unvaluedExchanges,
          // M-1 (revue adversariale) : seuil de spread du PROFIL, plus jamais
          // la valeur codée en dur du service — Kraken vaut déjà `0.10`
          // (comportement inchangé pour ce profil).
          maxLegValuationSpread: profile.crypto!.maxLegValuationSpread,
          // Étage 1-ter (amendement drive lot 2 : liste de CONFIANCE du profil — vide
          // pour tout profil qui ne la renseigne pas, comportement inchangé.
          usdStableCodes: profile.crypto!.usdStableCodes,
        );
        _lastCryptoValuations.addAll(resolution.valuations);

        // ---- LOT 4 : étage 2 « cours en-app » (conception interne) — pour les
        // entrées restées manuelles au motif SEUL `unreadable`. Best-effort STRICT
        // (B4) : ne lève jamais, voir la doc de la méthode.
        final positions = await _storage.getPositions(accountId);
        final positionByLedgerCode = <String, Position>{
          for (final p in positions)
            if (p.asset.ledgerCode != null) p.asset.ledgerCode!: p,
        };
        final quoteAliases = profile.crypto?.quoteAliases ?? const {};
        // M-2 (revue adversariale, LOT 4) : clés déjà JOURNALISÉES pour ce
        // compte — voir la doc de [_resolveMarketHistoryValuations].
        final existingJournal = await _txStorage.getByAccount(accountId);
        final existingImportKeys = <String>{
          for (final t in existingJournal)
            if (t.meta?['importKey'] is String)
              t.meta!['importKey'] as String,
        };
        final marketHistoryValuations = await _resolveMarketHistoryValuations(
          resolution.manual,
          quoteAliases: quoteAliases,
          positionByLedgerCode: positionByLedgerCode,
          accountCurrency: account.currency,
          tickerCache: tickerCacheForFinish,
          existingImportKeys: existingImportKeys,
        );
        _lastCryptoValuations.addAll(marketHistoryValuations);
        positionsForFinish = positions;

        for (final m in resolution.manual) {
          if (marketHistoryValuations.containsKey(m.source.importKey)) {
            continue; // résolu à l'étage 2 — ne reste plus manuel.
          }
          _lastCryptoManualReasons[m.source.importKey] = (
            reason: m.reason.wire,
            spreadPct: m.valuationSpreadPct,
            // Amendement drive lot 2 (suite) : `null` sauf motif `spread` avec taux
            // résolu (cf. `CryptoValuationManual`).
            suggestedPaidEur: m.suggestedPaidEur?.toString(),
            suggestedReceivedEur: m.suggestedReceivedEur?.toString(),
          );
        }
        financeMovements = StatementImportService.finalizeCryptoExchanges(
          plan,
          {...resolution.valuations, ...marketHistoryValuations},
          accountId: accountId,
          accountCurrency: account.currency,
          // Refactor B16 lot 3 : vocabulaire des VRAIS dépôts externes lu
          // sur le PROFIL, plus jamais un littéral codé dans le moteur.
          externalDepositKinds: profile.crypto!.externalDepositKinds,
        );
        unvaluedForPreview = [
          for (final m in resolution.manual)
            if (!marketHistoryValuations.containsKey(m.source.importKey))
              m.source.copyWith(
                manualReason: m.reason.wire,
                valuationSpreadPct: m.valuationSpreadPct,
                suggestedPaidEur: m.suggestedPaidEur?.toString(),
                suggestedReceivedEur: m.suggestedReceivedEur?.toString(),
              ),
        ];
      } on ExchangeRateUnavailable {
        // Aucune coercition (conception interne) : TOUS les échanges sans jambe fiat
        // repartent en arbitrage manuel, motif uniforme — le reste du fichier
        // (rewards, dépôts/retraits, trades à jambe fiat, déjà dans `plan.movements`)
        // continue à être proposé normalement. Motif `fxUnavailable` : jamais de
        // suggestion (cf. doc de tête du champ `UnvaluedExchange.suggestedPaidEur`).
        cryptoFxUnavailable = true;
        for (final u in plan.unvaluedExchanges) {
          _lastCryptoManualReasons[u.importKey] = (
            reason: 'fxUnavailable',
            spreadPct: null,
            suggestedPaidEur: null,
            suggestedReceivedEur: null,
          );
        }
        unvaluedForPreview = [
          for (final u in plan.unvaluedExchanges)
            u.copyWith(manualReason: 'fxUnavailable'),
        ];
      }
    }

    _lastCryptoPlan = plan;
    _lastCryptoAccount = account;
    _lastCryptoAccountId = accountId;
    _lastCryptoProfile = profile;
    _lastCryptoFxUnavailable = cryptoFxUnavailable;

    final preview = await _finishCryptoPreview(
      plan: plan,
      financeMovements: financeMovements,
      unvaluedForPreview: unvaluedForPreview,
      cryptoFxUnavailable: cryptoFxUnavailable,
      account: account,
      accountId: accountId,
      profile: profile,
      positionsSnapshot: positionsForFinish,
      tickerResolutionCache: tickerCacheForFinish,
    );
    // I-3 : persiste les résolutions de CET appel (étage 2 + résolution
    // finale des mouvements par [_finishCryptoPreview], qui mute
    // [tickerCacheForFinish] EN PLACE) pour les rebuilds ultérieurs — voir la
    // doc de [_lastCryptoTickerCache]/[_persistTickerCache].
    _persistTickerCache(tickerCacheForFinish);
    return preview;
  }

  /// Applique des valorisations EUR SAISIES MANUELLEMENT (étage 3 « arbitrage
  /// manuel », chantier B16, lot 2 — conception interne) aux échanges crypto
  /// encore en attente du DERNIER aperçu crypto calculé ([previewStatementImport]
  /// avec `profile.crypto != null`) : reconstruit l'aperçu complet SANS reparser
  /// le fichier (le plan PUR et les valorisations déjà résolues à l'étage 1
  /// restent en cache sur le contrôleur, cf. `_lastCrypto*`) — seule la
  /// dédup/résolution de ticker/delta est rejouée, exactement comme un second
  /// aperçu. CORRECTIF (I-3, revue adversariale LOT 4) : une affirmation
  /// ANTÉRIEURE de ce commentaire prétendait ne « jamais retoucher le réseau » —
  /// FAUX dans les deux sens : la résolution ticker/delta rejouée ICI peut
  /// parfaitement appeler `symbolExists` pour un ledgerCode encore jamais vu ; ce
  /// que ce rebuild ÉVITE réellement, c'est de le REFAIRE pour un ledgerCode déjà
  /// résolu lors d'un appel PRÉCÉDENT de CE MÊME aperçu, via le cache persistant
  /// [_lastCryptoTickerCache] (voir sa doc).
  ///
  /// [eurByImportKey] : clé = `UnvaluedExchange.importKey` (LA MÊME clé que
  /// `ImportPreview.unvaluedExchanges[i].importKey` — l'UI ne fabrique
  /// JAMAIS les clés `#sell:`/`#buy:`/`#deposit:` dérivées, c'est le rôle de
  /// `CryptoLedgerNormalizer.finalizeCryptoExchanges`), valeur = montant EUR
  /// SAISI (chaîne décimale, virgule OU point). Une entrée dont le montant
  /// n'est pas un [Decimal] strictement positif est IGNORÉE (garde
  /// défensive silencieuse — la validation du champ, côté UI, empêche déjà
  /// une saisie invalide d'atteindre cette méthode) : cette clé RESTE en
  /// arbitrage manuel avec son motif d'origine, jamais valorisée à zéro.
  ///
  /// Retourne `null` si aucun aperçu crypto n'est en cours (aucun appel
  /// préalable à [previewStatementImport] sur un profil crypto, ou le cache
  /// a été invalidé par un aperçu plus récent) — l'appelant garde alors
  /// l'aperçu affiché tel quel.
  Future<ImportPreview?> applyManualCryptoValuations(
    Map<String, String> eurByImportKey,
  ) async {
    final plan = _lastCryptoPlan;
    final account = _lastCryptoAccount;
    final accountId = _lastCryptoAccountId;
    final profile = _lastCryptoProfile;
    if (plan == null ||
        account == null ||
        accountId == null ||
        profile == null) {
      return null;
    }
    // I-2 (revue adversariale, LOT 4) : verrou UNIQUE — voir la doc de
    // [_valuationRebuildInFlight]. Un rebuild déjà en vol (saisie manuelle OU
    // repli d'une AUTRE ligne) rejette celui-ci tel quel, aperçu INCHANGÉ.
    if (_valuationRebuildInFlight) return null;

    // B-1 (BLOQUANT, revue adversariale) : refuse (ignore) toute clé PARTAGÉE
    // par ≥ 2 `UnvaluedExchange` du plan — même garde que `resolve`/
    // `finalizeCryptoExchanges`, ceinture supplémentaire côté saisie MANUELLE
    // (en pratique déjà inatteignable depuis l'UI, le champ correspondant y
    // est désactivé pour ce motif, mais ce contrôleur ne fait jamais confiance
    // à l'UI seule pour une garde B4).
    final keyCounts = <String, int>{};
    for (final u in plan.unvaluedExchanges) {
      keyCounts[u.importKey] = (keyCounts[u.importKey] ?? 0) + 1;
    }

    // B-A (BLOQUANT, contre-vérification lot 2) : même raisonnement que B-1
    // ci-dessus — refuse (ignore) toute clé dont l'`UnvaluedExchange` porte
    // une jambe FIAT (payée OU reçue, typiquement étrangère à la devise du
    // compte) : une saisie manuelle appliquée à cette clé émettrait le MÊME
    // `sell`/`buy` fiat fabriqué que la valorisation automatique
    // (`CryptoValuationService.resolve`/`CryptoLedgerNormalizer.
    // finalizeCryptoExchanges` la refusent déjà toutes les deux) — le champ
    // correspondant est désactivé côté UI pour ce motif, mais ce contrôleur
    // ne fait jamais confiance à l'UI seule pour une garde B4.
    final foreignFiatKeys = <String>{
      for (final u in plan.unvaluedExchanges)
        if (u.codePaidIsFiat || u.codeReceivedIsFiat) u.importKey,
    };

    for (final entry in eurByImportKey.entries) {
      if ((keyCounts[entry.key] ?? 0) >= 2) continue; // clé partagée — refusée.
      if (foreignFiatKeys.contains(entry.key)) continue; // jambe fiat — refusée.
      final amount = Decimal.tryParse(entry.value.trim().replaceAll(',', '.'));
      if (amount == null || amount <= Decimal.zero) continue;
      _lastCryptoValuations[entry.key] = CryptoValuation(
        amountEur: amount,
        source: 'manual',
      );
    }

    _valuationRebuildInFlight = true;
    try {
      return await _rebuildCryptoPreviewFromCache(
        plan: plan,
        account: account,
        accountId: accountId,
        profile: profile,
      );
    } finally {
      _valuationRebuildInFlight = false;
    }
  }

  /// UX « repasser en saisie manuelle » (chantier B16, LOT 4, conception interne)
  /// — pour une ligne valorisée à l'étage 2 « cours en-app »
  /// (`meta.valuationSource == 'marketHistory'`), moyen SOBRE de la renvoyer à
  /// l'étage 3 (arbitrage manuel) : RETIRE sa valorisation du cache
  /// ([_lastCryptoValuations]) et reconstruit l'aperçu, sans reparser le fichier —
  /// même patron que [applyManualCryptoValuations] (voir sa doc, I-3 : ce rebuild
  /// PEUT retoucher le réseau pour un ledgerCode jamais résolu, le cache
  /// persistant [_lastCryptoTickerCache] n'évite que les résolutions déjà faites
  /// lors d'un appel précédent).
  ///
  /// [baseImportKey] : la clé de BASE (`UnvaluedExchange.importKey`, celle
  /// AVANT le suffixe de rôle `#sell:`/`#buy:`/`#deposit:` posé par
  /// `finalizeCryptoExchanges`) — PAS la clé suffixée portée par le
  /// mouvement finalisé affiché à l'écran (l'UI retire ce suffixe avant
  /// d'appeler cette méthode, même convention que
  /// [applyManualCryptoValuations]).
  ///
  /// GARDE DÉFENSIVE (B4, même doctrine que B-1/B-A ailleurs dans ce
  /// contrôleur — ne jamais faire confiance à l'UI seule) : n'agit QUE si la
  /// valorisation actuellement en cache pour cette clé porte bien
  /// `source == 'marketHistory'` — reverser une valorisation étage 1 ou une
  /// saisie manuelle par cette voie serait une régression silencieuse d'un
  /// AUTRE mécanisme. Motif redevient `unreadable` (SEUL motif qui atteint
  /// jamais l'étage 2, cf. [_resolveMarketHistoryValuations]) — posé ici
  /// explicitement car [_lastCryptoManualReasons] n'a jamais été renseigné
  /// pour cette clé (elle a été résolue à l'étage 2 avant d'y être écrite,
  /// cf. [_previewCryptoImport]).
  ///
  /// Retourne `null` si aucun aperçu crypto n'est en cours, si
  /// [baseImportKey] ne porte aucune valorisation `marketHistory` en cache
  /// (rien à annuler), OU si un AUTRE rebuild est déjà en vol (I-2, revue
  /// adversariale LOT 4 — voir la doc de [_valuationRebuildInFlight]) —
  /// l'appelant garde alors l'aperçu affiché tel quel dans les trois cas.
  Future<ImportPreview?> revertCryptoValuationToManual(
    String baseImportKey,
  ) async {
    final plan = _lastCryptoPlan;
    final account = _lastCryptoAccount;
    final accountId = _lastCryptoAccountId;
    final profile = _lastCryptoProfile;
    if (plan == null ||
        account == null ||
        accountId == null ||
        profile == null) {
      return null;
    }
    // I-2 (revue adversariale, LOT 4) : verrou UNIQUE — voir la doc de
    // [_valuationRebuildInFlight].
    if (_valuationRebuildInFlight) return null;

    final current = _lastCryptoValuations[baseImportKey];
    if (current == null || current.source != 'marketHistory') {
      return null; // rien à annuler à cet étage — défensif (B4).
    }
    _lastCryptoValuations.remove(baseImportKey);
    _lastCryptoManualReasons.putIfAbsent(
      baseImportKey,
      () => (
        reason: 'unreadable',
        spreadPct: null,
        suggestedPaidEur: null,
        suggestedReceivedEur: null,
      ),
    );

    _valuationRebuildInFlight = true;
    try {
      return await _rebuildCryptoPreviewFromCache(
        plan: plan,
        account: account,
        accountId: accountId,
        profile: profile,
      );
    } finally {
      _valuationRebuildInFlight = false;
    }
  }

  /// Reconstruit l'[ImportPreview] crypto depuis l'état COURANT de
  /// [_lastCryptoValuations]/[_lastCryptoManualReasons] (cette méthode ne
  /// DÉCIDE d'aucune valorisation — l'appelant a déjà mis le cache à jour) —
  /// factorisé entre [applyManualCryptoValuations] (après une saisie
  /// manuelle) et [revertCryptoValuationToManual] (LOT 4, après le retrait
  /// d'une valorisation étage 2) pour que les deux chemins partagent
  /// EXACTEMENT la même logique de dédup/résolution/delta
  /// ([_finishCryptoPreview]).
  Future<ImportPreview> _rebuildCryptoPreviewFromCache({
    required CryptoImportPlan plan,
    required Account account,
    required String accountId,
    required BrokerProfile profile,
  }) async {
    final financeMovements = StatementImportService.finalizeCryptoExchanges(
      plan,
      _lastCryptoValuations,
      accountId: accountId,
      accountCurrency: account.currency,
      // Refactor B16 lot 3 : même relais que `_previewCryptoImport`.
      externalDepositKinds: profile.crypto!.externalDepositKinds,
    );
    // Ne restent en arbitrage manuel que les entrées SANS valorisation (ni étage
    // 1/2, ni saisie manuelle) — motif reporté tel quel depuis le cache posé au
    // premier aperçu (cf. [_lastCryptoManualReasons], jamais recalculé : il ne
    // dépend que des jambes du relevé). Les suggestions EUR (amendement drive lot 2
    // (suite) suivent la MÊME règle : elles survivent donc, elles aussi, à une
    // ré-application PARTIELLE.
    final unvaluedForPreview = [
      for (final u in plan.unvaluedExchanges)
        if (!_lastCryptoValuations.containsKey(u.importKey))
          u.copyWith(
            manualReason: _lastCryptoManualReasons[u.importKey]?.reason,
            valuationSpreadPct:
                _lastCryptoManualReasons[u.importKey]?.spreadPct,
            suggestedPaidEur:
                _lastCryptoManualReasons[u.importKey]?.suggestedPaidEur,
            suggestedReceivedEur:
                _lastCryptoManualReasons[u.importKey]?.suggestedReceivedEur,
          ),
    ];

    // I-3 (revue adversariale, LOT 4) : SEEDÉ depuis le cache PERSISTANT —
    // voir la doc de [_lastCryptoTickerCache] — plutôt que de repartir d'une
    // map vide comme avant ce correctif (chaque rebuild rejouait ALORS la
    // résolution réseau de TOUS les ledgerCode déjà connus).
    final tickerCache =
        Map<String, _CryptoTickerResolution>.of(_lastCryptoTickerCache);
    final preview = await _finishCryptoPreview(
      plan: plan,
      financeMovements: financeMovements,
      unvaluedForPreview: unvaluedForPreview,
      cryptoFxUnavailable: _lastCryptoFxUnavailable,
      account: account,
      accountId: accountId,
      profile: profile,
      tickerResolutionCache: tickerCache,
    );
    _persistTickerCache(tickerCache);
    return preview;
  }

  /// Termine la construction de l'[ImportPreview] crypto — dédup par
  /// `importKey`, résolution ledgerCode→ticker, delta projeté — commune à
  /// [_previewCryptoImport] (premier aperçu, depuis les bytes du fichier) et
  /// [applyManualCryptoValuations] (ré-aperçu après saisie manuelle, sans
  /// fichier). PUR de tout accès réseau/base propre à la valorisation :
  /// [financeMovements]/[unvaluedForPreview]/[cryptoFxUnavailable] sont
  /// calculés par l'APPELANT, cette méthode ne fait que la suite commune.
  Future<ImportPreview> _finishCryptoPreview({
    required CryptoImportPlan plan,
    required List<ImportedMovement> financeMovements,
    required List<UnvaluedExchange> unvaluedForPreview,
    required bool cryptoFxUnavailable,
    required Account account,
    required String accountId,
    required BrokerProfile profile,
    // LOT 4 (conception interne) : instantané de positions + cache de résolution
    // ticker déjà peuplés par l'étage 2 « cours en-app » de [_previewCryptoImport]
    // (voir sa doc et celle de [_resolveMarketHistoryValuations]) — évite de relire
    // les positions et de re-résoudre en réseau un ledgerCode déjà résolu à cet
    // étage (le cas Binance vise ~370 opérations, souvent le même actif). `null`
    // (défaut) : comportement HISTORIQUE inchangé, cette méthode charge son propre
    // instantané — c'est le cas d'[applyManualCryptoValuations], qui ne passe jamais
    // par l'étage 2.
    List<Position>? positionsSnapshot,
    Map<String, _CryptoTickerResolution>? tickerResolutionCache,
  }) async {
    final rejects = <ImportedMovement>[];
    final candidates = <ImportedMovement>[];
    for (final m in [...plan.movements, ...financeMovements]) {
      (m.isRejected ? rejects : candidates).add(m);
    }

    // ---- Dédup PAR importKey + détection des remplacements d'agrégats ----
    final existingJournal = await _txStorage.getByAccount(accountId);
    final existingByImportKey = <String, AssetTransaction>{};
    for (final t in existingJournal) {
      final key = t.meta?['importKey'];
      if (key is String) existingByImportKey[key] = t;
    }

    final duplicates = <ImportedMovement>[];
    final toCreateCandidates = <ImportedMovement>[];
    final replacements = <AggregateReplacement>[];
    for (final m in candidates) {
      final key = m.importKey;
      final existing = key != null ? existingByImportKey[key] : null;
      if (existing == null) {
        toCreateCandidates.add(m);
        continue;
      }
      if (_sameCryptoContent(existing, m.transaction!)) {
        duplicates.add(m);
        continue;
      }
      // Même clé, contenu DIFFÉRENT : remplacement d'agrégat SI ET SEULEMENT
      // SI le mouvement en base porte déjà `aggregation:'monthly'` (garde
      // stricte §5.1.8b) — sinon, anomalie : REJET motivé, jamais d'écrasement.
      if (existing.meta?['aggregation'] == 'monthly') {
        final prevRows = (existing.meta?['aggregatedRows'] as num?)?.toInt() ?? 0;
        final newMeta = m.transaction!.meta;
        final newRows = (newMeta?['aggregatedRows'] as num?)?.toInt() ?? 0;
        final prevQty = Decimal.tryParse(existing.quantity ?? '0') ?? Decimal.zero;
        final newQty =
            Decimal.tryParse(m.transaction!.quantity ?? '0') ?? Decimal.zero;
        replacements.add(AggregateReplacement(
          movement: m,
          month: (newMeta?['aggregatedMonth'] as String?) ?? '',
          previousRowCount: prevRows,
          newRowCount: newRows,
          quantityDelta: (newQty - prevQty).toString(),
        ));
      } else {
        // I-2 (revue adversariale) : `m.sourceRow`/`m.sourceRowIndex` sont
        // repris TELS QUELS depuis le mouvement candidat — pour un mouvement
        // issu de `finalizeCryptoExchanges` (sell/buy/dépôt en nature),
        // `sourceRowIndex` porte déjà `UnvaluedExchange.sourceLines.first`
        // (jamais -1 en pratique, ces listes ne sont jamais vides), donc le
        // rejet garde un numéro de ligne lisible même si `sourceRow` lui-même
        // reste vide (voir `finalizeCryptoExchanges`, qui n'a plus la ligne
        // brute à ce stade). Le libellé du motif est posé côté UI
        // (`statement_import_page._rejectReasonLabel`).
        rejects.add(ImportedMovement.rejected(
          sourceRow: m.sourceRow,
          sourceRowIndex: m.sourceRowIndex,
          rejectReason: 'cryptoImportKeyCollision',
        ));
      }
    }

    // ---- Cascade de résolution ledgerCode → ticker (§5.1.6) ----
    final existingPositions =
        positionsSnapshot ?? await _storage.getPositions(accountId);
    final positionByLedgerCode = <String, Position>{};
    final existingSymbols = <String>{};
    for (final p in existingPositions) {
      existingSymbols.add(p.symbol);
      final code = p.asset.ledgerCode;
      if (code != null) positionByLedgerCode[code] = p;
    }
    final quoteAliases = profile.crypto?.quoteAliases ?? const {};
    final resolutionCache =
        tickerResolutionCache ?? <String, _CryptoTickerResolution>{};

    final newAssets = <NewAssetCandidate>[];
    final newAssetCodesSeen = <String>{};
    final resolved = <ImportedMovement>[];

    for (final m in toCreateCandidates) {
      final code = m.ledgerCode;
      final tx = m.transaction!;
      if (code == null) {
        // Mouvement cash pur (deposit/withdrawal fiat) : aucun actif à résoudre.
        resolved.add(m);
        continue;
      }
      final r = await _resolveCryptoTicker(
        code,
        quoteAliases: quoteAliases,
        positionByLedgerCode: positionByLedgerCode,
        accountCurrency: account.currency,
        cache: resolutionCache,
      );
      if (!existingSymbols.contains(r.symbol) && newAssetCodesSeen.add(code)) {
        newAssets.add(NewAssetCandidate(
          label: code,
          proposedSymbol: r.symbol,
          quotable: r.quotable,
          ledgerCode: code,
          networkFailure: r.networkFailure,
        ));
      }
      resolved.add(ImportedMovement.candidate(
        sourceRow: m.sourceRow,
        sourceRowIndex: m.sourceRowIndex,
        transaction: tx.copyWith(
          symbol: r.symbol,
          currency: r.currency ?? tx.currency,
        ),
        ledgerCode: code,
        resolvedSymbol: r.symbol,
        importKey: m.importKey!,
      ));
    }

    // ---- Résolution cascade des résidus de transferts internes non
    // équilibrés (I-2, revue adversariale, §5.1.5) — RÉUTILISE la même
    // cascade/mémoïsation que les mouvements normaux ci-dessus, à
    // L'APERÇU (zéro réseau à la confirmation, cf. doc de
    // [confirmStatementImport]). AVANT ce correctif, la résolution n'était
    // tentée qu'à la confirmation et se limitait à l'étage 1 (position
    // PRÉEXISTANTE) : un actif dont le SEUL mouvement crypto est ce résidu
    // (ex. un airdrop livré directement en earn, sans jambe spot) n'avait
    // jamais de position existante — silencieusement ignoré au premier
    // import, alors que c'est justement le cas NOMINAL. La cascade complète
    // (position existante → alias de cotation → réseau → repli non coté)
    // s'applique maintenant ici, avec création d'un [NewAssetCandidate] au
    // besoin (dédupliqué via [newAssetCodesSeen], comme pour les mouvements
    // normaux) — le résidu représente une position réellement détenue,
    // jamais une simple ligne de journal.
    var unresolvedInternalTransferResidualCount = 0;
    final resolvedUnbalancedInternalTransfers = <UnbalancedInternalTransfer>[];
    for (final u in plan.unbalancedInternalTransfers) {
      final r = await _resolveCryptoTicker(
        u.asset,
        quoteAliases: quoteAliases,
        positionByLedgerCode: positionByLedgerCode,
        accountCurrency: account.currency,
        cache: resolutionCache,
      );
      // Clé de REMPLACEMENT stable (compte + PROFIL + actif, conception interne
      // généralisé, alignée sur la clé `agg:$accountId:${profile.id}:…` des agrégats
      // de récompenses) — un ré-import qui retrouve le MÊME résidu remplace
      // l'ajustement déjà en base au lieu de l'empiler (I-2 : idempotence). Le
      // profil DOIT figurer dans la clé (contre- vérification, R-... ②) : deux
      // profils crypto distincts importés sur le MÊME compte ne doivent jamais se
      // voler la clé de remplacement d'un résidu portant le même code d'actif.
      final replaceImportKey =
          'internalresidual:$accountId:${profile.id}:${u.asset}';
      resolvedUnbalancedInternalTransfers.add(u.copyWith(
        resolvedSymbol: r.symbol,
        replaceImportKey: replaceImportKey,
      ));
      if (!existingSymbols.contains(r.symbol) && newAssetCodesSeen.add(u.asset)) {
        newAssets.add(NewAssetCandidate(
          label: u.asset,
          proposedSymbol: r.symbol,
          quotable: r.quotable,
          ledgerCode: u.asset,
          networkFailure: r.networkFailure,
        ));
      }
      // `_resolveCryptoTicker` ne renvoie, dans l'état actuel de la cascade,
      // JAMAIS de symbole vide (repli ultime `'crypto:<code>'` non coté) —
      // branche DÉFENSIVE : « compter et exposer », jamais « ignorer en
      // silence », si un futur étage de la cascade venait à y déroger.
      if (r.symbol.trim().isEmpty) {
        unresolvedInternalTransferResidualCount++;
      }
    }
    _lastUnresolvedInternalTransferResidualCount =
        unresolvedInternalTransferResidualCount;

    // ---- Delta projeté (rejeu en mémoire, lecture seule — même mécanisme
    // que le chemin titres) ----
    final projectedDeltas = <ProjectedDelta>[];
    final touchedSymbols = <String>{
      for (final m in resolved)
        if (m.transaction!.symbol != null) m.transaction!.symbol!,
    };
    for (final symbol in touchedSymbols) {
      final before = existingJournal.where((t) => t.symbol == symbol).toList();
      final incoming = resolved
          .where((m) => m.transaction!.symbol == symbol)
          .map((m) => m.transaction!)
          .toList();
      final beforeProj = projectPosition(before);
      final afterProj = projectPosition([...before, ...incoming]);
      projectedDeltas.add(ProjectedDelta(
        symbol: symbol,
        quantityBefore: beforeProj.quantity.toString(),
        quantityAfter: afterProj.quantity.toString(),
        averageBuyPriceBefore: beforeProj.averagePrice,
        averageBuyPriceAfter: afterProj.averagePrice,
      ));
    }
    final cashCurrency = account.currency;
    final incomingAll = resolved.map((m) => m.transaction!).toList();
    final cashBefore =
        replayLedger(existingJournal).cashByCurrency[cashCurrency] ??
            Decimal.zero;
    final cashAfter = replayLedger([...existingJournal, ...incomingAll])
            .cashByCurrency[cashCurrency] ??
        Decimal.zero;
    projectedDeltas.add(ProjectedDelta(
      cashBefore: cashBefore.toDouble(),
      cashAfter: cashAfter.toDouble(),
    ));

    return ImportPreview(
      toCreate: resolved,
      duplicates: duplicates,
      rejects: rejects,
      newAssets: newAssets,
      projectedDeltas: projectedDeltas,
      unvaluedExchanges: unvaluedForPreview,
      cryptoFxUnavailable: cryptoFxUnavailable,
      unbalancedInternalTransfers: resolvedUnbalancedInternalTransfers,
      chainRuptures: plan.chainRuptures,
      quantityGaps: plan.quantityGaps,
      replacements: replacements,
      aggregatedRewardSourceRows: plan.aggregatedRewardSourceRows,
    );
  }

  /// Vrai si un mouvement relève du rapprochement « doublon probable
  /// d'espèces » (cf. [ImportPreview.probableDuplicates]) : un mouvement de
  /// TRÉSORERIE PURE, dont l'identité de dédup se réduit au libellé.
  ///
  /// Restreint aux kinds dont le relevé ne fournit AUCUN identifiant plus
  /// solide : `deposit`/`withdrawal` (virements, le cas mesuré),
  /// `interest`/`charge`. **Exclut** délibérément `adjustment` et
  /// `openingBalance` (gestes de correction/initialisation, non répétitifs par
  /// nature) et tout mouvement portant un `symbol` (une opération sur titre est
  /// identifiée par son ISIN, pas par son libellé).
  static bool _isCashMovementForMatching(TransactionKind kind, String? symbol) {
    if (symbol != null) return false;
    return kind == TransactionKind.deposit ||
        kind == TransactionKind.withdrawal ||
        kind == TransactionKind.interest ||
        kind == TransactionKind.charge;
  }

  /// Empreinte de rapprochement d'un mouvement d'espèces : `kind|jour|montant`,
  /// montant NORMALISÉ via [Decimal] pour que « 5000 » et « 5000.00 » se
  /// rapprochent. `null` si le montant est absent ou illisible (rien à
  /// rapprocher — jamais signalé plutôt que signalé à tort).
  ///
  /// Le LIBELLÉ est délibérément absent : c'est précisément lui qui varie et
  /// casse la clé de dédup. L'HEURE ne peut pas y figurer — les relevés n'en
  /// portent pas (d'où l'incertitude assumée, tranchée par l'utilisateur).
  static String? _cashMatchPrint(
    TransactionKind kind,
    DateTime date,
    String? amount,
  ) {
    final raw = amount?.replaceAll(',', '.').trim();
    if (raw == null || raw.isEmpty) return null;
    final value = Decimal.tryParse(raw);
    if (value == null) return null;
    final day = DateTime(date.year, date.month, date.day)
        .toIso8601String()
        .substring(0, 10);
    return '${kind.name}|$day|${value.toString()}';
  }

  /// Confirme un [preview] préalablement établi par [previewStatementImport] :
  /// écrit les mouvements retenus (`preview.toCreate`) et les actifs neufs déjà
  /// résolus à un symbole (`preview.newAssets` dont `proposedSymbol` est
  /// renseigné) via [LedgerService.importMovements], UNE SEULE fois, de façon
  /// atomique. Un [NewAssetCandidate] encore sans symbole reste hors périmètre
  /// du contrôleur (résolution UI non faite) : il est silencieusement ignoré
  /// ici plutôt que de fabriquer un symbole arbitraire.
  ///
  /// Retourne null en cas de succès, ou un code d'erreur :
  ///   - 'noActiveAccount' : pas de compte actif
  ///
  /// [replaceImportKeys] (OPTIONNEL, défaut vide → comportement historique INCHANGÉ
  /// pour les profils titres) : sous-ensemble des `importKey` de
  /// [preview.replacements] (chantier B16, conception interne) que l'appelant
  /// CONFIRME vouloir remplacer — un agrégat mensuel de [preview.replacements] dont
  /// la clé n'apparaît PAS ici reste silencieusement IGNORÉ (ni écrit, ni l'ancien
  /// supprimé), symétrique de [preview.newAssets] non résolus. Relayé tel quel à
  /// [LedgerService.importMovements], qui applique la suppression ciblée dans LA
  /// MÊME transaction que l'écriture.
  ///
  /// [journalizeUnbalancedInternalTransfers] (défaut `false`, doc §5.1.5) :
  /// journalise le résidu de chaque [preview.unbalancedInternalTransfers] en
  /// `adjustment` TITRE à coût 0, sur le symbole [UnbalancedInternalTransfer.
  /// resolvedSymbol] — résolu par la cascade COMPLÈTE (réseau inclus) à
  /// l'APERÇU ([_previewCryptoImport]), jamais ici (I-2, revue
  /// adversariale : zéro I/O à la confirmation, symétrique de
  /// [preview.newAssets] déjà résolus). Un actif SANS position préexistante
  /// dans le compte reçoit désormais ce résidu comme n'importe quel autre —
  /// l'ancien comportement (restreint à l'étage 1 de la cascade, résidu
  /// silencieusement ignoré si l'actif n'existait pas déjà) ratait
  /// précisément le cas NOMINAL d'un PREMIER import. Idempotent : la clé
  /// [UnbalancedInternalTransfer.replaceImportKey] (stable, compte+profil+
  /// actif) est unie À `replaceImportKeys` en interne — un ré-import qui
  /// retrouve le même résidu REMPLACE l'ajustement déjà en base au lieu de
  /// l'empiler, sans que l'appelant (l'écran) n'ait à connaître ce
  /// mécanisme : la SEULE décision qui reste à l'écran est le bouton
  /// bascule [journalizeUnbalancedInternalTransfers] lui-même.
  Future<String?> confirmStatementImport(
    ImportPreview preview, {
    required String accountId,
    Set<String> replaceImportKeys = const {},
    bool journalizeUnbalancedInternalTransfers = false,
  }) async {
    if (_activeAccount == null) return 'noActiveAccount';

    final movements = preview.toCreate
        .where((m) => !m.isRejected)
        .map((m) => m.transaction!)
        .toList();

    // Remplacements d'agrégats CONFIRMÉS (§5.1.8b) : mouvements EXCLUS de
    // `preview.toCreate` par construction, ajoutés ici UNIQUEMENT pour les
    // clés que l'appelant a explicitement retenues.
    for (final r in preview.replacements) {
      if (replaceImportKeys.contains(r.movement.transaction!.meta?['importKey'])) {
        movements.add(r.movement.transaction!);
      }
    }

    // Résidus de transferts internes non équilibrés (§5.1.5), option
    // EXPLICITE — symbole ET clé de remplacement CONSOMMÉS tels quels depuis
    // l'aperçu (I-2, revue adversariale), zéro I/O ici.
    final residualReplaceKeys = <String>{};
    if (journalizeUnbalancedInternalTransfers) {
      for (final u in preview.unbalancedInternalTransfers) {
        final symbol = u.resolvedSymbol;
        // Résolution manquante : déjà comptée/exposée à l'aperçu
        // (`lastUnresolvedInternalTransferResidualCount`) — pas de coup de
        // force ici (B4), la ligne est simplement omise de ce lot.
        if (symbol == null) continue;
        // Clé de remplacement ABSENTE de l'aperçu : PAS de repli recalculé
        // ici (contre-vérification, ②) — un recalcul divergerait de la clé
        // posée à l'aperçu (ex. si un futur appelant construit un
        // [ImportPreview] à la main sans passer par [_previewCryptoImport])
        // et CASSERAIT l'idempotence au lieu de la garantir : mieux vaut
        // omettre la ligne (B4, jamais de coup de force) que d'écrire sous
        // une clé qui ne sera jamais retrouvée au ré-import suivant.
        final key = u.replaceImportKey;
        if (key == null) continue;
        movements.add(AssetTransaction(
          id: AssetTransaction.generateId(),
          accountId: accountId,
          symbol: symbol,
          kind: TransactionKind.adjustment,
          quantity: u.residual,
          currency: _activeAccount!.currency,
          // Date du relevé (dernière jambe du groupe non équilibré),
          // tronquée au jour — jamais `DateTime.now()` (I-2 : daterait le
          // geste d'IMPORT, pas le relevé).
          date: DateTime(u.lastDate.year, u.lastDate.month, u.lastDate.day),
          meta: {
            'internalTransferResidual': true,
            'replaceable': true,
            'importKey': key,
          },
        ));
        residualReplaceKeys.add(key);
      }
    }

    // I-2 × UX (choix explicite, revue adversariale) : les clés de
    // remplacement des résidus sont unies ICI, en interne, plutôt que de
    // demander à l'écran de les calculer — la seule décision qui reste
    // visible à l'écran est le bouton bascule
    // `journalizeUnbalancedInternalTransfers` ; `_confirmImport`
    // (statement_import_page.dart) continue de calculer son
    // `replaceImportKeys` uniquement depuis `preview.replacements`
    // (agrégats de récompenses) sans rien connaître de ce mécanisme — un
    // ré-import remplace silencieusement la même ligne de résidu plutôt que
    // de l'empiler, ce qui EST le comportement honnête attendu (« mon
    // résidu est à jour », jamais « mon résidu est dupliqué »).
    final effectiveReplaceImportKeys = {
      ...replaceImportKeys,
      ...residualReplaceKeys,
    };

    final assetsToCreate = <String, Asset>{};
    for (final candidate in preview.newAssets) {
      final symbol = candidate.proposedSymbol;
      if (symbol == null ||
          symbol.isEmpty ||
          assetsToCreate.containsKey(symbol)) {
        continue;
      }
      // Devise de cotation reprise du premier mouvement rattaché à ce
      // symbole (aucune cotation réseau au MVP manuel/direct) ; aucun
      // mouvement rattaché → rien à créer (candidat orphelin).
      AssetTransaction? sample;
      for (final t in movements) {
        if (t.symbol == symbol) {
          sample = t;
          break;
        }
      }
      if (sample == null) continue;
      assetsToCreate[symbol] = Asset(
        symbol: symbol,
        name: candidate.label,
        currency: sample.currency,
        isin: candidate.isin,
        // Repli « non coté » (symbole == ISIN, titre délisté) : marqué non
        // interrogeable pour ne jamais déclencher d'appel réseau au refresh.
        quotable: candidate.quotable,
        // Code du RELEVÉ CRYPTO d'origine (conception interne) — `null` pour tout
        // candidat issu d'un profil titres (round-trip inchangé).
        ledgerCode: candidate.ledgerCode,
        type: candidate.ledgerCode != null ? AssetType.crypto : AssetType.other,
      );
    }

    // Identifiant de LOT unique (support de l'annulation). Estampillé sur chaque
    // mouvement écrit (meta['importBatch']) par le ledger. Généré ici et exposé
    // via [lastImportBatchId] APRÈS succès : l'UI l'utilise pour « Annuler cet
    // import » ([undoStatementImport]).
    final batchId = 'imp-${DateTime.now().microsecondsSinceEpoch}';

    await _ledger.importMovements(
      accountId: accountId,
      movements: movements,
      newAssets: assetsToCreate.values.toList(),
      importBatchId: batchId,
      replaceImportKeys: effectiveReplaceImportKeys,
    );
    // Mémorisé seulement APRÈS le succès de l'écriture (une exception ci-dessus
    // remonte sans laisser un batchId pointant sur un import qui n'a pas eu lieu).
    _lastImportBatchId = batchId;

    await _initService();
    return null;
  }

  /// Annule l'import de relevé identifié par [batchId] sur le compte
  /// [accountId] : supprime ATOMIQUEMENT du journal TOUS les mouvements de ce
  /// lot (estampillés `meta['importBatch']`), reprojette titres et cash côté
  /// ledger ([LedgerService.removeImportBatch]), puis rafraîchit l'état de la
  /// vue. Retourne le NOMBRE de mouvements supprimés (0 si le lot est inconnu /
  /// déjà annulé — no-op sûr).
  ///
  /// Seuls les mouvements du lot [batchId] sont retirés ; un mouvement d'un
  /// autre import ou saisi à la main n'est jamais touché (cf. la garde de
  /// [LedgerService.removeImportBatch]). Après une annulation qui a effacé le
  /// dernier lot mémorisé, [lastImportBatchId] est remis à null (plus rien à
  /// annuler pour ce batch).
  Future<int> undoStatementImport({
    required String accountId,
    required String batchId,
  }) async {
    final removed = await _ledger.removeImportBatch(accountId, batchId);
    if (_lastImportBatchId == batchId) _lastImportBatchId = null;
    await _initService();
    return removed;
  }

  // ---------------------------------------------------------------------------
  // Helpers (visibles pour les tests)
  // ---------------------------------------------------------------------------

  /// Génère un symbole interne unique (clé de stockage) pour un métal précieux
  /// à partir de son nom, en évitant les collisions avec les positions existantes.
  String generateMetalSymbol(String name, Set<String> existing) {
    var base = name
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (base.isEmpty) base = 'METAL';
    var candidate = base;
    var i = 2;
    while (existing.contains(candidate)) {
      candidate = '$base-$i';
      i++;
    }
    return candidate;
  }

  // ---------------------------------------------------------------------------
  // Presets métaux précieux (list partagée avec la vue pour le dialog)
  // ---------------------------------------------------------------------------

  /// Modèles de pièces/lingots d'investissement courants : poids de métal fin
  /// en grammes. Constantes physiques (non traduites).
  static const List<({String name, double weight})> metalPresets = [
    (name: 'Napoléon 20 F', weight: 5.807),
    (name: 'Napoléon 40 F', weight: 11.6135),
    (name: '20 F Suisse (Vreneli)', weight: 5.807),
    (name: 'Souverain (Sovereign)', weight: 7.3224),
    (name: '50 Pesos (Mexique)', weight: 37.5),
    (name: 'Krugerrand 1 oz', weight: 31.1035),
    (name: 'Maple Leaf 1 oz', weight: 31.1035),
    (name: 'American Eagle 1 oz', weight: 31.1035),
    (name: 'Lingotin 10 g', weight: 10.0),
  ];
}

/// Résultat de [AccountController._resolveCryptoTicker] — cascade
/// ledgerCode→ticker (chantier B16, conception interne).
class _CryptoTickerResolution {
  final String symbol;

  /// Devise à forcer sur l'actif créé (`'USD'` à l'étage 4), `null` = ne pas
  /// modifier la devise déjà portée par les mouvements résolus.
  final String? currency;
  final bool quotable;

  /// `true` si la résolution s'est arrêtée sur une PANNE RÉSEAU (timeout, 429…)
  /// plutôt qu'une non-existence CONSTATÉE (404) — jamais assimilée à une
  /// invalidité (conception interne).
  final bool networkFailure;

  const _CryptoTickerResolution({
    required this.symbol,
    this.currency,
    this.quotable = true,
    this.networkFailure = false,
  });
}

/// Candidat étage 2 « cours en-app » — un [UnvaluedExchange] resté manuel
/// au motif `unreadable`, dont l'une des deux jambes a été résolue à un
/// ticker COTABLE (voir [AccountController._resolveMarketHistoryValuations]).
class _MarketHistoryCandidate {
  final CryptoValuationManual manual;

  /// `'paid'` ou `'received'` — quelle jambe de [manual] a servi.
  final String leg;

  final String symbol;

  const _MarketHistoryCandidate({
    required this.manual,
    required this.leg,
    required this.symbol,
  });
}

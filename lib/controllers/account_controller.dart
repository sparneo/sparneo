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

import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/import_preview.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
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
    TransactionStorage? transactionStorage,

    /// Taux USD→EUR pré-chargé (évite l'appel réseau en test).
    /// Si fourni, [loadExchangeRate] l'utilise directement sans interroger
    /// [ExchangeRateService].
    double? initialUsdToEurRate,
  }) : _storage = storage ?? AccountStorage(),
       _ledger = ledgerService ?? LedgerService(),
       _marketService = marketService ?? MarketDataService.shared,
       _exchangeService = exchangeService ?? ExchangeRateService(),
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

  // Mode 2 « évolution réelle » (B7, design doc 18) : reconstruction datée
  // depuis le journal du compte, calculée EN PARALLÈLE du mode 1 ci-dessus
  // (additif — n'écrit JAMAIS les champs mode 1). ALIGNÉE index-par-index sur
  // [_chartDates] (même grille, garantie par construction — cf.
  // _computeAccountRealCurve). PÉRIMÈTRE : titres du compte reconstruits depuis
  // le journal + CASH DÉRIVÉ du compte (projection B5 du même journal, gating
  // d'ancrage `journalHasCashAnchor` appliqué par `reconstructRealNetWorth`) —
  // c'est la vraie valeur du compte dans le temps, dont le point final coïncide
  // avec la « Valeur totale » affichée (qui inclut le cash). Diffère donc du
  // mode 1 du compte ([HistoryAggregator.aggregateHistoricalData], titres seuls
  // sans cash) : le petit écart au basculement est le solde espèces, assumé.
  List<double> _realChartValues = [];
  // Symboles dont la valeur, à au moins une date, provient d'un repli
  // « dernier cours connu » (pas un vrai historique de marché) — badge UI.
  Set<String> _realCurveApproxSymbols = {};

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
  // `true` si [_realPeriodGainPercent] est ANNUALISÉ (fenêtre ≥ 2 ans) plutôt
  // que cumulé — cf. [RealGains.isAnnualized]. Pilote le suffixe « /an » côté
  // UI (TotalValueCard.percentIsAnnualized).
  bool _realPeriodGainIsAnnualized = false;
  // Gain TOTAL (état courant, base coût, INDÉPENDANT de la fenêtre affichée)
  // via [HistoryAggregator.computeRealTotalGain] — voir [RealTotalGain].
  // Passe les positions DU COMPTE (legacy incluses si leur PRU est connu),
  // jamais gaté par la période sélectionnée.
  double? _realTotalGain;
  double? _realTotalGainPercent;
  // Symboles EXCLUS du calcul ci-dessus faute de PRU connu — cf.
  // [RealTotalGain.noBasisSymbols], destiné à l'avertissement UI (Lot C).
  Set<String> _realNoBasisSymbols = {};

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

  // ---------------------------------------------------------------------------
  // Getters publics
  // ---------------------------------------------------------------------------

  List<PositionWithMarketData> get positionsData => _positionsData;
  String? get globalError => _globalError;
  List<Account> get accounts => _accounts;
  Account? get activeAccount => _activeAccount;
  Wallet? get activeWallet => _activeWallet;
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

  /// Vrai si une courbe mode 2 est disponible pour l'affichage.
  bool get hasRealCurve => _realChartValues.isNotEmpty;

  /// Courbe des apports nets cumulés du compte (B7 Lot 3b), ALIGNÉE
  /// index-par-index sur [chartDates]/[realChartValues]. Vide tant qu'aucun
  /// calcul mode 2 n'a abouti.
  List<double> get realContributionsValues => _realContributionsValues;

  /// Gains sur la période affichée (mode réel), isolés des apports/retraits —
  /// cf. [HistoryAggregator.computeRealGains]. `null` tant qu'aucun calcul
  /// mode 2 n'a abouti, ou fenêtre < 2 points.
  double? get realPeriodGain => _realPeriodGain;
  double? get realPeriodGainPercent => _realPeriodGainPercent;

  /// `true` si [realPeriodGainPercent] est ANNUALISÉ (fenêtre ≥ 2 ans) — cf.
  /// [HistoryAggregator.computeRealGains]/[RealGains.isAnnualized].
  bool get realPeriodGainIsAnnualized => _realPeriodGainIsAnnualized;

  /// Gains TOTAUX en état courant (base coût), INDÉPENDANTS de la période
  /// sélectionnée — cf. [HistoryAggregator.computeRealTotalGain]. `null` tant
  /// qu'aucun calcul mode 2 n'a abouti.
  double? get realTotalGain => _realTotalGain;
  double? get realTotalGainPercent => _realTotalGainPercent;

  /// Symboles EXCLUS du calcul des gains totaux faute de PRU connu — cf.
  /// [HistoryAggregator.computeRealTotalGain].
  Set<String> get realNoBasisSymbols => _realNoBasisSymbols;

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
  Future<void> initAccounts() async {
    _isLoadingAccounts = true;
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

      // Déterminer le wallet actif et le compte actif
      if (initialAccountId != null) {
        // Chercher le compte correspondant
        final targetAccount = allAccounts.firstWhere(
          (a) => a.id == initialAccountId,
          orElse: () => allAccounts.first,
        );
        // Utiliser le wallet du compte trouvé
        _activeWallet = wallets.firstWhere(
          (w) => w.id == targetAccount.walletId,
          orElse: () => wallets.first,
        );
      } else {
        _activeWallet = wallets.first;
      }

      // 3. Charger les comptes du wallet actif
      final accounts = allAccounts
          .where((a) => a.walletId == _activeWallet!.id)
          .toList();

      // 4. Sélectionner le compte actif
      _accounts = accounts;
      if (initialAccountId != null) {
        final found = accounts.firstWhere(
          (a) => a.id == initialAccountId,
          orElse: () => accounts.first,
        );
        _activeAccount = found;
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
    await _loadAccountHistory();
    await _loadDerivedCash();
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
      _isLoadingHistory = false;
      _chartValues = [];
      _chartDates = [];
      _periodChange = null;
      _periodChangePercent = null;
      _realChartValues = [];
      _realCurveApproxSymbols = {};
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

  /// Remet les champs de gains mode réel à `null` (+ [_realNoBasisSymbols]
  /// vidé) — à appeler PARTOUT où [_realChartValues]/[_realContributionsValues]
  /// sont réinitialisés (courbe réelle absente/périmée), pour ne jamais
  /// laisser un gain calculé sur une ancienne courbe affiché à côté d'une
  /// courbe vidée.
  void _resetRealGains() {
    _realPeriodGain = null;
    _realPeriodGainPercent = null;
    _realPeriodGainIsAnnualized = false;
    _realTotalGain = null;
    _realTotalGainPercent = null;
    _realNoBasisSymbols = {};
  }

  /// Calcule le mode 2 « évolution réelle » du COMPTE (B7, design doc 18) :
  /// reconstruction datée depuis le journal du compte actif, PÉRIMÈTRE TITRES
  /// SEULS (cf. commentaire de [_realChartValues] — aucun cash injecté, pour
  /// rester comparable au mode 1 du compte). Énumère TOUS les symboles du
  /// journal (y compris les titres soldés, absents de [currentPositions]),
  /// élargit le fetch d'historique au DELTA manquant, applique le repli
  /// « dernier cours » pour les symboles détenus sans historique.
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

    // Aucun titre JOURNALISÉ (compte 100 % legacy, saisi à la main sans
    // mouvement) : le mode 2 serait une courbe plate à 0 (rien à reconstruire),
    // trompeuse en regard du mode 1 qui, lui, valorise ces positions. On
    // n'expose alors PAS de courbe réelle (`hasRealCurve` reste faux → aucun
    // bascule proposé), plutôt que d'afficher un zéro cassé.
    if (txsBySymbol.isEmpty) {
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
    _realPeriodGainIsAnnualized = periodGains.isAnnualized;

    // Gain TOTAL (état courant, base coût) : calcul INDÉPENDANT des courbes
    // ci-dessus — positions DU COMPTE (legacy incluses si leur PRU est
    // connu), affiché quelle que soit la période sélectionnée.
    // Cash DÉRIVÉ du compte (devise de règlement du compte → EUR) : fait
    // partie de la valeur détenue, donc du capital investi. L'omettre
    // surévaluerait le `%` (cf. computeRealTotalGain).
    final derivedCashEur = (double.tryParse(_derivedCash ?? '0') ?? 0.0) *
        (_activeAccount!.currency.toUpperCase() == 'USD' ? _usdToEurRate : 1.0);

    final totalGain = HistoryAggregator.computeRealTotalGain(
      positions: currentPositions,
      txsBySymbol: txsBySymbol,
      txsByAccount: {_activeAccount!.id: txs},
      usdToEurRate: _usdToEurRate,
      cashEur: derivedCashEur,
    );
    _realTotalGain = totalGain.totalGain;
    _realTotalGainPercent = totalGain.totalGainPercent;
    _realNoBasisSymbols = totalGain.noBasisSymbols;
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
  ///   - 'noActiveAccount' : pas de compte actif
  ///   - 'invalidQuantity' : quantité nulle ou non parsable
  ///   - 'assetNotFound'   : le symbole est introuvable sur le marché
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
  ///   - 'noActiveAccount' : pas de compte actif
  ///   - 'invalidQuantity' : quantité nulle ou non parsable
  ///   - 'assetNotFound'   : le cours de référence est introuvable
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
  // Analogues cash de emitOpeningBalance/emitAdjustment (positions) : le cash
  // dérivé d'un compte titres est en LECTURE SEULE (corollaire D1/PRU) — toute
  // correction passe par un acte de journal nommé, jamais une édition directe
  // (cf. cash_balance_edit_dialog.dart, réservé aux comptes kind=cash).
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
    for (final m in nonDuplicates) {
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

    for (final m in nonDuplicates) {
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
      rejects: rejects,
      newAssets: newAssets,
      projectedDeltas: projectedDeltas,
      legacySymbols: legacySymbols,
    );
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
  Future<String?> confirmStatementImport(
    ImportPreview preview, {
    required String accountId,
  }) async {
    if (_activeAccount == null) return 'noActiveAccount';

    final movements = preview.toCreate
        .where((m) => !m.isRejected)
        .map((m) => m.transaction!)
        .toList();

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

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
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
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
       _marketService = marketService ?? MarketDataService(),
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
  double get usdToEurRate => _usdToEurRate;
  Map<String, double> get assetValues => _assetValues;
  bool get hasMultipleAssets => _hasMultipleAssets;
  String? get derivedCash => _derivedCash;
  bool get hasCashAnchor => _hasCashAnchor;
  int get foreignCashMovementCount => _foreignCashMovementCount;

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
  /// Réimplémente la logique de [AssetService.fetchAllPrices] en utilisant
  /// les services injectés (_storage, _marketService), ce qui permet de les
  /// remplacer par des fakes en test.
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
    final results = await Future.wait(
      positions.map((position) async {
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
      }).toList(),
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

      final futures = currentPositions.map((positionData) async {
        return await _marketService.getHistoricalDataForAsset(
          positionData.asset,
          days: _selectedPeriod.days,
        );
      }).toList();

      final results = await Future.wait(futures);

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
      _isLoadingHistory = false;
      _safeNotify();
    } catch (e) {
      AppLogger.error('Erreur chargement historique: $e');
      _historyError = e.toString();
      _isLoadingHistory = false;
      _safeNotify();
    }
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

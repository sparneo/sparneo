// lib/controllers/wallet_controller.dart
import 'package:decimal/decimal.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:portfolio_tracker/logic/history_aggregator.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/logic/snapshot_capture.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/logic/allocation.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/allocation_target_storage.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/snapshot_storage.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/utils/logger.dart';

/// Contrôleur de la vue patrimoine (WalletView).
///
/// Toute la logique d'I/O et d'état est centralisée ici ; la vue se contente
/// d'écouter via [ListenableBuilder] et de déléguer les interactions.
///
/// Services injectés par constructeur pour permettre des fakes en tests.
class WalletController extends ChangeNotifier {
  final AccountStorage _storage;
  final MarketDataService _marketService;
  final ExchangeRateService _exchangeService;
  final SnapshotStorage _snapshotStorage;
  final AllocationTargetStorage _allocationTargetStorage;
  /// Lecture du journal (lot cash-ledger) : sert UNIQUEMENT à décider l'opt-in
  /// d'agrégation du cash dérivé des comptes titres (cf. [journalHasCashAnchor]
  /// dans [loadAllData]) — aucune écriture ici.
  final TransactionStorage _txStorage;

  /// Nom du wallet par défaut (fourni par la vue qui a accès au contexte).
  final String defaultWalletName;

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

  WalletController({
    AccountStorage? storage,
    MarketDataService? marketService,
    ExchangeRateService? exchangeService,
    SnapshotStorage? snapshotStorage,
    AllocationTargetStorage? allocationTargetStorage,
    TransactionStorage? transactionStorage,
    this.defaultWalletName = 'Mon Patrimoine',
  }) : _storage = storage ?? AccountStorage(),
       _marketService = marketService ?? MarketDataService(),
       _exchangeService = exchangeService ?? ExchangeRateService(),
       _snapshotStorage = snapshotStorage ?? SnapshotStorage(),
       _allocationTargetStorage =
           allocationTargetStorage ?? AllocationTargetStorage(),
       _txStorage = transactionStorage ?? TransactionStorage();

  // ---------------------------------------------------------------------------
  // État exposé via getters
  // ---------------------------------------------------------------------------

  List<Wallet> _wallets = [];
  Wallet? _activeWallet;
  List<Account> _accounts = [];
  Map<String, double> _accountValues = {}; // accountId → totalValueEur
  List<PositionWithMarketData> _allPositionsData = [];
  // accountId → solde de liquidités EUR. Peuplé par DEUX sources DISJOINTES
  // (partition stricte par account.type, jamais les deux pour le même compte
  // — cf. loadAllData) :
  //   - comptes kind=cash : cashBalance manuel (modèle inchangé) ;
  //   - comptes titres (lot cash-ledger) : cash DÉRIVÉ du journal
  //     (getAccountDerivedCash), UNIQUEMENT si le journal contient un ancrage
  //     espèces (journalHasCashAnchor) — opt-in, sinon un journal composé
  //     seulement de buy/sell donnerait un solde négatif et FAUX (design §3/§6.7).
  final Map<String, double> _cashBalances = {};

  /// Comptes masqués de la liste affichée en attente de confirmation de
  /// suppression (motif « suppression différée + Annuler »). Tant qu'un id y
  /// figure, le compte est retiré de [_accounts] ET filtré à la source de chaque
  /// [loadAllData] — mais NON supprimé du stockage. Analogue de [_hiddenPositions]
  /// dans account_controller : un Set d'ids suffit ici car la vue conserve
  /// l'objet [Account] complet et le repasse à [restoreAccount] /
  /// [commitDeleteAccount]. `restoreAccount` et `commitDeleteAccount` le purgent.
  final Set<String> _hiddenAccountIds = {};

  /// Wallets masqués de la liste affichée en attente de confirmation de
  /// suppression. MÊME motif que [_hiddenAccountIds] (cf. commentaire
  /// ci-dessus) : un id y figure tant que la suppression n'est ni validée ni
  /// annulée, et [loadAllData] filtre la liste brute du stockage à la source
  /// pour qu'un reload pendant la fenêtre d'annulation ne le ressuscite pas.
  final Set<String> _hiddenWalletIds = {};

  /// Id du wallet qui était ACTIF au moment où [hideWallet] l'a masqué, et dont
  /// [hideWallet] a donc déplacé la sélection ([_activeWallet]) vers un autre
  /// wallet visible (correctif M-1 : fermeture immédiate de la fenêtre
  /// d'écriture sous un wallet en cours de suppression). Sert à [restoreWallet]
  /// pour la bascule INVERSE (rendre l'utilisateur au wallet qu'il regardait
  /// s'il annule) et à [commitDeleteWallet] pour purger la marque quand la
  /// suppression devient définitive. `null` quand aucune suppression différée
  /// n'a déplacé l'actif.
  ///
  /// Réduit volontairement à UN seul id : le flux réel n'enchaîne qu'une
  /// suppression annulable à la fois (une seule fenêtre snackbar ouverte). En
  /// cas de masquages imbriqués (rare — plusieurs suppressions différées se
  /// chevauchant), seul le DERNIER actif déplacé est rebasculé à l'annulation ;
  /// jamais de perte de données, au pire l'actif restauré n'est pas
  /// re-sélectionné (dégradation cosmétique, l'actif reste un wallet valide).
  String? _displacedActiveWalletId;

  double _usdToEurRate = 0.92;
  bool _isLoading = true;
  // Rechargement NON destructif : vrai pendant un rechargement alors que du
  // contenu est déjà à l'écran. Distinct de [_isLoading] (spinner plein écran,
  // réservé au tout premier chargement, cf. loadAllData).
  bool _isRefreshing = false;
  String? _error;

  // Graphique global
  ChartPeriod _selectedPeriod = ChartPeriod.month1;
  bool _isLoadingHistory = false;
  List<DateTime> _chartDates = [];
  List<double> _chartValues = [];
  double? _periodChange;
  double? _periodChangePercent;

  // Variations par compte
  Map<String, double> _accountPeriodChanges = {};
  Map<String, double> _accountPeriodChangePercents = {};

  // Série secondaire : snapshots de valorisation réels
  // Liste vide = série absente (< 2 points dans la période)
  List<FlSpot> _snapshotSpots = [];

  // Cibles d'allocation et écarts calculés pour le wallet actif
  AllocationTarget _allocationTarget = const AllocationTarget.empty();
  List<AllocationGap> _allocationGaps = [];
  // Allocation réelle par type d'actif (cash inclus comme catégorie
  // synthétique, type == null) : alimente le camembert « par type d'actif » et
  // la map currentAllocationPercents passée au dialogue d'édition des cibles.
  List<AssetTypeAllocation> _assetTypeAllocations = [];

  // --- Getters publics ---

  List<Wallet> get wallets => _wallets;
  Wallet? get activeWallet => _activeWallet;
  List<Account> get accounts => _accounts;
  Map<String, double> get accountValues => _accountValues;

  /// Total du patrimoine = somme des valeurs des comptes VISIBLES uniquement.
  /// Dérivé de [_accounts] (déjà filtré des comptes masqués) plutôt que de
  /// `_accountValues.values` brut : pendant la fenêtre d'annulation d'une
  /// suppression, un compte masqué peut subsister dans [_accountValues] (issu du
  /// dernier reload) ; l'ignorer ici garantit total == somme des comptes
  /// affichés == base du camembert (tous dérivés de [_accounts]).
  double get totalPatrimoine =>
      _accounts.fold(0.0, (sum, a) => sum + (_accountValues[a.id] ?? 0.0));
  List<PositionWithMarketData> get allPositionsData => _allPositionsData;
  Map<String, double> get cashBalances => _cashBalances;
  double get usdToEurRate => _usdToEurRate;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  String? get error => _error;

  ChartPeriod get selectedPeriod => _selectedPeriod;
  bool get isLoadingHistory => _isLoadingHistory;
  List<DateTime> get chartDates => _chartDates;
  List<double> get chartValues => _chartValues;
  double? get periodChange => _periodChange;
  double? get periodChangePercent => _periodChangePercent;

  Map<String, double> get accountPeriodChanges => _accountPeriodChanges;
  Map<String, double> get accountPeriodChangePercents =>
      _accountPeriodChangePercents;

  List<FlSpot> get snapshotSpots => _snapshotSpots;

  AllocationTarget get allocationTarget => _allocationTarget;
  List<AllocationGap> get allocationGaps => _allocationGaps;

  /// Allocation réelle par type d'actif, cash inclus (catégorie synthétique
  /// `type == null`). Ordre décroissant de valeur. Alimente le camembert
  /// « par type d'actif ».
  List<AssetTypeAllocation> get assetTypeAllocations => _assetTypeAllocations;

  /// Pourcentages réels par catégorie, keyés comme les cibles
  /// (`AssetType.name` + [kCashAllocationKey]). Passé au dialogue d'édition
  /// pour afficher « actuel : Y % » en regard de chaque cible, cash compris.
  Map<String, double> get currentAllocationPercents => {
    for (final a in _assetTypeAllocations)
      (a.type?.name ?? kCashAllocationKey): a.percent,
  };

  // ---------------------------------------------------------------------------
  // Chargement principal
  // ---------------------------------------------------------------------------

  Future<void> loadAllData() async {
    // Rafraîchissement non destructif : le spinner PLEIN ÉCRAN (_isLoading)
    // n'est armé qu'au tout premier chargement, quand il n'y a encore aucune
    // donnée à préserver (_accounts vide). Tout rechargement ultérieur
    // (contenu déjà affiché) passe par _isRefreshing en GARDANT _isLoading à
    // false, pour ne pas vider la vue à chaque refresh.
    final bool firstLoad = _accounts.isEmpty;
    if (firstLoad) {
      _isLoading = true;
    } else {
      _isRefreshing = true;
    }
    _error = null;
    _safeNotify();

    try {
      // 1. Charger le taux de change en premier
      final rate = await _exchangeService.getUsdToEurRate();

      // Charger les wallets. Le fallback « aucun wallet → défaut » et le choix
      // de l'actif ci-dessous doivent opérer sur des ids RÉELLEMENT créables/
      // sélectionnables : on filtre donc les wallets masqués (suppression
      // différée en attente, cf. hideWallet) juste après le chargement brut,
      // avant tout usage de la liste — même schéma que le filtrage des comptes
      // plus bas (l.244-249).
      var rawWallets = await _storage.getAllWallets();

      // Création d'un wallet par défaut si aucun n'existe (aucun wallet visible
      // NI masqué : un wallet masqué en attente d'annulation ne doit pas
      // déclencher la création d'un nouveau wallet par défaut).
      if (rawWallets.isEmpty) {
        final defaultWallet = Wallet(
          id: Wallet.generateId(),
          name: defaultWalletName,
        );
        await _storage.saveWallet(defaultWallet);
        rawWallets = [defaultWallet];
      }

      final filteredWallets = _hiddenWalletIds.isEmpty
          ? rawWallets
          : rawWallets.where((w) => !_hiddenWalletIds.contains(w.id)).toList();
      // Si TOUS les wallets bruts sont masqués (fenêtre d'annulation en cours
      // sur le dernier wallet visible — normalement empêché par la garde de
      // hideWallet, mais on reste défensif), retombe sur la liste brute pour
      // ne jamais présenter un patrimoine vide sans wallet actif valide.
      final wallets = filteredWallets.isEmpty ? rawWallets : filteredWallets;

      if (_activeWallet != null) {
        // Chercher le wallet actif dans la nouvelle liste pour obtenir ses données à jour
        _activeWallet = wallets.firstWhere(
          (w) => w.id == _activeWallet!.id,
          orElse: () => wallets.first,
        );
      } else {
        // Si aucun wallet n'était sélectionné, prendre le premier
        _activeWallet = wallets.first;
      }

      // 2. Charger les comptes du wallet actif.
      // Écarte les comptes masqués (suppression différée en attente) À LA SOURCE,
      // comme le motif positions (_fetchAllPrices filtre _hiddenPositions). Ainsi
      // TOUS les agrégats en aval (valeurs par compte, total, camembert,
      // historique, cibles d'allocation, snapshot) les excluent de façon
      // cohérente, et un reload pendant la fenêtre d'annulation ne les ressuscite
      // pas (défauts 1 & 2). L'invariant devient :
      //   _accounts == (comptes du stockage du wallet actif) − _hiddenAccountIds
      final allAccounts = await _storage.getAccountsByWallet(_activeWallet!.id);
      final accounts = _hiddenAccountIds.isEmpty
          ? allAccounts
          : allAccounts
                .where((a) => !_hiddenAccountIds.contains(a.id))
                .toList();

      // 3. Charger toutes les positions et calculer les valeurs
      _cashBalances.clear();
      List<PositionWithMarketData> allPositions = [];
      Map<String, double> accountValues = {};
      Map<String, List<PositionWithMarketData>> accountPositions = {};

      // ⭐ Étape A : charger les positions de tous les comptes investissement
      // et collecter l'ensemble des symboles UNIQUES. Les comptes cash sont
      // traités à part (valeur directe, pas de cotation).
      final Map<String, List<Position>> rawPositionsByAccount = {};
      final Set<String> uniqueSymbols = {};

      // ⭐ Comptes CASH (+ cash dérivé des comptes titres, lot cash-ledger) :
      // récupérer EN PARALLÈLE les taux des devises uniques utilisées par
      // TOUS les comptes ayant un solde de liquidités à convertir, puis
      // appliquer la conversion. Un seul lot de requêtes de taux pour les
      // deux familles de comptes (jamais le même compte dans les deux listes
      // — partition stricte par account.type).
      final cashAccounts = accounts
          .where((a) => a.type == AccountType.cash)
          .toList();
      final nonCashAccounts = accounts
          .where((a) => a.type != AccountType.cash)
          .toList();
      final uniqueCashCurrencies = {
        ...cashAccounts.map((a) => a.currency.toUpperCase()),
        ...nonCashAccounts.map((a) => a.currency.toUpperCase()),
      }.toList();
      final cashRatesList = await Future.wait(
        uniqueCashCurrencies.map((c) => _exchangeService.getRateToEur(c)),
      );
      final Map<String, double> cashRateByCurrency = {};
      for (int i = 0; i < uniqueCashCurrencies.length; i++) {
        cashRateByCurrency[uniqueCashCurrencies[i]] = cashRatesList[i];
      }

      // ⭐ CASH DÉRIVÉ DES COMPTES TITRES (lot cash-ledger — risque §6.7, double
      // comptage). Calculé ICI, EN PARALLÈLE (comme les cotations ci-dessous),
      // pour l'injecter plus loin dans `accountValues`/`_cashBalances` SANS
      // await dans la boucle de construction (invariant de l'Étape C).
      //
      // Opt-in (journalHasCashAnchor) : un journal composé uniquement de
      // buy/sell donnerait un solde dérivé négatif et FAUX (aucun dépôt/retrait/
      // intérêt/frais/solde initial espèces jamais enregistré) — on ne
      // l'agrège que si le journal atteste au moins un mouvement d'ancrage
      // espèces. Même garde que l'affichage opt-in du solde sur la page compte
      // (cf. position_projection.dart). `derived.cash == null` = compte jamais
      // projeté (aucun mouvement du tout) → rien à agréger non plus.
      final derivedCashResults = await Future.wait(
        nonCashAccounts.map((a) => _storage.getAccountDerivedCash(a.id)),
      );
      final nonCashTxsResults = await Future.wait(
        nonCashAccounts.map((a) => _txStorage.getByAccount(a.id)),
      );
      final Map<String, double> derivedCashEurByAccount = {};
      for (int i = 0; i < nonCashAccounts.length; i++) {
        final acc = nonCashAccounts[i];
        final derived = derivedCashResults[i];
        if (derived.cash == null) continue;
        if (!journalHasCashAnchor(nonCashTxsResults[i])) continue;
        final raw = Decimal.tryParse(derived.cash!)?.toDouble() ?? 0.0;
        final rate = cashRateByCurrency[acc.currency.toUpperCase()] ?? 1.0;
        derivedCashEurByAccount[acc.id] = raw * rate;
      }

      for (var account in accounts) {
        if (account.type == AccountType.cash) {
          final rawBalance = account.cashBalance ?? 0.0;
          final cashRate =
              cashRateByCurrency[account.currency.toUpperCase()] ?? 1.0;
          // _cashBalances et accountValues sont stockés EN EUR pour rester
          // cohérents avec le reste de l'agrégation du patrimoine.
          final balanceEur = rawBalance * cashRate;
          accountValues[account.id] = balanceEur;
          _cashBalances[account.id] = balanceEur;
          accountPositions[account.id] = []; // Pas de positions pour cash
          continue;
        }

        final positions = await _storage.getPositions(account.id);
        rawPositionsByAccount[account.id] = positions;
        for (final pos in positions) {
          uniqueSymbols.add(pos.symbol);
        }
      }

      // ⭐ Étape B : récupérer toutes les cotations EN PARALLÈLE et UNE SEULE
      // FOIS par symbole unique.
      final assetBySymbol = <String, Asset>{};
      for (final positions in rawPositionsByAccount.values) {
        for (final pos in positions) {
          assetBySymbol[pos.symbol] = pos.asset;
        }
      }
      final symbolsList = uniqueSymbols.toList();
      final quoteResults = await Future.wait(
        symbolsList.map(
          (s) => _marketService.getQuoteForAsset(assetBySymbol[s]!),
        ),
      );
      final Map<String, AssetQuoteData?> quotesBySymbol = {};
      for (int i = 0; i < symbolsList.length; i++) {
        quotesBySymbol[symbolsList[i]] = quoteResults[i];
      }

      // ⭐ Étape C : construire les valeurs des comptes/positions en lisant la
      // map de cotations (plus aucun await dans ces boucles de calcul).
      // Flag de complétude : passe à false dès qu'une cotation est manquante.
      // Les comptes cash sont sautés (continue) — un wallet 100 % cash
      // reste marketDataComplete = true.
      bool marketDataComplete = true;
      for (var account in accounts) {
        if (account.type == AccountType.cash) continue;

        final positions = rawPositionsByAccount[account.id] ?? [];
        double accountTotal = 0;
        List<PositionWithMarketData> accountPosList = [];

        for (var pos in positions) {
          final quote = quotesBySymbol[pos.symbol];
          // Données de marché incomplètes : prix manquant → valeur sous-évaluée.
          if (quote == null || quote.price == null) marketDataComplete = false;
          // Garde-fou snapshot (LOT 2) : un prix servi depuis le cache
          // « dernier cours connu » (asOf non-null) est affiché à l'écran
          // (dégradation douce) mais ne doit PAS fonder un snapshot journalier
          // — on préserve l'intégrité de l'historique en ne persistant que
          // des prix réellement à jour.
          if (quote != null && quote.asOf != null) marketDataComplete = false;
          double price = quote?.price?.toDouble() ?? 0;
          double qty = double.tryParse(pos.quantity) ?? 0;
          double value = price * qty;

          if (pos.asset.currency.toUpperCase() == 'USD') {
            value = value * rate;
          }
          accountTotal += value;

          final posWithData = PositionWithMarketData(
            position: pos,
            currentPrice: price,
            currency: quote?.currency,
            // asOf non-null = quote servie depuis le cache LOT 2 : afficher
            // la date réelle de cette cotation plutôt que l'instant présent.
            lastUpdated: quote?.asOf ?? DateTime.now(),
          );

          allPositions.add(posWithData);
          accountPosList.add(posWithData);
        }

        // Cash dérivé opt-in (lot cash-ledger, précalculé plus haut EN
        // PARALLÈLE — aucun await ici) : ajouté au total DU COMPTE (le cash
        // parqué sur un compte titres fait partie du patrimoine, au même
        // titre qu'une position) ET à `_cashBalances`, jamais les deux
        // familles pour le même compte (cf. garde ci-dessus, `continue` sur
        // kind=cash) → double comptage impossible par construction.
        final derivedCashEur = derivedCashEurByAccount[account.id];
        if (derivedCashEur != null) {
          accountTotal += derivedCashEur;
          _cashBalances[account.id] = derivedCashEur;
        }

        accountValues[account.id] = accountTotal;
        accountPositions[account.id] = accountPosList;
      }

      _usdToEurRate = rate;
      _wallets = wallets;
      _accounts = accounts;
      _accountValues = accountValues;
      _allPositionsData = allPositions;
      _isLoading = false;
      _isRefreshing = false;

      // Charger les cibles d'allocation et recalculer les écarts
      await _loadAllocationTarget(accountValues, allPositions, rate);

      _safeNotify();

      // Capturer l'id du wallet AVANT l'await suivant (correctif I2) :
      // si l'utilisateur change de wallet pendant _loadHistory, on ne persistera
      // pas le total du wallet précédent sous l'id du nouveau.
      final capturingWalletId = _activeWallet?.id;

      // Charger l'historique UNE SEULE FOIS : alimente le graphique global
      // ET les variations par compte via une map partagée.
      await _loadHistory(accountPositions);

      // Capturer le snapshot du jour (best-effort, non bloquant).
      // On vérifie que le wallet actif n'a pas changé depuis la capture de
      // capturingWalletId ; sinon on abandonne silencieusement (correctif I2).
      // Pas de await : l'échec éventuel ne doit jamais bloquer l'affichage.
      if (_activeWallet?.id == capturingWalletId) {
        _maybeCaptureSnapshot(
          accountValues,
          marketDataComplete,
          capturingWalletId,
        );
      }
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      _isRefreshing = false;
      _safeNotify();
    }
  }

  // ---------------------------------------------------------------------------
  // Sélection de wallet
  // ---------------------------------------------------------------------------

  Future<void> selectWallet(Wallet wallet) async {
    if (_activeWallet?.id == wallet.id) return;

    _activeWallet = wallet;
    _isLoading = true;
    _safeNotify();

    await loadAllData();
  }

  // ---------------------------------------------------------------------------
  // CRUD wallet (motif « account switcher » — sélecteur de patrimoine)
  // ---------------------------------------------------------------------------
  //
  // Tout le CRUD wallet passe désormais par le contrôleur (auparavant éclaté
  // entre ManageWalletsPage et un accès direct à AccountStorage) : la page de
  // gestion et la bottom sheet du sélecteur en deviennent de simples
  // `ListenableBuilder`, sans état ni I/O propres, ce qui élimine toute
  // course entre les deux surfaces (p. ex. renommage dans l'une pendant
  // qu'une suppression différée est en attente dans l'autre).

  /// Crée un nouveau wallet et recharge la liste. Ne le sélectionne PAS
  /// automatiquement : c'est à l'appelant d'enchaîner [selectWallet] avec le
  /// wallet retourné (la bottom sheet ferme d'abord, puis bascule).
  Future<Wallet> createWallet(String name) async {
    final newWallet = Wallet(id: Wallet.generateId(), name: name.trim());
    await _storage.saveWallet(newWallet);
    await loadAllData();
    return newWallet;
  }

  /// Renomme un wallet. Patch EN MÉMOIRE de [_wallets]/[_activeWallet]
  /// (réassignation, pas de mutation en place — même style que
  /// [hideAccount]/[restoreAccount]) : un renommage ne change aucune
  /// valorisation, donc pas de [loadAllData] (coûteux : cotations, historique,
  /// snapshot) pour une simple étiquette.
  Future<void> renameWallet(Wallet wallet, String newName) async {
    final renamed = Wallet(
      id: wallet.id,
      name: newName.trim(),
      createdAt: wallet.createdAt,
    );
    await _storage.saveWallet(renamed);
    // Garde symétrique des autres primitives (hideWallet retourne null si
    // introuvable) : un id absent de la liste visible donnerait index == -1 et
    // `list[-1] =` lèverait un RangeError. Inatteignable via l'UI (le renommage
    // part toujours d'un wallet affiché), mais on ne suppose pas l'invariant.
    final index = _wallets.indexWhere((w) => w.id == wallet.id);
    if (index >= 0) {
      _wallets = List<Wallet>.from(_wallets)..[index] = renamed;
    }
    if (_activeWallet?.id == wallet.id) {
      _activeWallet = renamed;
    }
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // Suppression différée d'un wallet (motif « supprimé + Annuler »)
  // ---------------------------------------------------------------------------
  //
  // Trois primitives, MIROIR EXACT de hideAccount/restoreAccount/
  // commitDeleteAccount ci-dessous (mêmes garanties d'idempotence et de
  // cohérence — cf. commentaire détaillé sur le motif compte) :
  //   1. hideWallet         — masque le wallet de la liste EN MÉMOIRE.
  //   2. restoreWallet      — le restaure si l'utilisateur annule.
  //   3. commitDeleteWallet — valide la suppression réelle (stockage) + reload.

  /// Retire le wallet [id] de la liste AFFICHÉE, sans toucher au stockage.
  /// Retourne le wallet retiré (ou null s'il est introuvable). Refuse de
  /// masquer le DERNIER wallet visible (cadenas — un patrimoine sans aucun
  /// wallet n'a pas de sens, contrairement à un compte dont le wallet peut
  /// rester vide).
  Wallet? hideWallet(String id) {
    if (_wallets.length <= 1) return null;
    final index = _wallets.indexWhere((w) => w.id == id);
    if (index < 0) return null;
    final wallet = _wallets[index];
    _hiddenWalletIds.add(id);
    final remaining = List<Wallet>.from(_wallets)..removeAt(index);
    _wallets = remaining;

    // Correctif M-1 (perte silencieuse de données). Si le wallet masqué est
    // l'ACTIF, on rebascule IMMÉDIATEMENT la sélection sur un autre wallet
    // visible. Sans cela, _activeWallet resterait le wallet en cours de
    // suppression pendant TOUTE la fenêtre d'annulation (~4 s) : un
    // createAccount (qui écrit sous `_activeWallet!.id`) le viserait, puis
    // commitDeleteWallet → _storage.deleteWallet cascade (ON DELETE CASCADE)
    // et DÉTRUIRAIT aussi les données saisies dans la fenêtre. La bascule est
    // SYNCHRONE (réassignation de _activeWallet) — c'est ELLE qui ferme la
    // fenêtre d'écriture, avant même tout rechargement. Le cadenas « dernier
    // wallet » ci-dessus (length <= 1) garantit qu'il reste toujours au moins
    // une cible : `remaining` est non vide. Corrige aussi la gêne visuelle
    // signalée (l'AppBar de WalletView bascule aussitôt sur le wallet restant).
    if (_activeWallet?.id == id) {
      _displacedActiveWalletId = id;
      _activeWallet = remaining.first;
      _safeNotify();
      // Recharge comptes/valeurs du nouvel actif. NON awaité : hideWallet reste
      // synchrone pour ses appelants (retour immédiat du wallet masqué à la vue
      // pour armer le snackbar undo). Rechargement NON destructif — _accounts
      // n'est pas vidé, seul _isRefreshing s'arme (cf. loadAllData) —, la vue
      // se réaligne via notifyListeners à la fin du reload. Nécessaire car
      // sinon _accounts garderait les comptes de l'ancien actif sous le nom du
      // nouveau (WalletView ne recharge pas au retour de ManageWalletsPage).
      loadAllData();
      return wallet;
    }

    _safeNotify();
    return wallet;
  }

  /// Restaure un wallet précédemment masqué par [hideWallet]. Idempotent :
  /// sans effet si le wallet est déjà présent (p. ex. après un reload).
  void restoreWallet(Wallet wallet) {
    // Purge du filtre EN PREMIER (cf. restoreAccount) : lève le masquage même
    // si le wallet est déjà présent, pour qu'un reload ultérieur ne le
    // refiltre pas.
    _hiddenWalletIds.remove(wallet.id);

    // Bascule INVERSE symétrique de hideWallet (correctif M-1). Si ce wallet
    // était l'actif DÉPLACÉ par sa mise en attente de suppression, l'annulation
    // doit rendre l'utilisateur à l'état qu'il percevait : il regardait ce
    // wallet quand il a déclenché la suppression. On restaure donc l'actif
    // AVANT le reload de ses comptes. Conditionné à l'égalité d'id : masquer un
    // wallet NON actif (possible via ManageWalletsPage sur n'importe quelle
    // ligne) n'a pas déplacé l'actif → l'annulation ne doit alors PAS le
    // changer.
    final bool restoreDisplacedActive = _displacedActiveWalletId == wallet.id;
    if (restoreDisplacedActive) {
      _displacedActiveWalletId = null;
      _activeWallet = wallet;
    }

    if (!_wallets.any((w) => w.id == wallet.id)) {
      _wallets = List<Wallet>.from(_wallets)..add(wallet);
    }
    _safeNotify();

    // Recharge les comptes du wallet redevenu actif (fire-and-forget, non
    // destructif) : après la bascule de hideWallet, _accounts contenait ceux du
    // wallet vers lequel on avait basculé, pas ceux de ce wallet restauré.
    if (restoreDisplacedActive) {
      loadAllData();
    }
  }

  /// Valide la suppression réelle (stockage) d'un wallet masqué puis
  /// recharge. Le fallback « wallet actif supprimé → bascule sur le premier
  /// restant » est déjà géré par [loadAllData] (choix de l'actif après
  /// filtrage) : rien à recoder ici.
  Future<void> commitDeleteWallet(Wallet wallet) async {
    // Garde-fou d'idempotence (calqué sur commitDeleteAccount) : sans effet si
    // le wallet n'est plus masqué (déjà validé, ou restauré via « Annuler »).
    if (!_hiddenWalletIds.contains(wallet.id)) return;
    await _storage.deleteWallet(wallet.id);
    // Ne lève le masquage qu'APRÈS le succès du stockage : en cas d'échec,
    // l'id reste dans le filtre (cohérent avec « non encore supprimé »).
    _hiddenWalletIds.remove(wallet.id);
    // Suppression définitive : purge l'éventuelle marque de bascule inverse
    // (correctif M-1). Le wallet déplacé n'existe plus, aucune restauration
    // n'est désormais possible ; sans cette purge, un id périmé traînerait dans
    // _displacedActiveWalletId. L'actif a déjà été rebasculé au hideWallet, le
    // fallback « actif introuvable → premier restant » de loadAllData reste
    // donc inerte ici (pas de double-bascule).
    if (_displacedActiveWalletId == wallet.id) {
      _displacedActiveWalletId = null;
    }
    await loadAllData();
  }

  // ---------------------------------------------------------------------------
  // Changement de période
  // ---------------------------------------------------------------------------

  void onPeriodChanged(ChartPeriod period) {
    if (_selectedPeriod == period) return;
    _selectedPeriod = period;
    _safeNotify();

    // Reconstruire la map comptes → positions puis ne fetcher l'historique
    // QU'UNE SEULE FOIS (graphique global + variations par compte).
    final Map<String, List<PositionWithMarketData>> accountPositions = {};
    for (var pos in _allPositionsData) {
      final accId = pos.accountId;
      accountPositions.putIfAbsent(accId, () => []);
      accountPositions[accId]!.add(pos);
    }
    _loadHistory(accountPositions);
  }

  // ---------------------------------------------------------------------------
  // Actions données / I-O
  // ---------------------------------------------------------------------------

  /// Supprime un compte et recharge les données.
  /// Retourne false si c'est le dernier compte (suppression impossible).
  Future<bool> deleteAccount(String accountId) async {
    if (_accounts.length <= 1) return false;
    await _storage.deleteAccount(accountId);
    await loadAllData();
    return true;
  }

  // ---------------------------------------------------------------------------
  // Suppression différée d'un compte (motif « supprimé + Annuler »)
  // ---------------------------------------------------------------------------
  //
  // Trois primitives destinées à la vue pour offrir une fenêtre d'annulation
  // SANS toucher au stockage tant que la suppression n'est pas validée :
  //   1. hideAccount     — masque le compte de la liste EN MÉMOIRE (aucune I/O).
  //   2. restoreAccount  — le restaure si l'utilisateur annule.
  //   3. commitDeleteAccount — valide la suppression réelle (stockage) + reload.
  //
  // Pendant la fenêtre d'annulation, hideAccount ne modifie que _accounts (retrait
  // de la liste) + _hiddenAccountIds (marque de filtrage) ; les cartes de valeurs
  // par compte (_accountValues), les positions et l'historique NE sont PAS
  // recalculés en place — exactement comme le motif positions ne rafraîchit pas
  // l'historique sur hidePosition. Ce qui garantit la cohérence immédiate du
  // TOTAL et du CAMEMBERT, c'est qu'ils sont DÉRIVÉS de _accounts (cf.
  // totalPatrimoine et _buildAllocationChart), donc un compte retiré de _accounts
  // en sort aussitôt. Les agrégats plus lourds (historique global, cibles
  // d'allocation, snapshot) ne se réalignent qu'au reload suivant, qui filtre les
  // comptes masqués À LA SOURCE (loadAllData) — un reload pendant la fenêtre ne
  // ressuscite donc plus le compte. La vue trie la liste par valeur : la position
  // d'insertion à la restauration est sans effet, d'où un simple ajout en fin.

  /// Retire le compte [accountId] de la liste AFFICHÉE, sans toucher au
  /// stockage. Retourne le compte retiré (ou null s'il est introuvable / déjà
  /// masqué), que la vue conservera pour un [restoreAccount] / [commitDeleteAccount].
  Account? hideAccount(String accountId) {
    final index = _accounts.indexWhere((a) => a.id == accountId);
    if (index < 0) return null;
    final account = _accounts[index];
    // Marque le compte comme masqué : le retire de la liste affichée ET le
    // filtre des rechargements ultérieurs (loadAllData) tant qu'il n'est ni
    // restauré ni supprimé. Le retrait de _accounts suffit à écarter sa
    // contribution du total ([totalPatrimoine]) et du camembert (tous deux
    // dérivés de _accounts) dès maintenant, sans attendre un reload.
    _hiddenAccountIds.add(accountId);
    _accounts = List<Account>.from(_accounts)..removeAt(index);
    _safeNotify();
    return account;
  }

  /// Restaure un compte précédemment masqué par [hideAccount]. Idempotent :
  /// sans effet si le compte est déjà présent (p. ex. après un reload).
  void restoreAccount(Account account) {
    // Purge du filtre EN PREMIER : même si le compte est déjà présent dans
    // _accounts (idempotence), il faut lever le masquage pour qu'un reload
    // ultérieur ne le refiltre pas.
    _hiddenAccountIds.remove(account.id);
    if (_accounts.any((a) => a.id == account.id)) return;
    _accounts = List<Account>.from(_accounts)..add(account);
    _safeNotify();
  }

  /// Valide la suppression réelle (stockage) d'un compte masqué puis recharge.
  /// Réutilise la suppression stockage existante ; le compte visé est passé
  /// explicitement (capturé par la vue) pour rester correct même si plusieurs
  /// suppressions se chevauchent.
  Future<void> commitDeleteAccount(Account account) async {
    // Garde-fou d'idempotence (calqué sur commitDeletePosition) : sans effet si
    // le compte n'est plus masqué (déjà validé, ou restauré via « Annuler »).
    // Protège d'une double suppression et d'une suppression après restauration.
    if (!_hiddenAccountIds.contains(account.id)) return;
    await _storage.deleteAccount(account.id);
    // Ne lève le masquage qu'APRÈS le succès du stockage : en cas d'échec, l'id
    // reste dans le filtre (le compte reste masqué, cohérent avec « non encore
    // supprimé du stockage ») et l'exception remonte à l'appelant.
    _hiddenAccountIds.remove(account.id);
    await loadAllData();
  }

  /// Crée un nouveau compte et recharge les données.
  ///
  /// [kind] est l'axe unique (nature du compte) : il porte la valorisation
  /// (dérivée) et la fiscalité. Le solde initial n'est retenu que pour un
  /// compte cash (`kind.valuationType == cash`).
  Future<Account> createAccount({
    required String name,
    required AccountKind kind,
    double? cashBalance,
  }) async {
    final newAccount = Account(
      id: Account.generateId(),
      walletId: _activeWallet!.id,
      name: name.trim(),
      kind: kind,
      cashBalance: kind.valuationType == AccountType.cash ? cashBalance : null,
    );
    await _storage.saveAccount(newAccount);
    await loadAllData();
    return newAccount;
  }

  /// Modifie le solde d'un compte cash et recharge les données.
  Future<void> updateCashBalance(Account account, double newBalance) async {
    if (newBalance == account.cashBalance) return;
    final updated = account.copyWith(cashBalance: newBalance);
    await _storage.saveAccount(updated);
    await loadAllData();
  }

  // ---------------------------------------------------------------------------
  // Historique (privé)
  // ---------------------------------------------------------------------------

  /// Coordinateur : récupère l'historique UNE SEULE FOIS par symbole unique
  /// (sur tous les comptes investissement) pour la période courante, puis
  /// réutilise la même map partagée pour l'agrégation globale ET le calcul des
  /// variations par compte. Évite le double téléchargement des mêmes symboles.
  Future<void> _loadHistory(
    Map<String, List<PositionWithMarketData>> accountPositions,
  ) async {
    // Afficher le graphique même s'il n'y a que des comptes cash
    if (_allPositionsData.isEmpty && _cashBalances.isEmpty) {
      _chartValues = [];
      _chartDates = [];
      _snapshotSpots = [];
      _isLoadingHistory = false;
      _safeNotify();
      // Pas de positions : variations par compte nulles (gérées par le calcul).
      _computeAccountsPeriodChanges(accountPositions, {});
      return;
    }

    // Cas avec uniquement des comptes cash (pas de positions) : graphique plat
    if (_allPositionsData.isEmpty && _cashBalances.isNotEmpty) {
      final totalCash = _cashBalances.values.fold(0.0, (a, b) => a + b);
      final now = DateTime.now();
      final dates = <DateTime>[];
      final values = <double>[];

      for (int i = 6; i >= 0; i--) {
        dates.add(now.subtract(Duration(days: i)));
        values.add(totalCash);
      }

      _chartDates = dates;
      _chartValues = values;
      _snapshotSpots = [];
      _periodChange = 0;
      _periodChangePercent = 0;
      _isLoadingHistory = false;
      _safeNotify();
      _computeAccountsPeriodChanges(accountPositions, {});
      return;
    }

    _isLoadingHistory = true;
    _safeNotify();

    try {
      // Un seul Future.wait pour l'ensemble des symboles uniques du patrimoine.
      final uniqueSymbols = _allPositionsData.map((p) => p.symbol).toSet();
      final assetBySymbol = <String, Asset>{
        for (final p in _allPositionsData) p.symbol: p.asset,
      };
      final symbolsList = uniqueSymbols.toList();
      final results = await Future.wait(
        symbolsList.map(
          (s) => _marketService.getHistoricalDataForAsset(
            assetBySymbol[s]!,
            days: _selectedPeriod.days,
          ),
        ),
      );

      final symbolToData = <String, AssetHistoricalData?>{};
      for (int i = 0; i < symbolsList.length; i++) {
        symbolToData[symbolsList[i]] = results[i];
      }

      // Map partagée : agrégation globale + variations par compte.
      _aggregateGlobalHistoricalData(symbolToData);
      _computeAccountsPeriodChanges(accountPositions, symbolToData);
      // Superposer la série réelle des snapshots (best-effort, non bloquant)
      await _loadSnapshotSeries();
      _isLoadingHistory = false;
      _safeNotify();
    } catch (e) {
      _isLoadingHistory = false;
      _safeNotify();
    }
  }

  void _aggregateGlobalHistoricalData(
    Map<String, AssetHistoricalData?> symbolToData,
  ) {
    final result = HistoryAggregator.aggregateGlobalHistoricalData(
      symbolToData: symbolToData,
      allPositionsData: _allPositionsData,
      cashBalances: _cashBalances,
      usdToEurRate: _usdToEurRate,
    );

    if (result.chartDates.isEmpty) {
      _chartDates = [];
      _chartValues = [];
      return;
    }

    _chartDates = result.chartDates;
    _chartValues = result.chartValues;
    _periodChange = result.periodChange;
    _periodChangePercent = result.periodChangePercent;
  }

  /// Calcule les variations par compte à partir de la map d'historique
  /// DÉJÀ récupérée par [_loadHistory] (plus aucun appel réseau ici).
  void _computeAccountsPeriodChanges(
    Map<String, List<PositionWithMarketData>> accountPositions,
    Map<String, AssetHistoricalData?> symbolToData,
  ) {
    final result = HistoryAggregator.computeAccountsPeriodChanges(
      accounts: _accounts,
      accountPositions: accountPositions,
      symbolToData: symbolToData,
      usdToEurRate: _usdToEurRate,
    );

    _accountPeriodChanges = result.accountPeriodChanges;
    _accountPeriodChangePercents = result.accountPeriodChangePercents;
    _safeNotify();
  }

  // ---------------------------------------------------------------------------
  // Snapshots (privé)
  // ---------------------------------------------------------------------------

  /// Charge les snapshots du wallet actif et les projette sur l'axe X du
  /// graphique (indices entiers dans [_chartDates]). Ne conserve que les
  /// snapshots dont la date tombe dans la fenêtre temporelle affichée.
  /// Stocke le résultat dans [_snapshotSpots] ; liste vide si < 2 points.
  Future<void> _loadSnapshotSeries() async {
    if (_activeWallet == null || _chartDates.isEmpty) {
      _snapshotSpots = [];
      return;
    }

    try {
      final snapshots = await _snapshotStorage.getSnapshots(_activeWallet!.id);

      _snapshotSpots = SnapshotCapture.projectSnapshotsToChart(
        snapshots,
        _chartDates,
      );
    } catch (e) {
      // Erreur non bloquante : on masque simplement la série
      AppLogger.warning(
        'Impossible de charger les snapshots pour le graphique',
        e,
      );
      _snapshotSpots = [];
    }
  }

  // ---------------------------------------------------------------------------
  // Cibles d'allocation (privé + public)
  // ---------------------------------------------------------------------------

  /// Charge les cibles du wallet actif, calcule l'allocation réelle et les
  /// écarts. Silencieux en cas d'erreur (best-effort comme les snapshots).
  Future<void> _loadAllocationTarget(
    Map<String, double> accountValues,
    List<PositionWithMarketData> positions,
    double usdToEurRate,
  ) async {
    if (_activeWallet == null) {
      _allocationTarget = const AllocationTarget.empty();
      _allocationGaps = [];
      _assetTypeAllocations = [];
      return;
    }

    try {
      final target = await _allocationTargetStorage.getTarget(
        _activeWallet!.id,
      );
      _allocationTarget = target;

      final total = accountValues.values.fold(0.0, (a, b) => a + b);
      // Solde total des liquidités (EUR) = somme des soldes des comptes cash
      // ET du cash dérivé opt-in des comptes titres (lot cash-ledger), déjà
      // agrégés dans _cashBalances (mêmes clés, sources disjointes par
      // account.type — cf. loadAllData) lors du chargement. Il est inclus
      // dans [total] (accountValues contient les deux familles), donc types +
      // cash somment à ~100 %.
      final cashValue = _cashBalances.values.fold(0.0, (a, b) => a + b);
      final realAllocations = AllocationCalculator.computeRealAllocations(
        positions: positions,
        totalValue: total,
        usdToEurRate: usdToEurRate,
        cashValue: cashValue,
      );
      _assetTypeAllocations = realAllocations;
      _allocationGaps = AllocationCalculator.computeGaps(
        target: target,
        realAllocations: realAllocations,
      );
    } catch (e) {
      AppLogger.warning('Impossible de charger les cibles d\'allocation', e);
      _allocationTarget = const AllocationTarget.empty();
      _allocationGaps = [];
      _assetTypeAllocations = [];
    }
  }

  /// Persiste les nouvelles cibles et recharge les écarts.
  Future<void> saveAllocationTarget(AllocationTarget target) async {
    if (_activeWallet == null) return;
    await _allocationTargetStorage.saveTarget(_activeWallet!.id, target);
    await _loadAllocationTarget(
      _accountValues,
      _allPositionsData,
      _usdToEurRate,
    );
    _safeNotify();
  }

  /// Supprime les cibles du wallet actif.
  Future<void> clearAllocationTarget() async {
    if (_activeWallet == null) return;
    await _allocationTargetStorage.deleteTargetForWallet(_activeWallet!.id);
    _allocationTarget = const AllocationTarget.empty();
    _allocationGaps = [];
    _safeNotify();
  }

  /// Capture best-effort du snapshot journalier de valorisation.
  /// Invariant fort : on ne persiste JAMAIS un total issu de données de marché
  /// incomplètes (quote null → prix compté 0 → total silencieusement sous-évalué).
  /// L'appel est fire-and-forget : toute exception est absorbée ici pour ne
  /// jamais perturber le chargement de la page.
  ///
  /// [capturingWalletId] est l'id capturé AVANT l'await de _loadHistory
  /// (correctif I2) : on le passe explicitement plutôt que de relire
  /// _activeWallet?.id, qui peut avoir été modifié par selectWallet entre-temps.
  Future<void> _maybeCaptureSnapshot(
    Map<String, double> accountValues,
    bool marketDataComplete,
    String? capturingWalletId,
  ) async {
    final snapshot = SnapshotCapture.buildIfEligible(
      accountValues: accountValues,
      marketDataComplete: marketDataComplete,
      accounts: _accounts,
      walletId: capturingWalletId,
      now: DateTime.now(),
    );

    if (snapshot == null) return;

    try {
      await _snapshotStorage.upsertSnapshot(capturingWalletId!, snapshot);
    } catch (e, st) {
      // Capture best-effort : l'échec ne remonte jamais à l'appelant.
      AppLogger.warning('Échec capture snapshot valorisation', e, st);
    }
  }
}

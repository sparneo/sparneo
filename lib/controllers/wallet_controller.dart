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
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/logic/allocation.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/allocation_target_storage.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/snapshot_storage.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/bounded_concurrency.dart';
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
  /// Lecture du journal (lot cash-ledger, élargi par B8/doc 19) : sert
  /// UNIQUEMENT à décider le RÉGIME de chaque compte (cf.
  /// [journalHasCashAnchor] dans [loadAllData]) — pour les comptes titres ET,
  /// depuis B8, pour les comptes cash. Aucune écriture ici.
  final TransactionStorage _txStorage;

  /// Écriture du journal (lot B8/doc 19 §3bis) : SEUL usage — émettre
  /// l'ancrage `openingBalance` ESPÈCES d'un compte cash à sa création
  /// (cf. [createAccount]). Aucune autre mutation du journal ici.
  final LedgerService _ledger;

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
    LedgerService? ledgerService,
    this.defaultWalletName = 'Mon Patrimoine',
  }) : _storage = storage ?? AccountStorage(),
       _marketService = marketService ?? MarketDataService.shared,
       _exchangeService = exchangeService ?? ExchangeRateService(),
       _snapshotStorage = snapshotStorage ?? SnapshotStorage(),
       _allocationTargetStorage =
           allocationTargetStorage ?? AllocationTargetStorage(),
       _txStorage = transactionStorage ?? TransactionStorage(),
       _ledger = ledgerService ?? LedgerService();

  // ---------------------------------------------------------------------------
  // État exposé via getters
  // ---------------------------------------------------------------------------

  List<Wallet> _wallets = [];
  Wallet? _activeWallet;
  List<Account> _accounts = [];
  Map<String, double> _accountValues = {}; // accountId → totalValueEur
  List<PositionWithMarketData> _allPositionsData = [];
  // accountId → solde de liquidités EUR. Peuplé par DEUX sources DISJOINTES,
  // partitionnées par le SEUL discriminant [journalHasCashAnchor] — B8/doc 19
  // §1 : la partition ne porte PLUS sur `account.type`, et la règle est la
  // MÊME pour les deux familles de comptes (cf. loadAllData) :
  //   - compte ANCRÉ (≥ 1 mouvement d'ancrage espèces au journal), cash OU
  //     titres : cash DÉRIVÉ du journal (getAccountDerivedCash) ;
  //   - compte NON ancré de type cash : `cashBalance` déclaratif LEGACY
  //     (régime d'avant B8, strictement inchangé — aucune migration, §3) ;
  //   - compte NON ancré de type titres : ABSENT de cette map (un journal
  //     composé seulement de buy/sell donnerait un solde négatif et FAUX,
  //     design cash-ledger §3/§6.7).
  // Un compte tombe dans EXACTEMENT une branche → double comptage impossible
  // par construction (invariant doc 19 §6.5).
  final Map<String, double> _cashBalances = {};

  /// Ids des comptes dont le journal porte au moins un ANCRAGE ESPÈCES
  /// ([journalHasCashAnchor]) — mémorisé par [loadAllData] en même temps que
  /// [_txsByAccountForHistory], dont il partage exactement la fraîcheur (les
  /// deux sont relus au même endroit, à partir des mêmes journaux).
  ///
  /// Ce n'est PAS un second discriminant (invariant doc 19 §6.6) : c'est la
  /// MÉMOÏSATION du résultat de [journalHasCashAnchor], jamais une règle
  /// parallèle — aucun autre prédicat de régime n'existe dans ce contrôleur.
  Set<String> _anchoredAccountIds = {};

  /// Borne gauche de la grille du graphique : date du PREMIER mouvement, tous
  /// comptes confondus, mais UNIQUEMENT sur la période « Max ». Les autres
  /// périodes ont déjà une fenêtre bornée par leur durée qu'il ne faut pas
  /// rogner. `null` = grille complète (comportement d'origine), y compris pour
  /// un patrimoine 100 % legacy dont aucun journal n'est daté.
  ///
  /// POURQUOI : la grille naît de l'historique de COTATION (Yahoo `range=max`
  /// pour cette période), qui remonte à l'introduction du support — d'où 22 ans
  /// de ligne plate à zéro devant un patrimoine ouvert en 2023 (constaté le
  /// 29/07). Dérivé de [_txsByAccountForHistory], déjà chargé par
  /// [loadAllData] : aucun état ni aucune lecture supplémentaires.
  DateTime? get _gridFrom {
    if (_selectedPeriod != ChartPeriod.max) return null;
    DateTime? first;
    for (final txs in _txsByAccountForHistory.values) {
      for (final tx in txs) {
        if (first == null || tx.date.isBefore(first)) first = tx.date;
      }
    }
    return first;
  }

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

  // Mode 2 « évolution réelle du patrimoine » (B7 Lot 2, design doc 18) :
  // reconstruction datée depuis le journal, calculée EN PARALLÈLE du mode 1
  // ci-dessus (additif — n'écrit JAMAIS les champs mode 1). ALIGNÉE
  // index-par-index sur [_chartDates] (même grille de dates, garantie par
  // construction — cf. _computeRealNetWorthCurve).
  //
  // [_txsByAccountForHistory] : journal COMPLET de TOUS les comptes (comptes
  // CASH INCLUS depuis B8/doc 19 §4.4 — c'est ce qui permet au journal d'un
  // livret d'atteindre le mode 2), capturé par loadAllData (txsResults, déjà
  // fetché pour décider le régime de chaque compte) et réutilisé ici pour
  // énumérer TOUS les symboles historiques (y compris soldés, absents de
  // [_allPositionsData]) sans reformuler un accès storage.
  Map<String, List<AssetTransaction>> _txsByAccountForHistory = {};
  List<double> _realChartValues = [];
  // Symboles dont la valeur, à au moins une date, provient d'un repli
  // « dernier cours connu » (pas un vrai historique de marché) — pour un
  // futur badge UI (Lot 3, design §4/§11.5 m1).
  Set<String> _realCurveApproxSymbols = {};
  // Positions ACTUELLEMENT détenues (tout le patrimoine) mais ABSENTES du
  // journal (saisies à la main, sans aucun mouvement associé) — donc EXCLUES
  // de la reconstruction ci-dessus (`_allPositionsData` dont le symbole n'est
  // pas clé de `txsBySymbol`, cf. [_computeRealNetWorthCurve]). Alimente
  // l'avertissement de complétude UI, conditionnel ET chiffré. Miroir wallet
  // de [AccountController._realExcludedLegacyCount].
  int _realExcludedLegacyCount = 0;
  // Courbe des FLUX EXTERNES CUMULÉS (B7 correction financière, design
  // §11.4 — ex-« apports nets », désormais [HistoryAggregator.
  // buildExternalFlowsCurve], flux complets pas seulement le cash pur) :
  // ALIGNÉE index-par-index sur [_chartDates]/[_realChartValues], superposée
  // en mode réel pour visualiser l'écart valeur−flux (≠ gains totaux, cf.
  // divergence assumée — voir [_realTotalGain]). Cash pur ajouté en
  // constante, comme [_realChartValues] — s'annule dans l'écart. Le NOM du
  // champ (`Contributions`) est conservé pour limiter le remue-ménage — seul
  // le LABEL affiché change (« Capital investi », cf. l10n).
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
  // via [HistoryAggregator.computeRealTotalGain] — voir [RealTotalGain]. Passe
  // TOUJOURS TOUTES les positions du patrimoine ([_allPositionsData], legacy
  // inclus si leur PRU est connu), jamais gaté par la période sélectionnée.
  double? _realTotalGain;
  double? _realTotalGainPercent;
  // Sous-total `charge` SEUL, EN PLUS de `_realTotalGain` (n'en change rien) —
  // cf. [RealTotalGain.chargesTotal], destiné à la ligne « dont frais » du
  // popup d'aide.
  double? _realTotalGainCharges;
  // Symboles EXCLUS du calcul ci-dessus faute de PRU connu — cf.
  // [RealTotalGain.noBasisSymbols], destiné à l'avertissement UI (Lot C).
  Set<String> _realNoBasisSymbols = {};

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

  /// Série du mode 2 « évolution réelle », ALIGNÉE index-par-index sur
  /// [chartDates] (même grille que le mode 1). Vide tant qu'aucun calcul mode
  /// 2 n'a abouti (cf. [hasRealCurve]).
  List<double> get realChartValues => _realChartValues;

  /// Symboles dont la valeur mode 2 provient d'un repli « dernier cours
  /// connu » plutôt que d'un véritable historique de marché (design §4/§11.5
  /// m1) — destiné à un futur badge « valeurs approchées » (Lot 3).
  Set<String> get realCurveApproxSymbols => _realCurveApproxSymbols;

  /// Nombre de positions détenues (tout le patrimoine) sans AUCUN mouvement
  /// journalisé, donc absentes de [realChartValues] — cf.
  /// [_realExcludedLegacyCount]. `0` = rien n'est exclu.
  int get realExcludedLegacyCount => _realExcludedLegacyCount;

  /// Vrai si une courbe mode 2 est disponible pour l'affichage.
  bool get hasRealCurve => _realChartValues.isNotEmpty;

  /// Courbe des apports nets cumulés (B7 Lot 3b), ALIGNÉE index-par-index sur
  /// [chartDates]/[realChartValues]. Vide tant qu'aucun calcul mode 2 n'a
  /// abouti.
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
      // et collecter l'ensemble des symboles UNIQUES. Les comptes cash n'ont
      // aucune position (leur valeur EST leur solde d'espèces, cf. Étape C) et
      // aucune cotation.
      final Map<String, List<Position>> rawPositionsByAccount = {};
      final Set<String> uniqueSymbols = {};

      // ⭐ Taux de change des soldes d'espèces : un seul lot de requêtes pour
      // les devises UNIQUES de TOUS les comptes (les deux familles reçoivent
      // désormais le même traitement du cash, cf. ci-dessous).
      final uniqueCashCurrencies = {
        for (final a in accounts) a.currency.toUpperCase(),
      }.toList();
      final cashRatesList = await Future.wait(
        uniqueCashCurrencies.map((c) => _exchangeService.getRateToEur(c)),
      );
      final Map<String, double> cashRateByCurrency = {};
      for (int i = 0; i < uniqueCashCurrencies.length; i++) {
        cashRateByCurrency[uniqueCashCurrencies[i]] = cashRatesList[i];
      }

      // ⭐ RÉGIME DU CASH — UNE SEULE RÈGLE, LA MÊME POUR LES DEUX FAMILLES DE
      // COMPTES (B8, doc 19 §1/§4.4 ; anciennement : deux chemins distincts
      // partitionnés par `account.type`). Le SEUL discriminant est
      // [journalHasCashAnchor] :
      //
      //   - ANCRÉ (≥ 1 deposit/withdrawal/interest/charge, ou openingBalance
      //     ESPÈCES) → cash DÉRIVÉ du journal (`derived_cash × fx`), que le
      //     compte soit de type cash ou titres — MÊME chemin, MÊME code ;
      //   - NON ancré + type cash → `cash_balance × fx`, régime LEGACY
      //     déclaratif STRICTEMENT inchangé (aucune migration : un compte cash
      //     existant y reste jusqu'à ce que l'utilisateur pose lui-même un
      //     ancrage, doc 19 §3 / invariant §6.9) ;
      //   - NON ancré + type titres → rien (un journal composé uniquement de
      //     buy/sell donnerait un solde dérivé négatif et FAUX, aucun dépôt/
      //     retrait/intérêt/frais/solde initial espèces n'ayant jamais été
      //     enregistré — opt-in du lot cash-ledger, cf. position_projection).
      //
      // Un compte tombe dans EXACTEMENT une branche ⇒ double comptage
      // impossible par construction (invariant doc 19 §6.5, risque §8.1
      // BLOQUANT). Calculé ICI, EN PARALLÈLE (comme les cotations ci-dessous),
      // pour l'injecter plus loin dans `accountValues`/`_cashBalances` SANS
      // await dans la boucle de construction (invariant de l'Étape C).
      //
      // Coût assumé (doc 19 §4.4) : un getByAccount/getAccountDerivedCash de
      // plus par compte CASH à chaque chargement — requêtes locales indexées
      // sur des journaux typiquement courts.
      final derivedCashResults = await Future.wait(
        accounts.map((a) => _storage.getAccountDerivedCash(a.id)),
      );
      final txsResults = await Future.wait(
        accounts.map((a) => _txStorage.getByAccount(a.id)),
      );
      // Mode 2 (B7 Lot 2, élargi par B8) : conserve le journal COMPLET par
      // compte — TOUS les comptes désormais, comptes cash inclus, c'est ce qui
      // fait entrer le journal d'un livret dans la reconstruction réelle et
      // dans computeRealTotalGain. Capturé AVANT tout gating (le gating
      // d'ancrage ne s'applique qu'à l'agrégation cash affichée, pas à
      // l'énumération des symboles pour le fetch d'historique).
      _txsByAccountForHistory = {
        for (int i = 0; i < accounts.length; i++) accounts[i].id: txsResults[i],
      };
      _anchoredAccountIds = {
        for (int i = 0; i < accounts.length; i++)
          if (journalHasCashAnchor(txsResults[i])) accounts[i].id,
      };
      // accountId → solde d'espèces EN EUR (les deux régimes confondus).
      // _cashBalances et accountValues sont stockés EN EUR pour rester
      // cohérents avec le reste de l'agrégation du patrimoine.
      final Map<String, double> cashEurByAccount = {};
      for (int i = 0; i < accounts.length; i++) {
        final acc = accounts[i];
        final rate = cashRateByCurrency[acc.currency.toUpperCase()] ?? 1.0;
        if (_anchoredAccountIds.contains(acc.id)) {
          final derived = derivedCashResults[i].cash;
          // `derived == null` = compte jamais projeté. Inatteignable dès qu'un
          // ancrage existe (toute écriture de mouvement reprojette le cash,
          // cf. LedgerService) — garde défensive : on n'agrège alors RIEN
          // plutôt que de retomber en douce sur `cash_balance`, ce qui
          // mélangerait les deux régimes.
          if (derived == null) continue;
          cashEurByAccount[acc.id] =
              (Decimal.tryParse(derived)?.toDouble() ?? 0.0) * rate;
        } else if (acc.type == AccountType.cash) {
          cashEurByAccount[acc.id] = (acc.cashBalance ?? 0.0) * rate;
        }
      }
      _cashBalances.addAll(cashEurByAccount);

      for (var account in accounts) {
        if (account.type == AccountType.cash) {
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
      // Concurrence BORNÉE (mapBounded) : ordre préservé, appairé par index à
      // `symbolsList` juste en dessous — sans borne, un patrimoine à
      // beaucoup de titres partirait en rafale non bornée vers Yahoo (risque
      // de 429).
      final quoteResults = await mapBounded(symbolsList, maxConcurrentMarketRequests, (
        s,
      ) {
        final asset = assetBySymbol[s]!;
        // Actif NON COTÉ (repli ISIN / titre délisté) : jamais interrogé sur
        // la source de marché — on n'émet aucune requête pour ce symbole.
        if (!asset.quotable) return Future<AssetQuoteData?>.value(null);
        return _marketService.getQuoteForAsset(asset);
      });
      final Map<String, AssetQuoteData?> quotesBySymbol = {};
      for (int i = 0; i < symbolsList.length; i++) {
        quotesBySymbol[symbolsList[i]] = quoteResults[i];
      }

      // ⭐ Étape C : construire les valeurs des comptes/positions en lisant la
      // map de cotations (plus aucun await dans ces boucles de calcul).
      // Flag de complétude : passe à false dès qu'une cotation est manquante.
      // Les comptes cash n'ont aucune cotation — un wallet 100 % cash reste
      // marketDataComplete = true.
      bool marketDataComplete = true;
      for (var account in accounts) {
        if (account.type == AccountType.cash) {
          // Valeur du compte = son solde d'espèces, DANS LES DEUX RÉGIMES
          // (dérivé du journal si ancré, `cash_balance` sinon — cf. la règle
          // unique plus haut). Absent de la map = compte ancré jamais projeté
          // (garde défensive ci-dessus) → 0, jamais un repli silencieux sur le
          // solde déclaratif.
          accountValues[account.id] = cashEurByAccount[account.id] ?? 0.0;
          continue;
        }

        final positions = rawPositionsByAccount[account.id] ?? [];
        double accountTotal = 0;
        List<PositionWithMarketData> accountPosList = [];

        for (var pos in positions) {
          // Actif NON COTÉ : valorisé 0 (position soldée = 0 par construction),
          // SANS dégrader marketDataComplete — un actif délibérément non coté
          // n'est pas une donnée « manquante » et ne doit pas empêcher la
          // persistance d'un snapshot journalier. Pas de badge « cours du … ».
          if (!pos.asset.quotable) {
            final posWithData =
                PositionWithMarketData(position: pos, currentPrice: 0);
            allPositions.add(posWithData);
            accountPosList.add(posWithData);
            continue;
          }
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
        // parqué sur un compte titres fait partie du patrimoine, au même titre
        // qu'une position). Déjà écrit dans `_cashBalances` par la règle
        // unique plus haut — une seule écriture, un seul chemin.
        final derivedCashEur = cashEurByAccount[account.id];
        if (derivedCashEur != null) {
          accountTotal += derivedCashEur;
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

      // Rafraîchissement MANUEL explicite : loadAllData est le point d'entrée
      // unique du pull-to-refresh (wallet_view.dart, RefreshIndicator.
      // onRefresh) — on vide le cache mémoire des séries historiques AVANT de
      // recharger, pour que l'utilisateur obtienne une vraie ronde réseau
      // plutôt qu'une réponse resservie (même si le TTL n'a pas expiré). Le
      // switch de période (onPeriodChanged) appelle _loadHistory DIRECTEMENT,
      // sans passer par loadAllData ni cette invalidation : c'est précisément
      // le chemin qui doit bénéficier du cache. Les autres rechargements
      // « structurels » qui passent par loadAllData (CRUD wallet/compte,
      // post-import) subissent aussi cette invalidation par simplicité — la
      // série de prix d'un symbole ne dépend jamais du journal local, ce
      // n'est donc pas une correction requise, juste le prix d'un point
      // d'entrée unique plutôt que d'un nouveau paramètre `forceRefresh`
      // propagé à travers tout loadAllData.
      _marketService.invalidateHistoryCache();

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
  /// (dérivée) et la fiscalité. `cashBalance` (l'ex-« solde initial » saisi
  /// pour un compte cash) n'écrit PLUS `Account.cashBalance` — B8/doc 19 §2
  /// ferme cette seconde source de vérité : le solde initial d'un compte
  /// cash s'exprime désormais comme un `openingBalance` ESPÈCES au journal
  /// (§3bis), émis INCONDITIONNELLEMENT (même 0/absent) juste après la
  /// création, pour que TOUT compte cash créé après ce lot naisse ANCRÉ
  /// (`journalHasCashAnchor`) — `cash_balance` reste NULL à vie pour ces
  /// comptes, la lecture legacy ne concernant plus que les comptes créés
  /// avant B8/lot 4.
  ///
  /// Non-atomique par construction (deux écritures distinctes : compte puis
  /// mouvement) — accepté par le design (§3bis) : l'échec du second appel
  /// laisse un compte non ancré à solde nul, dégradation propre, rattrapable
  /// par l'action d'amorçage (« Définir le solde espèces initial… »).
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
      cashBalance: null,
    );
    await _storage.saveAccount(newAccount);
    if (kind.valuationType == AccountType.cash) {
      await _ledger.emitCashOpeningBalance(
        accountId: newAccount.id,
        amount: (cashBalance ?? 0.0).toString(),
        currency: newAccount.currency,
        date: DateTime.now(),
      );
    }
    await loadAllData();
    return newAccount;
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
      // Mode 2 == mode 1 sur un patrimoine vide (design §9 Lot 2 pt.5).
      _realChartValues = List<double>.from(_chartValues);
      _realCurveApproxSymbols = {};
      _realExcludedLegacyCount = 0;
      // Aucun journal à agréger ici (patrimoine vide) : vidée pour rester
      // cohérente avec _realChartValues (évite un tableau apports périmé
      // d'une longueur différente si le patrimoine devient vide après avoir
      // eu une courbe réelle).
      _realContributionsValues = [];
      _resetRealGains();
      _isLoadingHistory = false;
      _safeNotify();
      // Pas de positions : variations par compte nulles (gérées par le calcul).
      _computeAccountsPeriodChanges(accountPositions, {});
      return;
    }

    // Cas SANS aucune position mais AVEC du cash (typiquement un patrimoine
    // 100 % comptes cash).
    if (_allPositionsData.isEmpty && _cashBalances.isNotEmpty) {
      // B8 (doc 19 §4.4) : dès qu'AU MOINS UN compte cash est ANCRÉ, son
      // journal porte une histoire réelle (escalier de versements/intérêts) —
      // la branche « courbe plate » cède alors la main à la reconstruction
      // datée, sur une grille SYNTHÉTIQUE (aucune série de prix ici). Aucun
      // compte ancré ⇒ comportement d'avant B8, bit pour bit (invariant §6.9).
      if (_hasAnchoredCashAccount) {
        await _loadCashOnlyHistory(accountPositions);
        return;
      }

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
      // Mode 2 == mode 1 sur du cash plat (design §9 Lot 2 pt.5).
      _realChartValues = List<double>.from(_chartValues);
      _realCurveApproxSymbols = {};
      _realExcludedLegacyCount = 0;
      // Aucun compte non-cash ici (que du cash) : pas de journal à agréger,
      // même motif que ci-dessus.
      _realContributionsValues = [];
      _resetRealGains();
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
      // Concurrence BORNÉE (mapBounded) : ordre préservé, appairé par index à
      // `symbolsList` (boucle juste en dessous).
      final results = await mapBounded(
        symbolsList,
        maxConcurrentMarketRequests,
        (s) => _marketService.getHistoricalDataForAsset(
          assetBySymbol[s]!,
          days: _selectedPeriod.days,
        ),
      );

      final symbolToData = <String, AssetHistoricalData?>{};
      for (int i = 0; i < symbolsList.length; i++) {
        symbolToData[symbolsList[i]] = results[i];
      }

      // Map partagée : agrégation globale + variations par compte.
      _aggregateGlobalHistoricalData(symbolToData);
      _computeAccountsPeriodChanges(accountPositions, symbolToData);

      // Mode 2 « évolution réelle » (B7 Lot 2) : calculé EN PARALLÈLE du
      // mode 1 ci-dessus, JAMAIS bloquant — une erreur ici (réseau, données
      // incohérentes) laisse simplement la courbe réelle absente
      // ([hasRealCurve] false) ; le mode 1 reste intact et affiché.
      try {
        await _computeRealNetWorthCurve(symbolToData);
      } catch (e, st) {
        AppLogger.warning(
          'Impossible de calculer la courbe réelle du patrimoine (mode 2)',
          e,
          st,
        );
        _realChartValues = [];
        _realCurveApproxSymbols = {};
        _realExcludedLegacyCount = 0;
        _realContributionsValues = [];
        _resetRealGains();
      }

      // Superposer la série réelle des snapshots (best-effort, non bloquant)
      await _loadSnapshotSeries();
      _isLoadingHistory = false;
      _safeNotify();
    } catch (e) {
      _isLoadingHistory = false;
      _safeNotify();
    }
  }

  // ---------------------------------------------------------------------------
  // B8 (doc 19) — patrimoine SANS aucun titre mais avec au moins un compte
  // cash ANCRÉ : grille de dates SYNTHÉTIQUE + reconstruction réelle.
  // ---------------------------------------------------------------------------

  /// Vrai si au moins un compte cash du wallet actif porte un ancrage espèces
  /// à son journal — le cas d'usage central de B8 (« un livret journalisé »).
  /// Dérivé du SEUL discriminant [journalHasCashAnchor] (mémoïsé dans
  /// [_anchoredAccountIds] par [loadAllData]).
  bool get _hasAnchoredCashAccount => _accounts.any(
        (a) =>
            a.type == AccountType.cash && _anchoredAccountIds.contains(a.id),
      );

  /// Budget de points de la grille synthétique (doc 19 §4.3/§8.5) : au-delà,
  /// [HistoryAggregator.buildDateGrid] sous-échantillonne à pas régulier
  /// plutôt que de produire un point par jour (« Max » sur 10 ans ≈ 3 650
  /// points, coûteux au rendu `fl_chart`).
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

  /// Borne gauche de la grille synthétique (doc 19 §4.3 règle 2) :
  /// `max(début de période, premier mouvement du journal)` — avant le premier
  /// mouvement la valeur est 0, pas une extrapolation, et
  /// [HistoryAggregator.buildDateGrid] ne connaît pas le journal.
  DateTime _syntheticGridFrom(DateTime now) {
    final periodStart = _selectedPeriodStart(now);
    DateTime? firstMovement;
    for (final txs in _txsByAccountForHistory.values) {
      for (final tx in txs) {
        if (firstMovement == null || tx.date.isBefore(firstMovement)) {
          firstMovement = tx.date;
        }
      }
    }
    if (firstMovement == null) return periodStart ?? now;
    if (periodStart == null) return firstMovement;
    return periodStart.isAfter(firstMovement) ? periodStart : firstMovement;
  }

  /// Historique d'un patrimoine SANS aucune position mais dont au moins un
  /// compte cash est ANCRÉ (B8, doc 19 §4.4).
  ///
  /// La grille naît ici de [HistoryAggregator.buildDateGrid] parce qu'aucune
  /// série de prix n'existe pour l'échantillonner — et elle reste la SEULE
  /// grille du calcul : mode 1, mode 2 et courbe de flux la partagent (doc 19
  /// §4.3 règle 3 / §8.3 MAJEUR — deux grilles concurrentes désaligneraient
  /// valeur et flux, donc l'écart affiché).
  ///
  /// Le mode 1 y garde sa sémantique inchangée (rétroprojection de la valeur
  /// ACTUELLE : courbe PLATE, d'où variation de période nulle) ; seule sa
  /// longueur suit désormais la période sélectionnée au lieu des 7 jours en
  /// dur de la branche legacy. C'est le mode 2 qui porte l'escalier réel.
  Future<void> _loadCashOnlyHistory(
    Map<String, List<PositionWithMarketData>> accountPositions,
  ) async {
    _isLoadingHistory = true;
    _safeNotify();

    try {
      final now = DateTime.now();
      final totalCash = _cashBalances.values.fold(0.0, (a, b) => a + b);
      final gridDates = HistoryAggregator.buildDateGrid(
        from: _syntheticGridFrom(now),
        to: now,
        maxPoints: _syntheticGridMaxPoints,
      );

      _chartDates = gridDates;
      _chartValues = [for (var i = 0; i < gridDates.length; i++) totalCash];
      _snapshotSpots = [];
      _periodChange = 0;
      _periodChangePercent = 0;

      // Mode 2 : aucune série de prix à passer (aucun titre) — le fetch de
      // delta interne ne portera sur rien. Même try/catch non bloquant que la
      // branche nominale : une erreur laisse la courbe réelle absente sans
      // perturber le mode 1.
      try {
        await _computeRealNetWorthCurve(const {});
      } catch (e, st) {
        AppLogger.warning(
          'Impossible de calculer la courbe réelle du patrimoine (mode 2)',
          e,
          st,
        );
        _realChartValues = [];
        _realCurveApproxSymbols = {};
        _realExcludedLegacyCount = 0;
        _realContributionsValues = [];
        _resetRealGains();
      }

      _isLoadingHistory = false;
      _safeNotify();
      // Aucune position : variations par compte nulles (un compte cash reste
      // à 0 de toute façon, cf. computeAccountsPeriodChanges / doc 19 §4.3).
      _computeAccountsPeriodChanges(accountPositions, const {});
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
      gridFrom: _gridFrom,
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
  }

  /// Calcule le mode 2 « évolution réelle » (B7 Lot 2, design doc 18 §9 ;
  /// élargi aux comptes cash par B8, doc 19) : énumère TOUS les symboles du
  /// journal (y compris les titres soldés — absents de [_allPositionsData]),
  /// élargit le fetch d'historique au DELTA manquant, applique le repli
  /// « dernier cours » pour les symboles détenus sans historique, puis compose
  /// avec le cash dérivé de TOUS les comptes ANCRÉS (via
  /// [HistoryAggregator.reconstructRealNetWorth], qui applique lui-même le
  /// gating [journalHasCashAnchor]) et le cash PUR des seuls comptes cash NON
  /// ancrés (ajouté en CONSTANTE — jamais le cash dérivé une seconde fois, cf.
  /// la partition par ancrage dans [loadAllData]).
  ///
  /// [symbolToData] est la map DÉJÀ récupérée par le mode 1 pour les
  /// positions actuelles — réutilisée ici pour ne refetcher QUE le delta
  /// (symboles du journal absents de cette map).
  ///
  /// Écrit UNIQUEMENT [_realChartValues]/[_realCurveApproxSymbols] — n'écrit
  /// JAMAIS les champs du mode 1. Toute exception se propage à l'appelant
  /// ([loadAllData]/_loadHistory), qui l'absorbe dans un try/catch dédié.
  Future<void> _computeRealNetWorthCurve(
    Map<String, AssetHistoricalData?> symbolToData,
  ) async {
    final txsByAccount = _txsByAccountForHistory;
    if (_chartDates.isEmpty) {
      _realChartValues = [];
      _realCurveApproxSymbols = {};
      _realExcludedLegacyCount = 0;
      _realContributionsValues = [];
      _resetRealGains();
      return;
    }

    // Regroupe TOUT le journal (comptes non-cash) par symbole — inclut les
    // titres VENDUS (plus de position actuelle dans _allPositionsData).
    final txsBySymbol = <String, List<AssetTransaction>>{};
    for (final txs in txsByAccount.values) {
      for (final tx in txs) {
        final sym = tx.symbol;
        if (sym == null) continue;
        txsBySymbol.putIfAbsent(sym, () => []).add(tx);
      }
    }

    // Positions détenues (tout le patrimoine) mais SANS AUCUN mouvement
    // journalisé : exclues de la reconstruction — comptées ICI, avant les
    // retours anticipés ci-dessous, pour rester cohérentes avec `txsBySymbol`
    // au même instant (cf. [_realExcludedLegacyCount]).
    _realExcludedLegacyCount = _allPositionsData
        .where((p) => !txsBySymbol.containsKey(p.symbol))
        .length;

    // Aucun titre JOURNALISÉ dans tout le patrimoine (positions 100 % legacy,
    // saisies sans mouvement) NI aucun compte cash ancré : la reconstruction ne
    // porterait qu'un cash pur plat, indiscernable du mode 1 et laissant croire
    // à tort que les positions legacy valent 0. On n'expose alors PAS de courbe
    // réelle (`hasRealCurve` reste faux → aucun bascule proposé).
    //
    // B8 (doc 19 §4.4) : la garde est désormais CONJOINTE. Un patrimoine « un
    // livret ancré, zéro titre » — le cas d'usage central du lot — a bien une
    // histoire à reconstruire (l'escalier de son journal) ; sans cet
    // élargissement il n'afficherait JAMAIS le mode 2.
    if (txsBySymbol.isEmpty && !_hasAnchoredCashAccount) {
      _realChartValues = [];
      _realCurveApproxSymbols = {};
      _realExcludedLegacyCount = 0;
      _realContributionsValues = [];
      _resetRealGains();
      return;
    }

    // Asset par symbole : position ACTUELLE (autoritatif : quoteSymbol,
    // currency, quotable) si elle existe, sinon SYNTHÉTISÉ (titre vendu sans
    // position résiduelle — on tente quand même le fetch, currency reprise
    // d'un mouvement quelconque de ce symbole).
    final currentAssetBySymbol = <String, Asset>{
      for (final p in _allPositionsData) p.symbol: p.asset,
    };
    final assetBySymbol = <String, Asset>{};
    for (final sym in txsBySymbol.keys) {
      final current = currentAssetBySymbol[sym];
      assetBySymbol[sym] =
          current ?? Asset(symbol: sym, currency: txsBySymbol[sym]!.first.currency);
    }

    // Fetch élargi : DELTA = symboles du journal absents de symbolToData
    // (déjà rempli par le mode 1 pour les positions actuelles), MÊME fenêtre
    // que le mode 1. Un actif non coté n'est jamais interrogé (repli direct).
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
    // historique exploitable (délisté/irrésolu/fetch en échec) — synthétise
    // une série PLATE et flag le symbole comme approché (design §4/§11.5 m1).
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

    final reconstructed = HistoryAggregator.reconstructRealNetWorth(
      txsBySymbol: txsBySymbol,
      txsByAccount: txsByAccount,
      symbolToData: fullSymbolToData,
      assetBySymbol: assetBySymbol,
      usdToEurRate: _usdToEurRate,
      gridDates: _chartDates,
    );

    // Cash PUR : comptes AccountType.cash NON ANCRÉS uniquement (périmètre
    // RESSERRÉ par B8, doc 19 §4.3/§8.1 — anciennement : tous les comptes
    // cash), ajouté EN CONSTANTE puisqu'un compte legacy n'a aucune histoire
    // datée à projeter.
    //
    // ⚠️ PIÈGE N°1 [BLOQUANT] — DOUBLE COMPTAGE DU CASH. Le cash DÉRIVÉ de
    // TOUT compte ANCRÉ (titres comme cash, depuis B8) est DÉJÀ dans
    // `reconstructed.values` : txsByAccount == _txsByAccountForHistory indexe
    // désormais TOUS les comptes, et reconstructRealNetWorth y applique
    // lui-même le gating journalHasCashAnchor. Un compte cash ancré qui
    // atterrirait AUSSI ici serait compté DEUX FOIS. Les deux chemins sont
    // mutuellement exclusifs par construction (un compte est ancré ou ne
    // l'est pas) — c'est ce `!_anchoredAccountIds.contains(...)` qui le
    // garantit côté appelant.
    final pureCashEur = _accounts
        .where((a) =>
            a.type == AccountType.cash && !_anchoredAccountIds.contains(a.id))
        .fold(0.0, (sum, a) => sum + (_cashBalances[a.id] ?? 0.0));

    _realChartValues = HistoryAggregator.addConstantPureCash(
      reconstructed.values,
      pureCashEur,
    );
    _realCurveApproxSymbols = approxSymbols;

    // Courbe des flux externes complets (design §11.4, ex-« apports nets ») :
    // même cash pur en constante que ci-dessus — il s'annule dans l'écart
    // valeur−flux (composition cohérente avec [_realChartValues]). Alimente
    // ET la courbe superposée ET le gain de période Modified Dietz plus bas.
    _realContributionsValues = HistoryAggregator.addConstantPureCash(
      HistoryAggregator.buildExternalFlowsCurve(
        txsBySymbol: txsBySymbol,
        txsByAccount: txsByAccount,
        symbolToData: fullSymbolToData,
        assetBySymbol: assetBySymbol,
        usdToEurRate: _usdToEurRate,
        gridDates: _chartDates,
      ),
      pureCashEur,
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
    // ci-dessus (voie b, pas de dérivation de la grille de dates) — TOUTES
    // les positions du patrimoine (legacy incluses si leur PRU est connu),
    // affiché quelle que soit la période sélectionnée (aucun gating).
    final totalGain = HistoryAggregator.computeRealTotalGain(
      positions: _allPositionsData,
      txsBySymbol: txsBySymbol,
      txsByAccount: txsByAccount,
      usdToEurRate: _usdToEurRate,
      // TOUT le cash du patrimoine (déjà en EUR), chaque compte dans SON
      // régime (dérivé si ancré, legacy sinon) : _cashBalances porte une
      // valeur et une seule par compte (cf. la règle unique de loadAllData),
      // donc aucun double-comptage. Entre dans le CAPITAL investi, jamais
      // dans le gain — les intérêts/frais d'un livret ancré, eux, entrent
      // désormais au terme « revenus » via txsByAccount (doc 19 §0.4.3).
      cashEur: _cashBalances.values.fold(0.0, (a, b) => a + b),
    );
    _realTotalGain = totalGain.totalGain;
    _realTotalGainPercent = totalGain.totalGainPercent;
    _realTotalGainCharges = totalGain.chargesTotal;
    _realNoBasisSymbols = totalGain.noBasisSymbols;
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

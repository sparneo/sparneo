// widgets/position_detail_page.dart
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';
import 'package:portfolio_tracker/widgets/charts/period_selector.dart';
import 'package:portfolio_tracker/widgets/charts/valuation_line_chart.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/utils/logger.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/widgets/transaction_edit_dialog.dart';
import 'package:portfolio_tracker/logic/transaction_analytics.dart';
import 'package:portfolio_tracker/widgets/common/responsive_body.dart';
import 'package:portfolio_tracker/widgets/common/delete_position_dialog.dart';
import 'package:portfolio_tracker/utils/error_text.dart';

class PositionDetailPage extends StatefulWidget {
  final Position position;
  final VoidCallback? onPositionModified; // ⭐ NOUVEAU CALLBACK

  /// Valeur renvoyée par [Navigator.pop] quand l'utilisateur a confirmé la
  /// suppression de la position depuis la barre. Le parent (AccountView) la
  /// détecte au retour de navigation pour déclencher son propre chemin de
  /// suppression différée + Annuler (la logique d'undo vit dans son
  /// contrôleur, pas ici — on se contente de signaler l'intention).
  static const String resultDeleted = 'deleted';

  const PositionDetailPage({
    super.key,
    required this.position,
    this.onPositionModified,
  });

  @override
  State<PositionDetailPage> createState() => _PositionDetailPageState();
}

class _PositionDetailPageState extends State<PositionDetailPage> {
  final MarketDataService _marketService = MarketDataService();
  final ExchangeRateService _exchangeService = ExchangeRateService();
  final AccountStorage _storage = AccountStorage();

  AssetHistoricalData? _historicalData;
  bool _isLoadingHistory = true;
  String? _historyError;
  ChartPeriod _selectedPeriod = ChartPeriod.month1;

  double? _periodStartValue;
  double? _periodEndValue;
  double? _periodChange;
  double? _periodChangePercent;

  double _usdToEurRate = 0.92;
  double? _currentPrice;

  late String _quantity;
  late Position _currentPosition;

  // --- Transactions / journal (modèle B*) ---
  final TransactionStorage _txStorage = TransactionStorage();
  final LedgerService _ledger = LedgerService();
  List<AssetTransaction> _transactions = [];
  bool _isLoadingTransactions = false;

  /// Horodatage de dernière projection (`positions.derived_at`, epoch ms) ou
  /// null si la position est legacy (quantité/PRU saisis, jamais dérivés d'un
  /// journal). Pilote le badge « Non réconcilié » + le bouton de réconciliation.
  int? _derivedAt;

  /// Devise du COMPTE (devise de règlement) — chargée une fois, transmise au
  /// [TransactionEditDialog] pour découpler cotation/règlement (design §8). Null
  /// tant que non chargée ; le dialogue retombe alors sur le comportement
  /// mono-devise (règlement supposé == cotation).
  String? _accountCurrency;

  // --- Analyse du journal (LOT F1) ---
  TransactionAnalytics? _analytics;

  @override
  void initState() {
    super.initState();
    _currentPosition = widget.position;
    _quantity = widget.position.quantity;
    _loadExchangeRate();
    _loadHistoricalData();
    _loadCurrentPrice();
    _loadTransactions();
    _loadDerivedAt();
    _loadAccountCurrency();
  }

  /// Charge la devise du compte (devise de règlement) pour la saisie de
  /// mouvements. Best-effort : un échec laisse [_accountCurrency] null (le
  /// dialogue reste en mono-devise).
  Future<void> _loadAccountCurrency() async {
    final account = await _storage.getAccount(_currentPosition.accountId);
    if (mounted) setState(() => _accountCurrency = account?.currency);
  }

  Future<void> _loadTransactions() async {
    setState(() => _isLoadingTransactions = true);
    final txs = await _txStorage.getBySymbol(
      _currentPosition.accountId,
      _currentPosition.symbol,
    );
    if (mounted) {
      setState(() {
        _transactions = txs;
        _isLoadingTransactions = false;
        // Recalcule la plus-value réalisée à chaque chargement.
        _analytics = computeTransactionAnalytics(txs);
      });
    }
  }

  /// Lit `positions.derived_at` pour piloter le badge « Non réconcilié ».
  Future<void> _loadDerivedAt() async {
    final d = await _storage.getPositionDerivedAt(
      _currentPosition.accountId,
      _currentPosition.symbol,
    );
    if (mounted) setState(() => _derivedAt = d);
  }

  /// Recharge la projection (quantité + PRU dérivés du journal) et son
  /// horodatage depuis la base, puis le journal. À appeler après TOUTE mutation
  /// de mouvement (ajout / édition / suppression / édition de quantité /
  /// réconciliation) : l'état q/PRU était tenu en mémoire et doit refléter la
  /// reprojection du ledger.
  Future<void> _reloadProjection() async {
    final accountId = _currentPosition.accountId;
    final symbol = _currentPosition.symbol;
    final pos = await _storage.getPosition(accountId, symbol);
    final derivedAt = await _storage.getPositionDerivedAt(accountId, symbol);
    if (!mounted) return;
    setState(() {
      if (pos != null) {
        _currentPosition = pos;
        _quantity = pos.quantity;
      }
      _derivedAt = derivedAt;
      // La variation de période dépend de la quantité projetée.
      if (_historicalData != null && !_historicalData!.isEmpty) {
        _calculatePeriodVariation(_historicalData!);
      }
    });
    await _loadTransactions();
  }

  Future<void> _openAddTransaction({TransactionKind? initialKind}) async {
    final result = await showDialog<AssetTransaction>(
      context: context,
      builder: (_) => TransactionEditDialog(
        accountId: _currentPosition.accountId,
        symbol: _currentPosition.symbol,
        currency: _currentPosition.currency,
        // Devise de règlement = devise du compte (découplage cotation/règlement,
        // design §8). Null tant que non chargée → dialogue mono-devise.
        settlementCurrency: _accountCurrency,
        exchangeRateService: _exchangeService,
        initialKind: initialKind,
        // Fiche position : seuls les mouvements rattachés à un titre (ou un
        // frais adossé) ont leur place ici. Les mouvements d'espèces purs
        // (deposit/withdrawal/interest) se créent depuis le journal du compte
        // (cf. account_journal_page.dart), pas depuis une fiche titre.
        allowedKinds: const {
          TransactionKind.buy,
          TransactionKind.sell,
          TransactionKind.dividend,
          TransactionKind.charge,
        },
      ),
    );
    if (result == null || !mounted) return;
    // Passe par le ledger : le mouvement est journalisé ET la position
    // reprojetée atomiquement (quantité/PRU dérivés).
    await _ledger.recordTransaction(result);
    if (mounted) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.transactionSaved,
        type: SnackType.success,
      );
      await _reloadProjection();
    }
  }

  Future<void> _openEditTransaction(AssetTransaction tx) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showDialog<AssetTransaction>(
      context: context,
      builder: (_) => TransactionEditDialog(
        accountId: _currentPosition.accountId,
        symbol: _currentPosition.symbol,
        currency: _currentPosition.currency,
        settlementCurrency: _accountCurrency,
        exchangeRateService: _exchangeService,
        existing: tx,
        // Cf. _openAddTransaction : la fiche position ne crée/n'édite que des
        // mouvements rattachés au titre (ou un frais adossé).
        allowedKinds: const {
          TransactionKind.buy,
          TransactionKind.sell,
          TransactionKind.dividend,
          TransactionKind.charge,
        },
      ),
    );
    if (result == null || !mounted) return;

    // Bouton Supprimer : l'appelant peut fermer le dialog avec un sentinel
    // spécial — ici on détecte une demande de suppression via un dialog séparé.
    // (Le dialog standard retourne la transaction modifiée ; la suppression
    //  passe par le long-press / bouton Supprimer ci-dessous.)
    await _ledger.recordTransaction(result);
    if (mounted) {
      showAppSnackBar(context, l10n.transactionSaved, type: SnackType.success);
      await _reloadProjection();
    }
  }

  Future<void> _confirmDeleteTransaction(AssetTransaction tx) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.deleteTransactionConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _ledger.deleteTransaction(tx.id);
    if (mounted) {
      showAppSnackBar(
        context,
        l10n.transactionDeleted,
        type: SnackType.success,
      );
      await _reloadProjection();
    }
  }

  Future<void> _loadExchangeRate() async {
    final rate = await _exchangeService.getUsdToEurRate();
    if (mounted) {
      setState(() => _usdToEurRate = rate);
    }
  }

  Future<void> _loadCurrentPrice() async {
    final quote = await _marketService.getQuoteForAsset(_currentPosition.asset);
    if (quote != null && mounted) {
      setState(() => _currentPrice = quote.price?.toDouble());
    }
  }

  Future<void> _loadHistoricalData() async {
    setState(() {
      _isLoadingHistory = true;
      _historyError = null;
      _periodStartValue = null;
      _periodEndValue = null;
      _periodChange = null;
      _periodChangePercent = null;
    });

    try {
      if (_currentPosition.currency.toUpperCase() == 'USD') {
        await _loadExchangeRate();
      }

      final data = await _marketService.getHistoricalDataForAsset(
        _currentPosition.asset,
        days: _selectedPeriod.days,
      );

      if (data != null && !data.isEmpty) {
        _calculatePeriodVariation(data);
      }

      setState(() {
        _historicalData = data;
        _isLoadingHistory = false;
      });
    } catch (e) {
      setState(() {
        _historyError = e.toString();
        _isLoadingHistory = false;
      });
    }
  }

  void _calculatePeriodVariation(AssetHistoricalData data) {
    final quantity = double.tryParse(_quantity) ?? 0;
    final isUsd = _currentPosition.currency.toUpperCase() == 'USD';

    if (data.prices.isEmpty) return;

    double startPrice = data.prices.first.toDouble();
    double endPrice = data.prices.last.toDouble();

    if (isUsd) {
      startPrice = startPrice * _usdToEurRate;
      endPrice = endPrice * _usdToEurRate;
    }

    _periodStartValue = startPrice * quantity;
    _periodEndValue = endPrice * quantity;
    _periodChange = _periodEndValue! - _periodStartValue!;

    if (_periodStartValue! != 0) {
      _periodChangePercent = ((_periodChange! / _periodStartValue!) * 100);
    } else {
      _periodChangePercent = 0;
    }
  }

  void _onPeriodChanged(ChartPeriod period) {
    if (_selectedPeriod != period) {
      setState(() => _selectedPeriod = period);
      _loadHistoricalData();
    }
  }

  // ---------------------------------------------------------------------------
  // Actions de journal explicites sur la quantité (modèle B*)
  //
  // La quantité est en LECTURE SEULE (dérivée du journal). On ne l'édite plus
  // inline : on émet un mouvement de journal nommé, et le ledger reprojette.
  // Ces actions ne sont proposées QUE sur une position réconciliée
  // (`_derivedAt != null`) — sur une position legacy, la seule action est
  // « Réconcilier » (le delta serait calculé contre une quantité stockée ≠
  // projection).
  // ---------------------------------------------------------------------------

  /// « Ajuster la quantité… » — position réconciliée, journal NON vide.
  ///
  /// L'utilisateur saisit la quantité CONSTATÉE (cible) ; on émet un ajustement
  /// du delta signé (cible − projection courante) au PRU projeté courant, ce qui
  /// laisse le PRU invariant sur un simple recomptage. Delta nul ⇒ aucun
  /// mouvement.
  Future<void> _openAdjustQuantity() async {
    final l10n = AppLocalizations.of(context)!;
    final projected = _currentPosition.quantity;

    final outcome = await showDialog<_AdjustQuantityOutcome>(
      context: context,
      builder: (_) => _AdjustQuantityDialog(projectedQuantity: projected),
    );
    if (outcome == null || !mounted) return;

    // Nudge fiscal : l'utilisateur préfère enregistrer une vraie vente.
    if (outcome.recordSaleInstead) {
      await _openAddTransaction(initialKind: TransactionKind.sell);
      return;
    }

    // Delta signé exact (Decimal) : cible − projection courante.
    final currentQty = Decimal.tryParse(projected) ?? Decimal.zero;
    final targetQty = Decimal.tryParse(outcome.targetQuantity!) ?? currentQty;
    final delta = targetQty - currentQty;
    if (delta == Decimal.zero) return; // garde-fou (le bouton est déjà désactivé)

    try {
      await _ledger.emitAdjustment(
        accountId: _currentPosition.accountId,
        symbol: _currentPosition.symbol,
        deltaQuantity: delta.toString(),
        // PRU projeté courant : recomptage ⇒ PRU invariant.
        unitPrice: _currentPosition.averageBuyPrice?.toString(),
        currency: _currentPosition.currency,
        date: outcome.date!,
        note: outcome.note,
      );
      await _reloadProjection();
      if (mounted) {
        widget.onPositionModified?.call();
        showAppSnackBar(
          context,
          l10n.adjustmentAddedToJournal,
          type: SnackType.success,
        );
      }
    } catch (e) {
      AppLogger.error('Erreur ajustement de quantité', e);
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.modificationError,
          type: SnackType.error,
        );
      }
    }
  }

  /// « Définir la position initiale… » — position réconciliée, journal VIDE.
  ///
  /// Seule occasion de poser une base de coût (PRU optionnel). Émet un
  /// openingBalance déclaratif, souvent antidaté (date éditable).
  Future<void> _openSetInitialPosition() async {
    final l10n = AppLocalizations.of(context)!;

    final outcome = await showDialog<_InitialPositionOutcome>(
      context: context,
      builder: (_) => _InitialPositionDialog(currency: _currentPosition.currency),
    );
    if (outcome == null || !mounted) return;

    try {
      await _ledger.emitOpeningBalance(
        accountId: _currentPosition.accountId,
        symbol: _currentPosition.symbol,
        quantity: outcome.quantity,
        unitPrice: outcome.unitPrice, // peut être null (base de coût inconnue)
        currency: _currentPosition.currency,
        date: outcome.date,
        declarative: true,
        note: outcome.note,
      );
      await _reloadProjection();
      if (mounted) {
        widget.onPositionModified?.call();
        showAppSnackBar(
          context,
          l10n.initialPositionDeclared,
          type: SnackType.success,
        );
      }
    } catch (e) {
      AppLogger.error('Erreur déclaration de position initiale', e);
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.modificationError,
          type: SnackType.error,
        );
      }
    }
  }

  /// Édite le poids fin (g) ou la prime (%) d'une position métal précieux, puis
  /// recharge le prix et l'historique (la valeur dépend de ces deux champs).
  Future<void> _editMetalField({
    required String title,
    required double? current,
    required Asset Function(Asset asset, double value) apply,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: current?.toString() ?? '');

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (val) => Navigator.pop(ctx, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(l10n.save),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty || !mounted) return;

    final value = double.tryParse(result.replaceAll(',', '.'));
    if (value == null || value < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.invalidValue),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    try {
      // Métadonnée d'actif (poids/prime) : UPDATE ciblé de asset_json, jamais
      // savePosition (qui écraserait la projection quantité/PRU/derived_at — M1).
      final newAsset = apply(_currentPosition.asset, value);
      await _storage.updatePositionMetadata(
        _currentPosition.accountId,
        _currentPosition.symbol,
        asset: newAsset,
      );
      final updated = _currentPosition.copyWith(asset: newAsset);

      if (mounted) {
        setState(() => _currentPosition = updated);
        // La valeur dépend du poids/prime : on recharge cotation et historique.
        _loadCurrentPrice();
        _loadHistoricalData();
        widget.onPositionModified?.call();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.modificationSaved),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      AppLogger.error('Erreur sauvegarde champ métal', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.modificationError),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _editPositionName() async {
    final l10n = AppLocalizations.of(context)!;
    final p = _currentPosition;
    final controller = TextEditingController(text: p.displayName);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.editNameTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.assetInfo(p.asset.symbol, p.asset.type.localizedLabel(l10n)),
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: l10n.customNameHint,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (val) {
                // Si on appuie sur Entrée, on valide le nouveau nom (si non vide)
                if (val.trim().isNotEmpty) {
                  Navigator.pop(ctx, val.trim());
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx), // Annuler
            child: Text(l10n.cancel),
          ),
          // ⭐ BOUTON RÉINITIALISER : Force le nom à null
          TextButton(
            onPressed: () => Navigator.pop(ctx, '__RESET__'),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: Text(l10n.reset),
          ),
          FilledButton(
            onPressed: () {
              final val = controller.text.trim();
              if (val.isNotEmpty) {
                Navigator.pop(ctx, val);
              }
              // Si vide, on ne fait rien (reste sur le dialogue) ou on annule
              // Ici, on laisse l'utilisateur cliquer sur Réinitialiser ou Annuler
            },
            child: Text(l10n.validate),
          ),
        ],
      ),
    );

    if (result == null) return; // Annulé par l'utilisateur

    try {
      Position updatedPosition;

      // Métadonnée d'affichage : UPDATE ciblé de custom_name, jamais
      // savePosition (qui écraserait la projection quantité/PRU/derived_at — M1).
      if (result == '__RESET__') {
        // ⭐ Réinitialisation : on met customName à null (efface la colonne)
        await _storage.updatePositionMetadata(
          p.accountId,
          p.symbol,
          customName: null,
        );
        updatedPosition = p.copyWith(customName: null);
      } else {
        // ⭐ Nouveau nom
        await _storage.updatePositionMetadata(
          p.accountId,
          p.symbol,
          customName: result,
        );
        updatedPosition = p.copyWith(customName: result);
      }

      if (mounted) {
        setState(() {
          _currentPosition = updatedPosition;
        });

        widget.onPositionModified?.call();

        showAppSnackBar(
          context,
          result == '__RESET__' ? l10n.nameReset : l10n.nameModified,
          type: SnackType.success,
        );
      }
    } catch (e) {
      AppLogger.error('Erreur sauvegarde nom', e);
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.modificationError,
          type: SnackType.error,
        );
      }
    }
  }

  /// Sélecteur de type d'actif. Deux modes :
  ///  - « Automatique » : type déduit de Yahoo (`instrumentType`) et reclassable
  ///    au fil des cotations (`typeLocked=false`). Choix par défaut.
  ///  - un type explicite : fait autorité (`typeLocked=true`), jamais écrasé par
  ///    la détection auto. Seule façon d'atteindre les types non détectables
  ///    (obligation, métal, immobilier). Sélectionner « Automatique » sur une
  ///    position verrouillée la DÉVERROUILLE (reclassée au prochain refresh).
  ///
  /// NB : classer un actif en `preciousMetal` ici ne fait que changer son bucket
  /// d'allocation — cela n'active PAS le modèle pièce/lingot (poids/prime/cours
  /// de référence), gouverné par [Asset.hasMetalPricing] (présence d'un
  /// refSymbol), réservé au flux d'ajout dédié.
  Future<void> _editPositionType() async {
    final l10n = AppLocalizations.of(context)!;
    final p = _currentPosition;
    final current = p.asset.type;
    final locked = p.asset.typeLocked;
    const autoSentinel = '__auto__';

    final selected = await showDialog<Object>(
      context: context,
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        Widget option(bool checked, String label, Object value) =>
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Row(
                children: [
                  Icon(checked ? Icons.check : null, size: 20, color: primary),
                  const SizedBox(width: 12),
                  Text(label),
                ],
              ),
            );
        return SimpleDialog(
          title: Text(l10n.detailType),
          children: [
            // Coché quand la position n'est PAS verrouillée (mode auto actif).
            option(!locked, l10n.assetTypeAuto, autoSentinel),
            const Divider(),
            for (final t in AssetType.values)
              option(locked && t == current, t.localizedLabel(l10n), t),
          ],
        );
      },
    );

    if (selected == null || !mounted) return;

    // Détermine le nouvel Asset ; null = aucun changement (no-op).
    Asset? newAsset;
    if (selected == autoSentinel) {
      // Déverrouille. Pour rafraîchir l'affichage TOUT DE SUITE (sans attendre
      // le prochain refresh global), on re-dérive le type depuis la cotation.
      // Même garde que le backfill : on ne re-dérive pas un actif porteur d'un
      // cours de référence (refSymbol) — la cotation porterait le type du spot,
      // pas celui de la position ; on se contente alors de déverrouiller.
      if (locked) {
        newAsset = p.asset.copyWith(typeLocked: false);
        if (p.asset.refSymbol == null) {
          final quote = await _marketService.getQuoteWithMetadata(p.asset.symbol);
          if (!mounted) return;
          if (quote != null && quote.instrumentType != null) {
            newAsset = newAsset.copyWith(
              type: AssetType.fromYahooInstrumentType(quote.instrumentType),
            );
          }
          // Cotation indisponible / sans instrumentType : on garde le type
          // courant (déverrouillé) ; le prochain refresh réussi reclassera.
        }
      }
    } else if (selected is AssetType) {
      // Choix manuel : verrouille. No-op si déjà verrouillé sur ce type.
      if (!(locked && selected == current)) {
        newAsset = p.asset.copyWith(type: selected, typeLocked: true);
      }
    }
    if (newAsset == null) return;

    try {
      // Métadonnée d'actif : UPDATE ciblé de asset_json, jamais savePosition
      // (qui écraserait la projection quantité/PRU/derived_at — M1).
      await _storage.updatePositionMetadata(
        p.accountId,
        p.symbol,
        asset: newAsset,
      );
      final updated = p.copyWith(asset: newAsset);
      if (mounted) {
        setState(() => _currentPosition = updated);
        widget.onPositionModified?.call();
        showAppSnackBar(context, l10n.modificationSaved, type: SnackType.success);
      }
    } catch (e) {
      AppLogger.error('Erreur sauvegarde type', e);
      if (mounted) {
        showAppSnackBar(context, l10n.modificationError, type: SnackType.error);
      }
    }
  }

  /// Demande confirmation (dialogue D2 partagé, avertissant du nombre de
  /// mouvements du journal emportés) puis, si l'utilisateur confirme, dépile la
  /// page en renvoyant [PositionDetailPage.resultDeleted]. C'est AccountView
  /// qui, au retour, exécute la suppression différée avec Annuler : on ne
  /// touche pas au stockage ici (l'undo doit rester offert et son état vit dans
  /// le contrôleur du parent).
  Future<void> _confirmAndDeletePosition() async {
    final confirmed = await confirmDeletePosition(
      context: context,
      txStorage: _txStorage,
      accountId: _currentPosition.accountId,
      symbol: _currentPosition.symbol,
    );
    if (!confirmed || !mounted) return;
    Navigator.pop(context, PositionDetailPage.resultDeleted);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: _editPositionName,
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _currentPosition
                      .displayName, // ⭐ Utilise displayName (customName ou asset.name)
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.edit,
                size: 16,
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // Suppression reléguée dans un overflow ⋮ : action d'exception, hors
          // de la rangée d'icônes fréquentes (critère « fréquence » de Material,
          // pas « destructivité »). Premier PopupMenuButton de l'app — motif à
          // reprendre pour les futures actions rares (cf. audit UI/UX 13). La
          // suppression différée + Annuler reste portée par le parent : on lui
          // signale l'intention via le résultat du pop.
          PopupMenuButton<String>(
            onSelected: (_) => _confirmAndDeletePosition(),
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      l10n.deletePositionTooltip,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ResponsiveBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInfoCard(),
              const SizedBox(height: 24),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.valueEvolutionTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  _buildPeriodSelector(),
                ],
              ),
              const SizedBox(height: 16),

              if (_isLoadingHistory)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                )
              else if (_historyError != null)
                Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 48,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(height: 8),
                      Text(ErrorText.of(context, _historyError)),
                    ],
                  ),
                )
              else if (_historicalData == null || _historicalData!.isEmpty)
                Center(child: Text(l10n.noHistoricalDataAvailable))
              else
                _buildChart(),

              const SizedBox(height: 24),
              _buildTransactionsSection(),
              const SizedBox(height: 24),
              _buildJournalAnalysisSection(),
              const SizedBox(height: 24),
              _buildAdditionalDetails(),
            ],
          ),
        ),
      ),
    );
  }

  /// Icône représentant visuellement le [TransactionKind].
  IconData _kindIcon(TransactionKind k) {
    switch (k) {
      case TransactionKind.buy:
        return Icons.add_shopping_cart;
      case TransactionKind.sell:
        return Icons.sell;
      case TransactionKind.dividend:
        return Icons.payments_outlined;
      case TransactionKind.deposit:
        return Icons.arrow_downward;
      case TransactionKind.withdrawal:
        return Icons.arrow_upward;
      case TransactionKind.openingBalance:
        return Icons.flag_outlined;
      case TransactionKind.adjustment:
        return Icons.tune;
      case TransactionKind.interest:
        return Icons.savings_outlined;
      case TransactionKind.charge:
        return Icons.receipt_long_outlined;
    }
  }

  String _kindLabel(AppLocalizations l10n, TransactionKind k) {
    switch (k) {
      case TransactionKind.buy:
        return l10n.transactionKindBuy;
      case TransactionKind.sell:
        return l10n.transactionKindSell;
      case TransactionKind.dividend:
        return l10n.transactionKindDividend;
      case TransactionKind.deposit:
        return l10n.transactionKindDeposit;
      case TransactionKind.withdrawal:
        return l10n.transactionKindWithdrawal;
      case TransactionKind.openingBalance:
        return l10n.transactionKindOpeningBalance;
      case TransactionKind.adjustment:
        return l10n.transactionKindAdjustment;
      case TransactionKind.interest:
        return l10n.transactionKindInterest;
      case TransactionKind.charge:
        return l10n.transactionKindCharge;
    }
  }

  String _formatTxDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  Widget _buildTransactionsSection() {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // En-tête avec bouton +
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.transactionsSectionTitle,
                  style: theme.textTheme.titleMedium,
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: l10n.addTransaction,
                  onPressed: _openAddTransaction,
                ),
              ],
            ),
            const Divider(height: 16),

            // Corps : chargement / vide / liste
            if (_isLoadingTransactions)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_transactions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    l10n.noTransactionsYet,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              )
            else
              ...(_transactions.map(
                (tx) => _buildTransactionTile(tx, l10n, theme),
              )),
          ],
        ),
      ),
    );
  }

  Widget _buildTransactionTile(
    AssetTransaction tx,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final amountVal = tx.amount != null ? double.tryParse(tx.amount!) : null;
    final isInflow = amountVal != null && amountVal >= 0;
    final amountColor = AppColors.gainLoss(context, isInflow);

    String amountLabel;
    if (amountVal != null) {
      final sign = amountVal >= 0 ? '+' : '';
      // `amount` est l'effet net sur les espèces, dans la devise de RÈGLEMENT
      // (`settlementCurrency ?? currency`), pas de cotation — sinon on afficherait
      // une valeur EUR avec un symbole $ pour un titre US réglé en euros.
      final settlement = tx.settlementCurrency ?? tx.currency;
      amountLabel = '$sign${Formatters.formatMoney(amountVal, settlement)}';
    } else {
      amountLabel = l10n.notAvailable;
    }

    String subtitle;
    if (tx.quantity != null && tx.unitPrice != null) {
      subtitle = '${tx.quantity} × ${tx.unitPrice} ${tx.currency}';
    } else {
      subtitle = _kindLabel(l10n, tx.kind);
    }

    return InkWell(
      onTap: () => _openEditTransaction(tx),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            // Icône kind
            CircleAvatar(
              radius: 16,
              backgroundColor: amountColor.withValues(alpha: 0.12),
              child: Icon(_kindIcon(tx.kind), size: 16, color: amountColor),
            ),
            const SizedBox(width: 12),
            // Date + détail
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatTxDate(tx.date),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(subtitle, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
            // Montant coloré
            Text(
              amountLabel,
              style: TextStyle(color: amountColor, fontWeight: FontWeight.w600),
            ),
            // Bouton supprimer
            IconButton(
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              tooltip: l10n.deleteTooltip,
              onPressed: () => _confirmDeleteTransaction(tx),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodSelector() {
    // Widget partagé avec WalletView et AccountView : chips non sélectionnés
    // sans fond (défaut Material 3), seul l'actif rempli en primary.
    return PeriodSelector(
      selectedPeriod: _selectedPeriod,
      onSelected: _onPeriodChanged,
      height: 32,
      selectedLabelBold: true,
      chipPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    );
  }

  Widget _buildInfoCard() {
    final l10n = AppLocalizations.of(context)!;
    final position = _currentPosition;
    final isUsd = position.currency.toUpperCase() == 'USD';
    final isPositive = _periodChange != null ? _periodChange! >= 0 : true;
    final changeColor = AppColors.gainLoss(context, isPositive);
    // Couleur d'identité de l'avatar : stable (dérivée du symbole), indépendante
    // de la performance — contrairement à changeColor utilisé ailleurs sur cette carte.
    final avatarColor = AppColors.avatarColor(position.symbol);

    final currentPrice = _currentPrice ?? 0;
    final qtyNum = double.tryParse(_quantity) ?? 0;
    double totalValueEur = currentPrice * qtyNum;
    if (isUsd) {
      totalValueEur = totalValueEur * _usdToEurRate;
    }

    // ⭐ PLUS-VALUE LATENTE (uniquement si un PRU est défini)
    final pru = position.averageBuyPrice;
    final hasPru = pru != null;
    // Calculs en devise native puis conversion EUR comme le reste de l'UI.
    double? unrealizedGainEur;
    double? unrealizedGainPercent;
    if (hasPru && _currentPrice != null) {
      final gainNative = (_currentPrice! - pru) * qtyNum;
      unrealizedGainEur = isUsd ? gainNative * _usdToEurRate : gainNative;
      if (pru != 0) {
        unrealizedGainPercent = (_currentPrice! - pru) / pru * 100;
      }
    }
    final gainPositive = (unrealizedGainEur ?? 0) >= 0;
    final gainColor = AppColors.gainLoss(context, gainPositive);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: avatarColor.withValues(alpha: 0.12),
                  child: Text(
                    position.symbol.substring(0, 1),
                    style: TextStyle(
                      color: avatarColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        position.asset.displayName,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (position.asset.name != position.symbol)
                        Text(
                          '(${position.symbol})',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),

            // Badge « Non réconcilié » + action de réconciliation : affiché
            // uniquement pour une position legacy (derived_at NULL — quantité/PRU
            // saisis, jamais dérivés d'un journal).
            if (_derivedAt == null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.sync_problem_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l10n.positionUnreconciledBadge,
                          style: TextStyle(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _reconcilePosition,
                    icon: const Icon(Icons.sync, size: 16),
                    label: Text(l10n.reconcilePosition),
                  ),
                ],
              ),
            ],

            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: _buildInfoItem(
                    l10n.unitPrice,
                    _formatPriceDisplay(currentPrice, isUsd),
                  ),
                ),
                // Quantité en LECTURE SEULE (dérivée du journal). Un tap ouvre
                // une info-bulle pédagogique — aucune édition inline.
                Flexible(
                  child: _buildQuantityInfoItem(l10n),
                ),
                Flexible(
                  child: _buildInfoItem(
                    l10n.totalValueAccount,
                    Formatters.formatEur(totalValueEur),
                  ),
                ),
              ],
            ),

            // Action de journal explicite sur la quantité. Masquée tant que la
            // position n'est pas réconciliée (`_derivedAt == null`) : le seul
            // recours est alors le bouton « Réconcilier » ci-dessus. Masquée
            // aussi pendant le chargement du journal : le choix ajuster/définir
            // dépend de `_transactions` (vide ⇒ définir), qu'on ne veut pas
            // trancher sur une liste encore incomplète.
            if (_derivedAt != null && !_isLoadingTransactions) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: _transactions.isEmpty
                    ? TextButton.icon(
                        onPressed: _openSetInitialPosition,
                        icon: const Icon(Icons.flag_outlined, size: 16),
                        label: Text(l10n.setInitialPositionAction),
                      )
                    : TextButton.icon(
                        onPressed: _openAdjustQuantity,
                        icon: const Icon(Icons.tune, size: 16),
                        label: Text(l10n.adjustQuantityAction),
                      ),
              ),
            ],
            const SizedBox(height: 12),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: changeColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: changeColor.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isPositive ? Icons.trending_up : Icons.trending_down,
                        color: changeColor,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.variationOverPeriod(
                            _selectedPeriod.localizedLabel(l10n)),
                        style: TextStyle(
                          color: changeColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.startValue(
                                _periodStartValue != null
                                    ? Formatters.formatEur(_periodStartValue!)
                                    : l10n.notAvailable,
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.endValue(
                                _periodEndValue != null
                                    ? Formatters.formatEur(_periodEndValue!)
                                    : l10n.notAvailable,
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            _periodChange != null
                                ? Formatters.formatEurSigned(_periodChange!)
                                : l10n.notAvailable,
                            style: TextStyle(
                              color: changeColor,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _periodChangePercent != null
                                ? Formatters.formatPercentFr(
                                    _periodChangePercent!,
                                  )
                                : l10n.notAvailable,
                            style: TextStyle(
                              color: changeColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ⭐ BLOC PLUS-VALUE LATENTE (uniquement si PRU défini)
            if (hasPru) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: gainColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: gainColor.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          gainPositive
                              ? Icons.trending_up
                              : Icons.trending_down,
                          color: gainColor,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          l10n.unrealizedGain,
                          style: TextStyle(
                            color: gainColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          l10n.averageBuyPriceShort(
                            _formatPriceDisplay(pru, isUsd),
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              unrealizedGainEur != null
                                  ? Formatters.formatEurSigned(
                                      unrealizedGainEur,
                                    )
                                  : l10n.notAvailable,
                              style: TextStyle(
                                color: gainColor,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              unrealizedGainPercent != null
                                  ? Formatters.formatPercentFr(
                                      unrealizedGainPercent,
                                    )
                                  : l10n.notAvailable,
                              style: TextStyle(
                                color: gainColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Quantité en LECTURE SEULE (dérivée du journal). Présentée comme les autres
  /// infos (pas d'affordance d'édition, pas d'icône crayon). Un tap sur la
  /// valeur ouvre une info-bulle pédagogique « Dérivé du journal (N mouvements) »
  /// — aucune édition. L'édition passe désormais par une action de journal
  /// nommée (ajuster / définir la position initiale).
  Widget _buildQuantityInfoItem(AppLocalizations l10n) {
    return Tooltip(
      message: l10n.derivedFromJournal(_transactions.length),
      triggerMode: TooltipTriggerMode.tap,
      child: _buildInfoItem(l10n.quantityLabel, _quantity),
    );
  }

  String _formatPriceDisplay(double price, bool isUsd) {
    if (isUsd) {
      return Formatters.formatCurrencyWithConversion(
        price,
        'USD',
        _usdToEurRate,
      );
    }
    return Formatters.formatEur(price);
  }

  Widget _buildInfoItem(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ],
    );
  }

  Widget _buildChart() {
    if (_historicalData == null) return const SizedBox.shrink();

    final data = _historicalData!;
    final quantity = double.tryParse(_quantity) ?? 0;
    final isUsd = _currentPosition.currency.toUpperCase() == 'USD';

    // Valeur totale de la ligne = prix (converti si USD) × quantité, alignée
    // sur data.dates (séries parallèles).
    final totalValues = data.prices.map((price) {
      final convertedPrice = isUsd
          ? price.toDouble() * _usdToEurRate
          : price.toDouble();
      return convertedPrice * quantity;
    }).toList();

    final chartHeight = data.prices.length > 200
        ? 350.0
        : (data.prices.length > 100 ? 300.0 : 250.0);

    // Graphe partagé avec WalletView et AccountView : même rendu d'axes
    // (graduations Y « nice », labels X temps-based, tooltip année > 1 an),
    // même adaptation aux thèmes clair/sombre.
    return ValuationLineChart(
      dates: data.dates,
      values: totalValues,
      selectedPeriod: _selectedPeriod,
      periodChange: _periodChange,
      height: chartHeight,
      leftTitlesReservedSize: 50,
      barWidth: 2,
      showSnapshotLegend: false,
    );
  }

  // ---------------------------------------------------------------------------
  // Section : analyse du journal (plus-value réalisée dérivée du journal)
  // ---------------------------------------------------------------------------

  /// Réconcilie une position legacy (derived_at NULL) depuis son état courant
  /// ou son journal (flux D3), après confirmation.
  ///
  ///   - journal VIDE  ⇒ emitOpeningBalance(quantité + PRU courants, declarative)
  ///   - journal NON VIDE ⇒ adoption du journal (reprojection) SANS
  ///     openingBalance, pour ne pas double-compter.
  Future<void> _reconcilePosition() async {
    final l10n = AppLocalizations.of(context)!;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.reconcileConfirmTitle),
        content: Text(l10n.reconcileConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.validate),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final accountId = _currentPosition.accountId;
    final symbol = _currentPosition.symbol;

    try {
      final journal = await _txStorage.getBySymbol(accountId, symbol);
      if (journal.isEmpty) {
        // D3 (journal vide) : la quantité/PRU legacy deviennent une position
        // initiale déclarative.
        await _ledger.emitOpeningBalance(
          accountId: accountId,
          symbol: symbol,
          quantity: _currentPosition.quantity,
          unitPrice: _currentPosition.averageBuyPrice?.toString(),
          currency: _currentPosition.currency,
          date: DateTime.now(),
          declarative: true,
        );
      } else {
        // D3 (journal non vide) : adoption — le ledger reprojette et pose
        // derived_at, SANS émettre d'openingBalance (évite le double comptage).
        await _ledger.reconcileFromJournal(accountId, symbol);
      }

      await _reloadProjection();
      if (mounted) {
        widget.onPositionModified?.call();
        showAppSnackBar(context, l10n.modificationSaved, type: SnackType.success);
      }
    } catch (e) {
      AppLogger.error('Erreur réconciliation position', e);
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.modificationError,
          type: SnackType.error,
        );
      }
    }
  }

  /// Carte d'analyse du journal : plus-value réalisée dérivée + disclaimer.
  ///
  /// Retourne [SizedBox.shrink] si le journal est vide ou si l'analyse n'est
  /// pas encore disponible. Le PRU n'est plus présenté ici (dérivé, affiché
  /// avec la position) — plus de comparaison « suggéré vs manuel ».
  Widget _buildJournalAnalysisSection() {
    if (_transactions.isEmpty) return const SizedBox.shrink();
    final analytics = _analytics;
    if (analytics == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final currency = _currentPosition.currency;

    final realizedGain = analytics.realizedGain;
    final realizedFormatted = Formatters.formatCurrency(realizedGain, currency);
    final gainColor = AppColors.gainLoss(context, realizedGain >= 0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.journalAnalysisTitle, style: theme.textTheme.titleMedium),
            const Divider(height: 16),

            // Plus-value réalisée, colorée vert/rouge
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                l10n.realizedGainLabel(realizedFormatted),
                style: TextStyle(color: gainColor, fontWeight: FontWeight.w600),
              ),
            ),

            const SizedBox(height: 8),

            // Légende courte (disclaimer)
            Text(
              l10n.journalAnalysisCaption,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdditionalDetails() {
    final l10n = AppLocalizations.of(context)!;
    final position = _currentPosition;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.additionalDetails,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Divider(height: 24),
            _buildDetailRow(l10n.detailSymbol, position.symbol),
            // Type éditable : l'auto-détection (Yahoo) ne couvre ni obligation,
            // ni métal, ni immobilier ; le choix manuel prime et se verrouille
            // (typeLocked) pour ne pas être écrasé au prochain rafraîchissement.
            _buildEditableDetailRow(
              l10n.detailType,
              position.asset.type.localizedLabel(l10n),
              _editPositionType,
            ),
            _buildDetailRow(l10n.detailCurrency, position.currency),
            if (position.asset.exchange != null)
              _buildDetailRow(l10n.detailExchange, position.asset.exchange!),
            // ⭐ Métaux précieux : poids fin et prime éditables (la valeur en
            // dépend). Gate sur hasMetalPricing (présence d'un cours de
            // référence), PAS sur le seul type : un actif classé « métal » à la
            // main sans modèle pièce/lingot (override de bucket) n'a pas de
            // poids/prime à éditer et n'est pas pricé comme un métal.
            if (position.asset.hasMetalPricing) ...[
              _buildEditableDetailRow(
                l10n.fineWeightLabel,
                position.asset.fineWeightGrams != null
                    ? '${position.asset.fineWeightGrams} g'
                    : l10n.undefined,
                () => _editMetalField(
                  title: l10n.fineWeightLabel,
                  current: position.asset.fineWeightGrams,
                  apply: (asset, value) =>
                      asset.copyWith(fineWeightGrams: value),
                ),
              ),
              _buildEditableDetailRow(
                l10n.premiumLabel,
                '${position.asset.premiumPercent ?? 0} %',
                () => _editMetalField(
                  title: l10n.premiumLabel,
                  current: position.asset.premiumPercent,
                  apply: (asset, value) =>
                      asset.copyWith(premiumPercent: value),
                ),
              ),
            ],
            // PRU en LECTURE SEULE (D1) : dérivé du journal, non éditable.
            _buildDetailRow(
              l10n.averageBuyPriceDetail,
              position.averageBuyPrice != null
                  ? Formatters.formatCurrency(
                      position.averageBuyPrice!,
                      position.currency,
                    )
                  : l10n.undefined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value),
        ],
      ),
    );
  }

  // ⭐ NOUVEAU : ligne de détail cliquable (édition)
  Widget _buildEditableDetailRow(
    String label,
    String value,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.edit,
                  size: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Dialogue « Ajuster la quantité » (position réconciliée, journal NON vide)
// =============================================================================

/// Résultat du dialogue d'ajustement de quantité.
///
/// Deux issues possibles :
///   - [recordSaleInstead] == true : l'utilisateur a suivi le nudge fiscal et
///     veut enregistrer une VRAIE vente (les autres champs sont null).
///   - sinon : ajustement demandé — [targetQuantity] (cible normalisée,
///     point décimal), [date] et [note] optionnelle sont fournis.
class _AdjustQuantityOutcome {
  final bool recordSaleInstead;
  final String? targetQuantity;
  final DateTime? date;
  final String? note;

  const _AdjustQuantityOutcome.adjust(this.targetQuantity, this.date, this.note)
      : recordSaleInstead = false;

  const _AdjustQuantityOutcome.recordSale()
      : recordSaleInstead = true,
        targetQuantity = null,
        date = null,
        note = null;
}

class _AdjustQuantityDialog extends StatefulWidget {
  /// Quantité PROJETÉE courante (String canonique, dérivée du journal).
  final String projectedQuantity;

  const _AdjustQuantityDialog({required this.projectedQuantity});

  @override
  State<_AdjustQuantityDialog> createState() => _AdjustQuantityDialogState();
}

class _AdjustQuantityDialogState extends State<_AdjustQuantityDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _targetCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _targetCtrl = TextEditingController(text: widget.projectedQuantity);
    _noteCtrl = TextEditingController();
    _date = DateTime.now();
  }

  @override
  void dispose() {
    _targetCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  /// Delta signé exact (cible − projection), ou null si la cible est invalide.
  Decimal? get _delta {
    final target = Decimal.tryParse(_targetCtrl.text.trim().replaceAll(',', '.'));
    if (target == null) return null;
    final projected =
        Decimal.tryParse(widget.projectedQuantity) ?? Decimal.zero;
    return target - projected;
  }

  String _formatDelta(Decimal delta) =>
      delta > Decimal.zero ? '+$delta' : delta.toString();

  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final delta = _delta;
    final canSubmit = delta != null && delta != Decimal.zero;

    return AlertDialog(
      title: Text(l10n.adjustQuantityTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Quantité projetée (lecture seule).
                Text(
                  l10n.projectedQuantityLabel(widget.projectedQuantity),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),

                // Quantité constatée (cible saisie par l'utilisateur).
                TextFormField(
                  controller: _targetCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.observedQuantityLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),

                // Aperçu du delta en direct.
                if (delta != null && delta != Decimal.zero)
                  Text(
                    l10n.adjustmentDeltaPreview(
                      _formatDelta(delta),
                      _formatDate(_date),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),

                // Nudge fiscal, dépendant du sens du delta.
                if (delta != null && delta < Decimal.zero) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.adjustmentSellNudge,
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => Navigator.of(context).pop(
                              const _AdjustQuantityOutcome.recordSale(),
                            ),
                            icon: const Icon(Icons.sell, size: 16),
                            label: Text(l10n.recordSaleInstead),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (delta != null && delta > Decimal.zero) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.adjustmentBuyNudge,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 12),

                // Date (défaut aujourd'hui).
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.transactionDate,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: const Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(_formatDate(_date)),
                  ),
                ),
                const SizedBox(height: 12),

                // Note optionnelle.
                TextFormField(
                  controller: _noteCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.optionalNoteLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: canSubmit
              ? () {
                  final note = _noteCtrl.text.trim();
                  Navigator.of(context).pop(
                    _AdjustQuantityOutcome.adjust(
                      _targetCtrl.text.trim().replaceAll(',', '.'),
                      _date,
                      note.isEmpty ? null : note,
                    ),
                  );
                }
              : null,
          child: Text(l10n.addAdjustmentButton),
        ),
      ],
    );
  }
}

// =============================================================================
// Dialogue « Définir la position initiale » (position réconciliée, journal VIDE)
// =============================================================================

/// Résultat du dialogue de position initiale : quantité (normalisée), PRU
/// optionnel (null = base de coût inconnue), date et note optionnelle.
class _InitialPositionOutcome {
  final String quantity;
  final String? unitPrice;
  final DateTime date;
  final String? note;

  const _InitialPositionOutcome({
    required this.quantity,
    required this.unitPrice,
    required this.date,
    required this.note,
  });
}

class _InitialPositionDialog extends StatefulWidget {
  final String currency;

  const _InitialPositionDialog({required this.currency});

  @override
  State<_InitialPositionDialog> createState() => _InitialPositionDialogState();
}

class _InitialPositionDialogState extends State<_InitialPositionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _qtyCtrl;
  late final TextEditingController _pruCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController();
    _pruCtrl = TextEditingController();
    _noteCtrl = TextEditingController();
    _date = DateTime.now();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _pruCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  String _formatDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final pru = _pruCtrl.text.trim();
    final note = _noteCtrl.text.trim();
    Navigator.of(context).pop(
      _InitialPositionOutcome(
        quantity: _qtyCtrl.text.trim().replaceAll(',', '.'),
        unitPrice: pru.isEmpty ? null : pru.replaceAll(',', '.'),
        date: _date,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.setInitialPositionTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Quantité (requise, > 0).
                TextFormField(
                  controller: _qtyCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.quantityLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final t = (v ?? '').trim().replaceAll(',', '.');
                    final n = double.tryParse(t);
                    if (n == null || n <= 0) return l10n.invalidQuantity;
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // PRU OPTIONNEL (seule occasion de poser une base de coût).
                TextFormField(
                  controller: _pruCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.averageBuyPriceLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                    helperText: l10n.optionalHint,
                    suffixText:
                        Formatters.formatCurrencySymbol(widget.currency),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null; // PRU facultatif
                    if (double.tryParse(t.replaceAll(',', '.')) == null) {
                      return l10n.invalidValue;
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // Date éditable (une position initiale est souvent antidatée).
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.transactionDate,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: const Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(_formatDate(_date)),
                  ),
                ),
                const SizedBox(height: 12),

                // Note optionnelle.
                TextFormField(
                  controller: _noteCtrl,
                  decoration: InputDecoration(
                    labelText: l10n.optionalNoteLabel,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.validate),
        ),
      ],
    );
  }
}

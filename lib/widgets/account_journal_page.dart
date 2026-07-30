// lib/widgets/account_journal_page.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';
import 'package:portfolio_tracker/utils/error_text.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/common/empty_state.dart';
import 'package:portfolio_tracker/widgets/common/help_dialog.dart';
import 'package:portfolio_tracker/widgets/common/responsive_body.dart';
import 'package:portfolio_tracker/widgets/position_detail_page.dart';
import 'package:portfolio_tracker/widgets/transaction_edit_dialog.dart';

// ---------------------------------------------------------------------------
// Fonction pure de filtrage — testable sans framework
// ---------------------------------------------------------------------------

/// Filtre [txs] selon un type ([kind]) et/ou une borne basse de date ([notBefore]).
///
/// - Si [kind] est null, aucun filtre sur le type.
/// - Si [notBefore] est null, aucune borne basse sur la date.
/// - Les transactions exactement à la date [notBefore] sont incluses.
/// - L'ordre d'entrée est préservé.
List<AssetTransaction> filterJournal(
  List<AssetTransaction> txs, {
  TransactionKind? kind,
  DateTime? notBefore,
}) {
  return txs.where((tx) {
    final kindOk = kind == null || tx.kind == kind;
    final dateOk = notBefore == null || !tx.date.isBefore(notBefore);
    return kindOk && dateOk;
  }).toList();
}

// ---------------------------------------------------------------------------
// Presets de période
// ---------------------------------------------------------------------------

enum _PeriodPreset { all, days30, days90, year1 }

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

class AccountJournalPage extends StatefulWidget {
  final String accountId;
  final String accountName;

  /// Réservés aux tests : permettent d'injecter des fakes (storage/ledger) sans
  /// ouvrir de base SQLite réelle dans un `testWidgets` — ouvrir/fermer une base
  /// réelle dans la zone à horloge factice d'un test widget est connu pour
  /// bloquer indéfiniment (cf. account_view_test.dart, statement_import_page_
  /// test.dart). `null` en production : chaque service retombe alors sur sa
  /// connexion par défaut (comportement inchangé).
  @visibleForTesting
  final TransactionStorage? debugTransactionStorage;
  @visibleForTesting
  final AccountStorage? debugAccountStorage;
  @visibleForTesting
  final LedgerService? debugLedgerService;

  const AccountJournalPage({
    super.key,
    required this.accountId,
    required this.accountName,
    this.debugTransactionStorage,
    this.debugAccountStorage,
    this.debugLedgerService,
  });

  @override
  State<AccountJournalPage> createState() => _AccountJournalPageState();
}

class _AccountJournalPageState extends State<AccountJournalPage> {
  late final TransactionStorage _txStorage =
      widget.debugTransactionStorage ?? TransactionStorage();
  late final AccountStorage _accountStorage =
      widget.debugAccountStorage ?? AccountStorage();
  late final LedgerService _ledger =
      widget.debugLedgerService ?? LedgerService();

  List<AssetTransaction> _all = [];
  bool _isLoading = true;
  String? _error;

  TransactionKind? _kindFilter;
  _PeriodPreset _periodFilter = _PeriodPreset.all;

  /// Devise DU COMPTE, requise pour créer un mouvement d'espèces (mono-devise
  /// stricte ici : pas de titre, donc pas de règlement croisé — cf.
  /// [_openAddCashTransaction]). Best-effort : tant que non chargée (ou en cas
  /// d'échec), le bouton d'ajout reste désactivé (cf. build()).
  String? _accountCurrency;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAccountCurrency();
  }

  /// Charge la devise du compte pour la création de mouvements d'espèces.
  Future<void> _loadAccountCurrency() async {
    final account = await _accountStorage.getAccount(widget.accountId);
    if (mounted) setState(() => _accountCurrency = account?.currency);
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final txs = await _txStorage.getByAccount(widget.accountId);
      if (mounted) {
        setState(() {
          _all = txs;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  // Calcule la borne basse selon le preset sélectionné.
  DateTime? _cutoff() {
    final now = DateTime.now();
    switch (_periodFilter) {
      case _PeriodPreset.all:
        return null;
      case _PeriodPreset.days30:
        return now.subtract(const Duration(days: 30));
      case _PeriodPreset.days90:
        return now.subtract(const Duration(days: 90));
      case _PeriodPreset.year1:
        return now.subtract(const Duration(days: 365));
    }
  }

  List<AssetTransaction> get _filtered =>
      filterJournal(_all, kind: _kindFilter, notBefore: _cutoff());

  // ---------------------------------------------------------------------------
  // Helpers d'affichage (calqués sur position_detail_page.dart)
  // ---------------------------------------------------------------------------

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
      case TransactionKind.transferOut:
        return Icons.swap_horiz;
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
      case TransactionKind.transferOut:
        return l10n.transactionKindTransferOut;
    }
  }

  /// Libellé d'une ligne : la NATURE de l'opération sur titre quand l'import
  /// l'a conservée (`meta['corporateAction']`), sinon le kind seul.
  ///
  /// Motif (retour auteur, « pourquoi je vois des ajustements ? ») : `adjustment`
  /// recouvre une attribution GRATUITE, un CHANGEMENT DE PLACE et une
  /// RÉGULARISATION PEA — trois choses sans rapport. Affiché « Ajustement », ça
  /// se lit comme une correction douteuse alors que la ligne est légitime.
  ///
  /// Purement cosmétique : un `meta` absent (mouvement saisi à la main, ou
  /// importé AVANT que cette clé existe) retombe simplement sur le kind — aucun
  /// calcul n'en dépend, et un nom d'enum inconnu (backup d'une version future)
  /// est ignoré plutôt que de faire échouer l'affichage.
  String _txNatureLabel(AppLocalizations l10n, AssetTransaction tx) {
    final raw = tx.meta?['corporateAction'];
    if (raw is String) {
      switch (raw) {
        case 'freeAttribution':
          return l10n.corporateActionFreeAttribution;
        case 'placeChange':
          return l10n.corporateActionPlaceChange;
        case 'cashRegularization':
          return l10n.corporateActionCashRegularization;
        case 'fractionalRedemption':
          return l10n.corporateActionFractionalRedemption;
        case 'transferOut':
          break; // le kind transferOut est déjà explicite
      }
    }
    return _kindLabel(l10n, tx.kind);
  }

  String _formatTxDate(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';

  // ---------------------------------------------------------------------------
  // Création d'un mouvement d'espèces (le journal est le seul point d'entrée
  // pour deposit/withdrawal/interest/charge : ces mouvements ne sont pas
  // rattachés à un titre, cf. position_detail_page.dart pour buy/sell/dividend).
  // ---------------------------------------------------------------------------

  Future<void> _openAddCashTransaction() async {
    final l10n = AppLocalizations.of(context)!;
    final currency = _accountCurrency;
    if (currency == null) return; // bouton désactivé tant que non chargée

    final result = await showDialog<AssetTransaction>(
      context: context,
      builder: (_) => TransactionEditDialog(
        accountId: widget.accountId,
        symbol: null,
        currency: currency,
        // Mono-devise stricte : pas de titre ici, donc pas de règlement
        // croisé possible (cf. doc [TransactionEditDialog.settlementCurrency]).
        settlementCurrency: null,
        allowedKinds: const {
          TransactionKind.deposit,
          TransactionKind.withdrawal,
          TransactionKind.interest,
          TransactionKind.charge,
        },
      ),
    );
    if (result == null || !mounted) return;

    // JAMAIS d'insert direct : le ledger journalise ET reprojette le cash
    // atomiquement (même garde-fou que position_detail_page._openAddTransaction).
    await _ledger.recordTransaction(result);
    if (mounted) {
      showAppSnackBar(context, l10n.transactionSaved, type: SnackType.success);
      await _load();
    }
  }

  // ---------------------------------------------------------------------------
  // Édition / suppression d'un mouvement d'espèces (calqué sur
  // position_detail_page.dart, mêmes garde-fous). RÉSERVÉ aux mouvements
  // SAISIS À LA MAIN (!isSystemGenerated, cf. _buildTile) : un openingBalance
  // /adjustment/transferOut reste en LECTURE SEULE dans ce journal — ces kinds
  // portent une sémantique câblée ailleurs (ancrage cash, PRU) qu'un dialogue
  // générique casserait s'il les rendait éditables ici.
  // ---------------------------------------------------------------------------

  Future<void> _openEditTransaction(AssetTransaction tx) async {
    final l10n = AppLocalizations.of(context)!;
    final currency = _accountCurrency;
    if (currency == null) return; // devise du compte pas encore chargée

    final result = await showDialog<AssetTransaction>(
      context: context,
      builder: (_) => TransactionEditDialog(
        accountId: widget.accountId,
        symbol: null,
        currency: currency,
        // Mono-devise stricte (cf. _openAddCashTransaction).
        settlementCurrency: null,
        existing: tx,
        allowedKinds: const {
          TransactionKind.deposit,
          TransactionKind.withdrawal,
          TransactionKind.interest,
          TransactionKind.charge,
        },
      ),
    );
    if (result == null || !mounted) return;

    // JAMAIS d'insert direct (même garde-fou que _openAddCashTransaction).
    await _ledger.recordTransaction(result);
    if (mounted) {
      showAppSnackBar(context, l10n.transactionSaved, type: SnackType.success);
      await _load();
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
      await _load();
    }
  }

  // ---------------------------------------------------------------------------
  // Navigation vers la fiche position (foyer d'édition d'un mouvement TITRE).
  //
  // Un mouvement rattaché à un titre (`symbol != null` : buy/sell/dividend, ou
  // une jambe titre système) ne s'édite PAS ici — le dialogue de ce journal
  // force `symbol: null` et le transformerait en espèces pures. Sa fiche
  // position porte le dialogue titre complet (quantité × prix, frais,
  // reprojection du PRU). On y navigue donc plutôt que de laisser un tap mort.
  // ---------------------------------------------------------------------------

  Future<void> _openPositionForSymbol(String symbol) async {
    final l10n = AppLocalizations.of(context)!;
    final positions = await _accountStorage.getPositions(widget.accountId);
    if (!mounted) return;
    final position = positions.cast<Position?>().firstWhere(
          (p) => p?.symbol == symbol,
          orElse: () => null,
        );
    // Titre SOLDÉ (aucune position résiduelle) : rien à ouvrir. On explique au
    // lieu de laisser croire à un bug — le mouvement reste consultable ici.
    if (position == null) {
      showHelpDialog(
        context,
        title: l10n.journalTitleLineTitle,
        body: l10n.journalSoldTitleBody,
      );
      return;
    }
    await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => PositionDetailPage(position: position),
      ),
    );
    if (mounted) await _load();
  }

  // Ligne SYSTÈME espèces (openingBalance/adjustment/transferOut, `symbol` null)
  // : lecture seule — sémantique câblée ailleurs (ancre de trésorerie, jambe
  // d'OST) qu'un dialogue générique casserait. Un tap explique le pourquoi au
  // lieu de rester inerte (le vrai défaut relevé : un tap mort sans raison).
  void _showSystemLineHelp() {
    final l10n = AppLocalizations.of(context)!;
    showHelpDialog(
      context,
      title: l10n.journalSystemLineTitle,
      body: l10n.journalSystemLineBody,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.journalPageTitle(widget.accountName),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: l10n.backTooltip,
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: l10n.addCashTransaction,
            onPressed: _accountCurrency == null ? null : _openAddCashTransaction,
          ),
        ],
      ),
      body: _buildBody(l10n),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 8),
            Text(ErrorText.of(context, _error)),
          ],
        ),
      );
    }
    return ResponsiveBody(
      child: Column(
        children: [
          _buildFilters(l10n),
          const Divider(height: 1),
          Expanded(child: _buildList(l10n)),
        ],
      ),
    );
  }

  Widget _buildFilters(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Filtre par type ---
          // `Wrap` et NON un défilement horizontal : celui-ci coupait le
          // dernier type au bord (« Frais » tronqué sur desktop, rien de
          // visible après « Dépôt » sur 360 dp) sans aucune affordance de
          // balayage — des filtres existants restaient donc introuvables.
          // Un passage à la ligne coûte quelques dp de hauteur et rend les
          // huit choix visibles d'un coup, à un tap.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _kindChip(l10n, null, l10n.filterAllKinds),
              // Les mouvements système (openingBalance/adjustment) ne sont
              // pas proposés au filtre : ils restent visibles via « tous ».
              ...TransactionKind.values
                  .where((k) => !k.isSystemGenerated)
                  .map((k) => _kindChip(l10n, k, _kindLabel(l10n, k))),
            ],
          ),
          const SizedBox(height: 6),
          // --- Filtre par période ---
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _PeriodPreset.values.map((p) {
              final selected = _periodFilter == p;
              return ChoiceChip(
                label: Text(_periodLabel(l10n, p)),
                selected: selected,
                onSelected: (_) => setState(() => _periodFilter = p),
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: selected
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _kindChip(AppLocalizations l10n, TransactionKind? k, String label) {
    final selected = _kindFilter == k;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _kindFilter = k),
      selectedColor: Theme.of(context).colorScheme.primary,
      labelStyle: TextStyle(
        fontSize: 12,
        color: selected
            ? Theme.of(context).colorScheme.onPrimary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  String _periodLabel(AppLocalizations l10n, _PeriodPreset p) {
    switch (p) {
      case _PeriodPreset.all:
        return l10n.periodAll;
      case _PeriodPreset.days30:
        return l10n.period30Days;
      case _PeriodPreset.days90:
        return l10n.period90Days;
      case _PeriodPreset.year1:
        return l10n.period1Year;
    }
  }

  Widget _buildList(AppLocalizations l10n) {
    final items = _filtered;
    if (items.isEmpty) {
      return EmptyState(
        icon: Icons.receipt_long_outlined,
        title: _all.isEmpty
            ? l10n.noTransactionsYet
            : l10n.noJournalEntriesForFilter,
      );
    }
    final theme = Theme.of(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (context, i) => const Divider(height: 1, indent: 56),
      itemBuilder: (_, i) => _buildTile(items[i], l10n, theme),
    );
  }

  Widget _buildTile(
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
      // `amount` = effet net sur les espèces, dans la devise de RÈGLEMENT
      // (`settlementCurrency ?? currency`), pas de cotation (cf. position_detail_page).
      final settlement = tx.settlementCurrency ?? tx.currency;
      amountLabel = '$sign${Formatters.formatCurrency(amountVal, settlement)}';
    } else {
      amountLabel = l10n.notAvailable;
    }

    // Ligne symbole / libellé cash
    final symbolLabel = tx.symbol ?? l10n.cashLabel;

    // Sous-titre : la NATURE de l'opération d'abord quand l'import l'a
    // conservée, car « qty × prix » la masquait au pire moment — une attribution
    // gratuite s'affichait « 89 × 0 EUR » et un changement de place « 0 × 0 »,
    // deux lignes indéchiffrables. Les chiffres restent appondus quand ils
    // portent une information (rachat de rompus). Sans nature connue :
    // comportement d'origine inchangé (qty × prix, sinon le kind).
    final hasQtyPrice = tx.quantity != null && tx.unitPrice != null;
    final qtyPrice = '${tx.quantity} × ${tx.unitPrice} ${tx.currency}';
    final nature = _txNatureLabel(l10n, tx);
    final String subtitle;
    if (tx.meta?['corporateAction'] is String) {
      final meaningfulNumbers = hasQtyPrice &&
          (double.tryParse(tx.quantity!) ?? 0) != 0 &&
          (double.tryParse(tx.unitPrice!) ?? 0) != 0;
      subtitle = meaningfulNumbers ? '$nature · $qtyPrice' : nature;
    } else if (hasQtyPrice) {
      subtitle = qtyPrice;
    } else {
      subtitle = nature;
    }

    // TROIS familles, chacune avec un tap PRÉVISIBLE (uniformisation du 30/07 :
    // le vrai défaut n'était pas que les espèces soient éditables, mais qu'une
    // ligne titre soit un tap MORT sans explication) :
    //
    // 1. ESPÈCES ORDINAIRES (`!isSystemGenerated && symbol == null` :
    //    deposit/withdrawal/interest/charge) → éditables/supprimables ICI, seul
    //    foyer de leur sémantique. Le critère est la NATURE de la ligne, jamais
    //    son origine : un dépôt importé d'un relevé est aussi éditable qu'un
    //    dépôt saisi à la main (l'utilisateur doit pouvoir corriger un import).
    // 2. TITRE (`symbol != null` : buy/sell/dividend, ou une jambe titre
    //    système) → tap qui NAVIGUE vers la fiche position, où vit le dialogue
    //    titre complet. Éditer ici forcerait `symbol: null` (cf.
    //    _openEditTransaction) et casserait le rattachement au titre.
    // 3. SYSTÈME espèces (`isSystemGenerated && symbol == null`) → lecture
    //    seule, mais un tap EXPLIQUE le pourquoi (ancre de trésorerie / jambe
    //    d'OST, câblées ailleurs) au lieu de rester inerte.
    final isPlainCash = !tx.kind.isSystemGenerated && tx.symbol == null;
    final isTitleLinked = tx.symbol != null;

    final VoidCallback? onTap;
    if (isPlainCash) {
      onTap = () => _openEditTransaction(tx);
    } else if (isTitleLinked) {
      onTap = () => _openPositionForSymbol(tx.symbol!);
    } else {
      onTap = _showSystemLineHelp;
    }

    // Affordance de fin de tuile, alignée sur le tap : supprimer (espèces),
    // chevron « ouvre ailleurs » (titre), ⓘ « pourquoi verrouillé » (système).
    final Widget trailing;
    if (isPlainCash) {
      trailing = IconButton(
        icon: Icon(
          Icons.delete_outline,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        tooltip: l10n.deleteTooltip,
        onPressed: () => _confirmDeleteTransaction(tx),
      );
    } else if (isTitleLinked) {
      trailing = Icon(
        Icons.chevron_right,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      );
    } else {
      trailing = Icon(
        Icons.info_outline,
        size: 18,
        color: theme.colorScheme.onSurfaceVariant,
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Icône kind
            CircleAvatar(
              radius: 18,
              backgroundColor: amountColor.withValues(alpha: 0.12),
              child: Icon(_kindIcon(tx.kind), size: 16, color: amountColor),
            ),
            const SizedBox(width: 12),
            // Symbole + date + sous-titre
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    symbolLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _formatTxDate(tx.date),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            // Montant coloré
            Text(
              amountLabel,
              style: TextStyle(color: amountColor, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            trailing,
          ],
        ),
      ),
    );
  }
}

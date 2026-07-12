// lib/widgets/account_view.dart
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/utils/logger.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';
import 'package:portfolio_tracker/widgets/allocation_pie_chart.dart';
import 'package:portfolio_tracker/widgets/position_card.dart';
import 'package:portfolio_tracker/widgets/common/delete_position_dialog.dart';
import 'package:portfolio_tracker/widgets/common/delete_account_dialog.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';
import 'package:portfolio_tracker/widgets/position_detail_page.dart';
import 'package:portfolio_tracker/model/position_with_market_data.dart';
import 'package:portfolio_tracker/widgets/charts/valuation_line_chart.dart';
import 'package:portfolio_tracker/widgets/charts/period_selector.dart';
import 'package:portfolio_tracker/widgets/total_value_card.dart';
import 'package:portfolio_tracker/widgets/account_journal_page.dart';
import 'package:portfolio_tracker/widgets/common/empty_state.dart';
import 'package:portfolio_tracker/widgets/common/responsive_body.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/error_text.dart';

class AccountView extends StatefulWidget {
  final String? initialAccountId;

  /// Valeur renvoyée par [Navigator.pop] quand l'utilisateur a confirmé la
  /// suppression du compte depuis la barre. Le parent (WalletView) la détecte
  /// au retour de navigation pour lancer sa propre suppression différée +
  /// Annuler (miroir de [PositionDetailPage.resultDeleted]).
  static const String resultDeleted = 'deleted';

  const AccountView({super.key, this.initialAccountId});

  @override
  State<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends State<AccountView> {
  late final AccountController _ctrl;

  /// Lecture seule du journal pour compter les mouvements impactés par une
  /// suppression de position (confirmation D2). Singleton partagé en production
  /// (même base que le contrôleur).
  final TransactionStorage _txStorage = TransactionStorage();

  @override
  void initState() {
    super.initState();
    _ctrl = AccountController(initialAccountId: widget.initialAccountId);
    _ctrl.initAccounts();
    _ctrl.loadExchangeRate();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Dialogs — restent en vue (dépendent de BuildContext, risque R4)
  // ---------------------------------------------------------------------------

  /// Affiche l'aide « comment trouver le symbole/ticker » : source de cotation
  /// (Yahoo Finance), suffixes de place pour les valeurs européennes, exemples.
  void _showSymbolHelp() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (helpContext) => AlertDialog(
        title: Text(l10n.symbolHelpTitle),
        content: SingleChildScrollView(
          child: SelectableText(l10n.symbolHelpBody),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(helpContext),
            child: Text(l10n.close),
          ),
        ],
      ),
    );
  }

  void _showAddPositionDialog() {
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final symbolController = TextEditingController();
    final quantityController = TextEditingController(text: '1');
    final pruController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.addPositionTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: symbolController,
                decoration: InputDecoration(
                  labelText: l10n.symbolLabel,
                  hintText: 'AIR.PA',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.info_outline),
                    tooltip: l10n.symbolHelpTooltip,
                    onPressed: _showSymbolHelp,
                  ),
                ),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: quantityController,
                decoration: InputDecoration(
                  labelText: l10n.quantityLabel,
                  hintText: '1',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: pruController,
                decoration: InputDecoration(
                  labelText: l10n.averageBuyPriceLabel,
                  hintText: l10n.optionalHint,
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (symbolController.text.trim().isEmpty) return;
              Navigator.pop(dialogContext);
              _doAddPosition(
                symbolController.text.toUpperCase().trim(),
                quantityController.text,
                pruController.text,
              );
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    );
  }

  Future<void> _doAddPosition(
    String symbol,
    String quantity,
    String pruText,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final erreur = await _ctrl.addNewPosition(
      symbol,
      quantity,
      pruText.isEmpty ? null : pruText,
    );
    if (!mounted) return;
    if (erreur == 'noActiveAccount') {
      showAppSnackBar(context, l10n.noActiveAccount, type: SnackType.error);
    } else if (erreur == 'invalidQuantity') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.invalidQuantity),
          backgroundColor: Colors.orange,
        ),
      );
    } else if (erreur == 'assetNotFound') {
      showAppSnackBar(
        context,
        l10n.assetNotFound(symbol),
        type: SnackType.error,
      );
    }
  }

  void _showAddPreciousMetalDialog() {
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController();
    final refSymbolController = TextEditingController(text: 'GC=F');
    final weightController = TextEditingController();
    final premiumController = TextEditingController();
    final quantityController = TextEditingController(text: '1');
    final pruController = TextEditingController();
    int presetIndex = -1; // -1 = personnalisé
    MetalQuoteUnit unit = MetalQuoteUnit.ounce;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(l10n.addPreciousMetalTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Modèle prédéfini : préremplit le poids fin (et le nom si vide).
                DropdownButtonFormField<int>(
                  initialValue: presetIndex,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.coinPresetLabel),
                  items: [
                    DropdownMenuItem(
                      value: -1,
                      child: Text(l10n.coinPresetCustom),
                    ),
                    for (
                      int i = 0;
                      i < AccountController.metalPresets.length;
                      i++
                    )
                      DropdownMenuItem(
                        value: i,
                        child: Text(AccountController.metalPresets[i].name),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      presetIndex = value;
                      if (value >= 0) {
                        final preset = AccountController.metalPresets[value];
                        weightController.text = preset.weight.toString();
                        if (nameController.text.trim().isEmpty) {
                          nameController.text = preset.name;
                        }
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: l10n.preciousMetalNameLabel,
                    hintText: l10n.preciousMetalNameHint,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: weightController,
                  decoration: InputDecoration(
                    labelText: l10n.fineWeightLabel,
                    hintText: '5.807',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: premiumController,
                  decoration: InputDecoration(
                    labelText: l10n.premiumLabel,
                    hintText: l10n.optionalHint,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: quantityController,
                  decoration: InputDecoration(
                    labelText: l10n.quantityLabel,
                    hintText: '1',
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                // PRU optionnel, en EUR (devise d'affichage des métaux précieux).
                TextField(
                  controller: pruController,
                  decoration: InputDecoration(
                    labelText: l10n.averageBuyPriceLabel,
                    hintText: l10n.optionalHint,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 16),
                // Paramètres du cours de référence (avancé).
                TextField(
                  controller: refSymbolController,
                  decoration: InputDecoration(
                    labelText: l10n.referenceSymbolLabel,
                    hintText: 'GC=F',
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<MetalQuoteUnit>(
                  initialValue: unit,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.quoteUnitLabel),
                  items: [
                    DropdownMenuItem(
                      value: MetalQuoteUnit.ounce,
                      child: Text(l10n.quoteUnitOunce),
                    ),
                    DropdownMenuItem(
                      value: MetalQuoteUnit.gram,
                      child: Text(l10n.quoteUnitGram),
                    ),
                  ],
                  onChanged: (value) => setDialogState(
                    () => unit = value ?? MetalQuoteUnit.ounce,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.preciousMetalHelp,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final weight = double.tryParse(
                  weightController.text.trim().replaceAll(',', '.'),
                );
                if (weight == null || weight <= 0) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(
                      content: Text(l10n.invalidFineWeight),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }
                final refSymbol = refSymbolController.text.trim().toUpperCase();
                if (refSymbol.isEmpty) return;
                final name = nameController.text.trim().isEmpty
                    ? refSymbol
                    : nameController.text.trim();
                final premium =
                    double.tryParse(
                      premiumController.text.trim().replaceAll(',', '.'),
                    ) ??
                    0;
                Navigator.pop(dialogContext);
                _doAddPreciousMetal(
                  name: name,
                  refSymbol: refSymbol,
                  unit: unit,
                  fineWeight: weight,
                  premiumPercent: premium,
                  quantity: quantityController.text,
                  pruText: pruController.text,
                );
              },
              child: Text(l10n.add),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doAddPreciousMetal({
    required String name,
    required String refSymbol,
    required MetalQuoteUnit unit,
    required double fineWeight,
    required double premiumPercent,
    required String quantity,
    String? pruText,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final erreur = await _ctrl.addNewPreciousMetal(
      name: name,
      refSymbol: refSymbol,
      unit: unit,
      fineWeight: fineWeight,
      premiumPercent: premiumPercent,
      quantity: quantity,
      pruText: pruText,
    );
    if (!mounted) return;
    if (erreur == 'noActiveAccount') {
      showAppSnackBar(context, l10n.noActiveAccount, type: SnackType.error);
    } else if (erreur == 'invalidQuantity') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.invalidQuantity),
          backgroundColor: Colors.orange,
        ),
      );
    } else if (erreur == 'assetNotFound') {
      showAppSnackBar(
        context,
        l10n.assetNotFound(refSymbol),
        type: SnackType.error,
      );
    }
  }

  // ⭐ NOUVELLE MÉTHODE : Éditer le nom du compte (dialog reste en vue)
  Future<void> _editAccountName() async {
    if (_ctrl.activeAccount == null) return;

    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: _ctrl.activeAccount!.name);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.editNameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.newNameHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (val) {
            if (val.trim().isNotEmpty) Navigator.pop(ctx, val.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: Text(l10n.validate),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        await _ctrl.renameAccount(result);
        if (mounted) {
          showAppSnackBar(
            context,
            l10n.nameUpdatedSuccess,
            type: SnackType.success,
          );
        }
      } catch (e) {
        AppLogger.error('Erreur sauvegarde nom', e);
        if (mounted) {
          showAppSnackBar(
            context,
            l10n.modificationError,
            type: SnackType.error,
          );
        }
      }
    }
  }

  /// Édite la nature ([AccountKind]) du compte actif. Réservé aux comptes
  /// titres, et n'offre que des natures « titres » : on affine l'enveloppe
  /// fiscale sans jamais changer le mode de valorisation (pas de bascule vers
  /// cash/métaux qui rendrait les positions incohérentes).
  Future<void> _editAccountKind() async {
    final account = _ctrl.activeAccount;
    if (account == null || !account.kind.isSecurities) return;

    final l10n = AppLocalizations.of(context)!;
    final securitiesKinds = AccountKind.values
        .where((k) => k.isSecurities)
        .toList();
    AccountKind selected = account.kind;

    final result = await showDialog<AccountKind>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l10n.accountType),
          content: DropdownButtonFormField<AccountKind>(
            initialValue: selected,
            isExpanded: true,
            decoration: InputDecoration(labelText: l10n.accountType),
            items: securitiesKinds
                .map(
                  (k) => DropdownMenuItem(
                    value: k,
                    child: Text(k.localizedLabel(l10n)),
                  ),
                )
                .toList(),
            onChanged: (v) => setDialogState(() => selected = v!),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: Text(l10n.validate),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      try {
        await _ctrl.setAccountKind(result);
        if (mounted) {
          showAppSnackBar(
            context,
            l10n.accountKindUpdatedSuccess,
            type: SnackType.success,
          );
        }
      } catch (e) {
        AppLogger.error('Erreur sauvegarde nature du compte', e);
        if (mounted) {
          showAppSnackBar(
            context,
            l10n.modificationError,
            type: SnackType.error,
          );
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Actions de journal explicites sur le SOLDE ESPÈCES (lot cash-ledger)
  //
  // Analogues cash de « Définir/Ajuster la quantité » (position_detail_page.dart) :
  // le cash dérivé est en LECTURE SEULE pour un compte titres (corollaire D1) ;
  // toute correction passe par un acte de journal nommé. Le choix de l'action
  // proposée se fait sur l'opt-in ([AccountController.hasCashAnchor]), pas sur
  // la nullité du solde dérivé — un journal composé uniquement de buy a déjà un
  // solde dérivé (négatif, non fiable) sans qu'aucun suivi de trésorerie n'ait
  // commencé (design §3).
  // ---------------------------------------------------------------------------

  /// « Définir le solde espèces initial… » — aucun ancrage cash encore posé.
  Future<void> _openSetInitialCashBalance() async {
    final l10n = AppLocalizations.of(context)!;

    final currency = _ctrl.activeAccount?.currency ?? 'EUR';
    final outcome = await showDialog<_CashOpeningBalanceOutcome>(
      context: context,
      builder: (_) => _CashOpeningBalanceDialog(currency: currency),
    );
    if (outcome == null || !mounted) return;

    final erreur = await _ctrl.emitCashOpeningBalance(
      amount: outcome.amount,
      date: outcome.date,
      note: outcome.note,
    );
    if (!mounted) return;
    if (erreur != null) {
      showAppSnackBar(context, l10n.modificationError, type: SnackType.error);
      return;
    }
    showAppSnackBar(
      context,
      l10n.cashOpeningBalanceDeclared,
      type: SnackType.success,
    );
  }

  /// « Ajuster le solde espèces… » — un ancrage cash existe déjà ; l'utilisateur
  /// saisit le solde CONSTATÉ, le delta signé est calculé automatiquement.
  Future<void> _openAdjustCashBalance() async {
    final l10n = AppLocalizations.of(context)!;
    final projected = _ctrl.derivedCash ?? '0';
    final currency = _ctrl.activeAccount?.currency ?? 'EUR';

    final outcome = await showDialog<_CashAdjustOutcome>(
      context: context,
      builder: (_) => _CashAdjustDialog(
        projectedCash: projected,
        currency: currency,
      ),
    );
    if (outcome == null || !mounted) return;

    final currentCash = Decimal.tryParse(projected) ?? Decimal.zero;
    final targetCash = Decimal.tryParse(outcome.targetAmount) ?? currentCash;
    final delta = targetCash - currentCash;
    if (delta == Decimal.zero) return; // garde-fou (le bouton est déjà désactivé)

    final erreur = await _ctrl.emitCashAdjustment(
      amount: delta.toString(),
      date: outcome.date,
      note: outcome.note,
    );
    if (!mounted) return;
    if (erreur != null) {
      showAppSnackBar(context, l10n.modificationError, type: SnackType.error);
      return;
    }
    showAppSnackBar(context, l10n.cashAdjustmentAdded, type: SnackType.success);
  }

  /// Suppression différée : masque la position de la liste (sans toucher au
  /// stockage), affiche un snackbar « supprimée » + Annuler. La suppression
  /// réelle n'est validée qu'à la fermeture du snackbar SANS annulation
  /// (motif « commit on close »). Aucun [Timer] : on s'appuie sur
  /// [ScaffoldFeatureController.closed].
  void _onPositionDismissed(PositionWithMarketData positionData) {
    final l10n = AppLocalizations.of(context)!;
    final symbol = positionData.symbol;

    // Retire immédiatement de la liste affichée (requis par Dismissible).
    _ctrl.hidePosition(symbol);

    final ctl = showAppSnackBar(
      context,
      l10n.positionDeleted(symbol),
      type: SnackType.info,
      action: SnackBarAction(
        label: l10n.undoAction,
        onPressed: () => _ctrl.restorePosition(symbol),
      ),
    );

    // Fermé par annulation → on restaure (déjà fait via l'action) et on ne
    // touche pas au stockage. Fermé autrement (timeout, remplacé, balayé) →
    // on valide la suppression réelle. Le contrôleur garde-fou empêche toute
    // double suppression si la position n'est plus masquée.
    ctl.closed.then((reason) {
      if (reason != SnackBarClosedReason.action) {
        _commitPositionDeletion(symbol);
      }
    });
  }

  Future<void> _commitPositionDeletion(String symbol) async {
    try {
      // Volontairement sans garde `mounted` : la suppression doit être validée
      // même si la vue a été dépilée (le contrôleur survit et neutralise ses
      // notifications post-dispose). Seul l'affichage d'erreur est gardé.
      await _ctrl.commitDeletePosition(symbol);
    } catch (e) {
      AppLogger.error('Erreur suppression position: $e');
      // Échec du stockage : on réintègre la position pour refléter la réalité.
      _ctrl.restorePosition(symbol);
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.positionDeletionError(symbol),
        type: SnackType.error,
      );
    }
  }

  void _navigateToDetail(PositionWithMarketData positionData) async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => PositionDetailPage(
          position: positionData.position,
          onPositionModified: () {
            _ctrl.initAccounts();
          },
        ),
      ),
    );
    if (!mounted) return;
    // Suppression demandée depuis la barre de la page de détail : on emprunte le
    // MÊME chemin que le balayage (masquage immédiat + snackbar Annuler + commit
    // différé). On sort AVANT le rafraîchissement de secours ci-dessous : celui-
    // ci rechargerait le stockage et ferait réapparaître la position (le commit
    // réel n'a pas encore eu lieu), écrasant le masquage et l'undo.
    if (result == PositionDetailPage.resultDeleted) {
      _onPositionDismissed(positionData);
      return;
    }
    // Rafraîchir aussi au retour (fallback)
    await _ctrl.initAccounts();
  }

  /// Supprime le compte courant depuis la barre (affordance canonique des
  /// comptes d'investissement, miroir de la corbeille des positions). Demande
  /// confirmation (dialogue partagé + garde « dernier compte ») puis, si
  /// l'utilisateur confirme, dépile la page en renvoyant
  /// [AccountView.resultDeleted] : c'est WalletView qui exécute la suppression
  /// différée avec Annuler (l'état d'undo vit dans son contrôleur).
  Future<void> _confirmAndDeleteAccount() async {
    final account = _ctrl.activeAccount;
    if (account == null) return;
    final confirmed = await confirmDeleteAccount(
      context: context,
      accountName: account.name,
      totalAccountCount: _ctrl.accounts.length,
    );
    if (!confirmed || !mounted) return;
    Navigator.pop(context, AccountView.resultDeleted);
  }

  // ---------------------------------------------------------------------------
  // Build — vue mince, reconstruit via ListenableBuilder
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _ctrl,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // Spinner plein écran UNIQUEMENT au premier chargement (aucune donnée à
    // afficher). Un rechargement ultérieur (refresh, retour de navigation qui
    // relance initAccounts) garde le contenu affiché et passe par l'indicateur
    // discret de l'AppBar, sans vider l'écran.
    if (_ctrl.isLoadingAccounts && _ctrl.positionsData.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_ctrl.globalError != null &&
        _ctrl.positionsData.isEmpty &&
        _ctrl.accounts.isEmpty) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(ErrorText.of(context, _ctrl.globalError)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _ctrl.initAccounts,
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }

    // ⭐ TRI DES POSITIONS PAR VALEUR DÉCROISSANTE
    final sortedPositions =
        List<PositionWithMarketData>.from(_ctrl.positionsData)..sort((a, b) {
          double valueA =
              (a.currentPrice ?? 0) * (double.tryParse(a.quantity) ?? 0);
          double valueB =
              (b.currentPrice ?? 0) * (double.tryParse(b.quantity) ?? 0);
          if (a.asset.currency.toUpperCase() == 'USD') {
            valueA *= _ctrl.usdToEurRate;
          }
          if (b.asset.currency.toUpperCase() == 'USD') {
            valueB *= _ctrl.usdToEurRate;
          }
          return valueB.compareTo(valueA); // Décroissant
        });

    // Rechargement non destructif en cours : refresh explicite (isRefreshing)
    // ou ré-initialisation avec du contenu déjà présent (retour de navigation).
    final busy =
        _ctrl.isRefreshing ||
        (_ctrl.isLoadingAccounts && _ctrl.positionsData.isNotEmpty);

    return Scaffold(
      appBar: AppBar(
        // ⭐ TITRE CLICABLE
        title: GestureDetector(
          onTap: _editAccountName,
          behavior: HitTestBehavior.opaque,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _ctrl.activeAccount!.name,
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: l10n.backTooltip,
          onPressed: () => Navigator.pop(context),
        ),
        // Ordre M3 : actions fréquentes en icônes (fréquence croissante vers la
        // droite), puis l'overflow ⋮ toujours en dernier. La suppression du
        // compte (action d'exception) y est reléguée, hors de la rangée des
        // icônes fréquentes et loin du titre éditable au tap (anti-misclic).
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long),
            tooltip: l10n.openJournalTooltip,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AccountJournalPage(
                  accountId: _ctrl.activeAccount!.id,
                  accountName: _ctrl.activeAccount!.name,
                ),
              ),
            ),
          ),
          // Indicateur discret : pendant un rafraîchissement, l'icône refresh
          // laisse place à un petit spinner (et le bouton est neutralisé pour
          // éviter les rafraîchissements concurrents).
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: l10n.refreshTooltip,
              onPressed: _ctrl.refresh,
            ),
          PopupMenuButton<String>(
            onSelected: (_) => _confirmAndDeleteAccount(),
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
                      l10n.deleteAccountTitle,
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
        // Liseré de progression fin sous l'AppBar : signale un rechargement en
        // cours sans masquer le contenu déjà affiché.
        bottom: busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      body: RefreshIndicator(
        onRefresh: _ctrl.refresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ResponsiveBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_ctrl.accounts.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: _buildAccountHeader(),
                  ),
                ],

                // Section graphique (si positions existent)
                if (_ctrl.positionsData.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildAccountChartSection(),
                ],

                // Header "Mes positions" avec bouton + et tooltip
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.myPositions,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      // ⭐ BOUTON + POUR AJOUTER
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        color: Theme.of(context).colorScheme.primary,
                        tooltip: l10n.addPositionTooltip,
                        onPressed:
                            _ctrl.activeAccount?.type ==
                                AccountType.preciousMetal
                            ? _showAddPreciousMetalDialog
                            : _showAddPositionDialog,
                      ),
                    ],
                  ),
                ),

                // Liste des positions (ou état vide si le compte n'en a aucune)
                if (_ctrl.positionsData.isEmpty)
                  EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: l10n.emptyPositionsTitle,
                    message: l10n.emptyPositionsBody,
                    action: FilledButton(
                      onPressed:
                          _ctrl.activeAccount?.type == AccountType.preciousMetal
                          ? _showAddPreciousMetalDialog
                          : _showAddPositionDialog,
                      child: Text(l10n.emptyPositionsCta),
                    ),
                  )
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    itemCount: sortedPositions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final positionData = sortedPositions[index];
                      return Dismissible(
                        key: Key(positionData.symbol),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: Theme.of(context).colorScheme.error,
                          child: Icon(
                            Icons.delete,
                            color: Theme.of(context).colorScheme.onError,
                          ),
                        ),
                        confirmDismiss: (direction) async {
                          // D2 (dialogue partagé avec l'action de la page de
                          // détail) : si la position a un journal, l'utilisateur
                          // doit savoir que N mouvements seront aussi supprimés.
                          final accountId = _ctrl.activeAccount?.id;
                          if (accountId == null) return false;
                          return confirmDeletePosition(
                            context: context,
                            txStorage: _txStorage,
                            accountId: accountId,
                            symbol: positionData.symbol,
                          );
                        },
                        onDismissed: (_) => _onPositionDismissed(positionData),
                        child: PositionCard(
                          position: positionData.position,
                          currentPrice: positionData.currentPrice,
                          periodChange: positionData.periodChange,
                          periodChangePercent: positionData.periodChangePercent,
                          onTap: () => _navigateToDetail(positionData),
                          usdToEurRate: _ctrl.usdToEurRate,
                          // Badge « Cours du JJ/MM » : non-null uniquement pour un
                          // cours servi depuis le cache (dernier cours connu). En
                          // direct lastUpdated est null → aucun badge.
                          lastUpdated: positionData.lastUpdated,
                        ),
                      );
                    },
                  ),

                // ⭐ GRAPHIQUE DE RÉPARTITION DES ACTIFS
                if (_ctrl.hasMultipleAssets) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _buildAssetAllocationChart(),
                  ),
                  const SizedBox(height: 20),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sous-widgets de rendu (lisent l'état depuis _ctrl)
  // ---------------------------------------------------------------------------

  Widget _buildAccountHeader() {
    final l10n = AppLocalizations.of(context)!;
    if (_ctrl.activeAccount == null) return const SizedBox.shrink();

    double totalValueEur = 0;
    for (final positionData in _ctrl.positionsData) {
      final price = positionData.currentPrice ?? 0;
      final qtyNum = double.tryParse(positionData.quantity) ?? 0;
      double value = price * qtyNum;
      if (positionData.asset.currency.toUpperCase() == 'USD') {
        value = value * _ctrl.usdToEurRate;
      }
      totalValueEur += value;
    }

    final account = _ctrl.activeAccount!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TotalValueCard(
          title: l10n.totalValueAccount,
          totalValue: totalValueEur,
          periodChange: _ctrl.periodChange,
          periodChangePercent: _ctrl.periodChangePercent,
          selectedPeriodLabel: _ctrl.selectedPeriod.localizedLabel(l10n),
        ),
        // Nature du compte (comptes titres) — puce cliquable pour affiner
        // l'enveloppe fiscale. Discrète : masquée pour cash/métaux.
        if (account.kind.isSecurities) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ActionChip(
              avatar: const Icon(Icons.account_balance_outlined, size: 16),
              label: Text(
                '${l10n.accountType} : '
                '${account.kind.localizedLabel(l10n)}',
              ),
              onPressed: _editAccountKind,
            ),
          ),
        ],
        const SizedBox(height: 8),
        _buildCashRow(account),
      ],
    );
  }

  /// Ligne « Espèces » opt-in (design §3/§4) : n'affiche un solde dérivé que
  /// si le journal contient un ancrage cash explicite ([AccountController.
  /// hasCashAnchor]) — un compte-titres avec uniquement des achats ne doit
  /// JAMAIS montrer un solde espèces (faux négatif interdit, cf. risque
  /// §6.7 de la spec). Sinon, wording discret « Espèces non suivies ».
  Widget _buildCashRow(Account account) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final hasAnchor = _ctrl.hasCashAnchor;

    final label = hasAnchor
        ? l10n.cashDerivedLabel(
            Formatters.formatMoney(
              double.tryParse(_ctrl.derivedCash ?? '0') ?? 0,
              account.currency,
            ),
          )
        : l10n.cashNotTrackedLabel;

    // Garde-fou anti-solde-trompeur (design §8.5) : le solde dérivé ne couvre
    // QUE la devise du compte. S'il existe des mouvements en devise de règlement
    // étrangère (lignes legacy d'avant le découplage, ou futur IBKR), on ANNOTE
    // la ligne plutôt que d'afficher un solde partiel silencieux.
    final foreignCount = _ctrl.foreignCashMovementCount;

    return Row(
      children: [
        Icon(
          Icons.payments_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (foreignCount > 0)
                Text(
                  l10n.cashForeignExcludedNote(foreignCount),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: hasAnchor
              ? _openAdjustCashBalance
              : _openSetInitialCashBalance,
          icon: Icon(hasAnchor ? Icons.tune : Icons.add_circle_outline, size: 16),
          label: Text(
            hasAnchor
                ? l10n.adjustCashBalanceAction
                : l10n.setInitialCashBalanceAction,
          ),
        ),
      ],
    );
  }

  Widget _buildAccountChartSection() {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 1,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPeriodSelector(),
            const SizedBox(height: 16),
            if (_ctrl.isLoadingHistory)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_ctrl.historyError != null)
              Center(
                child: Column(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 8),
                    Text(ErrorText.of(context, _ctrl.historyError)),
                  ],
                ),
              )
            else if (_ctrl.chartValues.isEmpty)
              Center(
                child: Text(
                  l10n.noHistoricalDataForPositions(_ctrl.positionsData.length),
                ),
              )
            else
              _buildAccountChart(),
          ],
        ),
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return PeriodSelector(
      selectedPeriod: _ctrl.selectedPeriod,
      onSelected: _ctrl.onPeriodChanged,
      height: 32,
      selectedLabelBold: true,
      unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
      chipPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    );
  }

  Widget _buildAccountChart() {
    if (_ctrl.chartValues.isEmpty) return const SizedBox.shrink();

    // Formule de hauteur identique à l'originale
    final chartHeight = _ctrl.chartValues.length > 200
        ? 250.0
        : (_ctrl.chartValues.length > 100 ? 200.0 : 150.0);

    return ValuationLineChart(
      dates: _ctrl.chartDates,
      values: _ctrl.chartValues,
      selectedPeriod: _ctrl.selectedPeriod,
      periodChange: _ctrl.periodChange,
      height: chartHeight,
      leftTitlesReservedSize: 50,
      barWidth: 2,
      showSnapshotLegend: false,
      // account_view n'a pas de série snapshot
      snapshotSpots: const [],
    );
  }

  Widget _buildAssetAllocationChart() {
    if (!_ctrl.hasMultipleAssets) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;

    final labelBySymbol = {
      for (final p in _ctrl.positionsData) p.symbol: p.asset.displayName,
    };

    final slices = _ctrl.assetValues.entries
        .map((e) => AllocationSlice(labelBySymbol[e.key] ?? e.key, e.value))
        .toList();

    return AllocationPieChart(
      slices: slices,
      othersLabel: l10n.chartOthers,
      noDataLabel: l10n.noData,
    );
  }
}

// =============================================================================
// Dialogue « Définir le solde espèces initial » (aucun ancrage cash encore posé)
// =============================================================================

/// Résultat du dialogue de solde espèces initial : montant SIGNÉ (négatif =
/// découvert déclaré), date et note optionnelle.
class _CashOpeningBalanceOutcome {
  final String amount;
  final DateTime date;
  final String? note;

  const _CashOpeningBalanceOutcome({
    required this.amount,
    required this.date,
    required this.note,
  });
}

class _CashOpeningBalanceDialog extends StatefulWidget {
  final String currency;

  const _CashOpeningBalanceDialog({required this.currency});

  @override
  State<_CashOpeningBalanceDialog> createState() =>
      _CashOpeningBalanceDialogState();
}

class _CashOpeningBalanceDialogState
    extends State<_CashOpeningBalanceDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController();
    _noteCtrl = TextEditingController();
    _date = DateTime.now();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
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
    final note = _noteCtrl.text.trim();
    Navigator.of(context).pop(
      _CashOpeningBalanceOutcome(
        amount: _amountCtrl.text.trim().replaceAll(',', '.'),
        date: _date,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: Text(l10n.setInitialCashBalanceTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Montant SIGNÉ (négatif = découvert déclaré, cf. design §3).
                TextFormField(
                  controller: _amountCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.cashOpeningBalanceAmountLabel,
                    suffixText: Formatters.formatCurrencySymbol(widget.currency),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  validator: (v) {
                    final t = (v ?? '').trim().replaceAll(',', '.');
                    if (Decimal.tryParse(t) == null) return l10n.invalidValue;
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // Date éditable (un solde initial est souvent antidaté).
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

// =============================================================================
// Dialogue « Ajuster le solde espèces » (un ancrage cash existe déjà)
// =============================================================================

/// Résultat du dialogue d'ajustement de solde espèces : montant CONSTATÉ
/// (cible, pas le delta — calculé par l'appelant), date et note optionnelle.
class _CashAdjustOutcome {
  final String targetAmount;
  final DateTime date;
  final String? note;

  const _CashAdjustOutcome({
    required this.targetAmount,
    required this.date,
    required this.note,
  });
}

class _CashAdjustDialog extends StatefulWidget {
  /// Solde espèces DÉRIVÉ courant (String canonique, cf.
  /// [AccountController.derivedCash]).
  final String projectedCash;
  final String currency;

  const _CashAdjustDialog({
    required this.projectedCash,
    required this.currency,
  });

  @override
  State<_CashAdjustDialog> createState() => _CashAdjustDialogState();
}

class _CashAdjustDialogState extends State<_CashAdjustDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _targetCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _targetCtrl = TextEditingController(text: widget.projectedCash);
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
    final projected = Decimal.tryParse(widget.projectedCash) ?? Decimal.zero;
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

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final note = _noteCtrl.text.trim();
    Navigator.of(context).pop(
      _CashAdjustOutcome(
        targetAmount: _targetCtrl.text.trim().replaceAll(',', '.'),
        date: _date,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final delta = _delta;
    final canSubmit = delta != null && delta != Decimal.zero;

    return AlertDialog(
      title: Text(l10n.adjustCashBalanceTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Solde dérivé courant (lecture seule).
                Text(
                  l10n.projectedCashBalanceLabel(
                    Formatters.formatMoney(
                      double.tryParse(widget.projectedCash) ?? 0,
                      widget.currency,
                    ),
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),

                // Solde constaté (cible saisie par l'utilisateur, signée).
                TextFormField(
                  controller: _targetCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.observedCashBalanceLabel,
                    suffixText: Formatters.formatCurrencySymbol(widget.currency),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final t = (v ?? '').trim().replaceAll(',', '.');
                    if (Decimal.tryParse(t) == null) return l10n.invalidValue;
                    return null;
                  },
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
                const SizedBox(height: 8),

                // Date éditable.
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
          onPressed: canSubmit ? _submit : null,
          child: Text(l10n.validate),
        ),
      ],
    );
  }
}

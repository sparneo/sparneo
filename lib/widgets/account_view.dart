// lib/widgets/account_view.dart
import 'package:decimal/decimal.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
// [isHeldPosition] vit désormais dans `logic/position_projection.dart`
// (réutilisée par [HistoryAggregator.computeRealTotalGain], doc 19) —
// importée ci-dessous pour l'usage local de ce fichier, RÉ-EXPORTÉE pour ne
// rien casser côté appelants existants
// (`import '.../account_view.dart' show isHeldPosition`, cf.
// test/corporate_actions_import_test.dart).
import 'package:portfolio_tracker/logic/position_projection.dart'
    show isHeldPosition;
export 'package:portfolio_tracker/logic/position_projection.dart'
    show isHeldPosition;
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
import 'package:portfolio_tracker/widgets/charts/chart_notes.dart';
import 'package:portfolio_tracker/widgets/charts/period_selector.dart';
import 'package:portfolio_tracker/widgets/total_value_card.dart';
import 'package:portfolio_tracker/widgets/account_journal_page.dart';
import 'package:portfolio_tracker/widgets/common/empty_state.dart';
import 'package:portfolio_tracker/widgets/common/help_dialog.dart';
import 'package:portfolio_tracker/widgets/common/responsive_body.dart';
import 'package:portfolio_tracker/widgets/import/statement_import_page.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/error_text.dart';

/// Projette [values] (mode 2 « apports nets », B7 Lot 3b) sur l'axe X du
/// graphique, EXACTEMENT comme [ValuationLineChart] indexe sa série
/// principale (`FlSpot(index, valeur)`, même référentiel que `chartDates` —
/// [values] est déjà alignée index-par-index dessus par le contrôleur).
/// Retourne `const []` si [values] est vide OU ne contient QUE des zéros
/// (aucun dépôt/retrait journalisé) : évite une ligne plate à 0 inutile.
List<FlSpot> _buildContributionsSpots(List<double> values) {
  if (values.isEmpty || values.every((v) => v == 0)) return const [];
  return [
    for (int i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
  ];
}

class AccountView extends StatefulWidget {
  final String? initialAccountId;

  /// Valeur renvoyée par [Navigator.pop] quand l'utilisateur a confirmé la
  /// suppression du compte depuis la barre. Le parent (WalletView) la détecte
  /// au retour de navigation pour lancer sa propre suppression différée +
  /// Annuler (miroir de [PositionDetailPage.resultDeleted]).
  static const String resultDeleted = 'deleted';

  /// Contrôleur pré-construit et déjà chargé (`initAccounts()` déjà résolu),
  /// réservé aux tests widget : la vue l'utilise TEL QUEL, sans appeler
  /// `initAccounts()`/`loadExchangeRate()` (le test charge son état via une
  /// base en mémoire AVANT de pumper le widget — ouvrir une base réelle À
  /// L'INTÉRIEUR d'un `testWidgets` est connu pour bloquer indéfiniment
  /// [dart:isolate], cf. `statement_import_page_test.dart`). Toujours `null`
  /// en production.
  @visibleForTesting
  final AccountController? debugController;

  const AccountView({super.key, this.initialAccountId, this.debugController});

  @override
  State<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends State<AccountView> {
  late final AccountController _ctrl;

  /// Lecture seule du journal pour compter les mouvements impactés par une
  /// suppression de position (confirmation D2). Singleton partagé en production
  /// (même base que le contrôleur).
  final TransactionStorage _txStorage = TransactionStorage();

  /// Mode de courbe sélectionné par l'utilisateur (performance / évolution
  /// réelle B7, design doc 18, MÊME motif que wallet_view Lot 3a). Combiné à
  /// [AccountController.hasRealCurve] via [_useRealCurve] : robustesse si la
  /// courbe réelle s'avère indisponible malgré la bascule utilisateur.
  // Défaut à true (retour manuel du 29/07) : l'évolution réelle reflète ce
  // qui s'est VRAIMENT passé, contrairement au mode « Vos positions »
  // (rétroprojection théorique) — sans effet tant que hasRealCurve est faux
  // (le sélecteur est alors masqué et _useRealCurve retombe à false via le
  // && ci-dessous).
  bool _showRealCurve = true;

  /// Mode réel EFFECTIVEMENT actif (garde de robustesse — cf. wallet_view) :
  /// si l'utilisateur a basculé sur « évolution réelle » mais que la série
  /// s'avère indisponible, on retombe silencieusement sur le mode 1 plutôt
  /// que d'afficher un graphe vide.
  ///
  /// Sur un compte CASH, le mode 1 (« Vos positions ») est un cas dégénéré :
  /// un compte cash n'a jamais de position, sa valeur y est donc TOUJOURS le
  /// solde ACTUEL répété sur toute la grille (`_loadCashAccountHistory`,
  /// `account_controller.dart`) — une droite plate par construction, dans
  /// 100 % des cas, jamais informative (contrairement à un compte titres où
  /// les cours historiques font varier ce mode même à quantités fixes).
  /// Offrir un choix dont une branche est tautologiquement inutile n'a pas de
  /// sens : dès qu'une courbe réelle existe, on la force, sans dépendre de
  /// [_showRealCurve] (dont le sélecteur est d'ailleurs masqué, cf.
  /// `_buildAccountChartSection`).
  bool get _useRealCurve =>
      (_showRealCurve || _isCashAccount) && _ctrl.hasRealCurve;

  /// Vrai pour un compte de type [AccountType.cash] (livret, compte courant) :
  /// repli « compte sans titre » (B8, doc 19 §4.5) — pas de positions à
  /// afficher, le solde espèces devient la valeur mise en avant de l'écran.
  bool get _isCashAccount => _ctrl.activeAccount?.type == AccountType.cash;

  @override
  void initState() {
    super.initState();
    if (widget.debugController != null) {
      // Test widget : contrôleur déjà chargé, on l'utilise tel quel (cf.
      // AccountView.debugController).
      _ctrl = widget.debugController!;
      return;
    }
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

  /// Popup d'aide « gain sur la période » (mode réel, B7 annualisation) —
  /// déclenchée par l'icône ⓘ de la carte de valeur totale. Remplace un
  /// ancien Tooltip (motif partagé [showHelpDialog], cf. _showSymbolHelp).
  /// Corps choisi selon `realPeriodGainPercentAnnualized != null` (fenêtre
  /// ≥ 1 an).
  void _showRealPeriodGainHelp() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showHelpDialog(
      context,
      title: l10n.chartRealPeriodGainHelpTitle,
      body: _ctrl.realPeriodGainPercentAnnualized != null
          ? l10n.chartRealPeriodGainHelpBodyAnnualized
          : l10n.chartRealPeriodGainHelpBody,
    );
  }

  /// Popup d'aide « gains totaux » (mode réel) — déclenchée par l'icône ⓘ à
  /// côté de la ligne sous le graphe. Remplace un ancien Tooltip.
  void _showRealTotalGainHelp() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final charges = _ctrl.realTotalGainCharges;
    final noBasisSymbols = _ctrl.realNoBasisSymbols;
    // Lignes optionnelles, ajoutées SEULEMENT si elles ont quelque chose à
    // isoler — même motif pour les deux : « dont frais » si le sous-total
    // est non-nul (négatif = frais, positif = rebate), « titres exclus » si
    // le calcul a dû en écarter (base de coût inconnue, cf. puce « partiel »
    // de TotalValueCard qui pointe vers cette popup pour le détail).
    final extraLines = <String>[
      if (charges != null && charges != 0)
        l10n.chartRealTotalGainFeesLine(Formatters.formatMoney(charges, 'EUR')),
      if (noBasisSymbols.isNotEmpty)
        l10n.chartRealTotalGainNoBasisLine(
          noBasisSymbols.length,
          (noBasisSymbols.toList()..sort()).join(', '),
        ),
    ];
    final body = extraLines.isEmpty
        ? l10n.chartRealTotalGainHelpBody
        : '${l10n.chartRealTotalGainHelpBody}\n\n${extraLines.join('\n\n')}';
    showHelpDialog(
      context,
      title: l10n.chartRealTotalGainHelpTitle,
      body: body,
    );
  }

  /// Popup d'aide « modes d'affichage » — déclenchée par l'icône ⓘ accolée au
  /// sélecteur de mode (SegmentedButton). Explique les DEUX modes d'un coup
  /// (épuration UI du 29/07) : reprend l'exposé de méthode retiré des
  /// captions permanentes sous le graphe (chartModePerformanceCaption ne
  /// garde que sa clause discriminante, chartModeRealCaption a disparu).
  void _showChartModeHelp() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showHelpDialog(
      context,
      title: l10n.chartModeHelpTitle,
      body: l10n.chartModeHelpBody,
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

  /// Ouvre le journal du compte et rafraîchit au retour (fallback, même
  /// pattern que [_navigateToDetail]) : `AccountJournalPage` écrit via son
  /// propre [LedgerService]/[TransactionStorage], indépendants du contrôleur
  /// de cette vue — sans ce rafraîchissement, un dépôt/retrait/intérêt/frais
  /// tout juste ajouté n'apparaît nulle part tant qu'on ne quitte pas l'écran
  /// (bug préexistant à B8, découvert par la passe manuelle du 28/07 : sur un
  /// compte titres le cash dérivé n'est qu'une ligne discrète, sur un compte
  /// cash c'est TOUTE la valeur affichée — le bug y devient flagrant).
  Future<void> _openJournal() async {
    final account = _ctrl.activeAccount;
    if (account == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AccountJournalPage(
          accountId: account.id,
          accountName: account.name,
        ),
      ),
    );
    if (!mounted) return;
    await _ctrl.initAccounts();
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

  /// Ouvre l'assistant d'import de relevé pour le compte actuellement ouvert
  /// (décision produit actée : le compte cible de l'import est toujours celui
  /// affiché, jamais un choix libre). Le contrôleur de cette vue est réutilisé
  /// tel quel par l'assistant : sa propre reconstruction post-confirmation
  /// (AccountController.confirmStatementImport → _initService()) suffit à
  /// rafraîchir positions/cash/historique ici, sans étape supplémentaire.
  Future<void> _openStatementImport() async {
    final account = _ctrl.activeAccount;
    if (account == null) return;
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => StatementImportPage(
          controller: _ctrl,
          accountId: account.id,
          accountName: account.name,
        ),
      ),
    );
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

    // Positions ouvertes uniquement : les positions SOLDÉES (quantité nette 0,
    // issues p. ex. d'un import d'historique complet) restent en base — elles
    // sont nécessaires à la plus-value réalisée et à l'export fiscal — mais ne
    // sont pas des avoirs détenus et n'ont pas à encombrer la liste. Sont AUSSI
    // masqués les RÉSIDUS NON COTÉS SANS VALEUR : une position `quotable == false`
    // (titre délisté / purgé de la source, souvent issu d'un transfert ou d'une
    // cession partielle) dont la valeur de marché est nulle (aucun dernier cours
    // connu). Elles restent en base (PV réalisée / historique) mais n'ont pas
    // leur place dans les avoirs détenus. Une position COTÉE de faible valeur
    // (un titre à 25 €) reste, elle, TOUJOURS affichée.
    final openPositions = sortedPositions
        .where((p) => isHeldPosition(
              quantity: p.quantity,
              quotable: p.asset.quotable,
              currentPrice: p.currentPrice,
            ))
        .toList();

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
            onPressed: () => _openJournal(),
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
            onSelected: (value) {
              switch (value) {
                case 'import':
                  _openStatementImport();
                  break;
                case 'cash':
                  _ctrl.hasCashAnchor
                      ? _openAdjustCashBalance()
                      : _openSetInitialCashBalance();
                  break;
                case 'delete':
                  _confirmAndDeleteAccount();
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'import',
                child: Row(
                  children: [
                    const Icon(Icons.upload_file),
                    const SizedBox(width: 12),
                    // Flexible (bug latent révélé par les tests de ce lot,
                    // le premier à réellement ouvrir ce menu) : la largeur du
                    // menu ⋮, ancré près du bord droit de l'AppBar, est
                    // bornée par le positionnement Material et ne wrappait
                    // jamais le texte, débordant silencieusement.
                    Flexible(
                      child: Text(
                        l10n.importStatementAction,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // Action sur le solde espèces (épuration UI, lot 3) : rare, donc
              // reléguée ici plutôt qu'en ligne dans le contenu (convention
              // V2.3). Réservée au compte-titres — sur un compte cash, elle
              // reste en avant dans le contenu ([_buildCashAccountRow]) : le
              // solde y EST toute la valeur du compte, ce n'est pas une action
              // rare. Les deux libellés sont mutuellement exclusifs selon
              // [AccountController.hasCashAnchor] (même règle que
              // [_buildCashAccountRow]).
              if (!_isCashAccount)
                PopupMenuItem<String>(
                  value: 'cash',
                  child: Row(
                    children: [
                      Icon(
                        _ctrl.hasCashAnchor
                            ? Icons.tune
                            : Icons.add_circle_outline,
                      ),
                      const SizedBox(width: 12),
                      // Flexible : cf. commentaire de l'entrée « import »
                      // ci-dessus.
                      Flexible(
                        child: Text(
                          _ctrl.hasCashAnchor
                              ? l10n.adjustCashBalanceAction
                              : l10n.setInitialCashBalanceAction,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        l10n.deleteAccountTitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
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

                // Section graphique : positions (mode 1) OU grille synthétique
                // d'un compte cash ancré (B8, doc 19 §4.3/4.4 — chartDates naît
                // alors du journal, pas des séries de prix).
                if (_ctrl.positionsData.isNotEmpty ||
                    _ctrl.chartDates.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _buildAccountChartSection(),
                ],

                // « Mes positions » (en-tête + liste + état vide) : un compte
                // cash (livret, compte courant) n'a aucune position à afficher
                // ni à ajouter — repli « compte sans titre » (B8, doc 19 §4.5).
                if (!_isCashAccount) ...[
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

                  // Liste des positions ouvertes (ou état vide si aucun avoir
                  // détenu — les soldées, filtrées plus haut, ne comptent pas).
                  if (openPositions.isEmpty)
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
                      itemCount: openPositions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final positionData = openPositions[index];
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
                ],

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
    final theme = Theme.of(context);
    if (_ctrl.activeAccount == null) return const SizedBox.shrink();

    final account = _ctrl.activeAccount!;

    double totalValueEur;
    if (_isCashAccount) {
      // Un livret n'a aucune position : sa valeur EST son solde espèces
      // (dérivé du journal si ancré, `cash_balance` legacy sinon — même règle
      // que WalletController.loadAllData, B8 doc 19 §4.4/§4.5).
      final cashRaw = _ctrl.hasCashAnchor
          ? double.tryParse(_ctrl.derivedCash ?? '0') ?? 0
          : account.cashBalance ?? 0.0;
      totalValueEur = account.currency.toUpperCase() == 'USD'
          ? cashRaw * _ctrl.usdToEurRate
          : cashRaw;
    } else {
      totalValueEur = 0;
      for (final positionData in _ctrl.positionsData) {
        final price = positionData.currentPrice ?? 0;
        final qtyNum = double.tryParse(positionData.quantity) ?? 0;
        double value = price * qtyNum;
        if (positionData.asset.currency.toUpperCase() == 'USD') {
          value = value * _ctrl.usdToEurRate;
        }
        totalValueEur += value;
      }
      // Cash dérivé du journal (achats/ventes/frais) : fait partie de la
      // valeur détenue du compte, même règle que le capital du gain total
      // mode 2 — l'omettre désynchronisait « Valeur totale » du solde
      // « Espèces » affiché en dessous et de la courbe « Évolution réelle ».
      //
      // GARDE D'ANCRAGE, non négociable (invariant « faux négatif interdit »,
      // design cash-ledger §6.7 / partition doc 19 §6.5) : sur un compte
      // titres SANS mouvement d'espèces au journal, [AccountController.
      // derivedCash] vaut « ce que les achats ont coûté », soit un solde
      // NÉGATIF FICTIF (cache `accounts.derived_cash`, écrit
      // inconditionnellement — sa non-nullité ne protège de rien, seul
      // [hasCashAnchor] protège). L'ajouter retranchait silencieusement ce
      // montant du total, sans RIEN à l'écran pour l'expliquer : la ligne
      // « dont espèces » est elle-même gatée sur l'ancrage et reste muette.
      // Même garde que la branche [_isCashAccount] ci-dessus, que
      // [WalletController._cashBalances] et que [reconstructRealNetWorth].
      if (_ctrl.hasCashAnchor) {
        totalValueEur += (double.tryParse(_ctrl.derivedCash ?? '0') ?? 0.0) *
            (account.currency.toUpperCase() == 'USD' ? _ctrl.usdToEurRate : 1.0);
      }
    }

    // Ligne « dont espèces » (épuration UI, lot 3) : sur un compte-titres
    // ANCRÉ uniquement — elle explicite une composante de [totalValueEur]
    // (déjà inclus, cf. calcul ci-dessus), pas un montant qui s'ajoute. Sans
    // ancrage, rien à décomposer (cas normal et majoritaire, cf. doc de
    // [_buildCashAccountRow] — la ligne grise permanente qu'affichait l'ancien
    // régime a été supprimée du contenu, l'entrée ⋮ « Définir le solde
    // initial… » suffit à rendre la fonction découvrable). Absente sur un
    // compte cash : le solde y EST toute la valeur ([_buildCashAccountRow]
    // s'en charge en premier plan, pas une décomposition du total).
    final foreignCount = _ctrl.foreignCashMovementCount;
    final cashLine = (!_isCashAccount && _ctrl.hasCashAnchor)
        ? l10n.accountCashLine(
            Formatters.formatMoney(
              double.tryParse(_ctrl.derivedCash ?? '0') ?? 0,
              account.currency,
            ),
          )
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TotalValueCard(
          title: l10n.totalValueAccount,
          totalValue: totalValueEur,
          // Gain total absolu (base coût, frais inclus), INDÉPENDANT du mode
          // de courbe ET de la période affichée — question prioritaire de
          // l'utilisateur, mise en premier plan (retour manuel du 29/07 : le
          // Modified Dietz seul en avant perturbait plus qu'il n'éclairait).
          // La perf de PÉRIODE, elle, a rejoint le graphe (PeriodGainLine).
          gainAmount: _ctrl.realTotalGain,
          gainPercent: _ctrl.realTotalGainPercent,
          onGainInfoPressed:
              _ctrl.realTotalGain != null ? _showRealTotalGainHelp : null,
          // Puce « partiel » TOUJOURS visible dès que des titres sont exclus
          // du gain total (base de coût inconnue), quel que soit le mode de
          // courbe — correctif d'honnêteté : l'ancien avertissement vivait
          // sous le graphe, gaté par `useRealCurve`, alors qu'il qualifie ce
          // gain-ci, affiché en permanence (cf. commit de ce lot).
          gainExcludedCount: _ctrl.realNoBasisSymbols.length,
          cashLine: cashLine,
        ),
        // Garde-fou anti-solde-trompeur (design §8.5) : reste dans le CONTENU
        // (jamais en popup/tooltip) — une réserve qui signale un solde
        // partiel ne se cache pas derrière une interaction. Placé juste sous
        // la carte de valeur (qui porte la ligne « dont espèces » quand elle
        // existe), INDÉPENDAMMENT de [cashLine] : un compte-titres peut avoir
        // des mouvements en devise étrangère avant même tout ancrage cash.
        // Régime compte cash exclu : la note y vit dans
        // [_buildCashAccountRow], au contact direct du solde qu'elle qualifie.
        if (!_isCashAccount && foreignCount > 0) ...[
          const SizedBox(height: 2),
          Text(
            l10n.cashForeignExcludedNote(foreignCount),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
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
        // Ligne « Espèces » mise en avant : réservée au régime compte cash
        // (émphase = toute la valeur du compte). Sur un compte-titres, le
        // cash n'est plus qu'une donnée accessoire déjà résumée ci-dessus
        // (ligne « dont espèces » + garde-fou devises) ; son action a rejoint
        // le menu ⋮ de l'AppBar (cf. [build], PopupMenuButton).
        if (_isCashAccount) ...[
          const SizedBox(height: 8),
          _buildCashAccountRow(account),
        ],
      ],
    );
  }

  /// Ligne « Espèces » d'un COMPTE CASH (livret, compte courant) — B8, doc 19
  /// §4.5 : le solde espèces y EST toute la valeur du compte (pas une donnée
  /// accessoire sous des positions), donc traitée en premier plan — icône
  /// 24, texte `titleMedium`, bouton d'action plein (`FilledButton.
  /// tonalIcon`). N'affiche un solde dérivé que si le journal contient un
  /// ancrage cash explicite ([AccountController.hasCashAnchor]) ; sinon,
  /// wording discret « Espèces non suivies ».
  ///
  /// RESTREINTE à ce régime depuis l'épuration UI (lot 3) : sur un
  /// compte-titres, le cash n'est plus qu'une donnée accessoire — sa valeur a
  /// rejoint la ligne « dont espèces » de [TotalValueCard] (avec ancrage
  /// seulement, cf. [_buildAccountHeader]) et son action a rejoint le menu ⋮
  /// de l'AppBar (cf. [build]).
  Widget _buildCashAccountRow(Account account) {
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
          size: 24,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
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
        FilledButton.tonalIcon(
          onPressed: hasAnchor
              ? _openAdjustCashBalance
              : _openSetInitialCashBalance,
          icon: Icon(
            hasAnchor ? Icons.tune : Icons.add_circle_outline,
            size: 16,
          ),
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
    final useRealCurve = _useRealCurve;
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
            // Sélecteur de mode courbe (performance / évolution réelle, B7
            // design doc 18), MÊME motif que wallet_view Lot 3a : n'apparaît
            // que si une courbe réelle est disponible pour ce compte ET que le
            // choix a un sens. Masqué sur un compte CASH (B8) : le mode
            // « Vos positions » y est TOUJOURS une droite plate au solde
            // actuel (aucune position, donc rien à faire varier) — offrir un
            // sélecteur dont une branche est tautologiquement inutile n'a pas
            // de sens, cf. [_useRealCurve] qui force alors le mode réel.
            if (_ctrl.hasRealCurve && !_isCashAccount) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SegmentedButton<bool>(
                      // « Évolution réelle » EN PREMIER : c'est le mode par
                      // défaut et celui qui dit ce qui s'est vraiment passé ;
                      // « Vos positions » est la vue théorique, secondaire.
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(l10n.chartModeRealEvolution),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text(l10n.chartModePerformance),
                        ),
                      ],
                      selected: {_showRealCurve},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      onSelectionChanged: (selection) {
                        setState(() => _showRealCurve = selection.first);
                      },
                    ),
                    // Épuration UI (29/07) : explique les DEUX modes d'un
                    // coup (méthode de calcul complète) — l'exposé détaillé a
                    // quitté les captions permanentes sous le graphe pour
                    // cette popup, ouverte à la demande.
                    Tooltip(
                      message: l10n.chartHelpTooltip,
                      child: InkWell(
                        onTap: _showChartModeHelp,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                  // Compte ce que l'utilisateur VOIT : mêmes positions
                  // « détenues » que la liste ci-dessous (isHeldPosition),
                  // pas la totalité de positionsData — celle-ci inclut les
                  // positions soldées / résidus non cotés sans valeur, que
                  // l'écran masque déjà (correctif d'honnêteté du compteur).
                  l10n.noHistoricalDataForPositions(
                    _ctrl.positionsData
                        .where(
                          (p) => isHeldPosition(
                            quantity: p.quantity,
                            quotable: p.asset.quotable,
                            currentPrice: p.currentPrice,
                          ),
                        )
                        .length,
                  ),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildAccountChart(useRealCurve),
                  // Performance sur la PÉRIODE affichée + notes conditionnelles
                  // — placées ici (et non dans TotalValueCard, déplacement du
                  // 29/07) car elles dépendent des deux sélecteurs qui les
                  // surplombent : période ET mode. Bloc partagé avec
                  // wallet_view (épuration UI du 29/07, évite la divergence
                  // lente entre les deux vues — cf. doc en tête de ChartNotes).
                  const SizedBox(height: 8),
                  ChartNotes(
                    // En mode réel, la variation naïve (% mode 1) mélange
                    // apports et performance — trompeuse, donc remplacée par le
                    // « gain sur la période » honnête (B7 Lot 4,
                    // HistoryAggregator.computeRealGains) : la performance de
                    // marché isolée des apports/retraits de la fenêtre.
                    periodGainAmount:
                        useRealCurve ? _ctrl.realPeriodGain : _ctrl.periodChange,
                    periodGainPercent: useRealCurve
                        ? _ctrl.realPeriodGainPercent
                        : _ctrl.periodChangePercent,
                    selectedPeriod: _ctrl.selectedPeriod,
                    useRealCurve: useRealCurve,
                    periodGainPercentAnnualized:
                        _ctrl.realPeriodGainPercentAnnualized,
                    onPeriodGainInfoPressed: _showRealPeriodGainHelp,
                    realExcludedLegacyCount: _ctrl.realExcludedLegacyCount,
                    realCurveApproxSymbolsCount:
                        _ctrl.realCurveApproxSymbols.length,
                    realUnanchoredRevenueEur: _ctrl.realUnanchoredRevenueEur,
                  ),
                ],
              ),
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

  Widget _buildAccountChart(bool useRealCurve) {
    if (_ctrl.chartValues.isEmpty) return const SizedBox.shrink();

    // Formule de hauteur identique à l'originale
    final chartHeight = _ctrl.chartValues.length > 200
        ? 250.0
        : (_ctrl.chartValues.length > 100 ? 200.0 : 150.0);

    return ValuationLineChart(
      dates: _ctrl.chartDates,
      values: useRealCurve ? _ctrl.realChartValues : _ctrl.chartValues,
      selectedPeriod: _ctrl.selectedPeriod,
      // Colore la courbe selon la performance de la période AFFICHÉE — en
      // mode réel c'est le gain Modified Dietz, pas la variation naïve du
      // mode 1. Passer `null` ici (ancien comportement) figeait la courbe en
      // ROUGE sur tout compte en mode réel, quelle que soit la période et même
      // très largement en gain (correctif du 29/07).
      periodChange: useRealCurve ? _ctrl.realPeriodGain : _ctrl.periodChange,
      height: chartHeight,
      leftTitlesReservedSize: 50,
      barWidth: 2,
      showSnapshotLegend: false,
      // account_view n'a pas de série snapshot
      snapshotSpots: const [],
      // Ligne « Apports » en mode réel (B7 Lot 3b).
      contributionsSpots: useRealCurve
          ? _buildContributionsSpots(_ctrl.realContributionsValues)
          : const [],
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

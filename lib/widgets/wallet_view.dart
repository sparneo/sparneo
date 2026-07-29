// lib/widgets/wallet_view.dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/controllers/wallet_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';
import 'package:portfolio_tracker/utils/error_text.dart';
import 'package:portfolio_tracker/utils/logger.dart';
import 'package:portfolio_tracker/widgets/account_view.dart';
import 'package:portfolio_tracker/widgets/common/empty_state.dart';
import 'package:portfolio_tracker/widgets/common/help_dialog.dart';
import 'package:portfolio_tracker/widgets/common/responsive_body.dart';
import 'package:portfolio_tracker/widgets/common/delete_account_dialog.dart';
import 'package:portfolio_tracker/model/allocation_target.dart';
import 'package:portfolio_tracker/widgets/allocation_gaps_section.dart';
import 'package:portfolio_tracker/widgets/allocation_pie_chart.dart';
import 'package:portfolio_tracker/widgets/allocation_target_edit_dialog.dart';
import 'package:portfolio_tracker/widgets/manage_wallets_page.dart';
import 'package:portfolio_tracker/widgets/settings_page.dart';
import 'package:portfolio_tracker/widgets/charts/valuation_line_chart.dart';
import 'package:portfolio_tracker/widgets/charts/chart_notes.dart';
import 'package:portfolio_tracker/widgets/charts/period_selector.dart';
import 'package:portfolio_tracker/widgets/total_value_card.dart';
import 'package:portfolio_tracker/widgets/wallet/account_list_tile.dart';
import 'package:portfolio_tracker/utils/formatters.dart';

/// Projette [values] (mode 2 « apports nets », B7 Lot 3b) sur l'axe X du
/// graphique, EXACTEMENT comme [ValuationLineChart] indexe sa série
/// principale (`FlSpot(index, valeur)`, même référentiel que [dates] —
/// [values] est déjà alignée index-par-index dessus par le contrôleur).
/// Retourne `const []` si [values] est vide OU ne contient QUE des zéros
/// (aucun dépôt/retrait journalisé) : évite une ligne plate à 0 inutile.
List<FlSpot> _buildContributionsSpots(List<double> values) {
  if (values.isEmpty || values.every((v) => v == 0)) return const [];
  return [
    for (int i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
  ];
}

class WalletView extends StatefulWidget {
  const WalletView({super.key});

  @override
  State<WalletView> createState() => _WalletViewState();
}

class _WalletViewState extends State<WalletView> {
  late final WalletController _controller;

  // Mode d'affichage du graphe global (B7 Lot 3a, design doc 18 §7.2/§11.6).
  // Purement local à la vue : les DEUX séries (performance / évolution
  // réelle) sont déjà calculées par le contrôleur (Lots 1+2) — basculer ne
  // recharge rien, un simple setState suffit. Faux par défaut : comportement
  // identique à avant ce lot pour tout utilisateur n'ayant pas de courbe
  // réelle disponible ([WalletController.hasRealCurve]).
  // Défaut à true (retour manuel du 29/07) : l'évolution réelle reflète ce
  // qui s'est VRAIMENT passé, contrairement au mode « Vos positions »
  // (rétroprojection théorique) — sans effet tant que hasRealCurve est faux
  // (le sélecteur est alors masqué et useRealCurve retombe à false via le
  // && ci-dessous).
  bool _showRealCurve = true;

  @override
  void initState() {
    super.initState();
    // Le nom par défaut du wallet sera mis à jour au premier build via
    // didChangeDependencies, mais on l'initialise avec une valeur de repli.
    _controller = WalletController();
    _controller.loadAllData();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _createNewAccount() async {
    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController();
    // Axe unique : la nature du compte porte valorisation + fiscalité.
    AccountKind selectedKind = AccountKind.autre;
    double cashBalance = 0.0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.newAccount),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(labelText: l10n.accountName),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                // Axe unique « Type de compte » : la nature porte à la fois la
                // valorisation (dérivée) et l'enveloppe fiscale → une seule
                // question, aucune combinaison incohérente possible.
                DropdownButtonFormField<AccountKind>(
                  initialValue: selectedKind,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.accountType),
                  items: AccountKind.values
                      .map(
                        (k) => DropdownMenuItem(
                          value: k,
                          child: Text(k.localizedLabel(l10n)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setDialogState(() {
                      selectedKind = v!;
                    });
                  },
                ),
                if (selectedKind.valuationType == AccountType.cash) ...[
                  const SizedBox(height: 16),
                  TextField(
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: l10n.initialBalance,
                      prefixText: '€ ',
                      hintText: '0.00',
                    ),
                    onChanged: (val) {
                      cashBalance = double.tryParse(val) ?? 0.0;
                    },
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.create),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && nameController.text.trim().isNotEmpty) {
      try {
        final newAccount = await _controller.createAccount(
          name: nameController.text.trim(),
          kind: selectedKind,
          cashBalance: cashBalance,
        );

        if (mounted) {
          // ⭐ CORRECTION : Navigation conditionnelle
          if (selectedKind.valuationType != AccountType.cash) {
            // Comptes investissement et métaux précieux : on navigue vers les détails
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    AccountView(initialAccountId: newAccount.id),
              ),
            );
          }
          // Pour cash : on reste sur WalletView

          // Rafraîchir la liste dans les deux cas
          if (mounted) {
            _controller.loadAllData();
          }
        }
      } catch (e) {
        AppLogger.error('Erreur création compte', e);
        if (mounted) {
          showAppSnackBar(
            context,
            AppLocalizations.of(context)!.accountCreationError,
            type: SnackType.error,
          );
        }
      }
    }
  }

  /// Popup d'aide « gain sur la période » (mode réel, B7 annualisation) —
  /// déclenchée par l'icône ⓘ de la carte de valeur totale. Remplace un
  /// ancien Tooltip (motif partagé [showHelpDialog], cf. account_view).
  /// Corps choisi selon `realPeriodGainPercentAnnualized != null` (fenêtre
  /// ≥ 1 an).
  void _showRealPeriodGainHelp() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showHelpDialog(
      context,
      title: l10n.chartRealPeriodGainHelpTitle,
      body: _controller.realPeriodGainPercentAnnualized != null
          ? l10n.chartRealPeriodGainHelpBodyAnnualized
          : l10n.chartRealPeriodGainHelpBody,
    );
  }

  /// Popup d'aide « gains totaux » (mode réel) — déclenchée par l'icône ⓘ à
  /// côté de la ligne sous le graphe. Remplace un ancien Tooltip.
  void _showRealTotalGainHelp() {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final charges = _controller.realTotalGainCharges;
    final noBasisSymbols = _controller.realNoBasisSymbols;
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

  /// Suppression DIFFÉRÉE (annulable) d'un compte, partagée par les deux points
  /// d'entrée restants : balayage de la liste et corbeille de la barre
  /// d'[AccountView] (le dialogue d'édition du solde cash, troisième chemin
  /// historique, a été retiré au Lot 4 — cf. doc 19 §2, la corbeille
  /// d'AccountView est désormais l'unique chemin de suppression d'un compte
  /// cash). La confirmation (+ garde « dernier compte ») a déjà eu lieu en
  /// amont ; ici on masque le compte de la liste sans toucher au stockage et
  /// on ouvre une fenêtre d'annulation. La suppression réelle n'est validée
  /// qu'à la fermeture du snackbar SANS action « Annuler ». Aligné sur
  /// _onPositionDismissed / manage_wallets_page.
  void _onAccountDismissed(Account account) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    // Retire immédiatement de la liste affichée : satisfait aussi le contrat du
    // Dismissible (l'item doit quitter le modèle après onDismissed).
    _controller.hideAccount(account.id);
    final ctl = showAppSnackBar(
      context,
      l10n.accountDeleted(account.name),
      type: SnackType.info,
      action: SnackBarAction(
        label: l10n.undoAction,
        onPressed: () {
          if (!mounted) return;
          _controller.restoreAccount(account);
        },
      ),
    );
    // Pas de Timer : on s'appuie sur la fermeture par timeout du snackbar (que
    // showAppSnackBar réarme via persist:false). Commit UNIQUEMENT si
    // l'utilisateur n'a pas annulé (reason != action) → jamais de double
    // suppression.
    ctl.closed.then((reason) {
      if (reason != SnackBarClosedReason.action) {
        _commitAccountDeletion(account);
      }
    });
  }

  /// Valide la suppression réelle (stockage) d'un compte à la fermeture du
  /// snackbar. Miroir de `_AccountViewState._commitPositionDeletion` :
  /// VOLONTAIREMENT sans garde `mounted` sur le commit (la suppression confirmée
  /// doit aboutir même si la vue est démontée — le contrôleur survit et
  /// neutralise ses notifications post-dispose) ; en cas d'échec du stockage on
  /// RESTAURE le compte pour refléter la réalité (il existe toujours en base) et
  /// on notifie. Sans ce catch, une erreur SQLite laissait le compte masqué et
  /// silencieux, incohérent avec le stockage.
  Future<void> _commitAccountDeletion(Account account) async {
    try {
      await _controller.commitDeleteAccount(account);
    } catch (e) {
      AppLogger.error('Erreur suppression compte: $e');
      _controller.restoreAccount(account);
      if (!mounted) return;
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.accountDeletionError(account.name),
        type: SnackType.error,
      );
    }
  }

  /// Bottom sheet « sélecteur de patrimoine » (motif account switcher). Se
  /// contente de lister/basculer/créer/renvoyer vers la gestion — PAS de
  /// suppression ni de renommage ici (ça reste le rôle de ManageWalletsPage).
  /// Non réactive à `notifyListeners` (pas de ListenableBuilder) : chaque
  /// action ferme la sheet AVANT de muter le contrôleur (pop synchrone puis
  /// action asynchrone), donc son contenu n'a jamais besoin de se
  /// rafraîchir pendant qu'elle est affichée.
  Future<void> _showWalletSwitcherSheet() async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.walletSwitcherTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...(_controller.wallets.map((wallet) {
              final isActive = wallet.id == _controller.activeWallet?.id;
              return ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: Text(wallet.name, overflow: TextOverflow.ellipsis),
                trailing: isActive
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () {
                  // Pop SYNCHRONE d'abord, PUIS bascule SANS await (le garde
                  // `activeWallet?.id == wallet.id` de selectWallet évite un
                  // rechargement inutile si l'utilisateur retape le wallet
                  // déjà actif) : la sheet ne doit pas rester ouverte le temps
                  // du rechargement des données du wallet ciblé.
                  Navigator.pop(sheetContext);
                  _controller.selectWallet(wallet);
                },
              );
            })),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(l10n.newWalletAction),
              onTap: () {
                Navigator.pop(sheetContext);
                _createWalletFromSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(l10n.manageWalletsTitle),
              onTap: () {
                // Capture AVANT le pop (use_build_context_synchronously) :
                // `context` (celui de WalletView) reste valide après la
                // fermeture de la sheet, mais on capture le Navigator qui
                // portera le push pour rester explicite et robuste à un
                // éventuel démontage entre-temps.
                final nav = Navigator.of(context);
                Navigator.pop(sheetContext);
                nav.push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ManageWalletsPage(controller: _controller),
                  ),
                );
                // Pas de rechargement au retour : le controller notifie déjà
                // ses listeners à chaque mutation (CRUD wallet centralisé).
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Dialogue de création d'un nouveau patrimoine, ouvert depuis la sheet
  /// (déjà fermée à ce stade). Calque la logique de saisie de
  /// `ManageWalletsPage._createWallet` : nom via TextField, création puis
  /// sélection automatique du wallet créé (contrairement à la page de gestion,
  /// la sheet vise justement le changement de patrimoine actif).
  Future<void> _createWalletFromSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final nameController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.newWalletTitle),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(labelText: l10n.walletNameLabel),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.create),
          ),
        ],
      ),
    );

    if (confirmed == true && nameController.text.trim().isNotEmpty) {
      final wallet = await _controller.createWallet(nameController.text);
      await _controller.selectWallet(wallet);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (_controller.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_controller.error != null && _controller.accounts.isEmpty) {
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
              Text(ErrorText.of(context, _controller.error)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _controller.loadAllData,
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }

    // Somme des comptes VISIBLES (cf. WalletController.totalPatrimoine) : reste
    // cohérent avec la liste affichée et le camembert pendant la fenêtre
    // d'annulation d'une suppression de compte.
    final totalPatrimoine = _controller.totalPatrimoine;

    // ⭐ CRÉER UNE LISTE TRIÉE AVANT L'AFFICHAGE
    final sortedAccounts = List<Account>.from(_controller.accounts)
      ..sort((a, b) {
        final valA = _controller.accountValues[a.id] ?? 0.0;
        final valB = _controller.accountValues[b.id] ?? 0.0;
        // Tri décroissant : le plus grand d'abord
        return valB.compareTo(valA);
      });

    return Scaffold(
      appBar: AppBar(
        // Titre TOUJOURS tappable (motif « account switcher » Google/Notion) :
        // même à un seul wallet, il ouvre la bottom sheet du sélecteur — ce qui
        // signale l'axe multi-patrimoine dès le premier wallet, au lieu de le
        // révéler seulement après en avoir créé un second (ancien comportement
        // DropdownButton/Text disjoint). L'icône folder_open est retirée : la
        // sheet couvre déjà bascule + création + lien vers la gestion.
        title: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _showWalletSwitcherSheet,
          child: Tooltip(
            message: l10n.switchWalletTooltip,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _controller.activeWallet?.name ?? l10n.defaultWalletName,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // Pendant un rafraîchissement non destructif (contenu conservé à
          // l'écran), l'icône refresh cède la place à un indicateur DISCRET :
          // le contenu reste visible, seule l'icône signale l'activité.
          if (_controller.isRefreshing)
            const SizedBox(
              width: 48,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _controller.loadAllData,
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: l10n.settingsTooltip,
            onPressed: () async {
              // La page Réglages porte désormais la sauvegarde/restauration/
              // export fiscal : un retour peut avoir changé les données
              // (restauration) → rechargement au retour, comme folder_open.
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsPage(
                    activeWalletId: _controller.activeWallet?.id,
                  ),
                ),
              );
              if (mounted) {
                await _controller.loadAllData();
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        // Pull-to-refresh : déclenche un rechargement non destructif
        // (isRefreshing), le contenu reste affiché pendant l'opération.
        onRefresh: _controller.loadAllData,
        child: SingleChildScrollView(
          // AlwaysScrollable : autorise le tirer-pour-rafraîchir même quand le
          // contenu tient dans l'écran (sinon pas d'overscroll → pas de pull).
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: ResponsiveBody(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_controller.accounts.isNotEmpty &&
                    (_controller.allPositionsData.isNotEmpty ||
                        _controller.cashBalances.isNotEmpty)) ...[
                  // Mode réel effectivement actif : garde de robustesse (design
                  // §Lot 3a) — si le bascule utilisateur est sur « évolution
                  // réelle » mais que la série s'avère indisponible (échec mode
                  // 2, cf. hasRealCurve), on retombe silencieusement sur le
                  // mode 1 plutôt que d'afficher un graphe vide.
                  Builder(
                    builder: (_) {
                      final bool useRealCurve =
                          _showRealCurve && _controller.hasRealCurve;

                      // En mode réel, la variation naïve (% mode 1) mélange
                      // apports et performance — trompeuse (masquée). On lui
                      // substitue le « gain sur la période » honnête (B7 Lot 4,
                      // [HistoryAggregator.computeRealGains]) : la performance
                      // de marché isolée des apports/retraits de la fenêtre.
                      final double? periodChange = useRealCurve
                          ? _controller.realPeriodGain
                          : _controller.periodChange;
                      final double? periodChangePercent = useRealCurve
                          ? _controller.realPeriodGainPercent
                          : _controller.periodChangePercent;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Carte valeur totale + variation de période. En
                          // mode réel seulement (B7 annualisation) : second
                          // pourcentage annualisé entre parenthèses si
                          // Modified Dietz l'a calculé (fenêtre ≥ 1 an) +
                          // tooltip pédagogique — corps du popup choisi selon
                          // realPeriodGainPercentAnnualized. Mode performance
                          // (mode 1) : comportement STRICTEMENT inchangé
                          // (percentAnnualized reste null).
                          TotalValueCard(
                            totalValue: totalPatrimoine,
                            title: l10n.totalValue,
                            // Gain total absolu (base coût, frais inclus),
                            // INDÉPENDANT du mode de courbe ET de la période —
                            // mis en premier plan (retour manuel du 29/07 : le
                            // Modified Dietz seul en avant perturbait plus
                            // qu'il n'éclairait). La perf de PÉRIODE a rejoint
                            // le graphe (PeriodGainLine).
                            gainAmount: _controller.realTotalGain,
                            gainPercent: _controller.realTotalGainPercent,
                            onGainInfoPressed:
                                _controller.realTotalGain != null
                                    ? _showRealTotalGainHelp
                                    : null,
                            // Puce « partiel » TOUJOURS visible dès que des
                            // titres sont exclus du gain total (base de coût
                            // inconnue), quel que soit le mode de courbe —
                            // correctif d'honnêteté : l'ancien avertissement
                            // vivait sous le graphe, gaté par `useRealCurve`,
                            // alors qu'il qualifie ce gain-ci, affiché en
                            // permanence.
                            gainExcludedCount:
                                _controller.realNoBasisSymbols.length,
                          ),
                          const SizedBox(height: 24),

                          // Sélecteur de période + sélecteur de mode + graphique global
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: PeriodSelector(
                                      selectedPeriod:
                                          _controller.selectedPeriod,
                                      onSelected: _controller.onPeriodChanged,
                                      // Défauts wallet_view : fond gris, pas de gras
                                    ),
                                  ),
                                ],
                              ),
                              // Sélecteur de mode courbe (performance /
                              // évolution réelle) : n'apparaît que si une
                              // courbe réelle est disponible (sinon
                              // comportement inchangé — patrimoine 100 %
                              // legacy ou vide, design §11.6).
                              if (_controller.hasRealCurve) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SegmentedButton<bool>(
                                        // « Évolution réelle » EN PREMIER :
                                        // mode par défaut et vue de ce qui
                                        // s'est vraiment passé ; « Vos
                                        // positions » est la vue théorique,
                                        // secondaire.
                                        segments: [
                                          ButtonSegment(
                                            value: true,
                                            label: Text(
                                              l10n.chartModeRealEvolution,
                                            ),
                                          ),
                                          ButtonSegment(
                                            value: false,
                                            label: Text(
                                              l10n.chartModePerformance,
                                            ),
                                          ),
                                        ],
                                        selected: {_showRealCurve},
                                        showSelectedIcon: false,
                                        style: const ButtonStyle(
                                          visualDensity:
                                              VisualDensity.compact,
                                        ),
                                        onSelectionChanged: (selection) {
                                          setState(
                                            () => _showRealCurve =
                                                selection.first,
                                          );
                                        },
                                      ),
                                      // Épuration UI (29/07) : explique les
                                      // DEUX modes d'un coup (méthode de
                                      // calcul complète) — l'exposé détaillé
                                      // a quitté les captions permanentes
                                      // sous le graphe pour cette popup,
                                      // ouverte à la demande.
                                      Tooltip(
                                        message: l10n.chartHelpTooltip,
                                        child: InkWell(
                                          onTap: _showChartModeHelp,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: Icon(
                                              Icons.info_outline,
                                              size: 16,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              SizedBox(
                                height: 200,
                                child: _controller.isLoadingHistory
                                    ? const Center(
                                        child: CircularProgressIndicator(),
                                      )
                                    : _controller.chartValues.isEmpty
                                    ? Center(
                                        child: Text(
                                          l10n.noData,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      )
                                    : ValuationLineChart(
                                        dates: _controller.chartDates,
                                        values: useRealCurve
                                            ? _controller.realChartValues
                                            : _controller.chartValues,
                                        // En mode réel, la ligne « Apports »
                                        // REMPLACE les snapshots (B7 Lot 3b) —
                                        // jamais les deux séries à la fois.
                                        snapshotSpots: useRealCurve
                                            ? const []
                                            : _controller.snapshotSpots,
                                        contributionsSpots: useRealCurve
                                            ? _buildContributionsSpots(
                                                _controller
                                                    .realContributionsValues,
                                              )
                                            : const [],
                                        periodChange: periodChange,
                                        selectedPeriod:
                                            _controller.selectedPeriod,
                                        // Paramètres wallet_view (tous par défaut)
                                        height:
                                            null, // géré par le SizedBox parent
                                        leftTitlesReservedSize: 40,
                                        barWidth: 3,
                                        showSnapshotLegend: true,
                                      ),
                              ),
                              // Performance sur la PÉRIODE affichée + notes
                              // conditionnelles — placées ici (et non dans
                              // TotalValueCard, déplacement du 29/07) car
                              // elles dépendent des deux sélecteurs qui les
                              // surplombent : période ET mode. Bloc partagé
                              // avec account_view (épuration UI du 29/07,
                              // évite la divergence lente entre les deux
                              // vues — cf. doc en tête de ChartNotes).
                              const SizedBox(height: 8),
                              ChartNotes(
                                periodGainAmount: periodChange,
                                periodGainPercent: periodChangePercent,
                                selectedPeriod: _controller.selectedPeriod,
                                useRealCurve: useRealCurve,
                                periodGainPercentAnnualized: _controller
                                    .realPeriodGainPercentAnnualized,
                                onPeriodGainInfoPressed:
                                    _showRealPeriodGainHelp,
                                realExcludedLegacyCount:
                                    _controller.realExcludedLegacyCount,
                                realCurveApproxSymbolsCount:
                                    _controller.realCurveApproxSymbols.length,
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                ],

                // LISTE DES COMPTES
                if (_controller.accounts.isEmpty) ...[
                  EmptyState(
                    icon: Icons.account_balance_wallet_outlined,
                    title: l10n.emptyAccountsTitle,
                    message: l10n.emptyAccountsBody,
                    action: FilledButton(
                      onPressed: _createNewAccount,
                      child: Text(l10n.emptyAccountsCta),
                    ),
                  ),
                ] else ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Pas de badge « glissez pour supprimer » : la suppression
                      // de compte est découvrable via l'overflow ⋮ de la barre
                      // d'AccountView, cash comme titres (aligné sur la liste
                      // des positions, cf. convention U4).
                      // Le balayage reste un raccourci non annoncé.
                      Text(
                        l10n.myAccounts,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        color: Theme.of(context).colorScheme.primary,
                        tooltip: l10n.addAccountTooltip,
                        onPressed: _createNewAccount,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: sortedAccounts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final account = sortedAccounts[index];
                      final value = _controller.accountValues[account.id] ?? 0;
                      final change =
                          _controller.accountPeriodChanges[account.id] ?? 0;
                      final changePercent =
                          _controller.accountPeriodChangePercents[account.id] ??
                          0;

                      return AccountListTile(
                        account: account,
                        value: value,
                        periodChange: change,
                        periodChangePercent: changePercent,
                        // Confirmation (+ garde « dernier compte ») et
                        // suppression différée mutualisées avec la corbeille de
                        // la barre d'AccountView et le dialogue cash.
                        confirmDismiss: (direction) => confirmDeleteAccount(
                          context: context,
                          accountName: account.name,
                          totalAccountCount: _controller.accounts.length,
                        ),
                        onDismissed: (_) => _onAccountDismissed(account),
                        onTap: () async {
                          // Cash comme titres : naviguer vers les détails. La
                          // page peut renvoyer resultDeleted (corbeille de sa
                          // barre) : on emprunte alors le MÊME chemin différé
                          // que le balayage, et on sort AVANT loadAllData —
                          // sinon le rechargement du stockage (commit non encore
                          // effectué) ferait réapparaître le compte, écrasant le
                          // masquage et l'undo.
                          final result = await Navigator.push<String>(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  AccountView(initialAccountId: account.id),
                            ),
                          );
                          if (!mounted) return;
                          if (result == AccountView.resultDeleted) {
                            _onAccountDismissed(account);
                            return;
                          }
                          await _controller.loadAllData();
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                ],

                // Camembert « par compte » : inchangé, uniquement si ≥ 2
                // comptes (la répartition par compte n'a de sens qu'à plusieurs).
                if (_controller.accounts.length > 1) ...[
                  const SizedBox(height: 24),
                  _buildAllocationChart(),
                ],
                // Camembert « par type d'actif » (cash inclus) : placé APRÈS
                // celui par compte. Pertinent dès qu'il existe au moins une
                // catégorie non nulle, même avec un seul compte. Il porte le
                // bouton d'édition des cibles + le tableau d'écarts (bonne
                // dimension : les cibles sont par type d'actif).
                if (_controller.assetTypeAllocations.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildAssetTypeAllocationChart(),
                ],
                if (_controller.accounts.length > 1 ||
                    _controller.assetTypeAllocations.isNotEmpty)
                  const SizedBox(height: 50),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAllocationChart() {
    if (_controller.accounts.length <= 1) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final slices = _controller.accounts
        .map(
          (a) => AllocationSlice(a.name, _controller.accountValues[a.id] ?? 0),
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.allocationByAccount, style: theme.textTheme.titleSmall),
        AllocationPieChart(
          slices: slices,
          othersLabel: l10n.chartOthers,
          noDataLabel: l10n.noData,
        ),
      ],
    );
  }

  /// Camembert « par type d'actif » (cash inclus). Porte le bouton d'édition
  /// des cibles et le tableau d'écarts — c'est la bonne dimension : les cibles
  /// d'allocation sont définies par type d'actif, pas par compte.
  Widget _buildAssetTypeAllocationChart() {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final slices = _controller.assetTypeAllocations
        .map(
          (a) => AllocationSlice(
            // type == null ⇒ catégorie synthétique « liquidités » (cash).
            a.type?.localizedLabel(l10n) ?? l10n.allocationCashCategory,
            a.value,
          ),
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // En-tête : titre + bouton d'édition des cibles.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      l10n.allocationByType,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  // Aide : d'où vient le type d'actif et comment le corriger.
                  // triggerMode.tap → l'aide s'ouvre au tap (mobile) autant qu'au
                  // survol (desktop). Le padding élargit la zone tapable au doigt
                  // (~40 px) tout en gardant l'icône visuellement discrète (16 px).
                  Tooltip(
                    message: l10n.allocationByTypeHelp,
                    triggerMode: TooltipTriggerMode.tap,
                    showDuration: const Duration(seconds: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        AllocationPieChart(
          slices: slices,
          othersLabel: l10n.chartOthers,
          noDataLabel: l10n.noData,
        ),
        // Section cibles/écarts — toujours rendue : elle porte désormais
        // l'action d'édition des cibles (⚙) et, à défaut de cible, un état vide
        // invitant à en définir (sinon l'éditeur serait inaccessible).
        const SizedBox(height: 16),
        AllocationGapsSection(
          gaps: _controller.allocationGaps,
          onEditTargets: _editAllocationTarget,
        ),
      ],
    );
  }

  /// Ouvre le dialog d'édition des cibles d'allocation et persiste le résultat.
  Future<void> _editAllocationTarget() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    final result = await showDialog<AllocationTarget>(
      context: context,
      builder: (_) => AllocationTargetEditDialog(
        current: _controller.allocationTarget,
        // Répartition réelle par catégorie (cash inclus) → « actuel : Y % ».
        currentPercents: _controller.currentAllocationPercents,
      ),
    );

    if (result == null || !mounted) return;

    // AllocationTarget.empty() signifie « effacer toutes les cibles »
    if (result.isEmpty) {
      await _controller.clearAllocationTarget();
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.allocationTargetCleared)),
        );
      }
    } else {
      await _controller.saveAllocationTarget(result);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.allocationTargetSaved)),
        );
      }
    }
  }
}

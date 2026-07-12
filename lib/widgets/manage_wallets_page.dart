// lib/widgets/manage_wallets_page.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:portfolio_tracker/controllers/wallet_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';

/// Page de gestion CRUD lourde des patrimoines (renommer, supprimer avec
/// annulation différée, cadenas du dernier wallet). Le sélecteur rapide
/// (bascule + création) vit désormais dans la bottom sheet de [WalletView] ;
/// cette page reste le point d'entrée pour les opérations destructives ou de
/// renommage, volontairement absentes de la sheet.
///
/// Tout le CRUD passe par [controller] (aucun accès direct à AccountStorage
/// ici) : la page se contente d'écouter via [ListenableBuilder] et de
/// déléguer les mutations, ce qui élimine toute course d'état avec
/// WalletView / la bottom sheet qui partagent le même contrôleur.
class ManageWalletsPage extends StatefulWidget {
  const ManageWalletsPage({super.key, required this.controller});

  final WalletController controller;

  @override
  State<ManageWalletsPage> createState() => _ManageWalletsPageState();
}

class _ManageWalletsPageState extends State<ManageWalletsPage> {
  Future<void> _createWallet() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.newWalletTitle),
        content: TextField(
          controller: controller,
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

    if (confirmed == true && controller.text.trim().isNotEmpty) {
      await widget.controller.createWallet(controller.text);
    }
  }

  // ⭐ NOUVEAU : Méthode pour modifier le nom du patrimoine
  Future<void> _editWallet(Wallet wallet) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: wallet.name);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.editWalletTitle),
        content: TextField(
          controller: controller,
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
            child: Text(l10n.save),
          ),
        ],
      ),
    );

    if (confirmed == true && controller.text.trim().isNotEmpty) {
      await widget.controller.renameWallet(wallet, controller.text);

      if (mounted) {
        showAppSnackBar(context, l10n.walletModified, type: SnackType.success);
      }
    }
  }

  Future<void> _deleteWallet(Wallet wallet) async {
    final l10n = AppLocalizations.of(context)!;
    if (widget.controller.wallets.length <= 1) {
      showAppSnackBar(
        context,
        l10n.cannotDeleteLastWallet,
        type: SnackType.warning,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteWalletTitle),
        content: Text(l10n.deleteWalletConfirm(wallet.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      _deleteWalletWithUndo(wallet);
    }
  }

  /// Masque [wallet] de la liste affichée (via le contrôleur, SANS toucher au
  /// stockage) et ouvre une fenêtre d'annulation (snackbar + action
  /// « Annuler »). La suppression réelle n'est validée qu'à la fermeture du
  /// snackbar sans annulation (motif de suppression différée, désormais porté
  /// par le contrôleur — insensible au démontage de CETTE page, contrairement
  /// à l'ancien état local `_wallets`). Appelée après confirmation par les
  /// deux points d'entrée (swipe et bouton).
  void _deleteWalletWithUndo(Wallet wallet) {
    final l10n = AppLocalizations.of(context)!;

    final hidden = widget.controller.hideWallet(wallet.id);
    // hideWallet retourne null si déjà masqué / introuvable / dernier wallet
    // (cadenas) : rien à faire, la garde ci-dessus (longueur <= 1) couvre déjà
    // ce dernier cas en amont, mais on reste défensif.
    if (hidden == null) return;

    final ctl = showAppSnackBar(
      context,
      l10n.walletDeleted(wallet.name),
      type: SnackType.info,
      action: SnackBarAction(
        label: l10n.undoAction,
        onPressed: () {
          if (!mounted) return;
          widget.controller.restoreWallet(hidden);
        },
      ),
    );

    ctl.closed.then((reason) async {
      if (reason != SnackBarClosedReason.action) {
        await widget.controller.commitDeleteWallet(hidden);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final wallets = widget.controller.wallets;
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.manageWalletsTitle),
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          ),
          body: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: wallets.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final wallet = wallets[index];
              final isLast = wallets.length == 1;

              return Dismissible(
                key: Key(wallet.id),
                direction: isLast
                    ? DismissDirection.none
                    : DismissDirection.endToStart,
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
                  if (isLast) return false;
                  return await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(l10n.deleteWalletTitle),
                          // Même message de confirmation que le bouton poubelle
                          // (_deleteWallet) : les deux chemins avertissent de la
                          // perte en cascade des comptes et positions.
                          content: Text(
                            l10n.deleteWalletConfirm(wallet.name),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(l10n.cancel),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              style: FilledButton.styleFrom(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.error,
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onError,
                              ),
                              child: Text(l10n.delete),
                            ),
                          ],
                        ),
                      ) ??
                      false;
                },
                // La confirmation est déjà faite par confirmDismiss :
                // pas de second dialogue, on passe directement en mode
                // suppression différée (annulable).
                onDismissed: (_) => _deleteWalletWithUndo(wallet),
                child: Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.primaryContainer,
                      child: Icon(
                        Icons.account_balance_wallet,
                        color: Theme.of(
                          context,
                        ).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    title: Text(
                      wallet.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      l10n.createdOn(
                        DateFormat.yMd(
                          Localizations.localeOf(context).languageCode,
                        ).format(wallet.createdAt),
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ⭐ NOUVEAU : Bouton de modification
                        IconButton(
                          icon: Icon(
                            Icons.edit_outlined,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          tooltip: l10n.editTooltip,
                          onPressed: () => _editWallet(wallet),
                        ),
                        // Bouton de suppression
                        if (!isLast)
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            tooltip: l10n.deleteTooltip,
                            onPressed: () => _deleteWallet(wallet),
                          )
                        else
                          Icon(
                            Icons.lock_outline,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            size: 18,
                          ),
                      ],
                    ),
                    // ⭐ NOUVEAU : Tap pour modifier
                    onTap: () => _editWallet(wallet),
                  ),
                ),
              );
            },
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: _createWallet,
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }
}

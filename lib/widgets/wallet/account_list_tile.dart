// lib/widgets/wallet/account_list_tile.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';

/// Tuile Dismissible+Card+ListTile d'un compte dans la liste du patrimoine.
///
/// La tuile délègue TOUTES les décisions de navigation et de confirmation de
/// suppression au caller via les callbacks [onTap] et [onDismissed] /
/// [confirmDismiss], conformément au risque R4 du design (dialogs restent en
/// vue).
///
/// Paramètres :
/// - [account]           : compte à afficher.
/// - [value]             : valeur en EUR du compte.
/// - [periodChange]      : variation absolue de la période.
/// - [periodChangePercent]: variation relative de la période.
/// - [onTap]             : action au tap (navigation ou édition solde cash).
/// - [confirmDismiss]    : async callback demandant confirmation de suppression.
/// - [onDismissed]       : action après confirmation et suppression effective.
class AccountListTile extends StatelessWidget {
  final Account account;
  final double value;
  final double periodChange;
  final double periodChangePercent;
  final VoidCallback onTap;
  final Future<bool?> Function(DismissDirection) confirmDismiss;
  final void Function(DismissDirection) onDismissed;

  const AccountListTile({
    super.key,
    required this.account,
    required this.value,
    required this.periodChange,
    required this.periodChangePercent,
    required this.onTap,
    required this.confirmDismiss,
    required this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isPositive = periodChange >= 0;
    final changeColor = AppColors.gainLoss(context, isPositive);

    return Dismissible(
      key: Key(account.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Theme.of(context).colorScheme.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: confirmDismiss,
      onDismissed: onDismissed,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: switch (account.type) {
              AccountType.cash => Colors.green.shade50,
              AccountType.preciousMetal => const Color(0xFFFFF3D6),
              AccountType.investment =>
                Theme.of(context).colorScheme.primaryContainer,
            },
            child: Icon(
              switch (account.type) {
                AccountType.cash => Icons.account_balance_wallet,
                AccountType.preciousMetal => Icons.savings_outlined,
                AccountType.investment => Icons.trending_up,
              },
              color: switch (account.type) {
                AccountType.cash => Colors.green,
                AccountType.preciousMetal => const Color(0xFFB8860B),
                AccountType.investment =>
                  Theme.of(context).colorScheme.onPrimaryContainer,
              },
            ),
          ),
          title: Text(account.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
            // Nature fine du compte (PEA, Assurance-vie, CTO, Cash-Épargne,
            // Crypto…) pour TOUS les comptes, cash inclus, plutôt que le type de
            // valorisation générique (« Investissement ») ou « Solde cash » : le
            // montant est déjà affiché à droite de la tuile. account.kind est
            // l'axe unique stocké, account.type n'en est que la projection.
            account.kind.localizedLabel(l10n),
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    Formatters.formatEur(value),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  // Variation uniquement pour les comptes non-cash
                  if (account.type != AccountType.cash)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          isPositive
                              ? Icons.trending_up
                              : Icons.trending_down,
                          color: changeColor,
                          size: 11,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${Formatters.formatEurSigned(periodChange)} (${Formatters.formatPercentFr(periodChangePercent)})',
                          style: TextStyle(
                            color: changeColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

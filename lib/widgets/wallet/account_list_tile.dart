// lib/widgets/wallet/account_list_tile.dart
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/theme/app_colors.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/utils/localized_labels.dart';

/// Tuile Dismissible+Card d'un compte dans la liste du patrimoine.
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
  /// Échelle de police système au-delà de laquelle le nom du compte et ses
  /// montants passent l'un SOUS l'autre au lieu de se partager la ligne.
  ///
  /// Côte à côte, les deux blocs se disputent une largeur qui ne grandit pas
  /// avec la police : à 2,0 sur Pixel 7a (mesuré le 31/07), la ligne de
  /// variation « +1 234,56 € (+12,3 %) » réclamait à elle seule plus de la
  /// moitié de l'écran et il ne restait au nom que de quoi l'émietter
  /// verticalement — « Bour / se / Direc / t ». Aucun réglage de troncature ne
  /// rattrape ça : c'est la mise en page en rangée qui ne tient plus. Seuil bas
  /// (1,3) parce que l'empilement ne coûte qu'un peu de hauteur, alors que
  /// l'émiettement rend la tuile illisible.
  static const double _stackedTextScaleThreshold = 1.3;

  /// Hauteur minimale de la tuile, reprise du [ListTile] à deux lignes qu'elle
  /// remplace, pour ne rien changer au rendu à l'échelle de police 1.
  static const double _minTileHeight = 72;

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
    final colorScheme = Theme.of(context).colorScheme;
    final isPositive = periodChange >= 0;
    final changeColor = AppColors.gainLoss(context, isPositive);

    // Sonde d'échelle : la taille demandée pour un corps de 15 rapportée à 15.
    const probeFontSize = 15.0;
    final textScale =
        MediaQuery.textScalerOf(context).scale(probeFontSize) / probeFontSize;
    final stacked = textScale > _stackedTextScaleThreshold;

    final avatar = CircleAvatar(
      backgroundColor: switch (account.type) {
        AccountType.cash => Colors.green.shade50,
        AccountType.preciousMetal => const Color(0xFFFFF3D6),
        AccountType.investment => colorScheme.primaryContainer,
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
          AccountType.investment => colorScheme.onPrimaryContainer,
        },
      ),
    );

    final identity = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          account.name,
          // Deux lignes puis ellipse : la tuile prend désormais la hauteur de
          // son contenu réel (le [ListTile] d'origine, lui, ignorait la hauteur
          // de son `trailing`, si bien que tronquer le titre RACCOURCISSAIT la
          // tuile et aggravait le débordement au lieu de le résoudre).
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          // Nature fine du compte (PEA, Assurance-vie, CTO, Cash-Épargne,
          // Crypto…) pour TOUS les comptes, cash inclus, plutôt que le type de
          // valorisation générique (« Investissement ») ou « Solde cash » : le
          // montant est déjà affiché à droite de la tuile. account.kind est
          // l'axe unique stocké, account.type n'en est que la projection.
          account.kind.localizedLabel(l10n),
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
        ),
      ],
    );

    final amounts = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          stacked ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      children: [
        Text(
          Formatters.formatEur(value),
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        // Variation uniquement pour les comptes non-cash
        if (account.type != AccountType.cash) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                isPositive ? Icons.trending_up : Icons.trending_down,
                color: changeColor,
                size: 11,
              ),
              const SizedBox(width: 2),
              Flexible(
                child: Text(
                  '${Formatters.formatEurSigned(periodChange)} (${Formatters.formatPercentFr(periodChangePercent)})',
                  style: TextStyle(
                    color: changeColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );

    // Empilé, le nom dispose de toute la largeur et les montants passent
    // dessous ; en rangée, c'est le nom qui cède la place (il s'ellipse sans
    // dommage, un montant tronqué serait trompeur).
    final content = stacked
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              avatar,
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    identity,
                    const SizedBox(height: 8),
                    amounts,
                  ],
                ),
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              avatar,
              const SizedBox(width: 16),
              Expanded(child: identity),
              const SizedBox(width: 8),
              amounts,
            ],
          );

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
        // Rangée maison plutôt que [ListTile] : ce dernier calcule sa hauteur
        // sur son titre et son sous-titre SANS tenir compte de son `trailing`,
        // d'où un débordement de 14 px par le bas à l'échelle de police 2,0 que
        // ni une ellipse ni une contrainte de hauteur ne pouvaient corriger. Ici
        // la tuile prend simplement la hauteur de ses enfants.
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _minTileHeight),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

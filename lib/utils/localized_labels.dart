// lib/utils/localized_labels.dart
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';

/// Helpers mappant les enums du modèle vers leurs libellés localisés.
/// On garde les enums du modèle inchangés (leur champ `label` reste utilisé
/// pour la sérialisation/compatibilité) et on centralise ici la traduction UI.
extension LocalizedAssetType on AssetType {
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case AssetType.etf:
        return l10n.assetTypeEtf;
      case AssetType.stock:
        return l10n.assetTypeStock;
      case AssetType.bond:
        return l10n.assetTypeBond;
      case AssetType.crypto:
        return l10n.assetTypeCrypto;
      case AssetType.fund:
        return l10n.assetTypeFund;
      case AssetType.preciousMetal:
        return l10n.assetTypePreciousMetal;
      case AssetType.realEstate:
        return l10n.assetTypeRealEstate;
      case AssetType.other:
        return l10n.assetTypeOther;
    }
  }
}

extension LocalizedAccountType on AccountType {
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case AccountType.investment:
        return l10n.accountTypeInvestment;
      case AccountType.cash:
        return l10n.accountTypeCash;
      case AccountType.preciousMetal:
        return l10n.accountTypePreciousMetal;
    }
  }
}

extension LocalizedAccountKind on AccountKind {
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case AccountKind.cto:
        return l10n.accountKindCto;
      case AccountKind.pea:
        return l10n.accountKindPea;
      case AccountKind.peaPme:
        return l10n.accountKindPeaPme;
      case AccountKind.assuranceVie:
        return l10n.accountKindAssuranceVie;
      case AccountKind.pee:
        return l10n.accountKindPee;
      case AccountKind.per:
        return l10n.accountKindPer;
      case AccountKind.crypto:
        return l10n.accountKindCrypto;
      // cash / preciousMetal réutilisent les libellés de valorisation existants.
      case AccountKind.cash:
        return l10n.accountTypeCash;
      case AccountKind.preciousMetal:
        return l10n.accountTypePreciousMetal;
      case AccountKind.autre:
        return l10n.accountKindAutre;
    }
  }
}

extension LocalizedChartPeriod on ChartPeriod {
  /// Libellé localisé, pour l'affichage (chips du sélecteur de période,
  /// variation « sur {période} »).
  ///
  /// Seules les périodes de `visibleChartPeriods` (jour, 1 mois, 3 mois,
  /// 1 an, 5 ans, max) sont réellement affichées dans l'UI. Les autres
  /// valeurs de l'enum (semaine, 6 mois, 2 ans, 10 ans, YTD) ne sont
  /// aujourd'hui jamais sélectionnables par l'utilisateur ; elles restent
  /// gérées ici pour un switch exhaustif et retombent sur `label` (libellé
  /// brut non traduit, jamais rendu à l'écran en pratique).
  String localizedLabel(AppLocalizations l10n) {
    switch (this) {
      case ChartPeriod.day:
        return l10n.chartPeriod1D;
      case ChartPeriod.month1:
        return l10n.chartPeriod1M;
      case ChartPeriod.month3:
        return l10n.chartPeriod3M;
      case ChartPeriod.year1:
        return l10n.chartPeriod1Y;
      case ChartPeriod.year5:
        return l10n.chartPeriod5Y;
      case ChartPeriod.max:
        return l10n.chartPeriodMax;
      case ChartPeriod.week:
      case ChartPeriod.month6:
      case ChartPeriod.year2:
      case ChartPeriod.year10:
      case ChartPeriod.ytd:
        return label;
    }
  }
}

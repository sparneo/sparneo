import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:portfolio_tracker/utils/chart_periods.dart';

class Formatters {
  /// Formate un nombre avec signe (+ ou -)
  static String formatDoubleWithSign(double value, {int decimalPlaces = 2}) {
    final sign = value >= 0 ? '+' : '-';
    return '$sign${value.abs().toStringAsFixed(decimalPlaces)}';
  }

  /// Formate un pourcentage avec signe (valeur nue, sans symbole %).
  static String formatPercentageDouble(double value, {int decimalPlaces = 1}) {
    final sign = value >= 0 ? '+' : '-';
    return '$sign${value.abs().toStringAsFixed(decimalPlaces)}';
  }

  /// Formate un pourcentage à la française, prêt à afficher : signe, virgule
  /// décimale et « % » précédé d'une espace insécable : « +2,2 % », « -4,8 % ».
  /// Le zéro est considéré positif (cohérent avec [formatPercentageDouble]).
  static String formatPercentFr(double value, {int decimalPlaces = 1}) {
    final sign = value >= 0 ? '+' : '-';
    final number = value.abs().toStringAsFixed(decimalPlaces).replaceAll('.', ',');
    return '$sign$number %';
  }

  /// Formate une date courte selon la période sélectionnée
  static String formatShortDate(DateTime dt, {required int periodDays}) {
    // 5 ans ou plus : mois/année
    if (periodDays >= 1825) {
      return '${dt.month}/${dt.year}';
    }
    // 1 an ou YTD : jour/mois
    else if (periodDays >= 365 || periodDays == 0) {
      return '${dt.day}/${dt.month}';
    }
    // Autres : jour/mois
    else {
      return '${dt.day}/${dt.month}';
    }
  }

  /// Formate une date avec heure (pour les vues journalières)
  static String formatDateTimeWithTime(DateTime dt) {
    return '${dt.day}/${dt.month} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  //// Formate une date pour l'axe des abscisses selon la période
  static String formatAxisDate(DateTime dt, ChartPeriod period, [String locale = 'fr']) {
    switch (period) {
      case ChartPeriod.day:
        // J -> heures à la minute 0 (1h00, 2h00, etc.)
        return '${dt.hour.toString().padLeft(2, '0')}h00';
      case ChartPeriod.week:
      case ChartPeriod.month1:
        // S et 1M -> jours (28/05, 29/05, 01/06)
        return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}';
      case ChartPeriod.month3:
      case ChartPeriod.month6:
      case ChartPeriod.year1:
      case ChartPeriod.ytd:
        // 3M, 6M, 1A, YTD -> mois abrégé localisé (jan, fév, mar / Jan, Feb...)
        return _getMonthAbbr(dt, locale);
      case ChartPeriod.year2:
      case ChartPeriod.year5:
      case ChartPeriod.year10:
      case ChartPeriod.max:
        // >= 2A -> année (2024, 2025)
        return dt.year.toString();
    }
  }

  /// Formate une date pour le tooltip selon la période
  static String formatTooltipDate(DateTime dt, ChartPeriod period, [String locale = 'fr']) {
    switch (period) {
      case ChartPeriod.day:
        // J -> heure exacte (3h10, 3h15)
        return '${dt.hour.toString().padLeft(2, '0')}h${dt.minute.toString().padLeft(2, '0')}';
      case ChartPeriod.week:
      case ChartPeriod.month1:
        // S et 1M -> jour + heure exacte (30/05 9h10)
        return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}h${dt.minute.toString().padLeft(2, '0')}';
      case ChartPeriod.month3:
      case ChartPeriod.month6:
      case ChartPeriod.ytd:
        // 3M, 6M, YTD -> jour seulement (28/05, 29/05)
        return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}';
      case ChartPeriod.year1:
      case ChartPeriod.year2:
      case ChartPeriod.year5:
      case ChartPeriod.year10:
      case ChartPeriod.max:
        // >= 1A (l'étendue peut chevaucher plusieurs années civiles) ->
        // jour + année (28/05/2023) pour lever l'ambiguïté
        return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
    }
  }

  /// Abréviation de mois localisée (ex : « janv. » / « Jan ») selon la locale.
  static String _getMonthAbbr(DateTime dt, String locale) {
    return DateFormat.MMM(locale).format(dt);
  }

  /// Formate une date complète
  static String formatDateTime(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// Retourne le symbole de devise
  static String formatCurrencySymbol(String? currency) {
    switch (currency?.toUpperCase()) {
      case 'EUR':
        return '€';
      case 'USD':
        return '\$';
      case 'GBP':
        return '£';
      default:
        return currency ?? '';
    }
  }

  /// Formate un montant en euros à la française : « 153 112,95 € »
  /// (séparateur de milliers = espace insécable, virgule décimale, € suffixé).
  ///
  /// À utiliser pour TOUT montant AFFICHÉ. Ne jamais l'employer pour la valeur
  /// d'un champ éditable (contrôleur de saisie) : garder `toStringAsFixed` brut.
  static String formatEur(num value, {int decimals = 2}) {
    return NumberFormat.currency(
      locale: 'fr_FR',
      symbol: '€',
      decimalDigits: decimals,
    ).format(value);
  }

  /// Comme [formatEur] mais préfixé d'un signe explicite (+ ou -), pour les
  /// variations affichées : « +1 234,56 € », « -1 234,56 € ». Le zéro est
  /// considéré positif (cohérent avec [formatDoubleWithSign]).
  static String formatEurSigned(num value, {int decimals = 2}) {
    final sign = value >= 0 ? '+' : '-';
    return '$sign${formatEur(value.abs(), decimals: decimals)}';
  }

  /// Formate un montant dans sa devise, mise en forme française :
  /// « 1 234,56 € », « 1 234,56 \$ », « 1 234,56 £ »…
  static String formatMoney(num value, String? currency, {int decimals = 2}) {
    return NumberFormat.currency(
      locale: 'fr_FR',
      symbol: formatCurrencySymbol(currency),
      decimalDigits: decimals,
    ).format(value);
  }

  /// Formate une valeur monétaire avec symbole (mise en forme française).
  static String formatCurrency(num value, String? currency, {int decimalPlaces = 2}) {
    return formatMoney(value, currency, decimals: decimalPlaces);
  }

  /// Formate une valeur monétaire avec conversion USD→EUR.
  static String formatCurrencyWithConversion(
    num value,
    String currency,
    double? eurRate, {
    int decimalPlaces = 2,
  }) {
    if (currency.toUpperCase() == 'USD' && eurRate != null) {
      final eurValue = value * eurRate;
      return '${formatMoney(value, currency, decimals: decimalPlaces)} '
          '(${formatEur(eurValue, decimals: decimalPlaces)})';
    }
    return formatMoney(value, currency, decimals: decimalPlaces);
  }

  /// Détermine la couleur basée sur la variation
  static Color getChangeColor(double value, {Color positive = const Color(0xFF1B5E20), Color negative = const Color(0xFFB71C1C)}) {
    return value >= 0 ? positive : negative;
  }

  /// Détermine l'icône basée sur la variation
  IconData getChangeIcon(double value) {
    return value >= 0 ? Icons.trending_up : Icons.trending_down;
  }
}
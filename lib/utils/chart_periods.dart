// lib/utils/chart_period.dart
enum ChartPeriod {
  day('J', 1),
  week('S', 7),
  month1('1M', 30),
  month3('3M', 90),
  month6('6M', 180),
  year1('1A', 365),
  year2('2A', 730),
  year5('5A', 1825),
  year10('10A', 3650),
  ytd('YTD', 0),
  max('Max', -1);

  final String label;
  final int days;
  const ChartPeriod(this.label, this.days);
}

/// Sous-ensemble de périodes affichées dans [PeriodSelector].
///
/// L'enum [ChartPeriod] reste complet (tests et `formatters.dart` en
/// dépendent) : seule la liste VISIBLE dans l'UI est restreinte, pour éviter
/// une rangée de ~11 chips minuscules. Choix : J / 1M / 3M / 1A / 5A / Max
/// couvrent les usages courants sans surcharger la barre.
const List<ChartPeriod> visibleChartPeriods = [
  ChartPeriod.day,
  ChartPeriod.month1,
  ChartPeriod.month3,
  ChartPeriod.year1,
  ChartPeriod.year5,
  ChartPeriod.max,
];
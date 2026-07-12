// lib/model/valuation_snapshot.dart

/// Instantané journalier de la valeur totale d'un wallet.
/// Une entrée par wallet et par jour (clé d'idempotence : [date]).
class ValuationSnapshot {
  /// Jour local de la capture, format 'YYYY-MM-DD'. Sert de clé d'idempotence.
  final String date;

  /// Valeur totale du patrimoine du wallet, exprimée en EUR.
  final double totalValue;

  /// Devise de valorisation (fixé à 'EUR' au MVP, conservé pour migration future).
  final String currency;

  /// Epoch ms du moment réel de la capture (traçabilité / tie-break).
  final int capturedAt;

  /// Nombre de comptes agrégés dans ce snapshot (diagnostic).
  final int accountCount;

  /// Version du schéma (1 au MVP, permet une migration SQLite future).
  final int schemaVersion;

  ValuationSnapshot({
    required this.date,
    required this.totalValue,
    this.currency = 'EUR',
    required this.capturedAt,
    this.accountCount = 0,
    this.schemaVersion = 1,
  });

  // --- Sérialisation JSON ---

  factory ValuationSnapshot.fromJson(Map<String, dynamic> json) {
    return ValuationSnapshot(
      date: json['date'] ?? '',
      totalValue: (json['totalValue'] as num?)?.toDouble() ?? 0.0,
      currency: json['currency'] ?? 'EUR',
      capturedAt: (json['capturedAt'] as num?)?.toInt() ?? 0,
      accountCount: (json['accountCount'] as num?)?.toInt() ?? 0,
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'date': date,
      'totalValue': totalValue,
      'currency': currency,
      'capturedAt': capturedAt,
      'accountCount': accountCount,
      'schemaVersion': schemaVersion,
    };
  }

  // --- Helpers ---

  /// Formate une [DateTime] en clé 'YYYY-MM-DD' (date locale, zéros padding).
  static String dateKeyFor(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

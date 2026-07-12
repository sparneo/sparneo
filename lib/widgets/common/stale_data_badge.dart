// lib/widgets/common/stale_data_badge.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';

/// Badge discret signalant qu'un cours provient du cache (« dernier cours
/// connu ») et non d'une cotation en direct.
///
/// [asOf] = date de mise en cache. `null` → donnée en direct, aucun badge
/// (le widget se réduit à néant). Non-null → petite puce « Cours du JJ/MM ».
class StaleDataBadge extends StatelessWidget {
  final DateTime? asOf;

  const StaleDataBadge({super.key, required this.asOf});

  @override
  Widget build(BuildContext context) {
    final at = asOf;
    if (at == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final label = l10n.quoteAsOf(DateFormat('dd/MM').format(at));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 12, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

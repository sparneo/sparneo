// lib/utils/error_text.dart
import 'package:flutter/widgets.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/services/api_error.dart';

/// Traduit une erreur (exception, [ApiError], ou message brut déjà stringifié)
/// en un message utilisateur localisé et NON technique.
///
/// Règle : ne jamais afficher `e.toString()` / `SocketException…` à
/// l'utilisateur — passer l'erreur (ou la chaîne d'erreur stockée) ici.
class ErrorText {
  const ErrorText._();

  static String of(BuildContext context, Object? error) {
    final l10n = AppLocalizations.of(context)!;
    if (error is ApiError) return _fromType(error.type, l10n);

    final lower = (error?.toString() ?? '').toLowerCase();
    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection') ||
        lower.contains('timeout') ||
        lower.contains('timed out')) {
      return l10n.errorNetwork;
    }
    return l10n.errorGeneric;
  }

  static String _fromType(ApiErrorType type, AppLocalizations l10n) {
    switch (type) {
      case ApiErrorType.rateLimit:
        return l10n.errorRateLimit;
      case ApiErrorType.network:
        return l10n.errorNetwork;
      case ApiErrorType.invalidSymbol:
        return l10n.errorInvalidSymbol;
      case ApiErrorType.serverError:
        return l10n.errorServer;
      case ApiErrorType.unknown:
        return l10n.errorGeneric;
    }
  }
}

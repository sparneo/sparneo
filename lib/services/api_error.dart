import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:portfolio_tracker/utils/logger.dart';

enum ApiErrorType { rateLimit, network, invalidSymbol, serverError, unknown }

class ApiError implements Exception {
  final ApiErrorType type;
  final String message;

  ApiError(this.type, this.message);

  /// Indique si l'erreur est susceptible de réussir lors d'une nouvelle tentative.
  /// On réessaie sur les problèmes réseau, le rate limit (429) et les erreurs serveur (5xx).
  /// On ne réessaie PAS sur un symbole invalide (404) ni sur les autres erreurs 4xx.
  bool get isRetryable =>
      type == ApiErrorType.network ||
      type == ApiErrorType.rateLimit ||
      type == ApiErrorType.serverError;

  /// Construit une ApiError à partir d'un code de statut HTTP.
  factory ApiError.fromStatusCode(int statusCode) {
    if (statusCode == 429) {
      return ApiError(
        ApiErrorType.rateLimit,
        'Limite de requêtes atteinte (HTTP 429)',
      );
    }
    if (statusCode == 404) {
      return ApiError(
        ApiErrorType.invalidSymbol,
        'Ressource introuvable / symbole invalide (HTTP 404)',
      );
    }
    if (statusCode >= 500 && statusCode <= 599) {
      return ApiError(
        ApiErrorType.serverError,
        'Erreur serveur (HTTP $statusCode)',
      );
    }
    return ApiError(
      ApiErrorType.unknown,
      'Erreur HTTP inattendue (HTTP $statusCode)',
    );
  }

  /// Construit une ApiError à partir d'une exception levée (réseau, timeout, etc.).
  factory ApiError.fromException(Object error) {
    if (error is ApiError) {
      return error;
    }
    if (error is SocketException ||
        error is TimeoutException ||
        error is http.ClientException ||
        error is HttpException) {
      return ApiError(
        ApiErrorType.network,
        'Erreur réseau: $error',
      );
    }
    return ApiError(
      ApiErrorType.unknown,
      'Erreur inattendue: $error',
    );
  }

  @override
  String toString() => '[ApiError:${type.name}] $message';
}

/// Exécute [action] avec un backoff exponentiel.
///
/// - [maxAttempts] tentatives au total (par défaut 3).
/// - Délais entre tentatives : 500ms, 1s, 2s, ...
/// - L'[action] doit lever une [ApiError] (via [ApiError.fromStatusCode] /
///   [ApiError.fromException]) pour signaler un échec ; seules les erreurs
///   marquées [ApiError.isRetryable] déclenchent une nouvelle tentative.
/// - [context] sert uniquement à enrichir les logs.
///
/// Si toutes les tentatives échouent (ou si l'erreur n'est pas réessayable),
/// la dernière [ApiError] est relancée à l'appelant, qui décide du fallback.
Future<T> retryWithBackoff<T>(
  Future<T> Function() action, {
  required String context,
  int maxAttempts = 3,
  Duration initialDelay = const Duration(milliseconds: 500),
}) async {
  Duration delay = initialDelay;
  ApiError lastError = ApiError(ApiErrorType.unknown, 'Aucune tentative exécutée');

  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await action();
    } catch (e) {
      lastError = ApiError.fromException(e);

      // Erreur non réessayable (ex: 404 symbole invalide) -> on abandonne tout de suite.
      if (!lastError.isRetryable) {
        AppLogger.warning('[$context] Échec non réessayable: $lastError');
        rethrow;
      }

      // Dernière tentative épuisée.
      if (attempt >= maxAttempts) {
        AppLogger.error(
          '[$context] Échec après $maxAttempts tentatives: $lastError',
        );
        throw lastError;
      }

      AppLogger.warning(
        '[$context] Tentative $attempt/$maxAttempts échouée ($lastError), '
        'nouvel essai dans ${delay.inMilliseconds}ms',
      );
      await Future.delayed(delay);
      delay *= 2; // Backoff exponentiel.
    }
  }

  // Inatteignable en pratique, mais nécessaire pour le typage.
  throw lastError;
}

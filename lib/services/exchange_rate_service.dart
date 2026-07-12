import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:portfolio_tracker/services/api_error.dart';
import 'package:portfolio_tracker/utils/logger.dart';

class ExchangeRateService {
  static const String _baseUrl = 'https://api.frankfurter.app/latest';
  static const double _fallbackRate = 0.92;

  // Singleton : tous les `ExchangeRateService()` du projet partagent la même
  // instance, donc le cache 24h (taux + horodatage) est mutualisé entre les
  // widgets (wallet_view, account_view, position_detail_page). Cela évite de
  // refaire un appel réseau au taux de change depuis chaque widget.
  static final ExchangeRateService _instance = ExchangeRateService._internal();
  factory ExchangeRateService() => _instance;
  ExchangeRateService._internal();

  /// Constructeur réservé aux tests : crée une instance indépendante du
  /// singleton, ce qui permet de sous-classer le service dans les fakes.
  @visibleForTesting
  ExchangeRateService.forTesting();

  // Cache PAR DEVISE : pour chaque devise (clé en majuscules), on mémorise le
  // dernier taux vers EUR et l'horodatage de récupération. La validité est de
  // 24h, comme le comportement historique du cache USD.
  final Map<String, double> _ratesToEur = {};
  final Map<String, DateTime> _lastUpdates = {};

  /// Récupère le taux `currency` -> EUR (avec cache de 24h par devise).
  ///
  /// - retourne 1.0 si `currency` vaut EUR (insensible à la casse) ;
  /// - sinon interroge frankfurter (`?from=XXX&to=EUR`) avec backoff ;
  /// - en cas d'échec, retombe sur un fallback raisonnable (0.92 pour USD,
  ///   1.0 sinon pour ne pas fausser brutalement l'agrégation).
  Future<double> getRateToEur(String currency) async {
    final code = currency.toUpperCase();

    // L'EUR n'a pas besoin de conversion.
    if (code == 'EUR') return 1.0;

    // Si le taux de cette devise est récent (< 24h), on le réutilise.
    final lastUpdate = _lastUpdates[code];
    if (lastUpdate != null &&
        lastUpdate.add(const Duration(hours: 24)).isAfter(DateTime.now())) {
      return _ratesToEur[code] ?? _fallbackFor(code);
    }

    try {
      // Tentatives avec backoff ; lève une ApiError en cas de statut non-200.
      final rate = await retryWithBackoff<double>(
        context: 'getRateToEur($code)',
        () async {
          final response = await http
              .get(Uri.parse('$_baseUrl?from=$code&to=EUR'))
              .timeout(const Duration(seconds: 10));

          if (response.statusCode != 200) {
            throw ApiError.fromStatusCode(response.statusCode);
          }

          final data = jsonDecode(response.body);
          final value = data['rates']['EUR'] as num;
          return value.toDouble();
        },
      );

      _ratesToEur[code] = rate;
      _lastUpdates[code] = DateTime.now();
      return rate;
    } catch (e) {
      // Échec final : on log via ApiError et on retombe sur le fallback.
      final apiError = ApiError.fromException(e);
      AppLogger.error('Erreur récupération taux de change ($code): $apiError');
    }

    // Retourne un taux par défaut en cas d'erreur.
    return _fallbackFor(code);
  }

  /// Fallback raisonnable par devise : 0.92 pour USD (valeur historique),
  /// 1.0 pour les autres afin de ne pas dénaturer le montant agrégé.
  double _fallbackFor(String code) {
    return code == 'USD' ? _fallbackRate : 1.0;
  }

  /// Récupère le taux USD -> EUR (avec cache de 24h).
  ///
  /// Conservé pour compatibilité : délègue désormais à [getRateToEur] afin
  /// d'éviter toute duplication de logique.
  Future<double> getUsdToEurRate() => getRateToEur('USD');
}
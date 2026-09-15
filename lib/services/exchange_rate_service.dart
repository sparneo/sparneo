import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:portfolio_tracker/services/api_error.dart';
import 'package:portfolio_tracker/utils/logger.dart';

/// Levée par [ExchangeRateService.getDailyRatesToEur] en cas d'échec réseau/
/// HTTP/parsing de la série FX HISTORIQUE (chantier B16, lot 2 — conception
/// interne). JAMAIS de repli [ExchangeRateService._fallbackFor] pour cette
/// méthode : un taux de secours peut servir un simple AFFICHAGE (cf.
/// [ExchangeRateService.getRateToEur]), jamais figer une base de coût au journal
/// — l'appelant (`CryptoValuationService`/`AccountController`) doit pouvoir
/// distinguer « FX indisponible » de « taux 0,92 approximatif » et basculer TOUS
/// les échanges concernés en arbitrage manuel, sans coercition.
class ExchangeRateUnavailable implements Exception {
  final String message;
  const ExchangeRateUnavailable(this.message);

  @override
  String toString() => 'ExchangeRateUnavailable: $message';
}

class ExchangeRateService {
  static const String _baseUrl = 'https://api.frankfurter.app/latest';
  static const double _fallbackRate = 0.92;

  // Endpoint HISTORIQUE (série journalière, lot 2) — domaine `.dev/v1`,
  // DISTINCT du `.app/latest` ci-dessus (taux spot du jour, `getRateToEur`) :
  // `.app` redirige (301) sur `.dev`, vérifié — on interroge directement le
  // domaine cible pour éviter un aller-retour de redirection inutile.
  static const String _dailyBaseUrl = 'https://api.frankfurter.dev/v1';

  // Élargissement de la borne `from` d'une requête [getDailyRatesToEur] : la série
  // frankfurter est ABSENTE les week-ends/jours fériés BCE (pas de fixing ces
  // jours-là) — sans cette marge, une requête dont `from` tombe un samedi ne
  // pourrait jamais retomber sur un dernier jour ouvré ANTÉRIEUR (conception
  // interne : repli au dernier jour ouvré, JAMAIS d'interpolation). ~10 jours
  // couvre largement le plus long enchaînement de fériés consécutifs observé en
  // zone euro (Noël/Nouvel An).
  static const int _dailyRatesLookbackDays = 10;

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

  // Cache des séries JOURNALIÈRES ([getDailyRatesToEur]) — MÉMOIRE SEULE, SANS TTL
  // (contrairement au cache spot ci-dessus) : la clé embarque déjà les bornes
  // ÉLARGIES de la requête (devise + from élargi + to), donc deux appels portant
  // sur la MÊME période servent le même résultat sans jamais devenir périmés au
  // sens où l'entend le cache spot (un taux BCE historique ne change pas
  // rétroactivement). Portée : la durée de vie de CETTE instance (conception
  // interne, "durée de l'assistant d'import") — pas de persistance disque, ~50 ko
  // au pire pour un historique Kraken complet.
  final Map<String, Map<DateTime, double>> _dailyRatesCache = {};

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

  // --------------------------------------------------------------------- Série
  // journalière historique (chantier B16, lot 2 — conception interne)
  // ---------------------------------------------------------------------

  /// Série JOURNALIÈRE [currency] → EUR sur `[from]..[to]` (bornes incluses),
  /// UN SEUL appel HTTP pour toute la période (ex. ~2 200 jours ouvrés d'un
  /// historique Kraken complet, ~60 ko). `rate` = combien d'EUR vaut 1
  /// [currency] ce jour-là.
  ///
  /// La requête RÉELLE part de `[from] - [_dailyRatesLookbackDays] jours`
  /// (jamais [to], qui n'a pas besoin d'être élargi) : les week-ends/jours
  /// fériés BCE sont ABSENTS de la série retournée par frankfurter, donc un
  /// `[from]` tombant un jour non ouvré ne retomberait sinon jamais sur un
  /// jour PRÉSENT dans la série — c'est au CONSOMMATEUR (`CryptoValuationService`)
  /// de replier sur le dernier jour ouvré antérieur trouvé dans la map
  /// retournée ; cette méthode ne fait QUE fournir la matière première, elle
  /// n'interpole ni ne devine jamais un taux absent.
  ///
  /// Cache MÉMOIRE SEUL, clé `devise + bornes ÉLARGIES` : un second appel sur
  /// la MÊME période élargie est servi depuis ce cache, sans repartir en
  /// réseau (cf. [_dailyRatesCache]).
  ///
  /// LÈVE [ExchangeRateUnavailable] en cas d'échec réseau/HTTP/parsing —
  /// JAMAIS de repli [_fallbackFor] : un taux de secours peut servir un
  /// simple affichage, jamais figer une base de coût au journal (cf. doc de
  /// [ExchangeRateUnavailable]).
  Future<Map<DateTime, double>> getDailyRatesToEur(
    String currency, {
    required DateTime from,
    required DateTime to,
  }) async {
    final code = currency.toUpperCase();
    final widenedFrom = _dateOnly(from)
        .subtract(const Duration(days: _dailyRatesLookbackDays));
    final widenedTo = _dateOnly(to);
    final cacheKey = '$code:${_isoDay(widenedFrom)}:${_isoDay(widenedTo)}';

    final cached = _dailyRatesCache[cacheKey];
    if (cached != null) return cached;

    final url = Uri.parse(
      '$_dailyBaseUrl/${_isoDay(widenedFrom)}..${_isoDay(widenedTo)}'
      '?base=$code&symbols=EUR',
    );

    try {
      final rates = await retryWithBackoff<Map<DateTime, double>>(
        context: 'getDailyRatesToEur($code)',
        () async {
          final response =
              await http.get(url).timeout(const Duration(seconds: 20));

          if (response.statusCode != 200) {
            throw ApiError.fromStatusCode(response.statusCode);
          }

          final data = jsonDecode(response.body);
          final ratesJson = data is Map ? data['rates'] : null;
          // M-3 (revue adversariale, B16 lot 2) : un `rates` VIDE (réponse 200
          // mais objet `{}`, ex. période hors couverture frankfurter) n'est
          // PAS un succès — sans cette garde, `parsed` resterait vide et
          // SERAIT MIS EN CACHE tel quel (cf. `_dailyRatesCache[cacheKey] =
          // rates` plus bas) : tout appel ultérieur sur la même période
          // élargie servirait silencieusement cette série vide au lieu de
          // retenter, et `CryptoValuationService._lastRateOnOrBefore` ne
          // trouverait jamais de jour ouvré antérieur. Même politique que
          // `ratesJson is! Map` : lève, ne cache rien.
          if (ratesJson is! Map || ratesJson.isEmpty) {
            throw const FormatException(
              'réponse frankfurter sans champ "rates" exploitable',
            );
          }
          final parsed = <DateTime, double>{};
          for (final entry in ratesJson.entries) {
            final day = DateTime.tryParse(entry.key.toString());
            final dayRates = entry.value;
            final eur = dayRates is Map ? dayRates['EUR'] : null;
            if (day != null && eur is num) {
              parsed[_dateOnly(day)] = eur.toDouble();
            }
          }
          return parsed;
        },
      );

      _dailyRatesCache[cacheKey] = rates;
      return rates;
    } catch (e) {
      AppLogger.error(
        'Erreur récupération série FX historique ($code, '
        '${_isoDay(widenedFrom)}..${_isoDay(widenedTo)}): $e',
      );
      throw ExchangeRateUnavailable(
        'Série FX $code→EUR indisponible (${_isoDay(widenedFrom)}..'
        '${_isoDay(widenedTo)}) : $e',
      );
    }
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

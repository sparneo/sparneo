// lib/utils/app_logger.dart
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class AppLogger {
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2, // Nombre de méthodes à afficher dans la pile d'appels
      errorMethodCount: 8, // Nombre de méthodes pour les erreurs
      lineLength: 120, // Largeur des lignes
      colors: true, // Couleurs activées
      printEmojis: true, // Emojis activés
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
    // ⭐ En production, n'afficher que les warnings et erreurs
    level: kDebugMode ? Level.debug : Level.warning,
    output: kDebugMode ? null : _ProductionOutput(), // Optionnel : rediriger vers un fichier
  );

  // Méthodes statiques pour faciliter l'utilisation
  static void debug(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.d(message, error: error, stackTrace: stackTrace);
  }

  static void info(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.i(message, error: error, stackTrace: stackTrace);
  }

  static void warning(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.w(message, error: error, stackTrace: stackTrace);
  }

  static void error(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }

  static void trace(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.t(message, error: error, stackTrace: stackTrace);
  }

  static void fatal(dynamic message, [dynamic error, StackTrace? stackTrace]) {
    _logger.f(message, error: error, stackTrace: stackTrace);
  }
}

// Optionnel : Output personnalisé pour la production (ex: fichier, Crashlytics)
class _ProductionOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    // Ici, vous pouvez envoyer les logs à Firebase Crashlytics, Sentry, etc.
    // Pour l'instant, on ne fait rien en production
  }
}
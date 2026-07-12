// lib/controllers/theme_controller.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Contrôleur de la préférence de THÈME (système / clair / sombre).
///
/// Préférence d'APPAREIL, pas de patrimoine : persistée via SharedPreferences
/// et volontairement EXCLUE du pont backup (cf. BackupService/AccountStorage,
/// qui n'exportent que les données de patrimoine — aucune clé de thème n'y
/// transite).
///
/// Singleton runtime accessible via [ThemeController.shared], calqué sur le
/// motif [AppDatabase.shared] : évite de faire transiter le contrôleur par
/// constructeur à travers MainApp → WalletView → SettingsPage, sans
/// introduire de mécanisme d'injection (Provider/InheritedWidget) absent du
/// projet.
class ThemeController extends ChangeNotifier {
  static const String _prefsKey = 'theme_mode';

  static ThemeController? _shared;

  /// Instance partagée (créée à la demande, une seule fois par process).
  static ThemeController shared() => _shared ??= ThemeController();

  /// Réservé aux tests : force une nouvelle instance partagée.
  @visibleForTesting
  static void resetSharedForTest() => _shared = null;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  /// Charge la préférence persistée (défaut : système si absente ou
  /// invalide). À appeler une fois, avant `runApp`.
  ///
  /// [prefs] injectable pour les tests (sinon `SharedPreferences.getInstance`).
  Future<void> load({SharedPreferences? prefs}) async {
    final sp = prefs ?? await SharedPreferences.getInstance();
    final mode = _decode(sp.getString(_prefsKey));
    if (mode != _themeMode) {
      _themeMode = mode;
      notifyListeners();
    }
  }

  /// Change le mode de thème et le persiste immédiatement.
  ///
  /// [prefs] injectable pour les tests (sinon `SharedPreferences.getInstance`).
  Future<void> setThemeMode(ThemeMode mode, {SharedPreferences? prefs}) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    final sp = prefs ?? await SharedPreferences.getInstance();
    await sp.setString(_prefsKey, _encode(mode));
  }

  static ThemeMode _decode(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}

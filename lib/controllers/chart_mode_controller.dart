// lib/controllers/chart_mode_controller.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Portée d'un choix de mode de courbe : le mode voulu sur le patrimoine
/// global n'est pas forcément celui voulu pour juger un titre (on regarde
/// volontiers l'évolution réelle de son patrimoine, et la rétroprojection
/// « Vos positions » d'une ligne pour lire son cours). Trois clés distinctes,
/// donc, plutôt qu'une préférence unique.
enum ChartModeScope { wallet, account, position }

/// Contrôleur de la préférence de MODE DE COURBE (mode 1 « Vos positions » /
/// mode 2 « Évolution réelle »), une valeur par [ChartModeScope].
///
/// `null` pour une portée = l'utilisateur n'a JAMAIS tranché sur cet écran :
/// le mode est alors résolu automatiquement par la politique de qualité
/// (`lib/logic/chart_mode_policy.dart`). Dès qu'il touche au sélecteur, son
/// choix est persisté et prime.
///
/// Préférence d'APPAREIL, pas de patrimoine — MÊME motif que
/// [ThemeController] : persistée via SharedPreferences et volontairement
/// EXCLUE du pont backup (BackupService/AccountStorage n'exportent que les
/// données de patrimoine ; aucune clé de mode n'y transite). Singleton
/// runtime accessible via [ChartModeController.shared], pour ne pas faire
/// transiter le contrôleur par constructeur à travers WalletView →
/// AccountView → PositionDetailPage.
class ChartModeController extends ChangeNotifier {
  /// Clés SharedPreferences, une par portée. Nommées en dur (pas dérivées de
  /// `scope.name`) : renommer un membre de l'enum ne doit pas effacer
  /// silencieusement la préférence des utilisateurs déjà installés.
  static const Map<ChartModeScope, String> _prefsKeys = {
    ChartModeScope.wallet: 'chart_mode_real_wallet',
    ChartModeScope.account: 'chart_mode_real_account',
    ChartModeScope.position: 'chart_mode_real_position',
  };

  static ChartModeController? _shared;

  /// Instance partagée (créée à la demande, une seule fois par process).
  static ChartModeController shared() => _shared ??= ChartModeController();

  /// Réservé aux tests : force une nouvelle instance partagée.
  @visibleForTesting
  static void resetSharedForTest() => _shared = null;

  final Map<ChartModeScope, bool> _choices = {};

  /// Choix persisté pour [scope], ou `null` si l'utilisateur n'a jamais
  /// basculé le sélecteur de cet écran (→ résolution automatique).
  bool? choiceFor(ChartModeScope scope) => _choices[scope];

  /// Charge les préférences persistées (absentes = `null` par portée). À
  /// appeler une fois, avant `runApp`.
  ///
  /// [prefs] injectable pour les tests (sinon `SharedPreferences.getInstance`).
  Future<void> load({SharedPreferences? prefs}) async {
    final sp = prefs ?? await SharedPreferences.getInstance();
    var changed = false;
    for (final entry in _prefsKeys.entries) {
      final stored = sp.getBool(entry.value);
      final previous = _choices[entry.key];
      if (stored == null) {
        if (previous != null) {
          _choices.remove(entry.key);
          changed = true;
        }
        continue;
      }
      if (previous != stored) {
        _choices[entry.key] = stored;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Enregistre le choix explicite de l'utilisateur pour [scope] et le
  /// persiste immédiatement. La valeur est posée en mémoire AVANT l'await :
  /// le `setState` de la vue appelante relit donc déjà la bonne, sans
  /// attendre le disque.
  ///
  /// [prefs] injectable pour les tests (sinon `SharedPreferences.getInstance`).
  Future<void> setChoice(
    ChartModeScope scope,
    bool useRealCurve, {
    SharedPreferences? prefs,
  }) async {
    if (_choices[scope] == useRealCurve) return;
    _choices[scope] = useRealCurve;
    notifyListeners();
    final sp = prefs ?? await SharedPreferences.getInstance();
    await sp.setBool(_prefsKeys[scope]!, useRealCurve);
  }
}

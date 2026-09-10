// test/controllers/chart_mode_controller_test.dart
//
// Vérifie ChartModeController : défaut « jamais choisi » (null) par portée,
// indépendance des trois portées, persistance/relecture via SharedPreferences,
// notification des listeners. Calqué sur theme_controller_test.dart. Pas
// d'appel réseau.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:portfolio_tracker/controllers/chart_mode_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChartModeController.resetSharedForTest();
  });

  test('défaut : aucune portée n\'a de choix (null partout)', () {
    final controller = ChartModeController();
    for (final scope in ChartModeScope.values) {
      expect(controller.choiceFor(scope), isNull);
    }
  });

  test('load() sans préférence stockée laisse tout à null', () async {
    final controller = ChartModeController();
    await controller.load();
    for (final scope in ChartModeScope.values) {
      expect(controller.choiceFor(scope), isNull);
    }
  });

  test('load() relit une préférence déjà persistée, portée par portée',
      () async {
    SharedPreferences.setMockInitialValues({
      'chart_mode_real_wallet': false,
      'chart_mode_real_position': true,
      // 'chart_mode_real_account' volontairement absente.
    });
    final controller = ChartModeController();
    await controller.load();

    expect(controller.choiceFor(ChartModeScope.wallet), isFalse);
    expect(controller.choiceFor(ChartModeScope.position), isTrue);
    expect(controller.choiceFor(ChartModeScope.account), isNull);
  });

  test('setChoice persiste puis est relu par une nouvelle instance', () async {
    final controller = ChartModeController();
    await controller.setChoice(ChartModeScope.account, false);
    expect(controller.choiceFor(ChartModeScope.account), isFalse);

    final reloaded = ChartModeController();
    await reloaded.load();
    expect(reloaded.choiceFor(ChartModeScope.account), isFalse);
    // Les autres portées restent vierges : trois clés distinctes.
    expect(reloaded.choiceFor(ChartModeScope.wallet), isNull);
    expect(reloaded.choiceFor(ChartModeScope.position), isNull);
  });

  test('les trois portées sont indépendantes', () async {
    final controller = ChartModeController();
    await controller.setChoice(ChartModeScope.wallet, true);
    await controller.setChoice(ChartModeScope.account, false);

    expect(controller.choiceFor(ChartModeScope.wallet), isTrue);
    expect(controller.choiceFor(ChartModeScope.account), isFalse);
    expect(controller.choiceFor(ChartModeScope.position), isNull);
  });

  test('setChoice notifie les listeners, et pas deux fois pour rien', () async {
    final controller = ChartModeController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.setChoice(ChartModeScope.wallet, false);
    expect(notifications, 1);

    // Même valeur : pas de notification superflue (idempotence).
    await controller.setChoice(ChartModeScope.wallet, false);
    expect(notifications, 1);

    await controller.setChoice(ChartModeScope.wallet, true);
    expect(notifications, 2);
  });

  test('la valeur est lisible AVANT que le disque ait répondu', () {
    final controller = ChartModeController();
    // Pas d'await : setChoice pose la valeur en mémoire puis notifie, avant
    // d'aller écrire — c'est ce qui permet au setState de la vue de relire
    // immédiatement le bon mode.
    controller.setChoice(ChartModeScope.position, false);
    expect(controller.choiceFor(ChartModeScope.position), isFalse);
  });

  test('shared() retourne toujours la même instance', () {
    final a = ChartModeController.shared();
    final b = ChartModeController.shared();
    expect(identical(a, b), isTrue);
  });
}

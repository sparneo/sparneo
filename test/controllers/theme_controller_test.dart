// test/controllers/theme_controller_test.dart
//
// Vérifie ThemeController : défaut système, persistance/relecture via
// SharedPreferences, notification des listeners. Pas d'appel réseau.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:portfolio_tracker/controllers/theme_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('défaut : themeMode == system avant tout chargement', () {
    final controller = ThemeController();
    expect(controller.themeMode, ThemeMode.system);
  });

  test('load() sans préférence stockée reste sur system', () async {
    final controller = ThemeController();
    await controller.load();
    expect(controller.themeMode, ThemeMode.system);
  });

  test('load() relit une préférence déjà persistée', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    final controller = ThemeController();
    await controller.load();
    expect(controller.themeMode, ThemeMode.dark);
  });

  test('load() ignore une valeur invalide (retombe sur system)', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'sepia'});
    final controller = ThemeController();
    await controller.load();
    expect(controller.themeMode, ThemeMode.system);
  });

  test('setThemeMode persiste puis est relu par une nouvelle instance',
      () async {
    final controller = ThemeController();
    await controller.setThemeMode(ThemeMode.light);
    expect(controller.themeMode, ThemeMode.light);

    // Une nouvelle instance doit relire la valeur persistée.
    final reloaded = ThemeController();
    await reloaded.load();
    expect(reloaded.themeMode, ThemeMode.light);
  });

  test('setThemeMode notifie les listeners à chaque changement', () async {
    final controller = ThemeController();
    var notifications = 0;
    controller.addListener(() => notifications++);

    await controller.setThemeMode(ThemeMode.dark);
    expect(notifications, 1);
    expect(controller.themeMode, ThemeMode.dark);

    // Même valeur : pas de notification superflue (idempotence).
    await controller.setThemeMode(ThemeMode.dark);
    expect(notifications, 1);

    await controller.setThemeMode(ThemeMode.system);
    expect(notifications, 2);
  });

  test('shared() retourne toujours la même instance', () {
    ThemeController.resetSharedForTest();
    final a = ThemeController.shared();
    final b = ThemeController.shared();
    expect(identical(a, b), isTrue);
  });
}

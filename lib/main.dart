// lib/main.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:portfolio_tracker/app_info.dart';
import 'package:portfolio_tracker/controllers/theme_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/sqlite_migration.dart';
import 'package:portfolio_tracker/utils/logger.dart';
import 'package:portfolio_tracker/widgets/wallet_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise les données de formatage de dates pour toutes les locales
  // (utilisé par intl DateFormat dans Formatters / les pages).
  await initializeDateFormatting();

  // Enregistre la licence de l'app elle-même (AGPL-3.0) auprès du registre
  // Flutter, pour qu'elle apparaisse dans showLicensePage (page Réglages)
  // aux côtés des licences des packages tiers. Notice concise : le texte
  // intégral reste dans le fichier LICENSE à la racine du dépôt.
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['Sparneo'], kAgplLegalese);
  });

  // Migration one-shot SharedPreferences → SQLite (zéro perte : les clés SP ne
  // sont jamais effacées, le flag n'est posé qu'après import vérifié).
  // NON FATALE : en cas d'erreur, l'app démarre quand même. SP intacte + flag
  // non posé → retry automatique au prochain lancement.
  try {
    await SqliteMigration.runIfNeeded(database: AppDatabase.shared());
  } catch (e, st) {
    AppLogger.error(
      'SqliteMigration : échec au démarrage (non fatal, retry au prochain '
      'lancement).',
      e,
      st,
    );
  }

  // Charge la préférence de thème (device, hors backup) AVANT le premier
  // build : évite un flash au thème par défaut suivi d'un changement.
  await ThemeController.shared().load();

  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  // Graine de la palette Sparneo : bleu profond « confiance / sécurité ».
  // Toute la charte (primary, containers, accents du camembert…) dérive de
  // cette seule couleur via ColorScheme.fromSeed — clair comme sombre.
  static const Color _seed = Color(0xFF2743B0);

  @override
  Widget build(BuildContext context) {
    // Écoute le contrôleur de thème (préférence d'appareil, déjà chargée
    // avant runApp) : reconstruit la MaterialApp à chaque changement de mode,
    // sans transformer MainApp en StatefulWidget.
    return ListenableBuilder(
      listenable: ThemeController.shared(),
      builder: (context, _) => MaterialApp(
        title: 'Sparneo',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _seed),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: _seed,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeController.shared().themeMode,
        home: const WalletView(),
      ),
    );
  }
}
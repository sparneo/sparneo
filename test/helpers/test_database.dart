// test/helpers/test_database.dart
//
// Helper partagé entre tous les tests de storage SQLite.
//
// Centralise l'initialisation sqfliteFfiInit() (risque R3 : si chaque fichier
// de test appelait sqfliteFfiInit() indépendamment, une initialisation manquée
// provoquerait une erreur silencieuse ou une DB ouverte avec la mauvaise
// factory). Ce helper est la SEULE source de vérité pour l'init ffi en test.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:portfolio_tracker/services/app_database.dart';

/// Retourne un [AppDatabase] en mémoire, isolé, prêt à l'emploi.
///
/// Chaque appel produit une instance DISTINCTE (chemin [inMemoryDatabasePath] +
/// factory ffi) : les tests sont ainsi indépendants les uns des autres.
///
/// Appeler [sqfliteFfiInit] UNE fois avant la première ouverture (idempotent,
/// mais on le fait systématiquement ici pour éviter l'oubli dans les setUpAll).
Future<AppDatabase> openTestDatabase() async {
  sqfliteFfiInit();
  final db = AppDatabase(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  // Déclenche l'ouverture et la création du schéma dès maintenant.
  await db.database;
  return db;
}

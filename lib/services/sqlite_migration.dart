// lib/services/sqlite_migration.dart
//
// Migration ONE-SHOT, idempotente et ZÉRO-PERTE des données SharedPreferences
// (ancien schéma) vers SQLite.
//
// INVARIANT I1 — ZÉRO PERTE : les clés SharedPreferences ne sont JAMAIS
// effacées (filet de sécurité permanent). Le flag `sqlite_migration_done`
// n'est posé qu'APRÈS écriture DB vérifiée (counts insérés == counts sources
// assainies). En cas de mismatch : exception levée, flag NON posé, SP intacte,
// retry au prochain lancement.
//
// Ordre des gardes (méthode [runIfNeeded]) :
//   1. Flag déjà posé              → no-op.
//   2. DB déjà peuplée sans flag   → récupération après crash : poser le flag,
//      pas de ré-import (évite doublon/écrasement).
//   3. Aucune donnée legacy        → utilisateur neuf : poser le flag, rien à
//      migrer.
//   4. Assainissement des orphelins référentiels (décision d'orchestration) :
//      retirer les entrées qui violeraient une contrainte FK à l'import
//      atomique, en comptant/loggant chaque catégorie.
//   5. Import atomique via AccountStorage.importRawData (purge + ordre FK).
//   6. Vérification des counts DB vs source assainie ; mismatch → exception.
//   7. Poser le flag.

import 'package:shared_preferences/shared_preferences.dart';

import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/legacy_shared_prefs_reader.dart';
import 'package:portfolio_tracker/utils/logger.dart';

/// Levée lorsque la vérification post-import échoue (counts DB ≠ counts source
/// assainie). Le flag n'est PAS posé : SP reste intacte, retry au prochain
/// lancement.
class SqliteMigrationException implements Exception {
  final String message;
  const SqliteMigrationException(this.message);

  @override
  String toString() => 'SqliteMigrationException: $message';
}

class SqliteMigration {
  /// Clé du flag « migration effectuée » dans SharedPreferences.
  static const String migrationDoneKey = 'sqlite_migration_done';

  const SqliteMigration._();

  /// Exécute la migration si elle n'a pas déjà eu lieu.
  ///
  /// [database] : instance cible (en prod, `AppDatabase.shared()` ; en test,
  /// une instance in-memory injectée).
  /// [prefs] : SharedPreferences à lire (injectable pour test) ; à défaut,
  /// `SharedPreferences.getInstance()`.
  static Future<void> runIfNeeded({
    required AppDatabase database,
    SharedPreferences? prefs,
    LegacySharedPrefsReader reader = const LegacySharedPrefsReader(),
  }) async {
    final sp = prefs ?? await SharedPreferences.getInstance();

    // --- Garde 1 : flag déjà posé → no-op ---
    if (sp.getBool(migrationDoneKey) == true) {
      return;
    }

    final storage = AccountStorage(database: database);

    // --- Garde 2 : DB déjà peuplée sans flag (récupération après crash) ---
    // Un crash a pu survenir entre l'import (commit) et la pose du flag. La DB
    // contient déjà les données : NE PAS ré-importer (importRawData purge tout
    // et pourrait écraser des modifications faites depuis). On pose le flag.
    if (await _databaseHasData(database)) {
      AppLogger.warning(
        'SqliteMigration : DB déjà peuplée sans flag (récupération après '
        'crash présumé) — pose du flag sans ré-import.',
      );
      await sp.setBool(migrationDoneKey, true);
      return;
    }

    // --- Lecture legacy ---
    final legacy = reader.read(sp);

    // --- Garde 3 : utilisateur neuf (aucune donnée legacy) ---
    if (_isEmptyLegacy(legacy)) {
      AppLogger.info(
        'SqliteMigration : aucune donnée legacy détectée (utilisateur neuf) '
        '— pose du flag, rien à migrer.',
      );
      await sp.setBool(migrationDoneKey, true);
      return;
    }

    // --- Garde 4 : assainissement des orphelins référentiels ---
    final sanitized = _sanitize(legacy);

    // --- Import atomique (purge + ordre FK) ---
    await storage.importRawData(sanitized);

    // --- Vérification des counts DB vs source assainie ---
    await _verifyCounts(database, sanitized);

    // --- Pose du flag UNIQUEMENT après import + vérif OK. SP jamais effacée ---
    await sp.setBool(migrationDoneKey, true);

    AppLogger.info('SqliteMigration : migration terminée avec succès.');
  }

  // ---------------------------------------------------------------------------
  // Garde 2 : détection DB non vide
  // ---------------------------------------------------------------------------

  static Future<bool> _databaseHasData(AppDatabase database) async {
    for (final table in const [
      'wallets',
      'accounts',
      'positions',
      'snapshots',
      'allocation_targets',
    ]) {
      if (await _countRows(database, table) > 0) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Garde 3 : legacy vide
  // ---------------------------------------------------------------------------

  static bool _isEmptyLegacy(Map<String, dynamic> legacy) {
    final wallets = (legacy['wallets'] as List?) ?? const [];
    final accounts = (legacy['accounts'] as List?) ?? const [];
    final positions = (legacy['positions'] as Map?) ?? const {};
    final snapshots = (legacy['snapshots'] as Map?) ?? const {};
    final targets = (legacy['allocationTargets'] as Map?) ?? const {};

    if (wallets.isNotEmpty) return false;
    if (accounts.isNotEmpty) return false;
    // Une map de positions/snapshots/targets peut contenir des clés dont la
    // valeur est une liste vide ; on considère « des données » dès qu'une
    // liste non vide (ou une valeur target non nulle) existe.
    if (_mapHasAnyEntryWithData(positions)) return false;
    if (_mapHasAnyEntryWithData(snapshots)) return false;
    if (targets.isNotEmpty) return false;

    return true;
  }

  static bool _mapHasAnyEntryWithData(Map map) {
    for (final value in map.values) {
      if (value is List && value.isNotEmpty) return true;
      if (value is! List && value != null) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Garde 4 : assainissement des orphelins référentiels
  // ---------------------------------------------------------------------------

  /// Retire de la map legacy les entrées qui violeraient une FK à l'import
  /// atomique (l'import est tout-ou-rien : un seul orphelin ferait échouer TOUTE
  /// la migration, laissant l'utilisateur sur une app vide en boucle). On
  /// préfère préserver au maximum les données cohérentes.
  ///
  /// Règles :
  ///   - account dont le walletId n'existe pas → retiré (+ ses positions) ;
  ///   - position dont l'accountId n'existe pas (parmi les accounts VALIDES)
  ///     → retirée ;
  ///   - snapshot / allocationTarget dont le walletId n'existe pas → retiré.
  static Map<String, dynamic> _sanitize(Map<String, dynamic> legacy) {
    final wallets = ((legacy['wallets'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final accounts = ((legacy['accounts'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final positions = Map<String, dynamic>.from(
      (legacy['positions'] as Map?) ?? const {},
    );
    final snapshots = Map<String, dynamic>.from(
      (legacy['snapshots'] as Map?) ?? const {},
    );
    final targets = Map<String, dynamic>.from(
      (legacy['allocationTargets'] as Map?) ?? const {},
    );

    final walletIds = <String>{
      for (final w in wallets)
        if (w['id'] != null) w['id'].toString(),
    };

    // 1. Accounts orphelins (walletId inexistant).
    final validAccounts = <Map>[];
    var orphanAccounts = 0;
    final validAccountIds = <String>{};
    for (final a in accounts) {
      final walletId = a['walletId']?.toString();
      if (walletId != null && walletIds.contains(walletId)) {
        validAccounts.add(a);
        final id = a['id']?.toString();
        if (id != null) validAccountIds.add(id);
      } else {
        orphanAccounts++;
      }
    }

    // 2. Positions orphelines (accountId absent des accounts VALIDES).
    //    Note : les positions d'un account retiré à l'étape 1 sont ainsi
    //    naturellement écartées (leur accountId n'est plus valide).
    final validPositions = <String, dynamic>{};
    var orphanPositionGroups = 0;
    positions.forEach((accountId, value) {
      if (validAccountIds.contains(accountId)) {
        validPositions[accountId] = value;
      } else {
        orphanPositionGroups++;
      }
    });

    // 3. Snapshots orphelins (walletId inexistant).
    final validSnapshots = <String, dynamic>{};
    var orphanSnapshotGroups = 0;
    snapshots.forEach((walletId, value) {
      if (walletIds.contains(walletId)) {
        validSnapshots[walletId] = value;
      } else {
        orphanSnapshotGroups++;
      }
    });

    // 4. AllocationTargets orphelins (walletId inexistant).
    final validTargets = <String, dynamic>{};
    var orphanTargets = 0;
    targets.forEach((walletId, value) {
      if (walletIds.contains(walletId)) {
        validTargets[walletId] = value;
      } else {
        orphanTargets++;
      }
    });

    if (orphanAccounts > 0 ||
        orphanPositionGroups > 0 ||
        orphanSnapshotGroups > 0 ||
        orphanTargets > 0) {
      AppLogger.warning(
        'SqliteMigration — assainissement des orphelins : '
        'accounts=$orphanAccounts, '
        'groupes de positions=$orphanPositionGroups, '
        'groupes de snapshots=$orphanSnapshotGroups, '
        'allocationTargets=$orphanTargets '
        '(entrées retirées avant import atomique).',
      );
    }

    return {
      'wallets': wallets,
      'accounts': validAccounts,
      'positions': validPositions,
      'snapshots': validSnapshots,
      'allocationTargets': validTargets,
    };
  }

  // ---------------------------------------------------------------------------
  // Garde 6 : vérification des counts
  // ---------------------------------------------------------------------------

  /// Compare les counts insérés en DB aux counts attendus depuis la map
  /// assainie. Mismatch → [SqliteMigrationException] (flag non posé).
  static Future<void> _verifyCounts(
    AppDatabase database,
    Map<String, dynamic> sanitized,
  ) async {
    final expectedWallets = ((sanitized['wallets'] as List?) ?? const []).length;
    final expectedAccounts =
        ((sanitized['accounts'] as List?) ?? const []).length;
    final expectedPositions = _countNestedListItems(
      (sanitized['positions'] as Map?) ?? const {},
    );
    final expectedSnapshots = _countNestedListItems(
      (sanitized['snapshots'] as Map?) ?? const {},
    );
    final expectedTargets =
        ((sanitized['allocationTargets'] as Map?) ?? const {}).length;

    final actualWallets = await _countRows(database, 'wallets');
    final actualAccounts = await _countRows(database, 'accounts');
    final actualPositions = await _countRows(database, 'positions');
    final actualSnapshots = await _countRows(database, 'snapshots');
    final actualTargets = await _countRows(database, 'allocation_targets');

    final mismatches = <String>[];
    void check(String label, int expected, int actual) {
      if (expected != actual) {
        mismatches.add('$label attendu=$expected inséré=$actual');
      }
    }

    check('wallets', expectedWallets, actualWallets);
    check('accounts', expectedAccounts, actualAccounts);
    check('positions', expectedPositions, actualPositions);
    check('snapshots', expectedSnapshots, actualSnapshots);
    check('allocationTargets', expectedTargets, actualTargets);

    if (mismatches.isNotEmpty) {
      final detail = mismatches.join(' ; ');
      AppLogger.error(
        'SqliteMigration : vérification des counts ÉCHOUÉE — $detail. '
        'Flag NON posé, SharedPreferences intacte, retry au prochain lancement.',
      );
      throw SqliteMigrationException(
        'Migration incohérente ($detail) — flag non posé.',
      );
    }
  }

  /// Compte le nombre total d'items dans une map { clé: List }.
  static int _countNestedListItems(Map map) {
    var total = 0;
    for (final value in map.values) {
      if (value is List) total += value.length;
    }
    return total;
  }

  static Future<int> _countRows(AppDatabase database, String table) async {
    final db = await database.database;
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    final value = result.first['c'];
    return (value as num).toInt();
  }
}

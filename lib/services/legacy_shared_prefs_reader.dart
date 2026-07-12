// lib/services/legacy_shared_prefs_reader.dart
//
// Lecteur LEGACY des données SharedPreferences (schéma d'avant la migration
// SQLite). Son unique rôle est de reproduire la MÊME map brute que produisait
// l'ancien `AccountStorage.exportRawData()` basé sur SharedPreferences, afin
// d'alimenter la migration one-shot vers SQLite.
//
// CRITIQUE : ce lecteur NE dépend PAS du nouvel `AccountStorage.exportRawData`
// (qui lit la base SQLite, VIDE au moment de la migration). Il réplique la
// logique de lecture SharedPreferences de l'ancien code :
//   - clé 'wallets'                      → JSON encodé d'une liste de Wallet.toJson()
//   - clé 'accounts'                     → JSON encodé d'une liste de Account.toJson()
//   - préfixe 'positions_<accountId>'    → JSON encodé d'une liste de Position.toJson()
//   - préfixe 'snapshots_<walletId>'     → JSON encodé d'une liste de Snapshot.toJson()
//   - préfixe 'allocation_targets_<wid>' → JSON encodé d'un AllocationTarget.toJson()
//
// La map produite a exactement la forme attendue par
// `AccountStorage.importRawData` :
//   {
//     'wallets': [ {...}, ... ],
//     'accounts': [ {...}, ... ],
//     'positions': { accountId: [ {...}, ... ], ... },
//     'snapshots': { walletId: [ {...}, ... ], ... },
//     'allocationTargets': { walletId: {...}, ... },
//   }
//
// Toutes les clés absentes sont tolérées (liste vide / map vide).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LegacySharedPrefsReader {
  // Clés / préfixes de l'ancien schéma SharedPreferences (référence :
  // git HEAD~2:lib/services/account_storage.dart et snapshot/allocation storages).
  static const String _walletsKey = 'wallets';
  static const String _accountsKey = 'accounts';
  static const String _positionsPrefix = 'positions_';
  static const String _snapshotsPrefix = 'snapshots_';
  static const String _allocationTargetsPrefix = 'allocation_targets_';

  const LegacySharedPrefsReader();

  /// Lit les anciennes clés de [prefs] et retourne la map brute (JSON déjà
  /// décodé) identique en forme à l'ancien `exportRawData()`.
  ///
  /// Tolérance :
  ///   - clés absentes → liste vide / map vide ;
  ///   - valeur JSON corrompue → l'entrée est ignorée (jamais d'exception).
  ///     On préfère perdre une entrée illisible plutôt que bloquer toute la
  ///     migration (elle resterait bloquée en boucle, flag jamais posé).
  Map<String, dynamic> read(SharedPreferences prefs) {
    final keys = prefs.getKeys();

    // --- wallets ---
    final wallets = _decodeList(prefs.getString(_walletsKey));

    // --- accounts ---
    final accounts = _decodeList(prefs.getString(_accountsKey));

    // --- positions groupées par accountId ---
    final positions = <String, dynamic>{};
    for (final key in keys) {
      if (key.startsWith(_positionsPrefix)) {
        final accountId = key.substring(_positionsPrefix.length);
        final decoded = _tryDecode(prefs.getString(key));
        if (decoded != null) positions[accountId] = decoded;
      }
    }

    // --- snapshots groupés par walletId ---
    final snapshots = <String, dynamic>{};
    for (final key in keys) {
      if (key.startsWith(_snapshotsPrefix)) {
        final walletId = key.substring(_snapshotsPrefix.length);
        final decoded = _tryDecode(prefs.getString(key));
        if (decoded != null) snapshots[walletId] = decoded;
      }
    }

    // --- allocationTargets par walletId ---
    final allocationTargets = <String, dynamic>{};
    for (final key in keys) {
      if (key.startsWith(_allocationTargetsPrefix)) {
        final walletId = key.substring(_allocationTargetsPrefix.length);
        final decoded = _tryDecode(prefs.getString(key));
        if (decoded != null) allocationTargets[walletId] = decoded;
      }
    }

    return {
      'wallets': wallets,
      'accounts': accounts,
      'positions': positions,
      'snapshots': snapshots,
      'allocationTargets': allocationTargets,
    };
  }

  /// Décode une valeur en liste ; retourne une liste vide si null / non-liste /
  /// corrompue.
  static List<dynamic> _decodeList(String? raw) {
    final decoded = _tryDecode(raw);
    if (decoded is List) return decoded;
    return <dynamic>[];
  }

  /// Décode le JSON ; retourne null en cas d'absence ou de corruption.
  static Object? _tryDecode(String? raw) {
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}

// test/services/legacy_shared_prefs_reader_test.dart
//
// Vérifie que LegacySharedPrefsReader reproduit fidèlement la map brute de
// l'ancien exportRawData() SharedPreferences, à partir des clés/préfixes de
// l'ancien schéma.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:portfolio_tracker/services/legacy_shared_prefs_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const reader = LegacySharedPrefsReader();

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  test('SP vide → map avec listes/maps vides', () async {
    final prefs = await prefsWith({});
    final map = reader.read(prefs);

    expect(map['wallets'], isEmpty);
    expect(map['accounts'], isEmpty);
    expect(map['positions'], isEmpty);
    expect(map['allocationTargets'], isEmpty);
    // Clé disparue avec le sous-système snapshots (schéma v8) : le lecteur
    // legacy ne doit plus la produire, même à vide.
    expect(map.containsKey('snapshots'), isFalse);
  });

  test('SP peuplé → map reproduit exactement la forme legacy', () async {
    final wallets = [
      {'id': 'w1', 'name': 'Wallet 1', 'createdAt': '2024-01-01T00:00:00.000'},
    ];
    final accounts = [
      {'id': 'a1', 'walletId': 'w1', 'name': 'Compte', 'type': 'brokerage'},
    ];
    final positions = [
      {
        'accountId': 'a1',
        'asset': {'symbol': 'AAPL', 'name': 'Apple', 'type': 'stock'},
        'quantity': '10',
      },
    ];
    final target = {'moving': {}, 'byClass': {}};

    final prefs = await prefsWith({
      'wallets': jsonEncode(wallets),
      'accounts': jsonEncode(accounts),
      'positions_a1': jsonEncode(positions),
      // Clés d'une installation d'avant SQLite : plus lues du tout.
      'snapshots_w1': jsonEncode([
        {'date': '2024-01-01', 'totalValue': 1000.0, 'currency': 'EUR'},
      ]),
      'allocation_targets_w1': jsonEncode(target),
    });

    final map = reader.read(prefs);

    expect(map['wallets'], wallets);
    expect(map['accounts'], accounts);
    expect(map['positions'], {'a1': positions});
    expect(map['allocationTargets'], {'w1': target});
    expect(map.containsKey('snapshots'), isFalse,
        reason: 'une clé snapshots_* legacy est désormais ignorée en silence');
  });

  test('préfixes multiples groupés par id', () async {
    final prefs = await prefsWith({
      'positions_a1': jsonEncode([
        {'accountId': 'a1', 'asset': {'symbol': 'X'}, 'quantity': '1'},
      ]),
      'positions_a2': jsonEncode([
        {'accountId': 'a2', 'asset': {'symbol': 'Y'}, 'quantity': '2'},
      ]),
    });

    final map = reader.read(prefs);
    expect((map['positions'] as Map).keys.toSet(), {'a1', 'a2'});
  });

  test('valeur JSON corrompue → entrée ignorée, pas d\'exception', () async {
    final prefs = await prefsWith({
      'wallets': 'ceci n\'est pas du json',
      'positions_a1': '{{{ corrompu',
      'accounts': jsonEncode([
        {'id': 'a1', 'walletId': 'w1'},
      ]),
    });

    final map = reader.read(prefs);
    expect(map['wallets'], isEmpty); // wallets corrompu → liste vide
    expect(map['positions'], isEmpty); // a1 corrompu → ignoré
    expect(map['accounts'], isNotEmpty); // accounts valide → conservé
  });

  test('clé wallets présente mais JSON non-liste → liste vide', () async {
    final prefs = await prefsWith({
      'wallets': jsonEncode({'not': 'a list'}),
    });
    final map = reader.read(prefs);
    expect(map['wallets'], isEmpty);
  });

  test('rétrocompat : sans clé allocation_targets', () async {
    final prefs = await prefsWith({
      'wallets': jsonEncode([
        {'id': 'w1', 'name': 'W', 'createdAt': '2024-01-01T00:00:00.000'},
      ]),
      'accounts': jsonEncode([]),
    });

    final map = reader.read(prefs);
    expect(map['wallets'], isNotEmpty);
    expect(map['allocationTargets'], isEmpty);
  });
}

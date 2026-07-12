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
    expect(map['snapshots'], isEmpty);
    expect(map['allocationTargets'], isEmpty);
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
    final snapshots = [
      {
        'date': '2024-01-01',
        'totalValue': 1000.0,
        'currency': 'EUR',
        'capturedAt': 1000,
      },
    ];
    final target = {'moving': {}, 'byClass': {}};

    final prefs = await prefsWith({
      'wallets': jsonEncode(wallets),
      'accounts': jsonEncode(accounts),
      'positions_a1': jsonEncode(positions),
      'snapshots_w1': jsonEncode(snapshots),
      'allocation_targets_w1': jsonEncode(target),
    });

    final map = reader.read(prefs);

    expect(map['wallets'], wallets);
    expect(map['accounts'], accounts);
    expect(map['positions'], {'a1': positions});
    expect(map['snapshots'], {'w1': snapshots});
    expect(map['allocationTargets'], {'w1': target});
  });

  test('préfixes multiples groupés par id', () async {
    final prefs = await prefsWith({
      'positions_a1': jsonEncode([
        {'accountId': 'a1', 'asset': {'symbol': 'X'}, 'quantity': '1'},
      ]),
      'positions_a2': jsonEncode([
        {'accountId': 'a2', 'asset': {'symbol': 'Y'}, 'quantity': '2'},
      ]),
      'snapshots_w1': jsonEncode([]),
      'snapshots_w2': jsonEncode([]),
    });

    final map = reader.read(prefs);
    expect((map['positions'] as Map).keys.toSet(), {'a1', 'a2'});
    expect((map['snapshots'] as Map).keys.toSet(), {'w1', 'w2'});
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

  test('rétrocompat : sans clé snapshots/allocation_targets', () async {
    final prefs = await prefsWith({
      'wallets': jsonEncode([
        {'id': 'w1', 'name': 'W', 'createdAt': '2024-01-01T00:00:00.000'},
      ]),
      'accounts': jsonEncode([]),
    });

    final map = reader.read(prefs);
    expect(map['wallets'], isNotEmpty);
    expect(map['snapshots'], isEmpty);
    expect(map['allocationTargets'], isEmpty);
  });
}

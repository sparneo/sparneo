// test/services/backup_service_test.dart
//
// Verrouille le contrat de restauration de BackupService :
//   - un JSON qui n'est pas une sauvegarde valide lève BackupException ;
//   - un backup référentiellement INCOHÉRENT (ex. position orpheline dont le
//     compte est absent) est rejeté ATOMIQUEMENT : l'import échoue via la
//     contrainte FK SQLite, la transaction rollback (données existantes
//     préservées), et l'exception SQLite brute est habillée en BackupException
//     (message clair pour l'utilisateur) — correctif IMPORTANT-1 revue LOT 4+6.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/backup_service.dart';

import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late BackupService service;

  setUp(() async {
    db = await openTestDatabase();
    service = BackupService(storage: AccountStorage(database: db));
  });

  tearDown(() async {
    await db.close();
  });

  String wrap(Map<String, dynamic> data, {String format = 'sparneo_backup'}) =>
      jsonEncode({
        'format': format,
        'version': 1,
        'exportedAt': '2026-01-01T00:00:00.000',
        'data': data,
      });

  group('BackupService.importFromJson — validation de structure', () {
    test('JSON non valide → BackupException', () async {
      await expectLater(
        service.importFromJson('pas du json {{'),
        throwsA(isA<BackupException>()),
      );
    });

    test('JSON valide mais pas une sauvegarde → BackupException', () async {
      await expectLater(
        service.importFromJson(jsonEncode({'foo': 'bar'})),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('BackupService.importFromJson — compatibilité de signature', () {
    // Régression : le nom de code historique du projet (portfolio_tracker) a
    // été renommé en Sparneo, mais des sauvegardes RÉELLES existent déjà avec
    // l'ancienne signature — elles doivent rester importables.
    test('sauvegarde à l\'ancienne signature (portfolio_tracker_backup) → importée',
        () async {
      final data = <String, dynamic>{
        'wallets': [
          {
            'id': 'w1',
            'name': 'Portefeuille',
            'createdAt': '2026-01-01T00:00:00.000'
          }
        ],
        'accounts': [],
        'positions': <String, dynamic>{},
        'snapshots': <String, dynamic>{},
        'allocationTargets': <String, dynamic>{},
      };

      await service.importFromJson(
        wrap(data, format: 'portfolio_tracker_backup'),
      );

      final wallets = await AccountStorage(database: db).getAllWallets();
      expect(wallets.map((w) => w.id), ['w1']);
    });

    test('signature inconnue → BackupException', () async {
      await expectLater(
        service.importFromJson(wrap({}, format: 'autre_chose')),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('BackupService.importFromJson — backup incohérent (IMPORTANT-1)', () {
    test(
        'position orpheline (compte absent) → BackupException, pas d\'exception SQLite brute',
        () async {
      // Position rattachée à un compte 'acc-ghost' qui n'existe pas dans
      // 'accounts' : viole la FK positions.account_id → accounts.id.
      final incoherent = <String, dynamic>{
        'wallets': [],
        'accounts': [],
        'positions': {
          'acc-ghost': [
            {
              'accountId': 'acc-ghost',
              'symbol': 'AAPL',
              'quantity': '10',
              'asset': {'symbol': 'AAPL', 'currency': 'USD'},
            }
          ],
        },
        'snapshots': <String, dynamic>{},
        'allocationTargets': <String, dynamic>{},
      };

      await expectLater(
        service.importFromJson(wrap(incoherent)),
        throwsA(isA<BackupException>()),
      );
    });

    test('les données existantes survivent à un import incohérent (rollback)',
        () async {
      // Seed d'un état valide via un premier import cohérent.
      final coherent = <String, dynamic>{
        'wallets': [
          {'id': 'w1', 'name': 'Portefeuille', 'createdAt': '2026-01-01T00:00:00.000'}
        ],
        'accounts': [],
        'positions': <String, dynamic>{},
        'snapshots': <String, dynamic>{},
        'allocationTargets': <String, dynamic>{},
      };
      await service.importFromJson(wrap(coherent));
      expect((await AccountStorage(database: db).getAllWallets()).length, 1);

      // Import incohérent : doit échouer et NE PAS détruire l'état existant.
      final incoherent = <String, dynamic>{
        'wallets': [
          {'id': 'w2', 'name': 'Nouveau', 'createdAt': '2026-01-02T00:00:00.000'}
        ],
        'accounts': [
          {'id': 'acc1', 'walletId': 'w-ghost', 'name': 'CTO', 'type': 'investment'}
        ],
        'positions': <String, dynamic>{},
        'snapshots': <String, dynamic>{},
        'allocationTargets': <String, dynamic>{},
      };
      await expectLater(
        service.importFromJson(wrap(incoherent)),
        throwsA(isA<BackupException>()),
      );

      // L'état d'origine (w1) est intact ; l'import partiel (w2) n'a pas été appliqué.
      final wallets = await AccountStorage(database: db).getAllWallets();
      expect(wallets.map((w) => w.id), ['w1']);
    });
  });
}

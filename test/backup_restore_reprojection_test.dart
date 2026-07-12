// test/backup_restore_reprojection_test.dart
//
// Vérifie la REPROJECTION POST-RESTAURATION (étape 8 de
// AccountStorage.importRawData) : les caches dérivés (positions.derived_at,
// accounts.derived_cash*) sont exclus du backup et doivent être reconstruits
// par vérification à l'import — CASH toujours reprojeté, TITRE adopté
// SEULEMENT si la déclaration est prouvée égale à la projection du journal
// (declaredMatchesProjection).
//
// Aucun appel réseau, bases in-memory (test/helpers/test_database.dart).

import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';

import 'helpers/test_database.dart';

/// Construit une position minimale (asset "other", pas de custom_name).
Position _pos(String accountId, String symbol, String quantity, double? pru) {
  return Position(
    accountId: accountId,
    asset: Asset(symbol: symbol, name: symbol, type: AssetType.stock, currency: 'EUR'),
    quantity: quantity,
    averageBuyPrice: pru,
  );
}

AssetTransaction _buy(
  String id,
  String accountId,
  String symbol,
  String qty,
  String price, {
  String? amount,
  DateTime? date,
  String currency = 'EUR',
  String? settlementCurrency,
}) {
  return AssetTransaction(
    id: id,
    accountId: accountId,
    symbol: symbol,
    kind: TransactionKind.buy,
    quantity: qty,
    unitPrice: price,
    amount: amount,
    currency: currency,
    settlementCurrency: settlementCurrency,
    date: date ?? DateTime(2024, 1, 1),
  );
}

AssetTransaction _sell(
  String id,
  String accountId,
  String symbol,
  String qty,
  String price, {
  String? amount,
  DateTime? date,
}) {
  return AssetTransaction(
    id: id,
    accountId: accountId,
    symbol: symbol,
    kind: TransactionKind.sell,
    quantity: qty,
    unitPrice: price,
    amount: amount,
    currency: 'EUR',
    date: date ?? DateTime(2024, 1, 1),
  );
}

AssetTransaction _cash(
  String id,
  String accountId,
  TransactionKind kind,
  String amount, {
  String currency = 'EUR',
  DateTime? date,
}) {
  return AssetTransaction(
    id: id,
    accountId: accountId,
    symbol: null,
    kind: kind,
    amount: amount,
    currency: currency,
    date: date ?? DateTime(2024, 1, 1),
  );
}

void main() {
  late AppDatabase sourceDb;
  late AccountStorage source;
  late LedgerService sourceLedger;

  const walletId = 'w1';
  const accountId = 'acc1';

  Future<void> seedWalletAndAccount({
    String currency = 'EUR',
    AccountKind kind = AccountKind.cto,
  }) async {
    await source.saveWallet(Wallet(id: walletId, name: 'Wallet', createdAt: DateTime(2024, 1, 1)));
    await source.saveAccount(Account(
      id: accountId,
      walletId: walletId,
      name: 'Compte',
      kind: kind,
      currency: currency,
    ));
  }

  setUp(() async {
    sourceDb = await openTestDatabase();
    source = AccountStorage(database: sourceDb);
    sourceLedger = LedgerService(database: sourceDb);
  });

  tearDown(() async {
    await sourceDb.close();
  });

  /// Crée une ligne positions vide (quantité "0", asset_json présent) pour
  /// [symbol] sur le compte source — condition préalable au projecteur
  /// (UPDATE ciblé, ne fabrique jamais la ligne) avant d'enregistrer des
  /// mouvements via [sourceLedger]. Miroir de `seedEmptyPosition` de
  /// ledger_service_test.dart.
  Future<void> seedEmptyPosition(String symbol) async {
    await source.savePosition(
      accountId,
      Position(
        accountId: accountId,
        asset: Asset(symbol: symbol, name: symbol, type: AssetType.stock, currency: 'EUR'),
        quantity: '0',
      ),
    );
  }

  /// Importe [data] dans une base FRAÎCHE (isolée de la source) et retourne
  /// (storage, db) — l'appelant doit fermer [db].
  Future<(AccountStorage, AppDatabase)> importIntoFreshDb(Map<String, dynamic> data) async {
    final freshDb = await openTestDatabase();
    final freshStorage = AccountStorage(database: freshDb);
    await freshStorage.importRawData(data);
    return (freshStorage, freshDb);
  }

  // ---------------------------------------------------------------------------
  // 1. Nominal
  // ---------------------------------------------------------------------------
  test('1. nominal : export→import dans une base fraîche adopte tout, cash reprojeté partout',
      () async {
    await seedWalletAndAccount();
    await seedEmptyPosition('AAPL');
    await sourceLedger.recordTransaction(
      _cash('c1', accountId, TransactionKind.deposit, '1000', date: DateTime(2024, 1, 1)),
    );
    await sourceLedger.recordTransaction(
      _buy('t1', accountId, 'AAPL', '10', '100', amount: '-1000', date: DateTime(2024, 1, 2)),
    );
    await sourceLedger.recordTransaction(
      _buy('t2', accountId, 'AAPL', '5', '110', amount: '-550', date: DateTime(2024, 1, 3)),
    );
    await sourceLedger.recordTransaction(
      _sell('t3', accountId, 'AAPL', '3', '120', amount: '360', date: DateTime(2024, 1, 4)),
    );
    await sourceLedger.recordTransaction(
      _cash('c2', accountId, TransactionKind.interest, '5.5', date: DateTime(2024, 1, 5)),
    );

    final exported = await source.exportRawData();
    final (fresh, freshDb) = await importIntoFreshDb(exported);
    addTearDown(freshDb.close);

    final pos = await fresh.getPosition(accountId, 'AAPL');
    expect(pos, isNotNull);
    final derivedAt = await fresh.getPositionDerivedAt(accountId, 'AAPL');
    expect(derivedAt, isNotNull, reason: 'nominal : adoption automatique attendue');
    // 10 + 5 - 3 = 12, PRU pondéré (10@100 + 5@110)/15 = 103.333...
    expect(pos!.quantity, '12');
    expect(pos.averageBuyPrice, closeTo(1550 / 15, 1e-6));

    final cash = await fresh.getAccountDerivedCash(accountId);
    expect(cash.at, isNotNull);
    // 1000 - 1000 - 550 + 360 + 5.5 = -184.5
    expect(cash.cash, '-184.5');
  });

  // ---------------------------------------------------------------------------
  // 2. Legacy à journal partiel : declared != projection → reste legacy
  // ---------------------------------------------------------------------------
  test('2. legacy à journal partiel : déclaration != projection ⇒ position legacy, déclarations intactes',
      () async {
    await seedWalletAndAccount();
    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {
          'id': accountId,
          'walletId': walletId,
          'name': 'Compte',
          'kind': 'cto',
          'currency': 'EUR',
        }
      ],
      'positions': {
        accountId: [_pos(accountId, 'AAPL', '100', 50.0).toJson()],
      },
      'transactions': {
        accountId: [_buy('t1', accountId, 'AAPL', '40', '30').toJson()],
      },
    };

    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);

    final derivedAt = await fresh.getPositionDerivedAt(accountId, 'AAPL');
    expect(derivedAt, isNull, reason: 'journal partiel ⇒ NE PAS adopter');
    final pos = await fresh.getPosition(accountId, 'AAPL');
    expect(pos!.quantity, '100');
    expect(pos.averageBuyPrice, 50.0);

    // Le cash, lui, est stampé (Σ amount = 0, aucun mouvement cash déclaré,
    // le buy n'a pas d'amount ici).
    final cash = await fresh.getAccountDerivedCash(accountId);
    expect(cash.at, isNotNull);
  });

  // ---------------------------------------------------------------------------
  // 3. Backup v1 sans clé transactions
  // ---------------------------------------------------------------------------
  test('3. backup v1 sans clé transactions : positions toutes legacy, cash "0" partout, pas de crash',
      () async {
    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {
          'id': accountId,
          'walletId': walletId,
          'name': 'Compte',
          'kind': 'cto',
          'currency': 'EUR',
        }
      ],
      'positions': {
        accountId: [_pos(accountId, 'AAPL', '10', 100.0).toJson()],
      },
      // pas de clé 'transactions' — backup v1.
    };

    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);

    expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNull);
    final cash = await fresh.getAccountDerivedCash(accountId);
    expect(cash.cash, '0');
    expect(cash.at, isNotNull);
  });

  // ---------------------------------------------------------------------------
  // 4. Fichier édité incohérent
  // ---------------------------------------------------------------------------
  test('4. fichier édité incohérent (999 déclaré vs 100 projeté) ⇒ legacy, 999 préservé', () async {
    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
      ],
      'positions': {
        accountId: [_pos(accountId, 'AAPL', '999', 100.0).toJson()],
      },
      'transactions': {
        accountId: [_buy('t1', accountId, 'AAPL', '100', '100').toJson()],
      },
    };

    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);

    expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNull);
    final pos = await fresh.getPosition(accountId, 'AAPL');
    expect(pos!.quantity, '999');
    expect(pos.averageBuyPrice, 100.0);
  });

  // ---------------------------------------------------------------------------
  // 5. PRU arrondi (cas démo) : adopté, réécrit à la valeur exacte
  // ---------------------------------------------------------------------------
  test('5. PRU déclaré = projection réellement arrondie (6 décimales) ⇒ adopté, réécrit exact',
      () async {
    // buy 3@10 puis buy 7@10.0000005 → PRU exact = (3*10 + 7*10.0000005)/10
    // = (30 + 70.0000035)/10 = 10.00000035, arrondi 6 décimales = 10.0
    final proj = projectPosition([
      AssetTransaction(
        id: 't1',
        accountId: accountId,
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '3',
        unitPrice: '10',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      ),
      AssetTransaction(
        id: 't2',
        accountId: accountId,
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '7',
        unitPrice: '10.0000005',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      ),
    ]);
    final exactPru = proj.averagePrice!;
    final roundedPru = double.parse(exactPru.toStringAsFixed(6));
    expect(roundedPru, isNot(exactPru), reason: 'préconditions : arrondi != exact');

    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
      ],
      'positions': {
        accountId: [_pos(accountId, 'AAPL', '10', roundedPru).toJson()],
      },
      'transactions': {
        accountId: [
          AssetTransaction(
            id: 't1',
            accountId: accountId,
            symbol: 'AAPL',
            kind: TransactionKind.buy,
            quantity: '3',
            unitPrice: '10',
            currency: 'EUR',
            date: DateTime(2024, 1, 1),
          ).toJson(),
          AssetTransaction(
            id: 't2',
            accountId: accountId,
            symbol: 'AAPL',
            kind: TransactionKind.buy,
            quantity: '7',
            unitPrice: '10.0000005',
            currency: 'EUR',
            date: DateTime(2024, 1, 2),
          ).toJson(),
        ],
      },
    };

    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);

    expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNotNull,
        reason: 'PRU arrondi dans la tolérance ⇒ adopté');
    final pos = await fresh.getPosition(accountId, 'AAPL');
    // Réécrit à la valeur EXACTE (pas l'arrondi déclaré).
    expect(pos!.averageBuyPrice, closeTo(exactPru, 1e-9));
  });

  // ---------------------------------------------------------------------------
  // 6. Cas limites : PRU divergent, asymétries null, quantité non parsable
  // ---------------------------------------------------------------------------
  group('6. cas limites declaredMatchesProjection via import', () {
    test('quantité égale mais PRU divergent ⇒ legacy', () async {
      final data = {
        'wallets': [
          {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
        ],
        'accounts': [
          {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
        ],
        'positions': {
          accountId: [_pos(accountId, 'AAPL', '10', 999.0).toJson()],
        },
        'transactions': {
          accountId: [_buy('t1', accountId, 'AAPL', '10', '100').toJson()],
        },
      };
      final (fresh, freshDb) = await importIntoFreshDb(data);
      addTearDown(freshDb.close);
      expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNull);
    });

    test('PRU déclaré null, projeté non-null ⇒ legacy', () async {
      final data = {
        'wallets': [
          {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
        ],
        'accounts': [
          {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
        ],
        'positions': {
          accountId: [_pos(accountId, 'AAPL', '10', null).toJson()],
        },
        'transactions': {
          accountId: [_buy('t1', accountId, 'AAPL', '10', '100').toJson()],
        },
      };
      final (fresh, freshDb) = await importIntoFreshDb(data);
      addTearDown(freshDb.close);
      expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNull);
    });

    test('PRU déclaré non-null, projeté null (journal vide) ⇒ legacy', () async {
      final data = {
        'wallets': [
          {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
        ],
        'accounts': [
          {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
        ],
        'positions': {
          accountId: [_pos(accountId, 'AAPL', '0', 100.0).toJson()],
        },
        // Aucun journal pour AAPL : projection quantité 0, PRU null.
      };
      final (fresh, freshDb) = await importIntoFreshDb(data);
      addTearDown(freshDb.close);
      expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNull);
    });

    test('quantité déclarée non parsable ("abc") avec journal vide ⇒ legacy '
        '(piège garbage→0 == projection 0 ne doit PAS adopter)', () async {
      final data = {
        'wallets': [
          {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
        ],
        'accounts': [
          {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
        ],
        'positions': {
          accountId: [
            {
              'accountId': accountId,
              'asset': Asset(symbol: 'AAPL', name: 'AAPL', type: AssetType.stock, currency: 'EUR')
                  .toJson(),
              'quantity': 'abc',
              'averageBuyPrice': null,
            }
          ],
        },
        // Aucun journal pour AAPL : projection quantité 0, PRU null.
      };
      final (fresh, freshDb) = await importIntoFreshDb(data);
      addTearDown(freshDb.close);
      expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNull);
      final pos = await fresh.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, 'abc', reason: 'déclaration non parsable préservée telle quelle');
    });
  });

  // ---------------------------------------------------------------------------
  // 7. Position soldée (qty 0, PRU null) → adoptée
  // ---------------------------------------------------------------------------
  test('7. position soldée (qty 0, PRU null, journal buy+sell exact) ⇒ adoptée', () async {
    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
      ],
      'positions': {
        accountId: [_pos(accountId, 'AAPL', '0', null).toJson()],
      },
      'transactions': {
        accountId: [
          _buy('t1', accountId, 'AAPL', '10', '100', date: DateTime(2024, 1, 1)).toJson(),
          _sell('t2', accountId, 'AAPL', '10', '120', date: DateTime(2024, 1, 2)).toJson(),
        ],
      },
    };
    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);
    expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNotNull);
    final pos = await fresh.getPosition(accountId, 'AAPL');
    expect(pos!.quantity, '0');
    expect(pos.averageBuyPrice, isNull);
  });

  // ---------------------------------------------------------------------------
  // 8. Round-trip settlementCurrency
  // ---------------------------------------------------------------------------
  test('8. round-trip settlementCurrency : cotation USD / règlement EUR', () async {
    await seedWalletAndAccount(currency: 'EUR');
    await seedEmptyPosition('AAPL');
    await sourceLedger.recordTransaction(
      _buy(
        't1',
        accountId,
        'AAPL',
        '10',
        '175.50',
        amount: '-1620.00',
        currency: 'USD',
        settlementCurrency: 'EUR',
        date: DateTime(2024, 1, 1),
      ),
    );

    final export1 = await source.exportRawData();
    final txJson = (export1['transactions'] as Map)[accountId] as List;
    expect(txJson.single['settlementCurrency'], 'EUR', reason: 'export doit porter la clé');

    final (fresh, freshDb) = await importIntoFreshDb(export1);
    addTearDown(freshDb.close);

    // La colonne settlement_currency est bien persistée en base (via un
    // second export identique, cf. test round-trip stable ci-dessous).
    final export2 = await fresh.exportRawData();
    expect(export2['transactions'], equals(export1['transactions']));

    // derived_cash EUR inclut ce mouvement (bucket USD absent).
    final cash = await fresh.getAccountDerivedCash(accountId);
    expect(cash.cash, '-1620');
  });

  // ---------------------------------------------------------------------------
  // 9. Multi-devises : mouvement réglé USD sur compte EUR
  // ---------------------------------------------------------------------------
  test('9. multi-devises : derived_cash = bucket EUR seul, jamais de somme inter-devises',
      () async {
    await seedWalletAndAccount(currency: 'EUR');
    await sourceLedger.recordTransaction(
      _cash('c1', accountId, TransactionKind.deposit, '1000', date: DateTime(2024, 1, 1)),
    );
    await sourceLedger.recordTransaction(
      _cash('c2', accountId, TransactionKind.deposit, '500', currency: 'USD', date: DateTime(2024, 1, 2)),
    );

    final exported = await source.exportRawData();
    final (fresh, freshDb) = await importIntoFreshDb(exported);
    addTearDown(freshDb.close);

    final cash = await fresh.getAccountDerivedCash(accountId);
    expect(cash.cash, '1000', reason: 'seul le bucket EUR (devise du compte) est persisté');
  });

  // ---------------------------------------------------------------------------
  // 10. Compte kind=cash : cash_balance intact, derived_cash "0" sans effet
  // ---------------------------------------------------------------------------
  test('10. compte kind=cash : cash_balance restauré intact, derived_cash "0" stampé sans effet',
      () async {
    const cashAccountId = 'acc-cash';
    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {
          'id': cashAccountId,
          'walletId': walletId,
          'name': 'Livret',
          'kind': 'cash',
          'currency': 'EUR',
          'cashBalance': 4200.0,
        }
      ],
    };
    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);

    final acc = await fresh.getAccount(cashAccountId);
    expect(acc!.cashBalance, 4200.0, reason: 'cash_balance manuel jamais touché par la reprojection');

    final cash = await fresh.getAccountDerivedCash(cashAccountId);
    expect(cash.cash, '0', reason: 'cache dérivé stampé (journal vide) sans effet sur cash_balance');
    expect(cash.at, isNotNull);
  });

  // ---------------------------------------------------------------------------
  // 11. Atomicité : rejet → données ET caches préexistants intacts
  // ---------------------------------------------------------------------------
  group('11. atomicité de la reprojection post-restauration', () {
    test('kind inconnu ⇒ rejet, positions et caches préexistants intacts', () async {
      await seedWalletAndAccount();
      await seedEmptyPosition('AAPL');
      await sourceLedger.recordTransaction(
        _buy('t1', accountId, 'AAPL', '10', '100', amount: '-1000', date: DateTime(2024, 1, 1)),
      );
      final preexisting = await source.exportRawData();
      // Import initial dans la base "cible" pour établir un état préexistant.
      final targetDb = await openTestDatabase();
      final target = AccountStorage(database: targetDb);
      addTearDown(targetDb.close);
      await target.importRawData(preexisting);
      final derivedAtBefore = await target.getPositionDerivedAt(accountId, 'AAPL');
      expect(derivedAtBefore, isNotNull);
      final cashBefore = await target.getAccountDerivedCash(accountId);

      final corrupted = {
        'wallets': [
          {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
        ],
        'accounts': [
          {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
        ],
        'positions': <String, dynamic>{},
        'transactions': {
          accountId: [
            {
              'id': 'tx-future',
              'accountId': accountId,
              'kind': 'someFutureKind',
              'currency': 'EUR',
              'date': '2024-03-01T00:00:00.000',
            },
          ],
        },
      };

      await expectLater(target.importRawData(corrupted), throwsA(anything));

      // Rollback complet : la position AAPL préexistante et son cache sont
      // toujours là, inchangés.
      final derivedAtAfter = await target.getPositionDerivedAt(accountId, 'AAPL');
      expect(derivedAtAfter, derivedAtBefore);
      final cashAfter = await target.getAccountDerivedCash(accountId);
      expect(cashAfter.cash, cashBefore.cash);
      expect(cashAfter.at, cashBefore.at);
    });

    test('position orpheline (accountId absent) ⇒ rejet, aucune écriture', () async {
      final corrupted = {
        'wallets': [
          {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
        ],
        'accounts': <Map<String, dynamic>>[],
        'positions': {
          'ghost-account': [_pos('ghost-account', 'AAPL', '10', 100.0).toJson()],
        },
      };
      final freshDb = await openTestDatabase();
      final fresh = AccountStorage(database: freshDb);
      addTearDown(freshDb.close);

      await expectLater(fresh.importRawData(corrupted), throwsA(anything));
      final wallets = await fresh.getAllWallets();
      expect(wallets, isEmpty, reason: 'rollback atomique complet');
    });
  });

  // ---------------------------------------------------------------------------
  // 12. Stabilité round-trip : export → import → export identique
  // ---------------------------------------------------------------------------
  test('12. round-trip export→import→export : section data identique', () async {
    await seedWalletAndAccount();
    await sourceLedger.recordTransaction(
      _cash('c1', accountId, TransactionKind.deposit, '1000', date: DateTime(2024, 1, 1)),
    );
    await sourceLedger.recordTransaction(
      _buy('t1', accountId, 'AAPL', '10', '100', amount: '-1000', date: DateTime(2024, 1, 2)),
    );

    final export1 = await source.exportRawData();
    final (fresh, freshDb) = await importIntoFreshDb(export1);
    addTearDown(freshDb.close);
    final export2 = await fresh.exportRawData();

    expect(export2, equals(export1));
  });

  // ---------------------------------------------------------------------------
  // 13. Régression revue adversariale (finding 1) : la clé de la map
  // `transactions` fait foi pour account_id — JAMAIS le champ interne
  // `accountId` du JSON, qui peut diverger sur un fichier malformé.
  // ---------------------------------------------------------------------------
  test(
      '13. accountId interne divergent (fichier malformé) : la clé de map fait '
      'foi partout, la déclaration n\'est jamais écrasée par une projection vide',
      () async {
    const accountA = 'acc1';
    const accountB = 'acc2';
    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {'id': accountA, 'walletId': walletId, 'name': 'Compte A', 'kind': 'cto', 'currency': 'EUR'},
        {'id': accountB, 'walletId': walletId, 'name': 'Compte B', 'kind': 'cto', 'currency': 'EUR'},
      ],
      'positions': {
        accountA: [_pos(accountA, 'AAPL', '100', 50.0).toJson()],
      },
      'transactions': {
        // Clé de map = accountA, mais le champ INTERNE 'accountId' du JSON
        // pointe vers accountB (fichier malformé — les deux comptes existent,
        // donc la FK ne rejette rien).
        accountA: [
          {
            'id': 'tx-mismatch',
            'accountId': accountB,
            'symbol': 'AAPL',
            'kind': 'buy',
            'quantity': '100',
            'unitPrice': '50',
            'currency': 'EUR',
            'date': '2024-01-01T00:00:00.000',
          },
        ],
      },
    };

    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);

    // Écriture : le mouvement est bien persisté sous account_id = accountA
    // (la clé de la map), PAS sous le champ interne divergent accountB.
    final database = await freshDb.database;
    final rowsA = await database.query('transactions', where: 'account_id = ?', whereArgs: [accountA]);
    expect(rowsA, hasLength(1));
    expect(rowsA.single['symbol'], 'AAPL');
    final rowsB = await database.query('transactions', where: 'account_id = ?', whereArgs: [accountB]);
    expect(rowsB, isEmpty);

    // Décision : la reprojection (relue par account_id = accountA) trouve
    // désormais le même journal que la décision d'adoption en mémoire
    // (groupée par la même clé) ⇒ cohérence, adoption correcte, déclaration
    // intacte (PAS écrasée par une reprojection vide).
    expect(await fresh.getPositionDerivedAt(accountA, 'AAPL'), isNotNull);
    final pos = await fresh.getPosition(accountA, 'AAPL');
    expect(pos!.quantity, '100');
    expect(pos.averageBuyPrice, 50.0);
  });

  // ---------------------------------------------------------------------------
  // 14. Régression revue adversariale (finding 2) : positions[] dupliquées sur
  // un même symbole (fichier fabriqué) — la DERNIÈRE entrée (celle que
  // l'INSERT OR REPLACE conserve en base) doit seule décider l'adoption.
  // ---------------------------------------------------------------------------
  test(
      '14. positions[] dupliquées sur AAPL : la DERNIÈRE entrée (ligne DB) décide, '
      'jamais la première (perdante, jamais écrite)', () async {
    final data = {
      'wallets': [
        {'id': walletId, 'name': 'Wallet', 'createdAt': '2024-01-01T00:00:00.000'}
      ],
      'accounts': [
        {'id': accountId, 'walletId': walletId, 'name': 'Compte', 'kind': 'cto', 'currency': 'EUR'}
      ],
      'positions': {
        accountId: [
          // Perdante (jamais en base) : matche EXACTEMENT la projection.
          _pos(accountId, 'AAPL', '10', 100.0).toJson(),
          // Gagnante (dernière — celle que l'INSERT OR REPLACE conserve) :
          // divergente de la projection.
          _pos(accountId, 'AAPL', '999', 1.0).toJson(),
        ],
      },
      'transactions': {
        accountId: [_buy('t1', accountId, 'AAPL', '10', '100').toJson()],
      },
    };

    final (fresh, freshDb) = await importIntoFreshDb(data);
    addTearDown(freshDb.close);

    // La ligne réellement en base est la DERNIÈRE (INSERT OR REPLACE).
    final pos = await fresh.getPosition(accountId, 'AAPL');
    expect(pos!.quantity, '999');
    expect(pos.averageBuyPrice, 1.0);
    // Elle diverge de sa projection ⇒ reste legacy — la première (perdante,
    // qui aurait matché) ne doit JAMAIS avoir déclenché l'adoption.
    expect(await fresh.getPositionDerivedAt(accountId, 'AAPL'), isNull);
  });
}

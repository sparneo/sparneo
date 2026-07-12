// test/services/ledger_service_test.dart
//
// Projecteur atomique B* : recordTransaction / deleteTransaction /
// emitOpeningBalance / emitAdjustment / deletePositionWithJournal.
//
// On travaille sur une base in-memory (openTestDatabase) seedée avec un wallet,
// un compte et des lignes positions PORTANT asset_json (le projecteur fait un
// UPDATE ciblé, il ne fabrique jamais la ligne).

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;

import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import '../helpers/test_database.dart';

/// Double de test pour le test I2 (atomicité) : hérite du [TransactionStorage]
/// réel (constructeur `forTesting`, jamais de connexion propre — LedgerService
/// lui passe toujours l'exécuteur de transaction en cours) mais force
/// [getBySymbol] à lever. Cette méthode est appelée par
/// `LedgerService._reprojectSymbol` APRÈS que le mouvement a déjà été inséré
/// dans la même transaction SQL (`db.transaction`) : ça simule un échec DANS
/// la reprojection, une fois le journal déjà muté, et permet de vérifier que
/// le rollback SQL défait bien les DEUX (mouvement ET position), jamais l'un
/// sans l'autre.
class _ThrowOnReprojectTransactionStorage extends TransactionStorage {
  _ThrowOnReprojectTransactionStorage() : super.forTesting();

  @override
  Future<List<AssetTransaction>> getBySymbol(
    String accountId,
    String symbol, {
    DatabaseExecutor? executor,
  }) {
    throw Exception('échec forcé de la reprojection (test I2 - rollback atomique)');
  }
}

void main() {
  late AppDatabase appDb;
  late LedgerService ledger;
  late AccountStorage accounts;
  late TransactionStorage txStorage;

  const accountId = 'a1';

  Future<void> seedAccount() async {
    final db = await appDb.database;
    await db.insert('wallets', {
      'id': 'w1',
      'name': 'W',
      'created_at': '2024-01-01T00:00:00.000',
    });
    await db.insert('accounts', {
      'id': accountId,
      'wallet_id': 'w1',
      'name': 'CTO',
      'type': 'investment',
      'currency': 'EUR',
      'kind': 'autre',
    });
  }

  /// Crée une ligne positions vide (quantité "0", asset_json présent) pour
  /// [symbol] afin que le projecteur puisse la mettre à jour.
  Future<void> seedEmptyPosition(String symbol) async {
    await accounts.savePosition(
      accountId,
      Position(
        accountId: accountId,
        asset: Asset(symbol: symbol, name: symbol, type: AssetType.stock, currency: 'EUR'),
        quantity: '0',
        customName: 'Nom-$symbol',
      ),
    );
  }

  AssetTransaction buy(String id, String symbol, String qty, String price, {DateTime? date}) {
    return AssetTransaction(
      id: id,
      accountId: accountId,
      symbol: symbol,
      kind: TransactionKind.buy,
      quantity: qty,
      unitPrice: price,
      currency: 'EUR',
      date: date ?? DateTime(2024, 1, int.parse(id.replaceAll(RegExp(r'\D'), '')).clamp(1, 28)),
    );
  }

  setUp(() async {
    appDb = await openTestDatabase();
    ledger = LedgerService(database: appDb);
    accounts = AccountStorage(database: appDb);
    txStorage = TransactionStorage(database: appDb);
    await seedAccount();
  });

  tearDown(() async {
    await appDb.close();
  });

  group('recordTransaction', () {
    test('buy → quantité/PRU/derived_at à jour, journal écrit (atomicité)', () async {
      await seedEmptyPosition('AAPL');
      final before = await accounts.getPositionDerivedAt(accountId, 'AAPL');
      expect(before, isNull, reason: 'position seedée = legacy, derived_at NULL');

      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));

      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos, isNotNull);
      expect(pos!.quantity, '10');
      expect(pos.averageBuyPrice, closeTo(100.0, 1e-9));
      // Métadonnées préservées (UPDATE ciblé, pas INSERT OR REPLACE).
      expect(pos.customName, 'Nom-AAPL');

      final derivedAt = await accounts.getPositionDerivedAt(accountId, 'AAPL');
      expect(derivedAt, isNotNull, reason: 'reprojection doit horodater derived_at');

      // Journal écrit dans la MÊME transaction.
      final journal = await txStorage.getBySymbol(accountId, 'AAPL');
      expect(journal, hasLength(1));
      expect(journal.first.id, '1');
    });

    test('deux buys cumulent quantité et pondèrent le PRU', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await ledger.recordTransaction(buy('2', 'AAPL', '10', '200', date: DateTime(2024, 1, 2)));

      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, '20');
      expect(pos.averageBuyPrice, closeTo(150.0, 1e-9));
    });

    test('position absente → skip défensif sans crash, journal tout de même écrit',
        () async {
      // Pas de seedEmptyPosition : aucune ligne positions pour GHOST.
      await ledger.recordTransaction(buy('1', 'GHOST', '3', '10', date: DateTime(2024, 1, 1)));

      // Aucune position fabriquée (asset_json inconnu).
      final pos = await accounts.getPosition(accountId, 'GHOST');
      expect(pos, isNull);
      // Le mouvement est bien journalisé (mutation faite avant la reprojection).
      final journal = await txStorage.getBySymbol(accountId, 'GHOST');
      expect(journal, hasLength(1));
    });

    test(
        'I2 : échec DANS la transaction (reprojection) → rollback complet, '
        'ni mouvement ni position modifiés (atomicité)', () async {
      await seedEmptyPosition('AAPL');

      final failingLedger = LedgerService(
        database: appDb,
        transactionStorage: _ThrowOnReprojectTransactionStorage(),
      );

      // L'upsert du mouvement réussit DANS la transaction SQL, mais l'appel
      // suivant (reprojection → getBySymbol) lève : verrouille l'invariant
      // « soit les deux, soit aucun » — le rollback SQL doit défaire l'INSERT
      // déjà exécuté, pas seulement empêcher l'UPDATE positions.
      await expectLater(
        failingLedger.recordTransaction(
          buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)),
        ),
        throwsException,
      );

      // (a) le mouvement n'a PAS été persisté (rollback de l'INSERT transactions).
      final journal = await txStorage.getBySymbol(accountId, 'AAPL');
      expect(journal, isEmpty,
          reason: 'le rollback doit défaire l\'insertion du mouvement');

      // (b) la position n'a PAS été modifiée (toujours la ligne seedée à "0").
      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos, isNotNull);
      expect(pos!.quantity, '0',
          reason: 'la position ne doit pas avoir été touchée par une '
              'reprojection avortée');
      expect(pos.averageBuyPrice, isNull);
    });

    test('mouvement cash pur (symbol null) → journalisé sans reprojection', () async {
      await ledger.recordTransaction(AssetTransaction(
        id: 'c1',
        accountId: accountId,
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '500',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      ));
      final all = await txStorage.getByAccount(accountId);
      expect(all.map((t) => t.id), contains('c1'));
    });
  });

  group('deleteTransaction', () {
    test('suppression décrémente la projection', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await ledger.recordTransaction(buy('2', 'AAPL', '5', '100', date: DateTime(2024, 1, 2)));

      await ledger.deleteTransaction('2');

      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, '10');
      expect(pos.averageBuyPrice, closeTo(100.0, 1e-9));
      final journal = await txStorage.getBySymbol(accountId, 'AAPL');
      expect(journal, hasLength(1));
    });

    test('suppression de la DERNIÈRE transaction → quantité "0", ligne conservée',
        () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));

      await ledger.deleteTransaction('1');

      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos, isNotNull, reason: 'D4 : le projecteur ne supprime jamais la position');
      expect(pos!.quantity, '0');
      expect(pos.averageBuyPrice, isNull);
      // La ligne reste projetée (derived_at horodaté par la reprojection).
      final derivedAt = await accounts.getPositionDerivedAt(accountId, 'AAPL');
      expect(derivedAt, isNotNull);
    });

    test('id inexistant → no-op sans crash', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await ledger.deleteTransaction('does-not-exist');
      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, '10');
    });
  });

  group('emitOpeningBalance / emitAdjustment', () {
    test('emitOpeningBalance → kind openingBalance, meta.declarative, reprojection',
        () async {
      await seedEmptyPosition('AAPL');
      await ledger.emitOpeningBalance(
        accountId: accountId,
        symbol: 'AAPL',
        quantity: '8',
        unitPrice: '50',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );

      final journal = await txStorage.getBySymbol(accountId, 'AAPL');
      expect(journal, hasLength(1));
      expect(journal.first.kind, TransactionKind.openingBalance);
      expect(journal.first.meta?['declarative'], isTrue);

      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, '8');
      expect(pos.averageBuyPrice, closeTo(50.0, 1e-9));
    });

    test('emitAdjustment négatif → kind adjustment, delta appliqué', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await ledger.emitAdjustment(
        accountId: accountId,
        symbol: 'AAPL',
        deltaQuantity: '-3',
        unitPrice: '100',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );

      final journal = await txStorage.getBySymbol(accountId, 'AAPL');
      final adj = journal.firstWhere((t) => t.kind == TransactionKind.adjustment);
      expect(adj.quantity, '-3');

      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, '7');
      expect(pos.averageBuyPrice, closeTo(100.0, 1e-9));
    });

    test('emitAdjustment propage la note dans le mouvement (round-trip)', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await ledger.emitAdjustment(
        accountId: accountId,
        symbol: 'AAPL',
        deltaQuantity: '2',
        unitPrice: '100',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
        note: 'recomptage inventaire',
      );

      final journal = await txStorage.getBySymbol(accountId, 'AAPL');
      final adj = journal.firstWhere((t) => t.kind == TransactionKind.adjustment);
      expect(adj.note, 'recomptage inventaire');
    });

    test('emitOpeningBalance propage la note dans le mouvement (round-trip)', () async {
      await seedEmptyPosition('AAPL');
      await ledger.emitOpeningBalance(
        accountId: accountId,
        symbol: 'AAPL',
        quantity: '5',
        unitPrice: null,
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
        note: 'portefeuille repris',
      );

      final journal = await txStorage.getBySymbol(accountId, 'AAPL');
      expect(journal, hasLength(1));
      expect(journal.first.note, 'portefeuille repris');
      // PRU nul admis (base de coût inconnue) : coût 0 dans la projection.
      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, '5');
      expect(pos.averageBuyPrice, isNull);
    });

    test(
        'flux « ajuster » : delta = cible − projection appliqué au journal '
        '(recomptage à PRU invariant)', () async {
      // Position réconciliée journal NON vide : 10 @ 100 (projection courante).
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      final projected = (await accounts.getPosition(accountId, 'AAPL'))!;
      expect(projected.quantity, '10');

      // L'UI saisit une cible de 12 → delta signé = 12 − 10 = +2, émis au PRU
      // projeté courant (100) pour laisser le PRU invariant.
      final target = Decimal.parse('12');
      final current = Decimal.parse(projected.quantity);
      final delta = target - current;
      expect(delta.toString(), '2');
      await ledger.emitAdjustment(
        accountId: accountId,
        symbol: 'AAPL',
        deltaQuantity: delta.toString(),
        unitPrice: projected.averageBuyPrice?.toString(),
        currency: 'EUR',
        date: DateTime(2024, 1, 3),
      );

      final pos = await accounts.getPosition(accountId, 'AAPL');
      expect(pos!.quantity, '12');
      expect(pos.averageBuyPrice, closeTo(100.0, 1e-9),
          reason: 'recomptage au PRU courant ⇒ PRU invariant');
    });
  });

  group('reconcileFromJournal (adoption D3)', () {
    test(
        'adopte le journal existant : projette q/PRU et horodate derived_at '
        'SANS double comptage ni mouvement ajouté', () async {
      // Position legacy : ligne seedée (qty "0", derived_at NULL) + journal
      // inséré HORS ledger (upsert direct = pas de reprojection). Simule une
      // position dont le journal existe mais n'a jamais été projeté.
      await seedEmptyPosition('AAPL');
      await txStorage.upsert(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await txStorage.upsert(buy('2', 'AAPL', '10', '200', date: DateTime(2024, 1, 2)));

      expect(await accounts.getPositionDerivedAt(accountId, 'AAPL'), isNull,
          reason: 'position encore legacy avant adoption');

      await ledger.reconcileFromJournal(accountId, 'AAPL');

      final pos = await accounts.getPosition(accountId, 'AAPL');
      // Projection du journal (20 @ PRU 150), PAS 0 (legacy) + 20 (additif).
      expect(pos!.quantity, '20');
      expect(pos.averageBuyPrice, closeTo(150.0, 1e-9));
      expect(await accounts.getPositionDerivedAt(accountId, 'AAPL'), isNotNull,
          reason: 'l\'adoption doit horodater derived_at');
      // Aucun mouvement ajouté : adoption pure (pas d'openingBalance).
      expect(await txStorage.getBySymbol(accountId, 'AAPL'), hasLength(2));
    });

    test(
        'reconcileFromJournal reprojette AUSSI le cash sur un compte jamais '
        'projeté (derived_cash_at NULL) : derived_at ET derived_cash posés',
        () async {
      await seedEmptyPosition('AAPL');
      // Journal inséré HORS ledger (upsert direct) : ni la position ni le
      // cache cash n'ont jamais été reprojetés (derived_at et derived_cash_at
      // tous deux NULL, simulant une base migrée pré-v6 ou une position
      // restaurée avant le correctif d'import).
      await txStorage.upsert(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await txStorage.upsert(AssetTransaction(
        id: 'c1',
        accountId: accountId,
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '2000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      ));

      expect(await accounts.getPositionDerivedAt(accountId, 'AAPL'), isNull);
      final cashBefore = await accounts.getAccountDerivedCash(accountId);
      expect(cashBefore.at, isNull, reason: 'compte jamais projeté avant adoption');

      await ledger.reconcileFromJournal(accountId, 'AAPL');

      expect(await accounts.getPositionDerivedAt(accountId, 'AAPL'), isNotNull);
      final cashAfter = await accounts.getAccountDerivedCash(accountId);
      expect(cashAfter.at, isNotNull, reason: 'l\'adoption doit initialiser le cache cash');
      // Σ amount de TOUT le journal du compte : 2000 (deposit) ; le buy n'a
      // pas d'amount ici (helper buy() n'en pose pas).
      expect(cashAfter.cash, '2000');
    });
  });

  group('deletePositionWithJournal', () {
    test('supprime la position + tout son journal ; un autre symbole survit',
        () async {
      await seedEmptyPosition('AAPL');
      await seedEmptyPosition('MSFT');
      await ledger.recordTransaction(buy('1', 'AAPL', '10', '100', date: DateTime(2024, 1, 1)));
      await ledger.recordTransaction(buy('2', 'AAPL', '5', '110', date: DateTime(2024, 1, 2)));
      await ledger.recordTransaction(buy('3', 'MSFT', '4', '300', date: DateTime(2024, 1, 3)));

      await ledger.deletePositionWithJournal(accountId, 'AAPL');

      // AAPL : position ET journal effacés.
      expect(await accounts.getPosition(accountId, 'AAPL'), isNull);
      expect(await txStorage.getBySymbol(accountId, 'AAPL'), isEmpty);

      // MSFT : intact.
      final msft = await accounts.getPosition(accountId, 'MSFT');
      expect(msft, isNotNull);
      expect(msft!.quantity, '4');
      expect(await txStorage.getBySymbol(accountId, 'MSFT'), hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  // Reprojection du SOLDE ESPÈCES DÉRIVÉ (lot cash).
  //
  // NB : le helper `buy()` ne pose PAS d'amount — le cash d'un buy vient
  // ENTIÈREMENT du champ amount (partition stricte, jamais recalculé depuis
  // q×p). Les tests cash construisent donc des mouvements AVEC amount explicite.
  // ---------------------------------------------------------------------------
  group('reprojection cash (accounts.derived_cash)', () {
    AssetTransaction cashMove({
      required String id,
      required TransactionKind kind,
      String? symbol,
      String? amount,
      String currency = 'EUR',
      DateTime? date,
    }) =>
        AssetTransaction(
          id: id,
          accountId: accountId,
          symbol: symbol,
          kind: kind,
          amount: amount,
          currency: currency,
          date: date ?? DateTime(2024, 1, int.parse(id.replaceAll(RegExp(r'\D'), '')).clamp(1, 28)),
        );

    test('compte seedé (jamais projeté) → derived_cash NULL', () async {
      final c = await accounts.getAccountDerivedCash(accountId);
      expect(c.cash, isNull);
      expect(c.at, isNull);
    });

    test('B5 : un deposit cash pur (symbol null) alimente le solde dérivé', () async {
      await ledger.recordTransaction(
        cashMove(id: '1', kind: TransactionKind.deposit, amount: '500'),
      );
      final c = await accounts.getAccountDerivedCash(accountId);
      expect(c.cash, '500');
      expect(c.at, isNotNull, reason: 'la reprojection cash doit horodater');
    });

    test('buy (amount signé) déplace le cash autant qu\'un mouvement pur', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(
        cashMove(id: '1', kind: TransactionKind.deposit, amount: '1000', date: DateTime(2024, 1, 1)),
      );
      await ledger.recordTransaction(
        cashMove(id: '2', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-1502', date: DateTime(2024, 1, 2)),
      );
      final c = await accounts.getAccountDerivedCash(accountId);
      expect(c.cash, '-502'); // 1000 − 1502
    });

    test('édition d\'un buy (même id, amount changé) reprojette le cash', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(
        cashMove(id: '2', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-1502', date: DateTime(2024, 1, 2)),
      );
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '-1502');
      // Ré-enregistrement (upsert) du même id avec un amount corrigé.
      await ledger.recordTransaction(
        cashMove(id: '2', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-1600', date: DateTime(2024, 1, 2)),
      );
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '-1600');
    });

    test('suppression d\'un mouvement reprojette le cash', () async {
      await ledger.recordTransaction(
        cashMove(id: '1', kind: TransactionKind.deposit, amount: '1000', date: DateTime(2024, 1, 1)),
      );
      await ledger.recordTransaction(
        cashMove(id: '2', kind: TransactionKind.withdrawal, amount: '-300', date: DateTime(2024, 1, 2)),
      );
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '700');
      await ledger.deleteTransaction('2');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '1000');
    });

    test('PAS de clamp : buys-only sans dépôt → solde dérivé négatif', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(
        cashMove(id: '1', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-500', date: DateTime(2024, 1, 1)),
      );
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '-500');
    });

    test('openingBalance TITRE (symbol non null) N\'AFFECTE PAS le cash', () async {
      await seedEmptyPosition('AAPL');
      await ledger.emitOpeningBalance(
        accountId: accountId,
        symbol: 'AAPL',
        quantity: '8',
        unitPrice: '50',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      // Le cash a bien été reprojeté (derived_cash_at posé) mais reste 0 : le
      // lot titre déclaratif ne porte aucun amount.
      final c = await accounts.getAccountDerivedCash(accountId);
      expect(c.at, isNotNull);
      expect(c.cash, '0');
    });

    test('emitCashOpeningBalance → openingBalance espèces, cash dérivé posé', () async {
      await ledger.emitCashOpeningBalance(
        accountId: accountId,
        amount: '2500',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
        note: 'trésorerie reprise',
      );
      final journal = await txStorage.getByAccount(accountId);
      expect(journal, hasLength(1));
      expect(journal.first.kind, TransactionKind.openingBalance);
      expect(journal.first.symbol, isNull);
      expect(journal.first.amount, '2500');
      expect(journal.first.meta?['declarative'], isTrue);
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '2500');
    });

    test('emitCashAdjustment → adjustment espèces, delta appliqué au cash', () async {
      await ledger.emitCashOpeningBalance(
        accountId: accountId,
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      );
      await ledger.emitCashAdjustment(
        accountId: accountId,
        amount: '-150',
        currency: 'EUR',
        date: DateTime(2024, 1, 2),
      );
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '850');
    });

    test('devise étrangère (≠ devise du compte) N\'entre PAS dans le bucket', () async {
      // Compte en EUR : un mouvement USD ne doit pas polluer le solde EUR.
      await ledger.recordTransaction(
        cashMove(id: '1', kind: TransactionKind.deposit, amount: '1000', currency: 'EUR', date: DateTime(2024, 1, 1)),
      );
      await ledger.recordTransaction(
        cashMove(id: '2', kind: TransactionKind.deposit, amount: '999', currency: 'USD', date: DateTime(2024, 1, 2)),
      );
      // Seul le total EUR est persisté (devises jamais sommées).
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '1000');
    });

    test('atomicité : reprojection avortée → derived_cash NON écrit (rollback)', () async {
      await seedEmptyPosition('AAPL');
      final failingLedger = LedgerService(
        database: appDb,
        transactionStorage: _ThrowOnReprojectTransactionStorage(),
      );
      await expectLater(
        failingLedger.recordTransaction(
          cashMove(id: '1', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-1000', date: DateTime(2024, 1, 1)),
        ),
        throwsException,
      );
      // Ni le mouvement ni le cache cash n'ont été persistés.
      expect(await txStorage.getByAccount(accountId), isEmpty);
      expect((await accounts.getAccountDerivedCash(accountId)).cash, isNull);
    });

    test('deletePositionWithJournal reprojette aussi le cash du compte', () async {
      await seedEmptyPosition('AAPL');
      await ledger.recordTransaction(
        cashMove(id: '1', kind: TransactionKind.deposit, amount: '1000', date: DateTime(2024, 1, 1)),
      );
      await ledger.recordTransaction(
        cashMove(id: '2', kind: TransactionKind.buy, symbol: 'AAPL', amount: '-600', date: DateTime(2024, 1, 2)),
      );
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '400');
      // Effacer la position AAPL + son journal (le buy) : le cash remonte à 1000.
      await ledger.deletePositionWithJournal(accountId, 'AAPL');
      expect((await accounts.getAccountDerivedCash(accountId)).cash, '1000');
    });
  });
}

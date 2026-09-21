// test/crypto_ledger_market_history_lot4_test.dart
//
// Tests du LOT 4 (PHASE A) du chantier B16 (étage 2 « cours en-app », conception
// interne) : intégration
// `AccountController._previewCryptoImport`/`_resolveMarketHistoryValuations`/
// `revertCryptoValuationToManual`. Couvre la cascade décrite dans
// `account_controller.dart` — SEUL le motif `unreadable` atteint cet étage,
// jambe PAYÉE cotée en priorité (repli REÇUE, systématique pour un dépôt en
// nature), jamais bloquant sur panne réseau/FX indisponible/absence de barre le
// jour exact.
//
// Fixtures 100 % SYNTHÉTIQUES (actifs fictifs AAA/BBB/CCC…, même patron que
// `crypto_ledger_kraken_lot1_test.dart`, dont le générateur de grand livre
// [_LedgerBuilder] est ici DUPLIQUÉ à l'identique — aucun import croisé entre
// fichiers de test). AUCUN appel réseau réel : `getHistoricalRange`/
// `symbolExists` sont interceptés par un [MarketDataService] fake dédié
// ([_FakeMarketDataServiceLot4]), la série FX (frankfurter) par
// `http.runWithClient`/`MockClient` (même mécanisme que le lot 1/2).

import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import 'helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Générateur de grand livre Kraken synthétique — DUPLIQUÉ à l'identique de
// `crypto_ledger_kraken_lot1_test.dart` (colonne `balance` calculée PAR
// ACCUMULATION, jamais fournie à la main).
// ---------------------------------------------------------------------------

const _krakenHeader = [
  'txid', 'refid', 'time', 'type', 'subtype', 'aclass', 'subclass',
  'asset', 'wallet', 'amount', 'fee', 'balance', 'amountusd', 'feeusd',
  'balanceusd', 'feecurrency', //
];

class _LedgerBuilder {
  final List<List<String>> rows = [];
  final Map<String, Decimal> _runningBalance = {};
  int _seq = 0;

  void leg({
    required String refid,
    required String time, // 'AAAA-MM-JJ HH:MM:SS'
    required String type,
    String subtype = '',
    required String asset,
    String wallet = 'spot/main',
    required String amount,
    String fee = '0',
    required String subclass,
    String? amountusd,
  }) {
    _seq++;
    final key = '$asset|$wallet';
    final newBalance = (_runningBalance[key] ?? Decimal.zero) +
        Decimal.parse(amount) -
        Decimal.parse(fee);
    _runningBalance[key] = newBalance;
    rows.add([
      'L$_seq', refid, time, type, subtype, 'currency', subclass,
      asset, wallet, amount, fee, newBalance.toString(),
      amountusd ?? '-', '0', '0', '', //
    ]);
  }

  Uint8List toCsvBytes() {
    final all = [_krakenHeader, ...rows];
    final text = all.map((r) => r.join(',')).join('\n');
    return Uint8List.fromList(utf8.encode(text));
  }
}

/// Fake SANS RÉSEAU RÉEL de [MarketDataService] — pilote `symbolExists`
/// (cascade de résolution ticker, `AccountController._resolveCryptoTicker`)
/// et `getHistoricalRange` (étage 2) par des tables `symbole → réponse`
/// fournies par le test, journalisant CHAQUE appel dans [symbolExistsCallLog]/
/// [rangeCallLog] — sert à la fois à contrôler les scénarios ET à prouver
/// l'absence d'appel quand la cascade ne doit JAMAIS atteindre l'étage 2 (ex.
/// motif `spread`, fichier entièrement valorisé à l'étage 1).
class _FakeMarketDataServiceLot4 extends MarketDataService {
  /// `symbole-devise → bool?` (`null` = panne réseau simulée).
  final Map<String, bool?> symbolAnswers;

  /// `symbole → barres` renvoyées par `getHistoricalRange` — `null` absent de
  /// la table = résultat `null` (aucune barre / panne, cf. doc de la méthode
  /// réelle).
  final Map<String, AssetHistoricalData?> rangeAnswers;

  /// Symboles pour lesquels `getHistoricalRange` doit lever une exception
  /// (panne réseau simulée AUTREMENT qu'un simple retour `null` — prouve que
  /// le `try/catch` B4 de `_resolveMarketHistoryValuations` absorbe aussi une
  /// exception, pas seulement un résultat `null`).
  final Set<String> rangeThrowsFor;

  final List<String> symbolExistsCallLog = [];
  final List<String> rangeCallLog = [];

  _FakeMarketDataServiceLot4({
    this.symbolAnswers = const {},
    this.rangeAnswers = const {},
    this.rangeThrowsFor = const {},
  });

  @override
  Future<bool?> symbolExists(String symbol) async {
    symbolExistsCallLog.add(symbol);
    return symbolAnswers[symbol];
  }

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async => null;

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(Asset asset,
          {int days = 30}) async =>
      null;

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol,
          {int days = 30}) async =>
      null;

  @override
  Future<AssetHistoricalData?> getHistoricalRange(
    String symbol,
    DateTime from,
    DateTime to, {
    int maxAttempts = 3,
  }) async {
    rangeCallLog.add(symbol);
    if (rangeThrowsFor.contains(symbol)) {
      throw Exception('panne réseau simulée (getHistoricalRange $symbol)');
    }
    return rangeAnswers[symbol];
  }
}

/// Barre UNIQUE au jour UTC [day] à la clôture [close] — construit
/// [AssetHistoricalData] pour un symbole donné (l'étage 2 n'utilise qu'une
/// clôture par jour, jamais l'heure).
AssetHistoricalData _oneBar(String symbol, DateTime day, num close) =>
    AssetHistoricalData(
      symbol: symbol,
      dates: [DateTime.utc(day.year, day.month, day.day)],
      prices: [close],
    );

/// Corps de réponse frankfurter minimal (mêmes clés que l'API réelle, même
/// helper que `crypto_ledger_kraken_lot1_test.dart`).
String _frankfurterBody(Map<String, double> ratesByDay) {
  final entries = ratesByDay.entries
      .map((e) => '"${e.key}":{"EUR":${e.value}}')
      .join(',');
  return '{"amount":1.0,"base":"USD","rates":{$entries}}';
}

void main() {
  final profile = BrokerProfile.kraken();

  // ===========================================================================
  // Intégration AccountController — base SQLite in-memory isolée par test
  // (aucun appel réseau réel : `symbolExists`/`getHistoricalRange` simulés
  // par [_FakeMarketDataServiceLot4], FX par `http.runWithClient`+MockClient).
  // ===========================================================================

  group('LOT 4 étage 2 « cours en-app » — intégration AccountController', () {
    Future<void> seedAccount(AppDatabase db, String accountId) async {
      final storage = AccountStorage(database: db);
      await storage.saveWallet(Wallet(id: 'w-crypto', name: 'Wallet crypto'));
      await storage.saveAccount(Account(
        id: accountId,
        walletId: 'w-crypto',
        name: 'Compte crypto',
        kind: AccountKind.cto,
        currency: 'EUR',
      ));
    }

    Future<void> seedLedgerCodePosition(
      AppDatabase db,
      String accountId,
      String ledgerCode,
      String symbol,
    ) async {
      final storage = AccountStorage(database: db);
      await storage.savePosition(
        accountId,
        Position(
          accountId: accountId,
          asset:
              Asset(symbol: symbol, name: symbol, currency: 'EUR', ledgerCode: ledgerCode),
          quantity: '0',
        ),
      );
    }

    Future<AccountController> makeCtrl(
      AppDatabase db,
      String accountId, {
      MarketDataService? marketService,
      ExchangeRateService? exchangeService,
    }) async {
      final storage = AccountStorage(database: db);
      final ctrl = AccountController(
        initialAccountId: accountId,
        storage: storage,
        ledgerService: LedgerService(database: db),
        transactionStorage: TransactionStorage(database: db),
        marketService: marketService ?? _FakeMarketDataServiceLot4(),
        // Instance DÉDIÉE (jamais le singleton applicatif) — même précaution
        // que le lot 1/2 : le cache mémoire de `getDailyRatesToEur` est
        // sinon partagé entre tests de ce fichier.
        exchangeService: exchangeService ?? ExchangeRateService.forTesting(),
      );
      await ctrl.initAccounts();
      return ctrl;
    }

    test(
        'dépôt en nature (`depositInKind`) motif `unreadable`, ticker EUR '
        'résolu via une position EXISTANTE → valorisé à l\'étage 2, jambe '
        'REÇUE, AUCUNE conversion FX (suffixe `-EUR`)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-deposit';
      await seedAccount(db, accountId);
      // Position existante AAA-EUR : étage ① de `_resolveCryptoTicker`, zéro
      // appel réseau pour la résolution du ticker.
      await seedLedgerCodePosition(db, accountId, 'AAA', 'AAA-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RD1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      // AUCUN `amountusd` : illisible à l'étage 1 → `unreadable`.
      b.leg(refid: 'RD2', time: '2024-02-10 09:00:00', type: 'deposit',
          asset: 'AAA', amount: '2', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        rangeAnswers: {
          'AAA-EUR': _oneBar('AAA-EUR', DateTime.utc(2024, 2, 10), 100.0),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.unvaluedExchanges, isEmpty); // valorisé, plus en attente.
      // Ticker résolu via la position EXISTANTE : zéro appel `symbolExists`.
      expect(fakeMarket.symbolExistsCallLog, isEmpty);
      expect(fakeMarket.rangeCallLog, equals(['AAA-EUR']));

      final deposit = preview.toCreate.firstWhere((m) => m.ledgerCode == 'AAA');
      final meta = deposit.transaction!.meta!;
      expect(meta['valuationSource'], equals('marketHistory'));
      expect(meta['quoteSymbol'], equals('AAA-EUR'));
      expect(meta['quoteDate'], equals('2024-02-10'));
      expect(meta['quoteInterval'], equals('1d'));
      expect(meta['quoteLeg'], equals('received'));
      // Suffixe EUR : AUCUNE clé FX posée (conception interne).
      expect(meta.containsKey('fxRate'), isFalse);
      expect(meta.containsKey('fxDate'), isFalse);
      // 2 × 100,0 = 200 EUR — `valueEur` posé par `finalizeCryptoExchanges`
      // pour un dépôt en nature (cf. son en-tête).
      expect(Decimal.parse(meta['valueEur'] as String), equals(Decimal.parse('200')));
    });

    test(
        'échange à 2 jambes motif `unreadable`, jambe PAYÉE cotée en '
        'USD (résolution réseau) → close × qty × FX, `quoteLeg`:`paid` sur '
        'LES DEUX mouvements (sell+buy) émis', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-exchange-paid';
      await seedAccount(db, accountId);
      // Jambe REÇUE (CCC) : position existante — évite un appel réseau
      // SUPPLÉMENTAIRE, hors sujet ici, lors de la résolution du ticker
      // FINAL du mouvement `buy` émis par `_finishCryptoPreview` (orthogonal
      // à la résolution de COTATION de l'étage 2, qui ne s'intéresse, elle,
      // qu'à la jambe PAYÉE puisqu'elle est cotable).
      await seedLedgerCodePosition(db, accountId, 'CCC', 'CCC-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RE1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      // AUCUN `amountusd` sur les deux jambes → `unreadable`.
      b.leg(refid: 'RE2', time: '2024-03-04 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'BBB', amount: '-3', subclass: 'crypto');
      b.leg(refid: 'RE2', time: '2024-03-04 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'CCC', amount: '30', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        symbolAnswers: {
          // Cascade BBB : `BBB-EUR` absent, repli `BBB-USD` présent.
          'BBB-EUR': false,
          'BBB-USD': true,
        },
        rangeAnswers: {
          'BBB-USD': _oneBar('BBB-USD', DateTime.utc(2024, 3, 4), 10.0),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-03-04': 1.1}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.unvaluedExchanges, isEmpty);
      // Jambe payée (BBB) résolue en premier — le TICKER de CCC (jambe
      // reçue) n'est jamais interrogé en réseau : il est déjà connu via sa
      // position EXISTANTE (résolution à coût nul), la résolution réseau
      // s'arrête bien dès que BBB est cotable.
      expect(fakeMarket.symbolExistsCallLog, equals(['BBB-EUR', 'BBB-USD']));
      // Fix cascade (drive auteur : la BARRE de la jambe reçue (CCC-EUR) est
      // désormais interrogée EN PLUS de celle de la payée, enregistrée dès la
      // construction du candidat comme repli de VALORISATION — même si, ici, elle
      // reste inutilisée (BBB-USD suffit).
      expect(fakeMarket.rangeCallLog, equals(['BBB-USD', 'CCC-EUR']));

      final sell = preview.toCreate.firstWhere((m) => m.ledgerCode == 'BBB');
      final buy = preview.toCreate.firstWhere((m) => m.ledgerCode == 'CCC');
      // 3 × 10,0 × 1,1 = 33,0 EUR — montants opposés (règle N4). `Decimal.
      // toString()` ne pousse pas de zéro de remplissage sur une division
      // exacte (même remarque que le lot 2, cf. `crypto_ledger_kraken_lot1_
      // test.dart`).
      expect(sell.transaction!.amount, equals('33'));
      expect(buy.transaction!.amount, equals('-33'));
      for (final m in [sell, buy]) {
        final meta = m.transaction!.meta!;
        expect(meta['valuationSource'], equals('marketHistory'));
        expect(meta['quoteSymbol'], equals('BBB-USD'));
        expect(meta['quoteDate'], equals('2024-03-04'));
        expect(meta['quoteLeg'], equals('paid'));
        expect(meta['fxRate'], equals('1.1'));
        expect(meta['fxDate'], equals('2024-03-04'));
      }
    });

    test(
        'jambe PAYÉE non cotable (`symbolExists` faux aux deux étages) → '
        'repli sur la jambe REÇUE (position existante), `quoteLeg`:`received`',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-exchange-fallback';
      await seedAccount(db, accountId);
      // EEE (jambe reçue) résolue via position existante — zéro appel réseau
      // pour ELLE (seule DDD, jambe payée, interroge le réseau).
      await seedLedgerCodePosition(db, accountId, 'EEE', 'EEE-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RF1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RF2', time: '2024-04-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'DDD', amount: '-1', subclass: 'crypto');
      b.leg(refid: 'RF2', time: '2024-04-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'EEE', amount: '40', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        symbolAnswers: {
          'DDD-EUR': false,
          'DDD-USD': false, // DDD non cotable NULLE PART.
        },
        rangeAnswers: {
          'EEE-EUR': _oneBar('EEE-EUR', DateTime.utc(2024, 4, 5), 5.0),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.unvaluedExchanges, isEmpty);
      expect(fakeMarket.symbolExistsCallLog, equals(['DDD-EUR', 'DDD-USD']));
      expect(fakeMarket.rangeCallLog, equals(['EEE-EUR']));

      final sell = preview.toCreate.firstWhere((m) => m.ledgerCode == 'DDD');
      final buy = preview.toCreate.firstWhere((m) => m.ledgerCode == 'EEE');
      // 40 × 5,0 = 200 EUR, suffixe EUR — aucune conversion.
      expect(sell.transaction!.amount, equals('200'));
      expect(buy.transaction!.amount, equals('-200'));
      expect(sell.transaction!.meta!['quoteLeg'], equals('received'));
      expect(buy.transaction!.meta!['quoteLeg'], equals('received'));
      expect(sell.transaction!.meta!['quoteSymbol'], equals('EEE-EUR'));
    });

    test(
        'AUCUNE des deux jambes cotable → reste en arbitrage manuel motif '
        '`unreadable` INCHANGÉ, AUCUN appel `getHistoricalRange`', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-exchange-neither';
      await seedAccount(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RG1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RG2', time: '2024-05-06 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'FFF', amount: '-1', subclass: 'crypto');
      b.leg(refid: 'RG2', time: '2024-05-06 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'GGG', amount: '10', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        symbolAnswers: {
          'FFF-EUR': false,
          'FFF-USD': false,
          'GGG-EUR': false,
          'GGG-USD': false,
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.toCreate.any((m) => m.ledgerCode == 'FFF'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'GGG'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      expect(preview.unvaluedExchanges.single.manualReason, equals('unreadable'));
      expect(fakeMarket.rangeCallLog, isEmpty);
    });

    test(
        'motif `spread` (écart > 10 %, jambes lisibles) → N\'ATTEINT JAMAIS '
        'l\'étage 2, zéro appel `symbolExists`/`getHistoricalRange`', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-spread';
      await seedAccount(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RH1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      // Jambes LISIBLES (`amountusd` présent des deux côtés), écart +25 %.
      b.leg(refid: 'RH2', time: '2024-06-07 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'HHH', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RH2', time: '2024-06-07 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'III', amount: '250', subclass: 'crypto',
          amountusd: '250');

      final fakeMarket = _FakeMarketDataServiceLot4();
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-06-07': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.unvaluedExchanges, hasLength(1));
      expect(preview.unvaluedExchanges.single.manualReason, equals('spread'));
      expect(fakeMarket.symbolExistsCallLog, isEmpty);
      expect(fakeMarket.rangeCallLog, isEmpty);
    });

    test(
        'panne réseau PENDANT `getHistoricalRange` (exception, pas un '
        'simple `null`) → repli SILENCIEUX motif `unreadable`, jamais '
        'd\'exception propagée, le reste du fichier importe quand même',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-range-throws';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'JJJ', 'JJJ-EUR');
      await seedLedgerCodePosition(db, accountId, 'RWD', 'RWD-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RI1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RI2', time: '2024-07-08 09:00:00', type: 'deposit',
          asset: 'JJJ', amount: '5', subclass: 'crypto');
      // Ligne INDÉPENDANTE (récompense ordinaire) — doit importer normalement
      // MALGRÉ la panne sur JJJ (B4 : jamais bloquant pour le reste).
      b.leg(refid: 'RI3', time: '2024-07-09 08:00:00', type: 'staking',
          asset: 'RWD', wallet: 'earn/flexible', amount: '0.5', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        rangeThrowsFor: {'JJJ-EUR'},
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.toCreate.any((m) => m.ledgerCode == 'JJJ'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      expect(preview.unvaluedExchanges.single.manualReason, equals('unreadable'));
      expect(preview.toCreate.any((m) => m.ledgerCode == 'RWD'), isTrue);

      // Confirmation directe : aucune exception ne remonte jusqu'à l'appelant.
      final err = await ctrl.confirmStatementImport(preview, accountId: accountId);
      expect(err, isNull);
    });

    test(
        'devise de cotation NON-EUR mais série FX indisponible (panne '
        'frankfurter) → repli SILENCIEUX motif `unreadable`, jamais '
        'd\'exception propagée', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-fx-unavailable';
      await seedAccount(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RJ1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RJ2', time: '2024-08-09 09:00:00', type: 'deposit',
          asset: 'KKK', amount: '1', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        symbolAnswers: {'KKK-EUR': false, 'KKK-USD': true},
        rangeAnswers: {
          'KKK-USD': _oneBar('KKK-USD', DateTime.utc(2024, 8, 9), 7.0),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      // Frankfurter renvoie une panne HTTP pour TOUTE requête — simule
      // l'échec de `ExchangeRateService.getDailyRatesToEur` (jette
      // `ExchangeRateUnavailable`, absorbée en `try/catch` best-effort par
      // `_resolveMarketHistoryValuations`).
      final mockClient = MockClient((request) async {
        return http.Response('panne simulée', 503);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.toCreate.any((m) => m.ledgerCode == 'KKK'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      expect(preview.unvaluedExchanges.single.manualReason, equals('unreadable'));
      // La barre a bien été récupérée (l'échec porte SEULEMENT sur la FX) —
      // prouve que l'étage 2 est allé jusqu'au bout de la résolution avant
      // d'échouer sur la conversion.
      expect(fakeMarket.rangeCallLog, equals(['KKK-USD']));
    });

    test(
        'non-régression : fichier ENTIÈREMENT valorisé à l\'étage 1 (jambes '
        'lisibles, spread sous seuil) → `_resolveMarketHistoryValuations` ne '
        'tourne même pas, zéro appel `symbolExists`/`getHistoricalRange`',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-non-regression';
      await seedAccount(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RK1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RK2', time: '2024-09-10 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RK2', time: '2024-09-10 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '198', subclass: 'stable_coin',
          amountusd: '198');

      final fakeMarket = _FakeMarketDataServiceLot4();
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final mockClient = MockClient((request) async {
        return http.Response(_frankfurterBody({'2024-09-10': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.unvaluedExchanges, isEmpty);
      final sell = preview.toCreate.firstWhere((m) => m.ledgerCode == 'AAA');
      expect(sell.transaction!.meta!['valuationSource'], equals('statement'));
      // SEUL `getHistoricalRange` (étage 2) est concerné par la
      // non-régression visée ici — `symbolExists` est, lui, appelé
      // MALGRÉ TOUT pour résoudre le ticker FINAL des mouvements émis
      // (`_finishCryptoPreview`, orthogonal à l'étage 2, cf. AAA/STB sans
      // position ni alias préexistants).
      expect(fakeMarket.rangeCallLog, isEmpty);
    });

    test(
        'revertCryptoValuationToManual : une ligne valorisée à l\'étage 2 '
        'repasse en arbitrage manuel motif `unreadable`, la ligne quitte '
        '`toCreate` et réapparaît dans `unvaluedExchanges` avec sa clé de '
        'BASE (suffixe de rôle retiré)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-revert';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'AAA', 'AAA-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RL1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RL2', time: '2024-10-11 09:00:00', type: 'deposit',
          asset: 'AAA', amount: '2', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        rangeAnswers: {
          'AAA-EUR': _oneBar('AAA-EUR', DateTime.utc(2024, 10, 11), 100.0),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );
      expect(preview.unvaluedExchanges, isEmpty);
      final deposit = preview.toCreate.firstWhere((m) => m.ledgerCode == 'AAA');
      final baseKey = 'ref:$accountId:RL2';
      expect(deposit.importKey, equals('$baseKey#deposit:AAA'));

      final reverted = await ctrl.revertCryptoValuationToManual(baseKey);
      expect(reverted, isNotNull);
      expect(reverted!.toCreate.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(reverted.unvaluedExchanges, hasLength(1));
      final back = reverted.unvaluedExchanges.single;
      expect(back.manualReason, equals('unreadable'));
      expect(back.importKey, equals(baseKey));

      // Filet défensif (B4) : une clé qui n'est PAS une valorisation
      // `marketHistory` (ici, déjà repassée en manuel) ne fait plus rien —
      // jamais de crash sur un double appel.
      final noop = await ctrl.revertCryptoValuationToManual(baseKey);
      expect(noop, isNull);
    });

    test(
        'M-2 (revue adversariale LOT 4, arbitrage : retour au comportement '
        'lot 2) : une clé DÉJÀ présente au journal du compte n\'est PAS '
        'soumise à l\'étage 2 — reste « à valoriser », zéro appel '
        '`getHistoricalRange`, aucun rejet `cryptoImportKeyCollision`',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-existing-journal';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'AAA', 'AAA-EUR');

      // Ligne DÉJÀ au journal (ex. arbitrée à la main lors d'un import
      // antérieur, ou confirmée telle quelle) — même clé DÉRIVÉE que
      // produirait un RE-import du même mouvement CSV
      // (`ref:$accountId:RN2#deposit:AAA`, cf. `_hasExistingJournalEntry`).
      final txStorage = TransactionStorage(database: db);
      await txStorage.upsert(AssetTransaction(
        id: AssetTransaction.generateId(),
        accountId: accountId,
        symbol: 'AAA-EUR',
        kind: TransactionKind.deposit,
        amount: '2',
        currency: 'AAA',
        date: DateTime(2024, 10, 11),
        meta: {'importKey': 'ref:$accountId:RN2#deposit:AAA'},
      ));

      final b = _LedgerBuilder();
      b.leg(refid: 'RN1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      // Même refid RN2 que la ligne déjà journalisée ci-dessus — un
      // RE-import du même relevé (motif `unreadable`, sans `amountusd`).
      b.leg(refid: 'RN2', time: '2024-10-11 09:00:00', type: 'deposit',
          asset: 'AAA', amount: '2', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        rangeAnswers: {
          'AAA-EUR': _oneBar('AAA-EUR', DateTime.utc(2024, 10, 11), 100.0),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      // L'étage 2 n'a JAMAIS interrogé AAA-EUR pour cette clé : la barre
      // fournie par le fake n'a servi à rien.
      expect(fakeMarket.rangeCallLog, isEmpty);
      // La ligne reste « à valoriser », comme au lot 2 — rien n'est proposé
      // pour AAA, donc aucun rejet `cryptoImportKeyCollision`.
      expect(preview.toCreate.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      expect(
          preview.unvaluedExchanges.single.manualReason, equals('unreadable'));
      expect(
        preview.rejects.where((r) => r.rejectReason == 'cryptoImportKeyCollision'),
        isEmpty,
      );
    });

    test(
        'M-5 (revue adversariale LOT 4) : deux opérations à cheval sur '
        'minuit UTC (23:50 la veille / 00:30 le lendemain) sont valorisées '
        'CHACUNE à la barre de SON jour calendaire UTC, jamais celle du jour '
        'voisin', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-midnight-boundary';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'AAA', 'AAA-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RM1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      // Jour D, tout près de minuit UTC (23:50) — `_parseCryptoDate` jette
      // l'heure, `leg.date` devient le 30/11 pur.
      b.leg(refid: 'RM2', time: '2024-11-30 23:50:00', type: 'deposit',
          asset: 'AAA', amount: '2', subclass: 'crypto');
      // Jour D+1, tout près de minuit UTC (00:30) — 40 minutes plus tard en
      // horloge murale, mais un jour calendaire DIFFÉRENT.
      b.leg(refid: 'RM3', time: '2024-12-01 00:30:00', type: 'deposit',
          asset: 'AAA', amount: '3', subclass: 'crypto');

      // Barres elles-mêmes horodatées tout près de minuit UTC (Yahoo
      // horodate parfois les barres crypto légèrement avant minuit UTC, cf.
      // commentaire de `YahooFinanceProvider.getHistoricalRange`) : si le
      // bucketing `DateTime.utc(d.year, d.month, d.day)` glissait vers
      // l'heure LOCALE quelque part dans la chaîne, ces deux barres se
      // retrouveraient fusionnées ou permutées.
      final fakeMarket = _FakeMarketDataServiceLot4(
        rangeAnswers: {
          'AAA-EUR': AssetHistoricalData(
            symbol: 'AAA-EUR',
            dates: [
              DateTime.utc(2024, 11, 30, 23, 59),
              DateTime.utc(2024, 12, 1, 0, 1),
            ],
            prices: [100.0, 200.0],
          ),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.unvaluedExchanges, isEmpty);
      // UN SEUL appel `getHistoricalRange` : les deux opérations partagent
      // le même symbole, une seule requête couvrant toute la plage.
      expect(fakeMarket.rangeCallLog, equals(['AAA-EUR']));

      final deposits =
          preview.toCreate.where((m) => m.ledgerCode == 'AAA').toList();
      expect(deposits, hasLength(2));

      final dayD = deposits.firstWhere(
          (m) => m.transaction!.meta!['quoteDate'] == '2024-11-30');
      final dayD1 = deposits.firstWhere(
          (m) => m.transaction!.meta!['quoteDate'] == '2024-12-01');

      // 2 × 100,0 = 200 EUR — barre du jour D, jamais celle du lendemain.
      expect(Decimal.parse(dayD.transaction!.meta!['valueEur'] as String),
          equals(Decimal.parse('200')));
      // 3 × 200,0 = 600 EUR — barre du jour D+1, jamais celle de la veille.
      expect(Decimal.parse(dayD1.transaction!.meta!['valueEur'] as String),
          equals(Decimal.parse('600')));
    });

    // ----------------------------------------------------------------- Fix drive
    // auteur : cascade PAYÉE→REÇUE à la VALORISATION (pas seulement à la résolution
    // du ticker) — voir la doc de tête de `_resolveMarketHistoryValuations`. Avant
    // ce correctif, une jambe payée dont le ticker se résolvait mais dont
    // l'historique ne couvrait pas la date de l'opération (ex. ticker coté après
    // l'opération) retombait directement en arbitrage manuel SANS jamais tenter la
    // jambe reçue.
    // -----------------------------------------------------------------

    test(
        '① cascade : jambe PAYÉE avec ticker EXISTANT mais SANS barre le '
        'jour exact → repli sur la jambe REÇUE à la VALORISATION, '
        '`quoteLeg`:`received`', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-cascade-fallback';
      await seedAccount(db, accountId);
      // Jambe reçue (MMM) : position existante — c'est la BARRE de la
      // payée qui manque, jamais son ticker (MMM n'a donc aucun coût réseau
      // propre, la preuve porte sur le repli de VALORISATION, pas de
      // résolution).
      await seedLedgerCodePosition(db, accountId, 'MMM', 'MMM-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RP1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RP2', time: '2024-09-30 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'LLL', amount: '-1', subclass: 'crypto');
      b.leg(refid: 'RP2', time: '2024-09-30 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'MMM', amount: '20', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        symbolAnswers: {'LLL-EUR': true}, // le ticker EXISTE...
        rangeAnswers: {
          // ...mais AUCUNE barre à ce jour exact (absent de la table =
          // `null`, cf. doc du fake) — ex. historique trop court.
          'MMM-EUR': _oneBar('MMM-EUR', DateTime.utc(2024, 9, 30), 3.0),
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.unvaluedExchanges, isEmpty);
      // LLL cotable dès `LLL-EUR` — MMM résolu via sa position, ZÉRO appel
      // réseau propre pour elle (seul son TICKER est gratuit, sa barre est
      // bien interrogée ci-dessous).
      expect(fakeMarket.symbolExistsCallLog, equals(['LLL-EUR']));
      // Les DEUX symboles sont interrogés pour leur barre : LLL-EUR
      // (principale, tentée en premier) ET MMM-EUR (repli, enregistré dès
      // la construction du candidat).
      expect(fakeMarket.rangeCallLog, equals(['LLL-EUR', 'MMM-EUR']));

      final sell = preview.toCreate.firstWhere((m) => m.ledgerCode == 'LLL');
      final buy = preview.toCreate.firstWhere((m) => m.ledgerCode == 'MMM');
      // 20 × 3,0 = 60 EUR — cours de la jambe REÇUE (MMM), la payée (LLL)
      // n'avait pas de barre exploitable.
      expect(sell.transaction!.amount, equals('60'));
      expect(buy.transaction!.amount, equals('-60'));
      for (final m in [sell, buy]) {
        final meta = m.transaction!.meta!;
        expect(meta['valuationSource'], equals('marketHistory'));
        expect(meta['quoteSymbol'], equals('MMM-EUR'));
        expect(meta['quoteLeg'], equals('received'));
      }
    });

    test(
        '② cascade : PAYÉE et REÇUE toutes deux cotables mais SANS AUCUNE '
        'barre disponible → retombe en arbitrage manuel motif `unreadable` '
        'INCHANGÉ (cascade épuisée)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-cascade-both-fail';
      await seedAccount(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RQ1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RQ2', time: '2024-10-15 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '-1', subclass: 'crypto');
      b.leg(refid: 'RQ2', time: '2024-10-15 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'OOO', amount: '10', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        symbolAnswers: {'NNN-EUR': true, 'OOO-EUR': true},
        // AUCUNE entrée dans `rangeAnswers` : les deux tickers existent
        // mais ni l'un ni l'autre n'a de barre exploitable — B4, jamais
        // bloquant, retombe simplement à l'étage 3.
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.toCreate.any((m) => m.ledgerCode == 'NNN'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'OOO'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      expect(
          preview.unvaluedExchanges.single.manualReason, equals('unreadable'));
      // Les DEUX symboles ont bien été interrogés (cascade épuisée), aucune
      // barre écrite.
      expect(fakeMarket.rangeCallLog, equals(['NNN-EUR', 'OOO-EUR']));
    });

    test(
        '③ non-régression : jambe PAYÉE cotable ET avec barre exploitable → '
        'valorisée par la PAYÉE comme avant, le repli (résolu EN PLUS) '
        'reste inutilisé quand la payée suffit', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-cascade-non-regression';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'QQQ', 'QQQ-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RR1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RR2', time: '2024-11-20 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'PPP', amount: '-2', subclass: 'crypto');
      b.leg(refid: 'RR2', time: '2024-11-20 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'QQQ', amount: '8', subclass: 'crypto');

      final fakeMarket = _FakeMarketDataServiceLot4(
        symbolAnswers: {'PPP-EUR': true},
        rangeAnswers: {
          'PPP-EUR': _oneBar('PPP-EUR', DateTime.utc(2024, 11, 20), 25.0),
          // QQQ-EUR volontairement ABSENT : la payée (PPP) suffit déjà, la
          // barre de repli — bien qu'interrogée — reste inutilisée.
        },
      );
      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);

      final preview = await ctrl.previewStatementImport(
        b.toCsvBytes(),
        profile,
        accountId: accountId,
      );

      expect(preview.unvaluedExchanges, isEmpty);
      final sell = preview.toCreate.firstWhere((m) => m.ledgerCode == 'PPP');
      final buy = preview.toCreate.firstWhere((m) => m.ledgerCode == 'QQQ');
      // 2 × 25,0 = 50 EUR — cours de la PAYÉE (PPP), comportement INCHANGÉ.
      expect(sell.transaction!.amount, equals('50'));
      expect(buy.transaction!.amount, equals('-50'));
      for (final m in [sell, buy]) {
        final meta = m.transaction!.meta!;
        expect(meta['quoteSymbol'], equals('PPP-EUR'));
        expect(meta['quoteLeg'], equals('paid'));
      }
    });
  });
}

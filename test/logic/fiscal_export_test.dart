// test/logic/fiscal_export_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/logic/fiscal_export.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';

// ---------------------------------------------------------------------------
// Jeu de données GOLDEN — voir docs/sparneo-fiscal-export.md pour le format.
//
// Périmètre couvert :
// - CTO (a-cto) : buy/sell/dividend AAPL (position encore détenue → asset
//   résolu depuis les positions) + un titre OLDCO entièrement cédé (absent
//   des positions → fallback asset avec métadonnées null).
// - PEA (a-pea) : prouve que le PEA n'est PAS exclu/filtré de l'export.
// - Crypto (a-crypto) : quantité/prix à nombreuses décimales préservés tels
//   quels (aucun arrondi).
// - Métal précieux (a-metal) : nature preciousMetal → enveloppe AUTRE.
// - Cash (a-cash) : deposit/withdrawal (symbol null → aucun asset émis).
// ---------------------------------------------------------------------------

void main() {
  final accounts = [
    Account(
      id: 'a-cto',
      walletId: 'w1',
      name: 'Compte-Titres',
      kind: AccountKind.cto,
      currency: 'USD',
    ),
    Account(
      id: 'a-pea',
      walletId: 'w1',
      name: 'PEA',
      kind: AccountKind.pea,
      currency: 'EUR',
    ),
    Account(
      id: 'a-crypto',
      walletId: 'w1',
      name: 'Crypto',
      kind: AccountKind.crypto,
      currency: 'EUR',
    ),
    Account(
      id: 'a-metal',
      walletId: 'w1',
      name: 'Métaux',
      kind: AccountKind.preciousMetal,
      currency: 'EUR',
    ),
    Account(
      id: 'a-cash',
      walletId: 'w1',
      name: 'Espèces',
      kind: AccountKind.cash,
      currency: 'EUR',
    ),
  ];

  // Transactions volontairement fournies dans le désordre (par compte et
  // globalement) pour vérifier que le tri date ASC / id ASC est bien
  // appliqué par la fonction, indépendamment de l'ordre d'entrée.
  final transactionsByAccount = <String, List<AssetTransaction>>{
    'a-cto': [
      AssetTransaction(
        id: 't3',
        accountId: 'a-cto',
        symbol: 'AAPL',
        kind: TransactionKind.dividend,
        amount: '5.00',
        currency: 'USD',
        date: DateTime(2024, 6, 1),
      ),
      AssetTransaction(
        id: 't1',
        accountId: 'a-cto',
        symbol: 'AAPL',
        kind: TransactionKind.buy,
        quantity: '2',
        unitPrice: '180.1234',
        amount: '-360.25',
        fee: '1.20',
        currency: 'USD',
        date: DateTime(2024, 4, 5),
        note: 'Achat initial',
      ),
      AssetTransaction(
        id: 't2',
        accountId: 'a-cto',
        symbol: 'AAPL',
        kind: TransactionKind.sell,
        quantity: '1',
        unitPrice: '190.00',
        amount: '190.00',
        fee: '0.50',
        currency: 'USD',
        date: DateTime(2024, 5, 1),
        note: '', // note vide → doit être OMISE dans l'export
      ),
      // Titre entièrement cédé : plus de position → absent de assetsBySymbol.
      AssetTransaction(
        id: 't-old',
        accountId: 'a-cto',
        symbol: 'OLDCO',
        kind: TransactionKind.sell,
        quantity: '5',
        unitPrice: '10.5',
        amount: '52.5',
        currency: 'GBP', // devise propre à la transaction (≠ devise du compte)
        date: DateTime(2024, 1, 5),
      ),
    ],
    'a-pea': [
      AssetTransaction(
        id: 't5',
        accountId: 'a-pea',
        symbol: 'CW8',
        kind: TransactionKind.buy,
        quantity: '3',
        unitPrice: '350.00',
        amount: '-1050.00',
        fee: '2.00',
        currency: 'EUR',
        date: DateTime(2023, 1, 10),
      ),
    ],
    'a-crypto': [
      AssetTransaction(
        id: 't6',
        accountId: 'a-crypto',
        symbol: 'BTC',
        kind: TransactionKind.buy,
        quantity: '0.12345678',
        unitPrice: '42000.987654321',
        amount: '-5185.3187654321',
        fee: '1.234567',
        currency: 'EUR',
        date: DateTime(2024, 2, 15),
      ),
    ],
    'a-metal': [
      AssetTransaction(
        id: 't7',
        accountId: 'a-metal',
        symbol: 'GOLD1OZ',
        kind: TransactionKind.buy,
        quantity: '1',
        unitPrice: '1800.00',
        amount: '-1810.00',
        fee: '10.00',
        currency: 'EUR',
        date: DateTime(2024, 3, 1),
      ),
    ],
    'a-cash': [
      AssetTransaction(
        id: 't9',
        accountId: 'a-cash',
        kind: TransactionKind.withdrawal,
        amount: '-200.00',
        currency: 'EUR',
        date: DateTime(2024, 7, 1),
      ),
      // Même date que t8a, id postérieur alphabétiquement → départage par id.
      AssetTransaction(
        id: 't8b',
        accountId: 'a-cash',
        kind: TransactionKind.deposit,
        amount: '600.00',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      ),
      AssetTransaction(
        id: 't8a',
        accountId: 'a-cash',
        kind: TransactionKind.deposit,
        amount: '400.00',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
      ),
    ],
  };

  final assetsBySymbol = <String, Asset>{
    'AAPL': Asset(
      symbol: 'AAPL',
      name: 'Apple Inc.',
      type: AssetType.stock,
      currency: 'USD',
      exchange: 'NMS', // → country US
    ),
    'CW8': Asset(
      symbol: 'CW8',
      name: 'Amundi MSCI World',
      type: AssetType.etf,
      currency: 'EUR',
      exchange: 'PAR', // → country FR
    ),
    'BTC': Asset(
      symbol: 'BTC',
      name: 'Bitcoin',
      type: AssetType.crypto,
      currency: 'EUR',
      exchange: 'XXX', // place inconnue de la table → country null
    ),
    'GOLD1OZ': Asset(
      symbol: 'GOLD1OZ',
      name: 'Or 1 once',
      type: AssetType.preciousMetal,
      currency: 'EUR',
      // exchange absent → country null
    ),
    // 'OLDCO' volontairement ABSENT : titre entièrement cédé.
  };

  final exportedAt = DateTime.utc(2026, 4, 15, 10, 0, 0);

  test('golden : structure complète conforme à sparneo-fiscal-export v3', () {
    final result = buildFiscalExport(
      accounts: accounts,
      transactionsByAccount: transactionsByAccount,
      assetsBySymbol: assetsBySymbol,
      taxYear: 2024,
      appVersion: '0.1.0',
      exportedAt: exportedAt,
    );

    final expected = {
      'format': 'sparneo-fiscal-export',
      'version': 3,
      'exportedAt': '2026-04-15T10:00:00.000Z',
      'taxYear': 2024,
      'source': {
        'app': 'Sparneo',
        'appVersion': '0.1.0',
      },
      'accounts': [
        {'id': 'a-cto', 'name': 'Compte-Titres', 'envelope': 'CTO', 'currency': 'USD'},
        {'id': 'a-pea', 'name': 'PEA', 'envelope': 'PEA', 'currency': 'EUR'},
        {'id': 'a-crypto', 'name': 'Crypto', 'envelope': 'CRYPTO', 'currency': 'EUR'},
        {'id': 'a-metal', 'name': 'Métaux', 'envelope': 'AUTRE', 'currency': 'EUR'},
        {'id': 'a-cash', 'name': 'Espèces', 'envelope': 'AUTRE', 'currency': 'EUR'},
      ],
      // Trié par symbol ASC (ordre déterministe, indépendant des transactions).
      'assets': [
        {
          'symbol': 'AAPL',
          'name': 'Apple Inc.',
          'class': 'stock',
          'currency': 'USD',
          'exchange': 'NMS',
          'country': 'US',
        },
        {
          'symbol': 'BTC',
          'name': 'Bitcoin',
          'class': 'crypto',
          'currency': 'EUR',
          'exchange': 'XXX',
          'country': null,
        },
        {
          'symbol': 'CW8',
          'name': 'Amundi MSCI World',
          'class': 'etf',
          'currency': 'EUR',
          'exchange': 'PAR',
          'country': 'FR',
        },
        {
          'symbol': 'GOLD1OZ',
          'name': 'Or 1 once',
          'class': 'preciousMetal',
          'currency': 'EUR',
          'exchange': null,
          'country': null,
        },
        // Fallback : titre entièrement cédé, absent de assetsBySymbol.
        {
          'symbol': 'OLDCO',
          'name': null,
          'class': null,
          'currency': 'GBP', // récupérée depuis la transaction OLDCO
          'exchange': null,
          'country': null,
        },
      ],
      // Trié par date ASC puis id ASC.
      'transactions': [
        {
          'id': 't5',
          'accountId': 'a-pea',
          'symbol': 'CW8',
          'kind': 'buy',
          'date': '2023-01-10',
          'quantity': '3',
          'unitPrice': '350.00',
          'amount': '-1050.00',
          'fee': '2.00',
          'currency': 'EUR',
        },
        {
          'id': 't8a',
          'accountId': 'a-cash',
          'symbol': null,
          'kind': 'deposit',
          'date': '2024-01-01',
          'quantity': null,
          'unitPrice': null,
          'amount': '400.00',
          'fee': null,
          'currency': 'EUR',
        },
        {
          'id': 't8b',
          'accountId': 'a-cash',
          'symbol': null,
          'kind': 'deposit',
          'date': '2024-01-01',
          'quantity': null,
          'unitPrice': null,
          'amount': '600.00',
          'fee': null,
          'currency': 'EUR',
        },
        {
          'id': 't-old',
          'accountId': 'a-cto',
          'symbol': 'OLDCO',
          'kind': 'sell',
          'date': '2024-01-05',
          'quantity': '5',
          'unitPrice': '10.5',
          'amount': '52.5',
          'fee': null,
          'currency': 'GBP',
        },
        {
          'id': 't6',
          'accountId': 'a-crypto',
          'symbol': 'BTC',
          'kind': 'buy',
          'date': '2024-02-15',
          'quantity': '0.12345678',
          'unitPrice': '42000.987654321',
          'amount': '-5185.3187654321',
          'fee': '1.234567',
          'currency': 'EUR',
        },
        {
          'id': 't7',
          'accountId': 'a-metal',
          'symbol': 'GOLD1OZ',
          'kind': 'buy',
          'date': '2024-03-01',
          'quantity': '1',
          'unitPrice': '1800.00',
          'amount': '-1810.00',
          'fee': '10.00',
          'currency': 'EUR',
        },
        {
          'id': 't1',
          'accountId': 'a-cto',
          'symbol': 'AAPL',
          'kind': 'buy',
          'date': '2024-04-05',
          'quantity': '2',
          'unitPrice': '180.1234',
          'amount': '-360.25',
          'fee': '1.20',
          'currency': 'USD',
          'note': 'Achat initial',
        },
        {
          'id': 't2',
          'accountId': 'a-cto',
          'symbol': 'AAPL',
          'kind': 'sell',
          'date': '2024-05-01',
          'quantity': '1',
          'unitPrice': '190.00',
          'amount': '190.00',
          'fee': '0.50',
          'currency': 'USD',
          // note absente : chaîne vide en entrée → omise.
        },
        {
          'id': 't3',
          'accountId': 'a-cto',
          'symbol': 'AAPL',
          'kind': 'dividend',
          'date': '2024-06-01',
          'quantity': null,
          'unitPrice': null,
          'amount': '5.00',
          'fee': null,
          'currency': 'USD',
        },
        {
          'id': 't9',
          'accountId': 'a-cash',
          'symbol': null,
          'kind': 'withdrawal',
          'date': '2024-07-01',
          'quantity': null,
          'unitPrice': null,
          'amount': '-200.00',
          'fee': null,
          'currency': 'EUR',
        },
      ],
    };

    expect(result, equals(expected));

    // Vérifications ciblées complémentaires (redondantes avec la comparaison
    // globale mais explicites sur les points figés de la spec).
    expect(result.containsKey('foreignTax'), isFalse);
    expect(result.containsKey('meta'), isFalse);
    final transactions = result['transactions'] as List;
    for (final tx in transactions) {
      expect((tx as Map).containsKey('foreignTax'), isFalse);
      expect(tx.containsKey('meta'), isFalse);
    }
    // note vide → clé absente (pas juste null).
    final sellTx = transactions.firstWhere((tx) => tx['id'] == 't2') as Map;
    expect(sellTx.containsKey('note'), isFalse);
    // note non vide → présente telle quelle.
    final buyTx = transactions.firstWhere((tx) => tx['id'] == 't1') as Map;
    expect(buyTx['note'], 'Achat initial');

    // Dédup assets : un seul symbol AAPL malgré 3 transactions AAPL.
    final assets = result['assets'] as List;
    expect(assets.where((a) => (a as Map)['symbol'] == 'AAPL').length, 1);
  });

  test(
      'date : format calendaire YYYY-MM-DD, sans heure ni composante fuseau',
      () {
    final result = buildFiscalExport(
      accounts: accounts,
      transactionsByAccount: transactionsByAccount,
      assetsBySymbol: assetsBySymbol,
      taxYear: 2024,
      appVersion: '0.1.0',
      exportedAt: exportedAt,
    );
    final transactions = result['transactions'] as List;
    for (final tx in transactions) {
      final date = (tx as Map)['date'] as String;
      expect(date, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
          reason: 'date de ${tx['id']} devrait être YYYY-MM-DD, pas $date');
    }
  });

  test(
      'envelope : les 10 valeurs AccountKind mappent exactement sur '
      'l\'enveloppe attendue (contrat figé)', () {
    // Couples FIGÉS par docs/sparneo-fiscal-export.md — toute faute de frappe
    // future (ex. 'PEA-PME' au lieu de 'PEA_PME') ou nature non mappée doit
    // faire échouer ce test.
    const expectedEnvelopeByKind = {
      AccountKind.cto: 'CTO',
      AccountKind.pea: 'PEA',
      AccountKind.peaPme: 'PEA_PME',
      AccountKind.assuranceVie: 'AV',
      AccountKind.pee: 'PEE',
      AccountKind.per: 'PER',
      AccountKind.crypto: 'CRYPTO',
      AccountKind.cash: 'AUTRE',
      AccountKind.preciousMetal: 'AUTRE',
      AccountKind.autre: 'AUTRE',
    };

    // Garde-fou : si une valeur est ajoutée à AccountKind sans être ajoutée
    // ci-dessus, ce test échoue plutôt que de silencieusement l'ignorer.
    expect(expectedEnvelopeByKind.keys.toSet(), AccountKind.values.toSet());

    for (final entry in expectedEnvelopeByKind.entries) {
      final account = Account(
        id: 'a-${entry.key.name}',
        walletId: 'w1',
        name: entry.key.name,
        kind: entry.key,
        currency: 'EUR',
      );
      final result = buildFiscalExport(
        accounts: [account],
        transactionsByAccount: const {},
        assetsBySymbol: const {},
        taxYear: 2024,
        appVersion: '0.1.0',
        exportedAt: exportedAt,
      );
      final accountsOut = result['accounts'] as List;
      expect(
        accountsOut.single,
        {
          'id': account.id,
          'name': account.name,
          'envelope': entry.value,
          'currency': 'EUR',
        },
        reason:
            'AccountKind.${entry.key.name} devrait mapper sur ${entry.value}',
      );
    }
  });

  test(
      'country : lookup insensible à la casse sur exchange, valeur exposée '
      'inchangée', () {
    final result = buildFiscalExport(
      accounts: [
        Account(
            id: 'a1', walletId: 'w1', name: 'A', kind: AccountKind.cto, currency: 'EUR'),
      ],
      transactionsByAccount: {
        'a1': [
          AssetTransaction(
            id: 't1',
            accountId: 'a1',
            symbol: 'FOO',
            kind: TransactionKind.buy,
            quantity: '1',
            unitPrice: '1',
            amount: '-1',
            currency: 'EUR',
            date: DateTime(2024, 1, 1),
          ),
        ],
      },
      assetsBySymbol: {
        // Place en minuscules : le lookup doit tout de même résoudre le pays.
        'FOO': Asset(
            symbol: 'FOO', type: AssetType.stock, currency: 'EUR', exchange: 'par'),
      },
      taxYear: 2024,
      appVersion: '0.1.0',
      exportedAt: exportedAt,
    );
    final asset = (result['assets'] as List).single as Map;
    // Le champ exposé reste tel que fourni (pas de ré-écriture du contrat) ;
    // seul le lookup interne est normalisé.
    expect(asset['exchange'], 'par');
    expect(asset['country'], 'FR');
  });

  test(
      'v2 : openingBalance/adjustment exportés avec leur wire ; meta.declarative '
      'propagé ; meta absent quand vide', () {
    final result = buildFiscalExport(
      accounts: [
        Account(
            id: 'a1', walletId: 'w1', name: 'A', kind: AccountKind.cto, currency: 'EUR'),
      ],
      transactionsByAccount: {
        'a1': [
          // openingBalance déclaratif → meta.declarative doit sortir.
          AssetTransaction(
            id: 't-ob',
            accountId: 'a1',
            symbol: 'FOO',
            kind: TransactionKind.openingBalance,
            quantity: '10',
            unitPrice: '50',
            currency: 'EUR',
            date: DateTime(2024, 1, 1),
            meta: const {'declarative': true},
          ),
          // adjustment sans meta → clé meta absente.
          AssetTransaction(
            id: 't-adj',
            accountId: 'a1',
            symbol: 'FOO',
            kind: TransactionKind.adjustment,
            quantity: '-2',
            unitPrice: '50',
            currency: 'EUR',
            date: DateTime(2024, 1, 2),
          ),
        ],
      },
      assetsBySymbol: const {},
      taxYear: 2024,
      appVersion: '0.1.0',
      exportedAt: exportedAt,
    );

    expect(result['version'], 3);

    final txs = result['transactions'] as List;
    final ob = txs.firstWhere((t) => (t as Map)['id'] == 't-ob') as Map;
    final adj = txs.firstWhere((t) => (t as Map)['id'] == 't-adj') as Map;

    // wire exporté tel quel (jamais coercé).
    expect(ob['kind'], 'openingBalance');
    expect(adj['kind'], 'adjustment');

    // meta.declarative propagé pour le lot déclaratif.
    expect(ob['meta'], {'declarative': true});

    // quantité négative de l'adjustment préservée telle quelle.
    expect(adj['quantity'], '-2');

    // meta absent (pas juste null) quand la transaction n'en porte pas.
    expect(adj.containsKey('meta'), isFalse);
  });

  test(
      'v3 : settlementCurrency exporté quand présent (titre USD réglé en EUR), '
      'clé absente sinon', () {
    final result = buildFiscalExport(
      accounts: [
        Account(
            id: 'a1', walletId: 'w1', name: 'CTO', kind: AccountKind.cto, currency: 'EUR'),
      ],
      transactionsByAccount: {
        'a1': [
          // Achat AAPL coté USD, réglé en EUR (net figé) → settlementCurrency émis.
          AssetTransaction(
            id: 't-cross',
            accountId: 'a1',
            symbol: 'AAPL',
            kind: TransactionKind.buy,
            quantity: '10',
            unitPrice: '175.50',
            amount: '-1620.00',
            currency: 'USD',
            settlementCurrency: 'EUR',
            date: DateTime(2024, 1, 1),
            fee: '1.99',
          ),
          // Mouvement mono-devise (EUR natif) → clé settlementCurrency ABSENTE.
          AssetTransaction(
            id: 't-mono',
            accountId: 'a1',
            symbol: null,
            kind: TransactionKind.deposit,
            amount: '500',
            currency: 'EUR',
            date: DateTime(2024, 1, 2),
          ),
        ],
      },
      assetsBySymbol: const {},
      taxYear: 2024,
      appVersion: '0.1.0',
      exportedAt: exportedAt,
    );

    expect(result['version'], 3);
    final txs = result['transactions'] as List;
    final cross = txs.firstWhere((t) => (t as Map)['id'] == 't-cross') as Map;
    final mono = txs.firstWhere((t) => (t as Map)['id'] == 't-mono') as Map;

    // Devise de règlement exposée + amount en EUR ; currency reste la cotation.
    expect(cross['settlementCurrency'], 'EUR');
    expect(cross['currency'], 'USD');
    expect(cross['amount'], '-1620.00');

    // Ligne mono-devise : clé absente (pas juste null) → export legacy inchangé.
    expect(mono.containsKey('settlementCurrency'), isFalse);
  });
}

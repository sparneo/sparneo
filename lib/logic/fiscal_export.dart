// lib/logic/fiscal_export.dart
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';

/// Version courante du format `sparneo-fiscal-export`.
///
/// v2 (additif, rétro-compatible en lecture) : ajoute les kinds
/// `openingBalance` et `adjustment` au champ `transactions.kind`, et propage
/// le champ optionnel `transactions.meta` (notamment `meta.declarative = true`,
/// marqueur d'un lot déclaratif). Un lecteur v1 ignore simplement `meta` et
/// doit traiter tout `kind` non reconnu comme une erreur (jamais le coercer).
///
/// v3 (additif, lot « cash comme projection du journal ») : ajoute les kinds
/// `interest` (intérêts sur espèces, `amount` positif) et `charge` (frais
/// autonomes, `amount` signé — typiquement négatif, positif pour un rebate) ;
/// et généralise `openingBalance`/`adjustment` à `symbol=null` (mouvement
/// ESPÈCES : `amount` signé, `quantity`/`unitPrice` null). Le consommateur ne
/// doit donc PLUS supposer `symbol`/`quantity` non-null sur ces deux kinds.
/// Un `kind` inconnu reste une erreur (jamais coercé). Le passage à v3 est
/// requis AVANT publication : un backup contenant `interest`/`charge` serait
/// rejeté par toute version antérieure (compatibilité stricte des kinds).
///
/// v3 (suite, additif) : champ optionnel `transactions.settlementCurrency` — la
/// DEVISE DE RÈGLEMENT de `amount` quand elle diffère de la cotation `currency`
/// (ex. titre USD réglé en EUR sur un CTO €). Émis uniquement s'il est présent
/// (absent = règlement identique à `currency`). Donne au consommateur la
/// contre-valeur EUR à la date d'opération (design cash-ledger §8). Un lecteur
/// qui l'ignore lit `amount` dans `currency` (comportement mono-devise legacy).
/// Voir `docs/sparneo-fiscal-export.md`.
const int fiscalExportFormatVersion = 3;

/// Mapping [AccountKind] → enveloppe fiscale exposée dans l'export (§ table
/// figée de `docs/sparneo-fiscal-export.md`). Toute nature non listée retombe
/// sur `AUTRE` (cash/preciousMetal/autre).
const Map<AccountKind, String> _envelopeByKind = {
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

/// Table place de cotation (`exchange`) → pays ISO 3166-1 alpha-2, figée en
/// v1 et extensible en additif (voir `docs/sparneo-fiscal-export.md`).
const Map<String, String> _countryByExchange = {
  'PAR': 'FR',
  'AMS': 'NL',
  'BRU': 'BE',
  'LIS': 'PT',
  'XET': 'DE',
  'FRA': 'DE',
  'GER': 'DE',
  'NMS': 'US',
  'NYQ': 'US',
  'NGM': 'US',
  'NGS': 'US',
  'NCM': 'US',
  'ASE': 'US',
  'PCX': 'US',
  'LSE': 'GB',
  'MIL': 'IT',
  'MTA': 'IT',
  'SWX': 'CH',
  'EBS': 'CH',
  'MCE': 'ES',
  'VIE': 'AT',
  'STO': 'SE',
  'HEL': 'FI',
  'CPH': 'DK',
  'OSL': 'NO',
  'TSE': 'JP',
  'JPX': 'JP',
  'HKG': 'HK',
  'TOR': 'CA',
  'ASX': 'AU',
};

/// Construit le contenu (map JSON-able) de l'export fiscal `sparneo-fiscal-export`
/// (version [fiscalExportFormatVersion]) — voir `docs/sparneo-fiscal-export.md`
/// pour la spécification du format.
///
/// Fonction **pure** : aucune I/O, uniquement des transformations sur les
/// données fournies. Le périmètre (quels comptes, quelles transactions,
/// quels actifs) est entièrement décidé par l'appelant ([FiscalExportService]).
///
/// - `accounts` : comptes du périmètre (déjà filtrés par l'appelant).
/// - `transactionsByAccount` : transactions de chaque compte, indexées par
///   `account.id`. Aucun filtre sur l'année : l'historique complet est
///   nécessaire à la reconstitution des lots côté outil consommateur.
/// - `assetsBySymbol` : métadonnées d'actif (issues des positions), indexées
///   par `symbol`. Un symbole apparaissant dans les transactions mais absent
///   de cette map (titre entièrement cédé) déclenche le fallback métadonnées
///   nulles (voir plus bas).
Map<String, dynamic> buildFiscalExport({
  required List<Account> accounts,
  required Map<String, List<AssetTransaction>> transactionsByAccount,
  required Map<String, Asset> assetsBySymbol,
  required int taxYear,
  required String appVersion,
  required DateTime exportedAt,
}) {
  // Toutes les transactions des comptes du périmètre, triées de façon
  // déterministe (date ASC puis id ASC — cf. spec du format).
  final transactions = <AssetTransaction>[
    for (final account in accounts)
      ...?transactionsByAccount[account.id],
  ]..sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      if (byDate != 0) return byDate;
      return a.id.compareTo(b.id);
    });

  // Symboles distincts (non-null) présents dans le périmètre, triés pour un
  // ordre de sortie déterministe (indépendant de l'ordre des transactions).
  final symbols = <String>{
    for (final tx in transactions)
      if (tx.symbol != null) tx.symbol!,
  }.toList()
    ..sort();

  return {
    'format': 'sparneo-fiscal-export',
    'version': fiscalExportFormatVersion,
    'exportedAt': exportedAt.toIso8601String(),
    'taxYear': taxYear,
    'source': {
      'app': 'Sparneo',
      'appVersion': appVersion,
    },
    'accounts': [
      for (final account in accounts)
        {
          'id': account.id,
          'name': account.name,
          'envelope': _envelopeByKind[account.kind] ?? 'AUTRE',
          'currency': account.currency,
        },
    ],
    'assets': [
      for (final symbol in symbols)
        _assetEntry(symbol, assetsBySymbol[symbol], transactions),
    ],
    'transactions': [
      for (final tx in transactions)
        {
          'id': tx.id,
          'accountId': tx.accountId,
          'symbol': tx.symbol,
          'kind': tx.kind.wire,
          'date': _dateOnly(tx.date),
          'quantity': tx.quantity,
          'unitPrice': tx.unitPrice,
          'amount': tx.amount,
          'fee': tx.fee,
          'currency': tx.currency,
          // Devise de RÈGLEMENT de `amount` (v3, additif) : émise UNIQUEMENT si
          // présente (règlement ≠ cotation, ex. titre USD réglé en EUR). Absente
          // = règlement identique à `currency` (mono-devise). Donne au
          // consommateur fiscal la contre-valeur EUR à la date d'opération (net
          // réglé), exactement la donnée requise pour la PV imposable FR.
          if (tx.settlementCurrency != null)
            'settlementCurrency': tx.settlementCurrency,
          if (tx.note != null && tx.note!.isNotEmpty) 'note': tx.note,
          // Propagation du meta (additif v2) : émis UNIQUEMENT s'il est non
          // vide (ex. `meta.declarative = true`, marqueur d'un lot déclaratif
          // posé sur un openingBalance). Une transaction sans meta n'expose pas
          // la clé (les exports v1 restent bit-identiques sur ce point).
          if (tx.meta != null && tx.meta!.isNotEmpty) 'meta': tx.meta,
        },
    ],
  };
}

/// Formate une date en `YYYY-MM-DD` (date calendaire seule, sans heure ni
/// fuseau). Un export fiscal manipule des dates de faits (achat, cession…) :
/// `toIso8601String()` inclurait une heure et pourrait laisser croire à une
/// composante horaire/fuseau à interpréter, avec un risque de décalage de
/// jour côté consommateur. On compose donc explicitement depuis
/// `year`/`month`/`day` (jamais de split sur une chaîne ISO complète, qui
/// traînerait l'heure locale du [DateTime] source).
String _dateOnly(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Construit l'entrée `assets` pour [symbol].
///
/// Si [asset] est fourni (position encore détenue), les métadonnées en
/// dérivent directement. Sinon (titre entièrement cédé : plus de position,
/// donc plus d'[Asset] connu) → **fallback** : l'entrée est quand même émise
/// (le consommateur doit voir le symbole), avec `name`/`class`/`exchange`/
/// `country` à `null` et `currency` récupérée sur la première transaction du
/// symbole (une transaction porte toujours une devise).
Map<String, dynamic> _assetEntry(
  String symbol,
  Asset? asset,
  List<AssetTransaction> sortedTransactions,
) {
  if (asset != null) {
    // Lookup insensible à la casse (une place stockée en minuscules ne doit
    // pas retomber à tort sur country=null) ; le champ `exchange` exposé
    // reste tel que fourni par l'appelant, seul le lookup est normalisé.
    final country = asset.exchange != null
        ? _countryByExchange[asset.exchange!.toUpperCase()]
        : null;
    return {
      'symbol': symbol,
      'name': asset.name,
      'class': asset.type.name,
      'currency': asset.currency,
      'exchange': asset.exchange,
      'country': country,
    };
  }

  final fallbackCurrency = sortedTransactions
      .firstWhere((tx) => tx.symbol == symbol)
      .currency;
  return {
    'symbol': symbol,
    'name': null,
    'class': null,
    'currency': fallbackCurrency,
    'exchange': null,
    'country': null,
  };
}

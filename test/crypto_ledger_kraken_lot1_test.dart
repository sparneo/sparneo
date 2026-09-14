// test/crypto_ledger_kraken_lot1_test.dart
//
// Tests du LOT 1 du chantier B16 (moteur d'import Kraken, conception interne)
// : le pipeline PUR (`CryptoLedgerNormalizer`/
// `StatementImportService.planCryptoImport`) ET son intégration contrôleur
// (`AccountController._previewCryptoImport`/`confirmStatementImport`, cascade
// de résolution ledgerCode→ticker, remplacement d'agrégats).
//
// Fixtures 100 % SYNTHÉTIQUES — actifs fictifs (AAA/BBB/CCC…), sauf pour
// EXERCER la table d'alias RÉELLEMENT embarquée dans `BrokerProfile.kraken()`
// (ETH2/MATIC/UST/LUNA…, des codes de ticker PUBLICS, pas une donnée
// personnelle issue d'un export) — aucune ligne ni valeur d'un relevé réel.
//
// Le GÉNÉRATEUR de grand livre ci-dessous ([_LedgerBuilder]) calcule
// lui-même la colonne `balance` par ACCUMULATION (`amount − fee`) au fil des
// jambes ajoutées : la fixture est donc auto-cohérente PAR CONSTRUCTION —
// c'est cette propriété qui fait de « 0 rupture détectée sur un import
// complet » un test valide de l'oracle (§5.1.10), et non une tautologie.

import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';
import 'package:portfolio_tracker/services/market_data_service.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

import 'helpers/test_database.dart';

// ---------------------------------------------------------------------------
// Générateur de grand livre Kraken synthétique — colonne `balance` calculée
// PAR ACCUMULATION (`amount − fee`, par couple actif BRUT/wallet), jamais
// fournie à la main : c'est le mécanisme même qui rend le test de l'oracle
// (§5.1.10) probant plutôt que circulaire.
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

  /// Ajoute UNE jambe, dans l'ordre CHRONOLOGIQUE d'appel (ordre de fichier
  /// attendu par le pipeline — seule la comparaison globale premier/dernier
  /// horodatage est faite, pas un tri ligne à ligne). [subclass] est le
  /// classifieur FOURNI par le fichier ('fiat' / 'stable_coin' / 'crypto').
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

  static Uint8List bytesFor(List<List<String>> dataRows) {
    final all = [_krakenHeader, ...dataRows];
    final text = all.map((r) => r.join(',')).join('\n');
    return Uint8List.fromList(utf8.encode(text));
  }

  Uint8List toCsvBytes() => bytesFor(rows);
}

/// Variante MINIMALE (sans `wallet`/`subclass`/`amountusd`) simulant
/// l'ancien format Kraken (N1) — pour le test de refus global.
Uint8List _legacyKrakenCsv() {
  const header = ['txid', 'refid', 'time', 'type', 'asset', 'amount', 'fee', 'balance'];
  const row = ['L1', 'R1', '2024-01-05 10:00:00', 'deposit', 'EUR', '100', '0', '100'];
  return Uint8List.fromList(utf8.encode([header, row].map((r) => r.join(',')).join('\n')));
}

CryptoImportPlan _plan(
  Uint8List bytes,
  BrokerProfile profile, {
  String accountId = 'acc1',
  String accountCurrency = 'EUR',
}) {
  final parsed = StatementImportService.parseWithLineNumbers(bytes, profile);
  return StatementImportService.planCryptoImport(
    parsed.rows,
    profile,
    accountCurrency: accountCurrency,
    accountId: accountId,
    sourceLines: parsed.sourceLines,
  );
}

ImportedMovement _byLedgerCode(CryptoImportPlan plan, String code, {String? kind}) =>
    plan.movements.firstWhere((m) =>
        !m.isRejected &&
        m.ledgerCode == code &&
        (kind == null || m.transaction!.kind.name == kind));

void main() {
  final profile = BrokerProfile.kraken();

  // -------------------------------------------------------------------------
  // Test 1 — oracle gate : import complet d'un grand livre couvrant la
  // majorité des 22 natures §5.2.1 (+ alias à suffixe `.S`, migration
  // équilibrée, dustsweeping N→1, échange sans jambe fiat, transfert interne
  // déséquilibré, redirection par signe des codes `transfer*` ambigus) → 0
  // rupture de chaîne, et le mécanisme d'écart PROJETÉ/RAPPORTÉ est vérifié
  // ligne à ligne (pas seulement « pas d'erreur »).
  // -------------------------------------------------------------------------
  group('Lot 1 Kraken — moteur pur, oracle balance (§5.1.10)', () {
    late _LedgerBuilder b;
    late CryptoImportPlan plan;

    setUp(() {
      b = _LedgerBuilder();
      // -- Espèces --
      b.leg(refid: 'R1', time: '2024-01-05 10:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      // -- Achat AAA (jambe fiat + jambe crypto, frais EN NATURE) --
      b.leg(refid: 'R2', time: '2024-01-08 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'EUR', amount: '-500', subclass: 'fiat');
      b.leg(refid: 'R2', time: '2024-01-08 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '10', fee: '0.01', subclass: 'crypto');
      // -- Récompenses BBB, 2 lignes de janvier --
      b.leg(refid: 'R4A', time: '2024-01-15 09:00:00', type: 'staking',
          asset: 'BBB', wallet: 'earn/flexible', amount: '0.5', fee: '0.01', subclass: 'crypto');
      b.leg(refid: 'R4B', time: '2024-01-25 09:00:00', type: 'staking',
          asset: 'BBB', wallet: 'earn/flexible', amount: '0.3', subclass: 'crypto');
      // -- Vente AAA --
      b.leg(refid: 'R3', time: '2024-02-01 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'EUR', amount: '300', subclass: 'fiat');
      b.leg(refid: 'R3', time: '2024-02-01 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-6', subclass: 'crypto');
      // -- Récompense BBB de février (bucket distinct) --
      b.leg(refid: 'R4C', time: '2024-02-05 09:00:00', type: 'staking',
          asset: 'BBB', wallet: 'earn/flexible', amount: '0.4', fee: '0.02', subclass: 'crypto');
      // -- Dustsweeping N→1 : CCC + DDD vendus, EUR reçu --
      b.leg(refid: 'R5', time: '2024-02-10 11:00:00', type: 'spend',
          subtype: 'dustsweeping', asset: 'CCC', amount: '-5', subclass: 'crypto', amountusd: '10');
      b.leg(refid: 'R5', time: '2024-02-10 11:00:00', type: 'spend',
          subtype: 'dustsweeping', asset: 'DDD', amount: '-3', subclass: 'crypto', amountusd: '20');
      b.leg(refid: 'R5', time: '2024-02-10 11:00:00', type: 'receive',
          subtype: 'dustsweeping', asset: 'EUR', amount: '30', subclass: 'fiat');
      // -- Échange SANS jambe fiat (EEE payé, STB stable reçu) : non valorisé --
      b.leg(refid: 'R6', time: '2024-02-12 12:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'EEE', amount: '-2', subclass: 'crypto', amountusd: '100');
      b.leg(refid: 'R6', time: '2024-02-12 12:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '99', subclass: 'stable_coin', amountusd: '99');
      // -- Migration FFF équilibrée (2 jambes du même code, net 0) --
      b.leg(refid: 'R7', time: '2024-03-01 08:00:00', type: 'earn',
          subtype: 'migration', asset: 'FFF', amount: '-4', subclass: 'crypto');
      b.leg(refid: 'R7', time: '2024-03-01 08:00:00', type: 'earn',
          subtype: 'migration', asset: 'FFF', amount: '4', subclass: 'crypto');
      // -- Allocation/déallocation GGG équilibrée (wallets différents) --
      b.leg(refid: 'R8', time: '2024-03-05 08:00:00', type: 'earn',
          subtype: 'allocation', asset: 'GGG', amount: '-10', subclass: 'crypto');
      b.leg(refid: 'R9', time: '2024-03-06 08:00:00', type: 'earn',
          subtype: 'deallocation', asset: 'GGG', wallet: 'earn/flexible', amount: '10', subclass: 'crypto');
      // -- Autoallocation HHH DÉSÉQUILIBRÉE (une seule jambe, cas §5.1.5) --
      b.leg(refid: 'R10', time: '2024-03-08 08:00:00', type: 'earn',
          subtype: 'autoallocation', asset: 'HHH', wallet: 'earn/flexible', amount: '7.5', subclass: 'crypto');
      // -- Entrée en nature non valorisée (transfer/spotfromfutures, III) --
      b.leg(refid: 'R11', time: '2024-03-10 08:00:00', type: 'transfer',
          subtype: 'spotfromfutures', asset: 'III', amount: '1.2', subclass: 'crypto', amountusd: '60');
      // -- `transfer` bare, net NÉGATIF : redirection par signe vers sortie --
      b.leg(refid: 'R12', time: '2024-03-12 08:00:00', type: 'transfer',
          asset: 'JJJ', amount: '-0.5', subclass: 'crypto');
      // -- Transfert interne KKK spot↔staking, équilibré --
      b.leg(refid: 'R13', time: '2024-03-15 08:00:00', type: 'transfer',
          subtype: 'spottostaking', asset: 'KKK', amount: '-3', subclass: 'crypto');
      b.leg(refid: 'R14', time: '2024-03-16 08:00:00', type: 'transfer',
          subtype: 'stakingfromspot', asset: 'KKK', wallet: 'earn/flexible', amount: '3', subclass: 'crypto');
      // -- Retrait espèces --
      b.leg(refid: 'R15', time: '2024-03-20 08:00:00', type: 'withdrawal',
          asset: 'EUR', amount: '-100', subclass: 'fiat');
      // -- Récompense avec suffixe staké (.S) : alias d'identité avant tout --
      b.leg(refid: 'R16', time: '2024-03-22 09:00:00', type: 'staking',
          asset: 'LLL.S', wallet: 'earn/flexible', amount: '2', subclass: 'crypto');

      plan = _plan(b.toCsvBytes(), profile);
    });

    test('0 rupture de chaîne sur un import auto-cohérent', () {
      expect(plan.globalRejectReason, isNull);
      expect(plan.chainRuptures, isEmpty);
    });

    test('aucune ligne rejetée, exactement 10 mouvements journalisables', () {
      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      expect(plan.movements, hasLength(10));
    });

    test('achat/vente AAA (jambe fiat) : quantités et prix corrects', () {
      final buy = _byLedgerCode(plan, 'AAA', kind: 'buy');
      expect(buy.transaction!.quantity, equals('9.99')); // 10 − 0.01 de frais en nature
      expect(buy.transaction!.amount, equals('-500'));
      final sell = _byLedgerCode(plan, 'AAA', kind: 'sell');
      expect(sell.transaction!.quantity, equals('6'));
      expect(sell.transaction!.amount, equals('300'));
    });

    test('agrégation mensuelle BBB : 2 buckets (janvier/février), 3 lignes consommées', () {
      final adjustments = plan.movements
          .where((m) => !m.isRejected && m.ledgerCode == 'BBB')
          .toList();
      expect(adjustments, hasLength(2));
      final jan = adjustments.firstWhere(
          (m) => m.transaction!.meta!['aggregatedMonth'] == '2024-01');
      expect(jan.transaction!.quantity, equals('0.79')); // 0.49 + 0.3
      expect(jan.transaction!.meta!['aggregatedRows'], equals(2));
      final feb = adjustments.firstWhere(
          (m) => m.transaction!.meta!['aggregatedMonth'] == '2024-02');
      expect(feb.transaction!.quantity, equals('0.38'));
      expect(feb.transaction!.meta!['aggregatedRows'], equals(1));
    });

    test('suffixe staké .S : LLL.S devient LLL avant agrégation', () {
      final lll = _byLedgerCode(plan, 'LLL');
      expect(lll.transaction!.quantity, equals('2'));
      expect(lll.transaction!.meta!['ledgerCode'], equals('LLL'));
    });

    test('dustsweeping N→1 : répartition exacte, aucune perte', () {
      final ccc = _byLedgerCode(plan, 'CCC', kind: 'sell');
      final ddd = _byLedgerCode(plan, 'DDD', kind: 'sell');
      expect(ccc.transaction!.quantity, equals('5'));
      expect(ddd.transaction!.quantity, equals('3'));
      final total = Decimal.parse(ccc.transaction!.amount!) +
          Decimal.parse(ddd.transaction!.amount!);
      expect(total, equals(Decimal.parse('30'))); // Σ == EUR net reçu, exact
    });

    test('transfer bare à net négatif : redirigé en sortie (transferOut), pas en dépôt', () {
      final jjj = _byLedgerCode(plan, 'JJJ');
      expect(jjj.transaction!.kind.name, equals('transferOut'));
      expect(jjj.transaction!.quantity, equals('0.5'));
    });

    test('échange sans jambe fiat (EEE↔STB) : exclu de movements, en attente de valorisation', () {
      expect(plan.movements.any((m) => m.ledgerCode == 'EEE'), isFalse);
      expect(plan.movements.any((m) => m.ledgerCode == 'STB'), isFalse);
      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      expect(ex.codePaid, equals('EEE'));
      expect(ex.quantityPaid, equals('2'));
      expect(ex.codeReceived, equals('STB'));
      expect(ex.quantityReceived, equals('99'));
    });

    test('entrée en nature non valorisée (III, transfer/spotfromfutures)', () {
      final deposit = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'depositInKind');
      expect(deposit.codeReceived, equals('III'));
      expect(deposit.quantityReceived, equals('1.2'));
      expect(deposit.codePaid, isNull);
    });

    test('migration FFF équilibrée : rien journalisé, aucun rejet', () {
      expect(plan.movements.any((m) => m.ledgerCode == 'FFF'), isFalse);
      expect(plan.movements.any((m) => m.rejectReason == 'cryptoMigrationNotBalanced'), isFalse);
    });

    test('allocation/déallocation GGG équilibrées (wallets différents) : rien journalisé, pas de résidu', () {
      expect(plan.movements.any((m) => m.ledgerCode == 'GGG'), isFalse);
      expect(plan.unbalancedInternalTransfers.any((u) => u.asset == 'GGG'), isFalse);
    });

    test('transfert interne HHH déséquilibré : résidu signalé (§5.1.5)', () {
      expect(plan.unbalancedInternalTransfers, hasLength(1));
      final u = plan.unbalancedInternalTransfers.single;
      expect(u.asset, equals('HHH'));
      expect(u.residual, equals('7.5'));
      expect(u.rowCount, equals(1));
      // I-2 (revue adversariale) : date de la DERNIÈRE jambe du groupe, pas
      // `DateTime.now()` — ici la seule jambe (R10, 08/03/2024).
      expect(u.lastDate, equals(DateTime(2024, 3, 8)));
    });

    test('transfert interne KKK spot↔staking équilibré : rien journalisé', () {
      expect(plan.movements.any((m) => m.ledgerCode == 'KKK'), isFalse);
    });

    test(
        'mécanisme d\'écart projeté/rapporté (I-1, revue adversariale) : les '
        'échanges non valorisés sont CRÉDITÉS, seul le résidu de transfert '
        'interne reste', () {
      final gapsByAsset = {for (final g in plan.quantityGaps) g.asset: g};
      // Résolus / équilibrés / CRÉDITÉS depuis les échanges non valorisés
      // (I-1) → AUCUN écart (y compris le cash EUR, exclu du tout par
      // construction — ce n'est pas une « position »). EEE (payé)/STB
      // (reçu)/III (dépôt en nature reçu) proviennent tous des
      // `unvaluedExchanges` : leur QUANTITÉ est connue dès ce lot (seule la
      // VALORISATION manque, lot 2) — le moteur ne doit donc JAMAIS les
      // re-signaler comme un écart, contrairement à l'AVANT-correctif où ils
      // ressortaient tous les trois.
      for (final resolved in [
        'EUR', 'AAA', 'BBB', 'CCC', 'DDD', 'FFF', 'GGG', 'JJJ', 'KKK', 'LLL',
        'EEE', 'STB', 'III',
      ]) {
        expect(gapsByAsset.containsKey(resolved), isFalse, reason: resolved);
      }
      // Seul le résidu de transfert interne non équilibré (HHH, §5.1.5)
      // reste un écart légitime — mécanisme DISTINCT, jamais absorbé par le
      // crédit des échanges non valorisés.
      expect(gapsByAsset['HHH']!.reportedTotal, equals('7.5'));
      expect(gapsByAsset['HHH']!.projectedTotal, equals('0'));
      expect(plan.quantityGaps, hasLength(1));
    });

    test('4 lignes source consommées par l\'agrégation mensuelle (3 BBB + 1 LLL)', () {
      expect(plan.aggregatedRewardSourceRows, equals(4));
    });

    // -----------------------------------------------------------------------
    // Fenêtre retirée du milieu : le groupe dustsweeping R5 (3 lignes,
    // physiquement lignes 10/11/12 du fichier — l'en-tête occupe la ligne 1)
    // disparaît intégralement. CCC/DDD ne réapparaissent jamais ailleurs (pas
    // de rupture possible, faute de ligne suivante à confronter) ; EUR, lui,
    // réapparaît au retrait (R15) — sa `balance` déclarée à cette ligne reste
    // celle du fichier ORIGINAL (730, calculée avec le dépôt dust inclus),
    // alors que le rejeu SANS la fenêtre retirée n'attend que 700 → rupture
    // détectée exactement là, pas ailleurs.
    // -----------------------------------------------------------------------
    test('fenêtre retirée du milieu → rupture détectée à la bonne ligne', () {
      final dustGroupStart = b.rows.indexWhere((r) => r[1] == 'R5');
      expect(dustGroupStart, greaterThanOrEqualTo(0));
      final trimmed = [...b.rows]..removeRange(dustGroupStart, dustGroupStart + 3);
      final trimmedPlan = _plan(_LedgerBuilder.bytesFor(trimmed), profile);

      expect(trimmedPlan.chainRuptures, hasLength(1));
      final rupture = trimmedPlan.chainRuptures.single;
      expect(rupture.asset, equals('EUR'));
      expect(rupture.wallet, equals('spot/main'));
      expect(rupture.expectedBalance, equals('700'));
      expect(rupture.actualBalance, equals('730'));
      // Position du retrait EUR (R15) dans le fichier TRONQUÉ : en-tête (1) +
      // 20 lignes le précédant (24 − 3 retirées − 1 lui-même = 20) = ligne 21.
      expect(rupture.sourceLine, equals(21));
    });
  });

  // -------------------------------------------------------------------------
  // Revue adversariale (B-1, B-2, I-4, mineur) — corrections postérieures au
  // premier livrable du lot 1.
  // -------------------------------------------------------------------------
  group('Lot 1 Kraken — revue adversariale', () {
    test(
        'B-1 : transfer/<sous-type INCONNU> → rejet motivé unknownCryptoAction, '
        'JAMAIS un transferOut silencieux (repli type nu réservé aux lignes '
        'SANS sous-type)', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RB1', time: '2024-10-01 08:00:00', type: 'transfer',
          subtype: 'unknownvariant', asset: 'MMM', amount: '-1', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements, hasLength(1));
      final m = plan.movements.single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('unknownCryptoAction'));
      // AVANT le correctif : un sous-type inconnu retombait sur `actions['transfer']`
      // (`depositIn`), redirigé par signe en `transferOut` RÉEL — position
      // détruite sans alerte. Garde explicite que ceci ne se reproduit plus.
      expect(
        plan.movements.any((mv) => mv.transaction?.kind == TransactionKind.transferOut),
        isFalse,
      );
    });

    test(
        'B-2 : échange avec jambe fiat ÉTRANGÈRE à la devise du compte (USD '
        'sur un compte EUR) → en attente de valorisation, JAMAIS écrite au '
        'pair', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RB2', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '-50', subclass: 'fiat');
      b.leg(refid: 'RB2', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '1', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      // Aucun mouvement écrit pour ce groupe (ni buy/sell au pair, ni rejet) :
      // il part intégralement en attente de valorisation (lot 2, FX historique).
      expect(plan.movements.any((m) => m.ledgerCode == 'NNN'), isFalse);
      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      expect(ex.codePaid, equals('USD'));
      expect(ex.quantityPaid, equals('50'));
      expect(ex.codeReceived, equals('NNN'));
      expect(ex.quantityReceived, equals('1'));
    });

    test(
        'B-2 : dépôt fiat ÉTRANGER à la devise du compte → rejet motivé '
        'cryptoForeignFiatUnsupported, JAMAIS au pair', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RB3', time: '2024-10-03 08:00:00', type: 'deposit',
          asset: 'USD', amount: '100', subclass: 'fiat');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      expect(plan.movements, hasLength(1));
      final m = plan.movements.single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('cryptoForeignFiatUnsupported'));
    });

    test(
        'R-1 : trade EUR↔USD sur un compte EUR → rejet motivé, JAMAIS un '
        'ledgerCode "USD" fabriqué ni un écart de quantité fantôme sur USD '
        '(trou ouvert par B-2, contre-vérification)', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RR1', time: '2024-10-06 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'EUR', amount: '-45', subclass: 'fiat');
      b.leg(refid: 'RR1', time: '2024-10-06 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '50', subclass: 'fiat');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      expect(plan.movements, hasLength(2));
      expect(plan.movements.every((m) => m.isRejected), isTrue);
      expect(
        plan.movements.every((m) => m.rejectReason == 'cryptoForeignFiatUnsupported'),
        isTrue,
      );
      // AVANT le correctif : la jambe USD, exclue de `fiatLegs` (filtré sur
      // la devise du COMPTE) mais retombant dans `nonFiatLegs` (calculé par
      // simple exclusion, pas par nature), était traitée comme un actif
      // TITRE — `ledgerCode:'USD'` fabriqué, avec la position et l'écart de
      // quantité fantôme qui vont avec.
      expect(plan.movements.any((m) => m.ledgerCode == 'USD'), isFalse);
      expect(plan.quantityGaps.any((g) => g.asset == 'USD'), isFalse);
    });

    test(
        'I-4 : la clé de dédup d\'un dépôt fiat porte le CODE d\'actif dans '
        'son rôle (doc §5.1.9), pas seulement le kind', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RI4', time: '2024-10-04 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '100', subclass: 'fiat');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      final m = plan.movements.singleWhere((mv) => !mv.isRejected);
      expect(m.importKey, equals('ref:acc1:RI4#deposit:EUR'));
    });

    test(
        'mineur : un dépôt Kraken au signe NÉGATIF est une anomalie signalée '
        '(cryptoAmbiguousDirection), jamais réinterprété en retrait', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RM3', time: '2024-10-05 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '-50', subclass: 'fiat');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      expect(plan.movements, hasLength(1));
      final m = plan.movements.single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('cryptoAmbiguousDirection'));
    });
  });

  // -------------------------------------------------------------------------
  // Test 5 — refus global N1 (ancien format Kraken).
  // -------------------------------------------------------------------------
  test('N1 : ancien format Kraken (sans wallet/subclass/amountusd) → refus global motivé', () {
    final plan = _plan(_legacyKrakenCsv(), profile);
    expect(plan.globalRejectReason, equals('cryptoLegacyFormatUnsupported'));
    expect(plan.movements, isEmpty);
    expect(plan.unvaluedExchanges, isEmpty);
    expect(plan.chainRuptures, isEmpty);
  });

  // -------------------------------------------------------------------------
  // Test 4 — alias d'identité RÉELS du profil Kraken (ETH2→ETH, LUNA→LUNC)
  // appliqués AVANT le bilan de migration (§5.1.5/§5.2.0).
  // -------------------------------------------------------------------------
  group('Lot 1 Kraken — alias d\'identité et migration (§5.1.5)', () {
    test('migration ETH2→ETH équilibrée après alias : rien journalisé', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RM1', time: '2024-04-01 08:00:00', type: 'earn',
          subtype: 'migration', asset: 'ETH2', amount: '-5', subclass: 'crypto');
      b.leg(refid: 'RM1', time: '2024-04-01 08:00:00', type: 'earn',
          subtype: 'migration', asset: 'ETH', amount: '5', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile);
      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      expect(plan.chainRuptures, isEmpty);
    });

    test('migration LUNA→LUNC DÉSÉQUILIBRÉE après alias : rejet motivé, jamais silencieux', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RM2', time: '2024-04-02 08:00:00', type: 'earn',
          subtype: 'migration', asset: 'LUNA', amount: '-10', subclass: 'crypto');
      b.leg(refid: 'RM2', time: '2024-04-02 08:00:00', type: 'earn',
          subtype: 'migration', asset: 'LUNC', amount: '8', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile);
      final rejected = plan.movements.where((m) => m.isRejected).toList();
      expect(rejected, hasLength(2));
      expect(rejected.every((m) => m.rejectReason == 'cryptoMigrationNotBalanced'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Test 8 — agrégation mensuelle : cas limites (bucket NET NÉGATIF quand le
  // frais en nature dépasse la récompense, plusieurs lignes/mois distincts).
  // -------------------------------------------------------------------------
  group('Lot 1 Kraken — agrégation mensuelle, cas limites (§5.1.8)', () {
    test('bucket net négatif (frais > récompense) : signalé tel quel, jamais masqué', () {
      final b = _LedgerBuilder();
      // Janvier : 2 lignes, net positif.
      b.leg(refid: 'RW1', time: '2024-06-01 08:00:00', type: 'staking',
          asset: 'RWD', wallet: 'earn/flexible', amount: '1', fee: '1.5', subclass: 'crypto');
      b.leg(refid: 'RW2', time: '2024-06-10 08:00:00', type: 'staking',
          asset: 'RWD', wallet: 'earn/flexible', amount: '2', subclass: 'crypto');
      // Février : 1 ligne, net NÉGATIF.
      b.leg(refid: 'RW3', time: '2024-07-05 08:00:00', type: 'staking',
          asset: 'RWD', wallet: 'earn/flexible', amount: '0.5', fee: '1.2', subclass: 'crypto');

      final plan = _plan(b.toCsvBytes(), profile, accountId: 'acc-rwd');
      final buckets = plan.movements.where((m) => m.ledgerCode == 'RWD').toList();
      expect(buckets, hasLength(2));

      final juin = buckets.firstWhere((m) => m.transaction!.meta!['aggregatedMonth'] == '2024-06');
      expect(juin.transaction!.quantity, equals('1.5')); // (1−1.5) + (2−0)
      expect(juin.transaction!.meta!['aggregatedRows'], equals(2));
      expect(juin.transaction!.meta!['aggregatedFeeInKind'], equals('1.5'));

      final juillet = buckets.firstWhere((m) => m.transaction!.meta!['aggregatedMonth'] == '2024-07');
      expect(juillet.transaction!.quantity, equals('-0.7')); // 0.5 − 1.2, NÉGATIF
      expect(juillet.transaction!.meta!['aggregatedRows'], equals(1));
      expect(juillet.transaction!.meta!['aggregatedFeeInKind'], equals('1.2'));

      // Clé stable, prête pour le mécanisme de remplacement (§5.1.8b).
      expect(juillet.importKey, equals('agg:acc-rwd:kraken-ledgers:RWD:2024-07'));
      expect(juillet.transaction!.meta!['corporateAction'], equals('stakingReward'));
      expect(juillet.transaction!.meta!['aggregation'], equals('monthly'));
    });
  });

  // -------------------------------------------------------------------------
  // Test 6 (complément) — dustsweeping avec pondérations non proportionnelles
  // (prorata NON exact) : invariant de conservation totale, quelle que soit
  // l'arrondi retenu sur la jambe la plus lourde.
  // -------------------------------------------------------------------------
  test('dustsweeping N→1 à prorata non exact : conservation exacte de la somme', () {
    final b = _LedgerBuilder();
    b.leg(refid: 'RD1', time: '2024-08-01 10:00:00', type: 'spend',
        subtype: 'dustsweeping', asset: 'PPP', amount: '-1', subclass: 'crypto', amountusd: '7');
    b.leg(refid: 'RD1', time: '2024-08-01 10:00:00', type: 'spend',
        subtype: 'dustsweeping', asset: 'QQQ', amount: '-2', subclass: 'crypto', amountusd: '11');
    b.leg(refid: 'RD1', time: '2024-08-01 10:00:00', type: 'spend',
        subtype: 'dustsweeping', asset: 'RRR', amount: '-3', subclass: 'crypto', amountusd: '13');
    b.leg(refid: 'RD1', time: '2024-08-01 10:00:00', type: 'receive',
        subtype: 'dustsweeping', asset: 'EUR', amount: '100', subclass: 'fiat');

    final plan = _plan(b.toCsvBytes(), profile);
    final sells = plan.movements.where((m) => !m.isRejected && m.transaction!.kind.name == 'sell').toList();
    expect(sells, hasLength(3));
    final sum = sells.fold<Decimal>(
        Decimal.zero, (acc, m) => acc + Decimal.parse(m.transaction!.amount!));
    expect(sum, equals(Decimal.parse('100'))); // Σ jambes réparties == net EUR reçu, EXACT
    for (final s in sells) {
      expect(Decimal.parse(s.transaction!.amount!).sign, equals(1)); // aucune part négative/nulle
    }
  });

  // ===========================================================================
  // Intégration CONTRÔLEUR (`AccountController`) — remplacement d'agrégats,
  // garde anti-collision, résidu de transfert interne, cascade de résolution
  // ledgerCode→ticker. Base SQLite in-memory isolée par test (aucun appel
  // réseau : soit la résolution est court-circuitée dès l'étage 1 [position
  // existante], soit un faux [MarketDataService] dédié la simule).
  // ===========================================================================

  group('Lot 1 Kraken — intégration AccountController', () {
    // Wallet/compte créés à PART de la construction du contrôleur : les
    // positions « graine » (résolution étage 1 de la cascade) doivent
    // pouvoir être insérées ENTRE la création du compte (contrainte de clé
    // étrangère `positions.account_id → accounts.id`) et celle du contrôleur.
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

    Future<AccountController> makeCtrl(
      AppDatabase db,
      String accountId, {
      MarketDataService? marketService,
    }) async {
      final storage = AccountStorage(database: db);
      final ctrl = AccountController(
        initialAccountId: accountId,
        storage: storage,
        ledgerService: LedgerService(database: db),
        transactionStorage: TransactionStorage(database: db),
        marketService: marketService ?? _NoNetworkMarketDataService(),
      );
      await ctrl.initAccounts();
      return ctrl;
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
          asset: Asset(symbol: symbol, name: symbol, currency: 'EUR', ledgerCode: ledgerCode),
          quantity: '0',
        ),
      );
    }

    Uint8List rewardCsv(List<String> amounts, {String monthDay = '01'}) {
      final b = _LedgerBuilder();
      for (var i = 0; i < amounts.length; i++) {
        b.leg(
          refid: 'RWA${i + 1}',
          time: '2024-01-${(5 + i * 5).toString().padLeft(2, '0')} 08:00:00',
          type: 'staking',
          asset: 'RWD',
          wallet: 'earn/flexible',
          amount: amounts[i],
          subclass: 'crypto',
        );
      }
      return b.toCsvBytes();
    }

    test('double import : le mois allongé devient un REMPLACEMENT, pas un doublon ni un mouvement neuf', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-replace';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'RWD', 'RWD-EUR');
      final ctrl = await makeCtrl(db, accountId);

      // Import de base : 2 lignes de janvier.
      final basePreview = await ctrl.previewStatementImport(
        rewardCsv(['1', '1']),
        profile,
        accountId: accountId,
      );
      expect(basePreview.toCreate, hasLength(1));
      final err1 = await ctrl.confirmStatementImport(basePreview, accountId: accountId);
      expect(err1, isNull);

      // Ré-import : le mois s'est ALLONGÉ (3 lignes).
      final extendedPreview = await ctrl.previewStatementImport(
        rewardCsv(['1', '1', '1']),
        profile,
        accountId: accountId,
      );
      expect(extendedPreview.toCreate, isEmpty); // pas un mouvement neuf
      expect(extendedPreview.duplicates, isEmpty); // pas un doublon franc
      expect(extendedPreview.replacements, hasLength(1));
      final repl = extendedPreview.replacements.single;
      expect(repl.month, equals('2024-01'));
      expect(repl.previousRowCount, equals(2));
      expect(repl.newRowCount, equals(3));
      expect(repl.quantityDelta, equals('1'));
      final key = repl.movement.transaction!.meta!['importKey'] as String;

      final err2 = await ctrl.confirmStatementImport(
        extendedPreview,
        accountId: accountId,
        replaceImportKeys: {key},
      );
      expect(err2, isNull);

      final journal = await TransactionStorage(database: db).getByAccount(accountId);
      final aggEntries = journal.where((t) => t.meta?['importKey'] == key).toList();
      expect(aggEntries, hasLength(1)); // l'ancien agrégat a bien été REMPLACÉ, pas dupliqué
      expect(aggEntries.single.quantity, equals('3'));
      expect(aggEntries.single.meta!['aggregatedRows'], equals(3));
    });

    test('garde anti-collision : même clé, contenu différent, PAS un agrégat → rejet motivé, base intacte', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-collision';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'AAA', 'AAA-EUR');
      final ledger = LedgerService(database: db);

      // Mouvement DÉJÀ en base, sous la clé que le prochain import calculera
      // EXACTEMENT — mais SANS la marque `aggregation: 'monthly'` (donc
      // jamais remplaçable) et avec un contenu délibérément différent.
      const collidingKey = 'ref:acc-collision:RX#buy:AAA';
      await ledger.recordTransaction(AssetTransaction(
        id: 'tx-anomaly',
        accountId: accountId,
        symbol: 'AAA-EUR',
        kind: TransactionKind.buy,
        quantity: '999',
        unitPrice: '1',
        amount: '-999',
        currency: 'EUR',
        date: DateTime(2024, 5, 1),
        meta: {'importKey': collidingKey},
      ));

      final b = _LedgerBuilder();
      b.leg(refid: 'RX', time: '2024-05-01 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'EUR', amount: '-100', subclass: 'fiat');
      b.leg(refid: 'RX', time: '2024-05-01 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '2', subclass: 'crypto');

      final ctrl = await makeCtrl(db, accountId);
      final preview = await ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId);

      expect(preview.toCreate, isEmpty);
      expect(preview.replacements, isEmpty);
      expect(preview.rejects, hasLength(1));
      expect(preview.rejects.single.rejectReason, equals('cryptoImportKeyCollision'));

      // Base intacte : toujours la SEULE ligne d'origine, contenu inchangé.
      final journal = await TransactionStorage(database: db).getByAccount(accountId);
      final entries = journal.where((t) => t.meta?['importKey'] == collidingKey).toList();
      expect(entries, hasLength(1));
      expect(entries.single.quantity, equals('999'));
    });

    test('résidu de transfert interne déséquilibré : ignoré par défaut, journalisé en option explicite', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-hhh';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'HHH', 'HHH-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RH1', time: '2024-06-01 08:00:00', type: 'earn',
          subtype: 'autoallocation', asset: 'HHH', wallet: 'earn/flexible',
          amount: '7.5', subclass: 'crypto');

      final ctrl = await makeCtrl(db, accountId);
      final preview = await ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId);
      expect(preview.unbalancedInternalTransfers, hasLength(1));
      expect(preview.unbalancedInternalTransfers.single.residual, equals('7.5'));

      // Défaut : AUCUNE option → rien journalisé pour le résidu.
      final err = await ctrl.confirmStatementImport(preview, accountId: accountId);
      expect(err, isNull);
      final journalDefault = await TransactionStorage(database: db).getByAccount(accountId);
      expect(journalDefault.where((t) => t.meta?['internalTransferResidual'] == true), isEmpty);
    });

    test('résidu de transfert interne : option explicite → adjustment coût 0 sur la position existante', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-hhh2';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'HHH', 'HHH-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RH2', time: '2024-06-01 08:00:00', type: 'earn',
          subtype: 'autoallocation', asset: 'HHH', wallet: 'earn/flexible',
          amount: '7.5', subclass: 'crypto');

      final ctrl = await makeCtrl(db, accountId);
      final preview = await ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId);

      final err = await ctrl.confirmStatementImport(
        preview,
        accountId: accountId,
        journalizeUnbalancedInternalTransfers: true,
      );
      expect(err, isNull);
      final journal = await TransactionStorage(database: db).getByAccount(accountId);
      final residualEntries =
          journal.where((t) => t.meta?['internalTransferResidual'] == true).toList();
      expect(residualEntries, hasLength(1));
      expect(residualEntries.single.symbol, equals('HHH-EUR'));
      expect(residualEntries.single.kind, equals(TransactionKind.adjustment));
      expect(residualEntries.single.quantity, equals('7.5'));
      // I-2 (revue adversariale) : date du RELEVÉ (dernière jambe du groupe),
      // jamais `DateTime.now()`, et marqué remplaçable pour l'idempotence.
      expect(residualEntries.single.date, equals(DateTime(2024, 6, 1)));
      expect(residualEntries.single.meta!['replaceable'], isTrue);
    });

    test(
        'I-2 : premier import, AUCUNE position préexistante pour l\'actif du '
        'résidu, bascule active → résidu journalisé quand même (cas NOMINAL, '
        'pas le cas dégradé)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-hhh3';
      await seedAccount(db, accountId);
      // AUCUNE position seedée pour HHH — c'est justement le cas nominal
      // d'un PREMIER import (avant B-1/I-2, ce cas était silencieusement
      // ignoré : la résolution se limitait à l'étage 1 de la cascade).

      final b = _LedgerBuilder();
      b.leg(refid: 'RH3', time: '2024-06-01 08:00:00', type: 'earn',
          subtype: 'autoallocation', asset: 'HHH', wallet: 'earn/flexible',
          amount: '7.5', subclass: 'crypto');

      final ctrl = await makeCtrl(db, accountId); // _NoNetworkMarketDataService
      final preview =
          await ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId);
      // Cascade complète tentée dès l'APERÇU : pas de position (étage 1), pas
      // d'alias (étage 2), panne réseau simulée au 1er étage réseau (étage
      // 3, `_NoNetworkMarketDataService` renvoie toujours `null`) → repli non
      // coté, JAMAIS `null`.
      expect(preview.unbalancedInternalTransfers.single.resolvedSymbol, equals('crypto:HHH'));
      expect(ctrl.lastUnresolvedInternalTransferResidualCount, equals(0));

      final err = await ctrl.confirmStatementImport(
        preview,
        accountId: accountId,
        journalizeUnbalancedInternalTransfers: true,
      );
      expect(err, isNull);
      final journal = await TransactionStorage(database: db).getByAccount(accountId);
      final residualEntries =
          journal.where((t) => t.meta?['internalTransferResidual'] == true).toList();
      expect(residualEntries, hasLength(1));
      expect(residualEntries.single.symbol, equals('crypto:HHH'));
      expect(residualEntries.single.date, equals(DateTime(2024, 6, 1)));
    });

    test(
        'I-2 : ré-import du MÊME résidu (bascule active) → REMPLACÉ, jamais '
        'empilé (idempotence, clé stable)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-hhh4';
      await seedAccount(db, accountId);
      await seedLedgerCodePosition(db, accountId, 'HHH', 'HHH-EUR');

      final b = _LedgerBuilder();
      b.leg(refid: 'RH4', time: '2024-06-01 08:00:00', type: 'earn',
          subtype: 'autoallocation', asset: 'HHH', wallet: 'earn/flexible',
          amount: '7.5', subclass: 'crypto');
      final bytes = b.toCsvBytes();

      final ctrl = await makeCtrl(db, accountId);

      final preview1 =
          await ctrl.previewStatementImport(bytes, profile, accountId: accountId);
      final err1 = await ctrl.confirmStatementImport(
        preview1,
        accountId: accountId,
        journalizeUnbalancedInternalTransfers: true,
      );
      expect(err1, isNull);

      // Ré-import STRICTEMENT identique : la clé de remplacement
      // (`internalresidual:accountId:profileId:asset`) est stable — un
      // deuxième passage REMPLACE l'ajustement déjà en base, ne l'empile pas.
      final preview2 =
          await ctrl.previewStatementImport(bytes, profile, accountId: accountId);
      final err2 = await ctrl.confirmStatementImport(
        preview2,
        accountId: accountId,
        journalizeUnbalancedInternalTransfers: true,
      );
      expect(err2, isNull);

      final journal = await TransactionStorage(database: db).getByAccount(accountId);
      final residualEntries =
          journal.where((t) => t.meta?['internalTransferResidual'] == true).toList();
      expect(residualEntries, hasLength(1));
      expect(residualEntries.single.quantity, equals('7.5'));
    });

    test('cascade de résolution ledgerCode→ticker : 5 étages, mémoïsation, panne réseau non assimilée à une invalidité', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-cascade';
      await seedAccount(db, accountId);
      // Étage 1 : position existante.
      await seedLedgerCodePosition(db, accountId, 'ZZZ', 'ZZZ-EUR');

      final fakeMarket = _CascadeFakeMarketDataService({
        'WWW-EUR': true,
        'VVV-EUR': false,
        'VVV-USD': true,
        'UUU-EUR': false,
        'UUU-USD': false,
        'TTT-EUR': null, // panne réseau simulée
      });

      final b = _LedgerBuilder();
      void buy(String refid, String code) {
        b.leg(refid: refid, time: '2024-09-01 08:00:00', type: 'trade',
            subtype: 'tradespot', asset: 'EUR', amount: '-10', subclass: 'fiat');
        b.leg(refid: refid, time: '2024-09-01 08:00:00', type: 'trade',
            subtype: 'tradespot', asset: code, amount: '1', subclass: 'crypto');
      }
      buy('CA1', 'ZZZ'); // étage 1 : position existante
      buy('CA2', 'POL'); // étage 2 : quoteAliases du profil (POL→POL-USD)
      buy('CA3', 'WWW'); // étage 3 : réseau <code>-EUR trouvé
      buy('CA4', 'WWW'); // même code : doit réutiliser le cache (mémoïsation)
      buy('CA5', 'VVV'); // étage 4 : <code>-EUR absent, <code>-USD trouvé
      buy('CA6', 'UUU'); // étage 5 : ni EUR ni USD → non coté (constaté)
      buy('CA7', 'TTT'); // panne réseau au 1er étage réseau → non coté (jamais « invalide »)

      final ctrl = await makeCtrl(db, accountId, marketService: fakeMarket);
      final preview = await ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId);

      final newByCode = {for (final a in preview.newAssets) a.ledgerCode: a};

      // Étage 1 : ZZZ a une position existante → jamais listé comme actif neuf.
      expect(newByCode.containsKey('ZZZ'), isFalse);

      // Étage 2 : alias de cotation, AUCUN appel réseau.
      expect(newByCode['POL']!.proposedSymbol, equals('POL-USD'));
      expect(newByCode['POL']!.quotable, isTrue);
      expect(fakeMarket.callLog.contains('POL-EUR'), isFalse);
      // B-3 (revue adversariale) : l'alias de cotation porte sa propre
      // devise dans son SUFFIXE (`POL-USD`) — l'actif doit être créé en USD
      // (cotation Yahoo réelle), PAS en EUR (devise du compte, AVANT le
      // correctif) sous peine de sous-évaluation silencieuse et permanente.
      final polMovement = preview.toCreate.firstWhere((m) => m.ledgerCode == 'POL');
      expect(polMovement.transaction!.currency, equals('USD'));

      // Étage 3 + mémoïsation : WWW résolu en réseau, appelé UNE SEULE fois
      // malgré 2 mouvements référençant ce code.
      expect(newByCode['WWW']!.proposedSymbol, equals('WWW-EUR'));
      expect(fakeMarket.callLog.where((c) => c == 'WWW-EUR'), hasLength(1));

      // Étage 4 : repli USD, devise forcée sur le mouvement résolu.
      expect(newByCode['VVV']!.proposedSymbol, equals('VVV-USD'));
      final vvvMovement =
          preview.toCreate.firstWhere((m) => m.ledgerCode == 'VVV');
      expect(vvvMovement.transaction!.currency, equals('USD'));

      // Étage 5 : ni EUR ni USD constatés → non coté.
      expect(newByCode['UUU']!.proposedSymbol, equals('crypto:UUU'));
      expect(newByCode['UUU']!.quotable, isFalse);

      // Panne réseau au 1er étage réseau : non coté AUSSI, mais les étages
      // réseau suivants ne sont JAMAIS tentés sur une panne (pas de
      // `TTT-USD` dans le journal d'appels).
      expect(newByCode['TTT']!.proposedSymbol, equals('crypto:TTT'));
      expect(newByCode['TTT']!.quotable, isFalse);
      expect(fakeMarket.callLog.contains('TTT-USD'), isFalse);
    });
  });
}

/// Fake SANS RÉSEAU par défaut : court-circuite toute cotation/historique
/// (jamais utilisée dans les tests contrôleur ci-dessus, qui résolvent tout
/// dès l'étage 1 de la cascade — présente comme garde-fou si un test futur
/// oubliait de seeder une position).
class _NoNetworkMarketDataService extends MarketDataService {
  @override
  Future<bool?> symbolExists(String symbol) async => null;

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async => null;

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(Asset asset, {int days = 30}) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30}) async => null;
}

/// Fake de [MarketDataService.symbolExists] piloté par une table `symbole →
/// bool?` fournie par le test (`null` = panne réseau simulée), et journalisant
/// CHAQUE appel dans [callLog] — sert à vérifier la mémoïsation (M-5, conception
/// interne) et l'arrêt de la cascade sur panne.
class _CascadeFakeMarketDataService extends MarketDataService {
  final Map<String, bool?> _answers;
  final List<String> callLog = [];

  _CascadeFakeMarketDataService(this._answers);

  @override
  Future<bool?> symbolExists(String symbol) async {
    callLog.add(symbol);
    return _answers[symbol];
  }

  @override
  Future<AssetQuoteData?> getQuoteForAsset(Asset asset) async => null;

  @override
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalDataForAsset(Asset asset, {int days = 30}) async => null;

  @override
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30}) async => null;
}

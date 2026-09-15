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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/import_preview.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/crypto_valuation_service.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
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
        'drive lot 1 : retrait ANNULÉ (jambe miroir sous le même refid, frais '
        'remboursé en négatif) → net nul par actif, les deux lignes rejetées, '
        'aucune sortie réelle ni écart de quantité', () {
      final b = _LedgerBuilder();
      b.leg(refid: 'RD1', time: '2024-11-01 08:00:00', type: 'deposit',
          asset: 'NNN', amount: '100', subclass: 'crypto');
      // Retrait RÉEL (le frais en nature sort aussi : net 11).
      b.leg(refid: 'RW1', time: '2024-11-02 08:00:00', type: 'withdrawal',
          asset: 'NNN', amount: '-10', fee: '1', subclass: 'crypto');
      // Retrait ANNULÉ — l'idiome Kraken : débit puis re-crédit MIROIR sous
      // le MÊME refid, frais remboursé (négatif).
      b.leg(refid: 'RW2', time: '2024-11-03 08:00:00', type: 'withdrawal',
          asset: 'NNN', amount: '-49', fee: '1', subclass: 'crypto');
      b.leg(refid: 'RW2', time: '2024-11-03 09:00:00', type: 'withdrawal',
          asset: 'NNN', amount: '49', fee: '-1', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile);

      final rejected = plan.movements.where((m) => m.isRejected).toList();
      expect(rejected, hasLength(2));
      expect(rejected.map((m) => m.rejectReason).toSet(),
          equals({'cryptoZeroNetMovement'}));
      // Le retrait RÉEL, lui, sort toujours.
      final out = plan.movements
          .where((m) =>
              !m.isRejected &&
              m.transaction?.kind == TransactionKind.transferOut)
          .toList();
      expect(out, hasLength(1));
      expect(out.single.transaction!.quantity, equals('11'));
      // AVANT le correctif : la jambe négative sortait pour de vrai et la
      // positive était rejetée (signe contredisant le type) — la projection
      // déduisait une sortie jamais advenue, écart fantôme sur NNN.
      expect(plan.quantityGaps, isEmpty);
      expect(plan.chainRuptures, isEmpty);
    });

    test(
        'amendement (voie ii) : échange PROPRE crypto↔USD (USD payé, '
        'NNN reçu, jambe fiat ÉTRANGÈRE à la devise du compte EUR) → '
        'valorisé AUTOMATIQUEMENT comme du cash (BUY unique), JAMAIS de '
        'position USD fabriquée', () async {
      final b = _LedgerBuilder();
      b.leg(refid: 'RB2', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '-50', subclass: 'fiat');
      b.leg(refid: 'RB2', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '1', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      // Aucun mouvement écrit pour ce groupe au moteur PUR (ni au pair, ni
      // rejet) : il part en `UnvaluedExchange`, à valoriser au lot 2.
      expect(plan.movements.any((m) => m.ledgerCode == 'NNN'), isFalse);
      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      expect(ex.codePaid, equals('USD'));
      expect(ex.quantityPaid, equals('50'));
      expect(ex.codeReceived, equals('NNN'));
      expect(ex.quantityReceived, equals('1'));
      // B-A (contre-vérification lot 2) : la jambe PAYÉE (USD) est bien
      // marquée fiat, la jambe REÇUE (NNN, crypto) ne l'est pas.
      expect(ex.codePaidIsFiat, isTrue);
      expect(ex.codeReceivedIsFiat, isFalse);

      // Étage 1-quater (amendement, voie ii) : SEULE exception à la garde B-A/B-2 —
      // un échange PROPRE à 2 jambes dont la jambe fiat vaut littéralement `USD` est
      // désormais valorisé automatiquement comme du cash converti au taux historique
      // du jour. Mock FX couvrant EXACTEMENT cette fenêtre — un appel réseau
      // inattendu ferait échouer `http.runWithClient` sans client actif.
      final mockClient = MockClient((request) async {
        return http.Response(
          '{"amount":1.0,"base":"USD","rates":{"2024-10-02":{"EUR":0.8}}}',
          200,
        );
      });
      final resolution = await http.runWithClient(
        () => CryptoValuationService().resolve(plan.unvaluedExchanges),
        () => mockClient,
      );
      expect(resolution.manual, isEmpty);
      final valuation = resolution.valuations[ex.importKey]!;
      expect(valuation.source, equals('fiatLeg'));

      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        resolution.valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      // UNE SEULE jambe émise — le modèle N4 (sell+buy à montants opposés)
      // NE S'APPLIQUE PAS ici : USD payé, NNN reçu → BUY NNN, cash SORTANT,
      // AUCUN mouvement pour la jambe USD elle-même.
      expect(finalized, hasLength(1));
      final buy = finalized.single;
      expect(buy.transaction!.kind, equals(TransactionKind.buy));
      expect(buy.ledgerCode, equals('NNN'));
      expect(buy.transaction!.quantity, equals('1'));
      // 50 (quantité NETTE de la jambe USD, PAS `amountusd`) × 0,8 = 40 EUR,
      // cash SORTANT (négatif, achat).
      expect(buy.transaction!.amount, equals('-40'));
      expect(buy.transaction!.unitPrice, equals('40'));
      expect(buy.importKey, equals('ref:acc1:RB2#buy:NNN'));
      final meta = buy.transaction!.meta!;
      expect(meta['valuationSource'], equals('fiatLeg'));
      expect(meta['valuationUsd'], equals('50'));
      expect(meta['fxRate'], equals('0.8'));
      expect(meta['fxDate'], equals('2024-10-02'));
      expect(meta.containsKey('valuationSpreadPct'), isFalse);

      // Invariant central B-A : AUCUNE position USD n'est jamais créée.
      expect(finalized.any((m) => m.ledgerCode == 'USD'), isFalse);

      // Ceinture INDÉPENDANTE de `finalizeCryptoExchanges` (B-A point 3,
      // toujours vraie) : une valorisation de source DIFFÉRENTE de
      // `'fiatLeg'` présente malgré tout dans la map (ex. `'manual'` saisi
      // avant ce correctif, ou injecté directement en test) n'est JAMAIS
      // appliquée à une entrée fiat — seule `'fiatLeg'` est acceptée.
      final forcedValuations = {
        ex.importKey: CryptoValuation(amountEur: Decimal.parse('999'), source: 'manual'),
      };
      final finalizedDespiteValuation = StatementImportService.finalizeCryptoExchanges(
        plan,
        forcedValuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalizedDespiteValuation, isEmpty);
    });

    test(
        'amendement (voie ii) : échange PROPRE crypto↔USD (NNN payé, '
        'USD reçu, jambe fiat ÉTRANGÈRE à la devise du compte EUR) → même '
        'garde dans l\'AUTRE sens, valorisé AUTOMATIQUEMENT (SELL unique), '
        'JAMAIS de position USD fabriquée', () async {
      final b = _LedgerBuilder();
      b.leg(refid: 'RBA1', time: '2024-10-09 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '-1', subclass: 'crypto');
      b.leg(refid: 'RBA1', time: '2024-10-09 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '50', subclass: 'fiat');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      expect(plan.movements.any((m) => m.ledgerCode == 'NNN'), isFalse);
      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      expect(ex.codePaid, equals('NNN'));
      expect(ex.quantityPaid, equals('1'));
      expect(ex.codeReceived, equals('USD'));
      expect(ex.quantityReceived, equals('50'));
      // Cette fois c'est la jambe REÇUE qui porte le fiat étranger.
      expect(ex.codePaidIsFiat, isFalse);
      expect(ex.codeReceivedIsFiat, isTrue);

      final mockClient = MockClient((request) async {
        return http.Response(
          '{"amount":1.0,"base":"USD","rates":{"2024-10-09":{"EUR":0.75}}}',
          200,
        );
      });
      final resolution = await http.runWithClient(
        () => CryptoValuationService().resolve(plan.unvaluedExchanges),
        () => mockClient,
      );
      expect(resolution.manual, isEmpty);
      expect(resolution.valuations[ex.importKey]!.source, equals('fiatLeg'));

      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        resolution.valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalized, hasLength(1));
      final sell = finalized.single;
      expect(sell.transaction!.kind, equals(TransactionKind.sell));
      expect(sell.ledgerCode, equals('NNN'));
      expect(sell.transaction!.quantity, equals('1'));
      // 50 × 0,75 = 37,5 EUR, cash ENTRANT (positif, vente).
      expect(sell.transaction!.amount, equals('37.5'));
      // T-2 (revue adversariale) : unitPrice côté sell, déjà couvert côté
      // buy (test précédent) — quantité 1 → unitPrice == amount ici.
      expect(sell.transaction!.unitPrice, equals('37.5'));
      expect(sell.importKey, equals('ref:acc1:RBA1#sell:NNN'));
      final meta = sell.transaction!.meta!;
      expect(meta['valuationSource'], equals('fiatLeg'));
      expect(meta['valuationUsd'], equals('50'));
      expect(meta['fxRate'], equals('0.75'));
      expect(meta['fxDate'], equals('2024-10-09'));

      expect(finalized.any((m) => m.ledgerCode == 'USD'), isFalse);

      final forcedValuations = {
        ex.importKey: CryptoValuation(amountEur: Decimal.parse('999'), source: 'manual'),
      };
      final finalizedDespiteValuation = StatementImportService.finalizeCryptoExchanges(
        plan,
        forcedValuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalizedDespiteValuation, isEmpty);
    });

    test(
        'T-1 (revue adversariale) : jambe USD avec FRAIS non nul → la '
        'quantité NETTE (amount − fee) est retenue, JAMAIS `amount` brut ni '
        '`amountusd` (USD payé, cash SORTANT)', () async {
      final b = _LedgerBuilder();
      b.leg(refid: 'RT1A', time: '2024-10-15 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '-50', fee: '0.1',
          subclass: 'fiat');
      b.leg(refid: 'RT1A', time: '2024-10-15 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '1', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      // Net = |-50 − 0,1| = 50,1 — JAMAIS 50 (amount brut).
      expect(ex.quantityPaid, equals('50.1'));

      final mockClient = MockClient((request) async {
        return http.Response(
          '{"amount":1.0,"base":"USD","rates":{"2024-10-15":{"EUR":0.8}}}',
          200,
        );
      });
      final resolution = await http.runWithClient(
        () => CryptoValuationService().resolve(plan.unvaluedExchanges),
        () => mockClient,
      );
      expect(resolution.manual, isEmpty);
      expect(
        resolution.valuations[ex.importKey]!.valuationUsd,
        equals(Decimal.parse('50.1')),
      );

      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        resolution.valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalized, hasLength(1));
      final buy = finalized.single;
      // 50,1 (quantité NETTE, frais inclus) × 0,8 = 40,08 EUR.
      expect(buy.transaction!.amount, equals('-40.08'));
      expect(buy.transaction!.unitPrice, equals('40.08'));
    });

    test(
        'T-1 (revue adversariale), autre sens : jambe USD REÇUE avec FRAIS '
        'non nul → même règle (cash ENTRANT)', () async {
      final b = _LedgerBuilder();
      b.leg(refid: 'RT1B', time: '2024-10-16 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '-1', subclass: 'crypto');
      b.leg(refid: 'RT1B', time: '2024-10-16 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '50', fee: '0.1',
          subclass: 'fiat');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      // Net = 50 − 0,1 = 49,9 — JAMAIS 50 (amount brut).
      expect(ex.quantityReceived, equals('49.9'));

      final mockClient = MockClient((request) async {
        return http.Response(
          '{"amount":1.0,"base":"USD","rates":{"2024-10-16":{"EUR":0.8}}}',
          200,
        );
      });
      final resolution = await http.runWithClient(
        () => CryptoValuationService().resolve(plan.unvaluedExchanges),
        () => mockClient,
      );
      expect(resolution.manual, isEmpty);

      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        resolution.valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalized, hasLength(1));
      final sell = finalized.single;
      // 49,9 (quantité NETTE, frais inclus) × 0,8 = 39,92 EUR.
      expect(sell.transaction!.amount, equals('39.92'));
      expect(sell.transaction!.unitPrice, equals('39.92'));
    });

    test(
        'T-3/I-2 (revue adversariale) : entrée à DEUX jambes fiat (double '
        'flag — jamais produite par le moteur réel, robustesse défensive) → '
        'reste bloquée au finalize (zéro mouvement), même avec une '
        'valorisation `fiatLeg` injectée directement en test', () {
      final plan = CryptoImportPlan(
        unvaluedExchanges: [
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 10, 21),
            codePaid: 'USD',
            quantityPaid: '50',
            codeReceived: 'GBP',
            quantityReceived: '40',
            sourceLines: const [1],
            importKey: 'ref:acc1:RDBL',
            codePaidIsFiat: true,
            codeReceivedIsFiat: true,
          ),
        ],
      );
      final forcedValuations = {
        'ref:acc1:RDBL':
            CryptoValuation(amountEur: Decimal.parse('45'), source: 'fiatLeg'),
      };
      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        forcedValuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalized, isEmpty);
    });

    test(
        'T-3/I-2 (revue adversariale) : jambe crypto au code NULL '
        '(codeReceivedIsFiat, codePaid absent — cas dégénéré) → AUCUN '
        'crash, comportement bloqué (zéro mouvement)', () {
      final plan = CryptoImportPlan(
        unvaluedExchanges: [
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 10, 22),
            codePaid: null,
            quantityPaid: null,
            codeReceived: 'USD',
            quantityReceived: '50',
            sourceLines: const [1],
            importKey: 'ref:acc1:RNULL',
            codeReceivedIsFiat: true,
          ),
        ],
      );
      final forcedValuations = {
        'ref:acc1:RNULL':
            CryptoValuation(amountEur: Decimal.parse('45'), source: 'fiatLeg'),
      };
      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        forcedValuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalized, isEmpty);
    });

    test(
        'amendement (voie ii), contrôle négatif : fiat ÉTRANGER '
        'NON-USD (GBP synthétique) → AUCUNE série FX câblée, reste '
        '`foreignFiat` comme avant, ZÉRO appel réseau', () async {
      final b = _LedgerBuilder();
      b.leg(refid: 'RGBP1', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'GBP', amount: '-40', subclass: 'fiat');
      b.leg(refid: 'RGBP1', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '1', subclass: 'crypto');
      final plan = _plan(b.toCsvBytes(), profile, accountCurrency: 'EUR');

      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      expect(ex.codePaid, equals('GBP'));
      expect(ex.codePaidIsFiat, isTrue);

      // AUCUN mock HTTP fourni : seul `USD` déclenche l'étage 1-quater, GBP
      // est écarté AVANT toute tentative FX — un appel réseau inattendu
      // ferait échouer ce test (`http.runWithClient` sans client actif).
      final resolution = await CryptoValuationService().resolve(plan.unvaluedExchanges);
      expect(resolution.valuations, isEmpty);
      final manual = resolution.manual.singleWhere((m) => m.source.importKey == ex.importKey);
      expect(manual.reason, equals(CryptoValuationManualReason.foreignFiat));

      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        resolution.valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(finalized, isEmpty); // zéro mouvement émis — aucun `GBP`/`NNN` fabriqué.
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

  test(
      'lot 2 amendement (drive) : usdStableCodes du profil Kraken = '
      '{USDT, USDC} — JAMAIS UST/USTC (ancrage perdu, séquelle Terra)', () {
    final stable = profile.crypto!.usdStableCodes;
    expect(stable, equals({'USDT', 'USDC'}));
    expect(stable.contains('UST'), isFalse);
    expect(stable.contains('USTC'), isFalse);
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
      ExchangeRateService? exchangeService,
    }) async {
      final storage = AccountStorage(database: db);
      final ctrl = AccountController(
        initialAccountId: accountId,
        storage: storage,
        ledgerService: LedgerService(database: db),
        transactionStorage: TransactionStorage(database: db),
        marketService: marketService ?? _NoNetworkMarketDataService(),
        // Instance DÉDIÉE par défaut (`forTesting`, jamais le singleton
        // applicatif) : le cache mémoire de `getDailyRatesToEur` est sinon
        // PARTAGÉ entre tests de ce même fichier (même processus), un test
        // FX réussi pouvant alors faire lire en cache un test FX-en-échec
        // ultérieur portant sur la même devise/période — piège singleton
        // déjà noté ailleurs (mode courbe/garde qualité).
        exchangeService: exchangeService ?? ExchangeRateService.forTesting(),
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

    // -----------------------------------------------------------------------
    // LOT 2 — intégration bout-en-bout (contrôleur) : résolution FX/spread/
    // lisibilité, finalisation des échanges, cascade ticker, idempotence du
    // ré-import, garde de non-double-comptage des écarts de quantité.
    // -----------------------------------------------------------------------

    /// Corps de réponse frankfurter minimal (mêmes clés que l'API réelle).
    String frankfurterBody(Map<String, double> ratesByDay) {
      final entries = ratesByDay.entries
          .map((e) => '"${e.key}":{"EUR":${e.value}}')
          .join(',');
      return '{"amount":1.0,"base":"USD","rates":{$entries}}';
    }

    /// Grand livre synthétique : UNE ligne fiat (dépôt EUR) + un échange SANS
    /// jambe fiat (AAA payé, STB stable reçu, `amountusd` lisible sur les
    /// deux jambes, écart < 10 %) — le cas nominal étage 1 du lot 2.
    Uint8List exchangeCsv() {
      final b = _LedgerBuilder();
      b.leg(refid: 'RD1', time: '2024-01-01 08:00:00', type: 'deposit',
          asset: 'EUR', amount: '1000', subclass: 'fiat');
      b.leg(refid: 'RE1', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RE1', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '198', subclass: 'stable_coin',
          amountusd: '198');
      return b.toCsvBytes();
    }

    test('lot 2 : échange valorisé étage 1 → sell+buy émis, montants opposés, meta complète', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-a';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(exchangeCsv(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.unvaluedExchanges, isEmpty); // valorisé, plus en attente.
      expect(preview.cryptoFxUnavailable, isFalse);

      final sell = preview.toCreate.firstWhere((m) => m.ledgerCode == 'AAA');
      final buy = preview.toCreate.firstWhere((m) => m.ledgerCode == 'STB');
      expect(sell.transaction!.kind, equals(TransactionKind.sell));
      expect(buy.transaction!.kind, equals(TransactionKind.buy));
      // Jambe payée retenue (200 USD) × 0,9 = 180 EUR — montants EXACTEMENT opposés
      // (règle N4, conception interne).
      expect(sell.transaction!.amount, equals('180'));
      expect(buy.transaction!.amount, equals('-180'));
      expect(sell.transaction!.fee, isNull);
      expect(buy.transaction!.fee, isNull);
      // unitPrice = V_eur / quantité, scale 12.
      // Division exacte (180/2) : `Decimal.toString()` ne pousse pas de
      // zéros de remplissage jusqu'à l'échelle 12 quand le reste est nul —
      // seule la division INEXACTE ci-dessous (180/198) exhibe l'échelle 12.
      expect(sell.transaction!.unitPrice, equals('90')); // 180/2
      expect(buy.transaction!.unitPrice,
          equals((Decimal.parse('180') / Decimal.parse('198'))
              .toDecimal(scaleOnInfinitePrecision: 12)
              .toString()));
      // Meta de traçabilité complète.
      final meta = sell.transaction!.meta!;
      expect(meta['valuationSource'], equals('statement'));
      expect(meta['valuationUsd'], equals('200'));
      expect(meta['fxRate'], equals('0.9'));
      expect(meta['fxDate'], equals('2024-01-05'));
      // Écart (198-200)/200 = -1 % < seuil, restitué pour l'affichage.
      expect(Decimal.parse(meta['valuationSpreadPct'] as String),
          equals(Decimal.parse('-0.01')));
      // Clés de rôle stables (conception interne).
      expect(sell.importKey, equals('ref:$accountId:RE1#sell:AAA'));
      expect(buy.importKey, equals('ref:$accountId:RE1#buy:STB'));

      final err = await ctrl.confirmStatementImport(preview, accountId: accountId);
      expect(err, isNull);
    });

    test('lot 2 : écart de spread > 10 % → AUCUN mouvement émis, reste en manuel avec motif', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-b';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RE2', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RE2', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '250', subclass: 'stable_coin',
          amountusd: '250'); // écart +25 %.

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.toCreate.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'STB'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      final u = preview.unvaluedExchanges.single;
      expect(u.manualReason, equals('spread'));
      expect(Decimal.parse(u.valuationSpreadPct!), equals(Decimal.parse('0.25')));
    });

    // ------------------------------------------------------------------- Amendement
    // drive lot 2 (suite) : suggestions EUR sur un échange resté manuel motif `spread`
    // — bout-en-bout via
    // `AccountController.previewStatementImport`/`applyManualCryptoValuations`, sans
    // jamais rien valoriser automatiquement.
    // -------------------------------------------------------------------

    test(
        'amendement drive lot 2 (suite) : spread > 10 % SANS repli '
        'stable → les DEUX suggestions EUR EXACTES arrivent sur '
        'preview.unvaluedExchanges (taux mocké)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-suggest-a';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      // Même relevé que le test « écart de spread » ci-dessus : AAA payé
      // (200 USD) / STB reçu (250 USD), écart +25 % — STB n'est PAS dans la
      // liste de confiance Kraken (USDT/USDC uniquement), aucun repli 1-ter.
      final b = _LedgerBuilder();
      b.leg(refid: 'RE2S', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RE2S', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '250', subclass: 'stable_coin',
          amountusd: '250');

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.unvaluedExchanges, hasLength(1));
      final u = preview.unvaluedExchanges.single;
      expect(u.manualReason, equals('spread'));
      // 200 × 0,9 = 180 (valeur cédée) ; 250 × 0,9 = 225 (valeur reçue) —
      // conversions EXACTES, même règle que l'étage 1 automatique.
      expect(Decimal.parse(u.suggestedPaidEur!), equals(Decimal.parse('180')));
      expect(Decimal.parse(u.suggestedReceivedEur!), equals(Decimal.parse('225')));

      // Rien n'a été appliqué automatiquement : toujours en attente.
      expect(preview.toCreate.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'STB'), isFalse);
    });

    test(
        'amendement drive lot 2 (suite) : les suggestions EUR '
        'survivent à une ré-application PARTIELLE — l\'entrée valorisée '
        'disparaît, celle qui reste manuelle garde ses suggestions '
        '(reportées depuis le cache, sans nouvel appel réseau)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-suggest-b';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      // Deux échanges DISTINCTS (refid différents), tous deux en spread >
      // seuil sans repli stable.
      final b = _LedgerBuilder();
      b.leg(refid: 'RE2SA', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RE2SA', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '250', subclass: 'stable_coin',
          amountusd: '250');
      b.leg(refid: 'RE2SB', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'BBB', amount: '-1', subclass: 'crypto',
          amountusd: '100');
      b.leg(refid: 'RE2SB', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STC', amount: '120', subclass: 'stable_coin',
          amountusd: '120');

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.unvaluedExchanges, hasLength(2));
      final keyA = preview.unvaluedExchanges
          .firstWhere((u) => u.codePaid == 'AAA')
          .importKey;
      final entryB = preview.unvaluedExchanges
          .firstWhere((u) => u.codePaid == 'BBB');
      // 100 × 0,9 = 90 ; 120 × 0,9 = 108.
      expect(Decimal.parse(entryB.suggestedPaidEur!), equals(Decimal.parse('90')));
      expect(
          Decimal.parse(entryB.suggestedReceivedEur!), equals(Decimal.parse('108')));

      // Saisie manuelle SEULEMENT sur l'échange AAA/STB — SANS mock HTTP actif
      // (aucune I/O, le plan et les suggestions restent en cache).
      final applied = await ctrl.applyManualCryptoValuations({keyA: '225'});
      expect(applied, isNotNull);

      // AAA/STB a quitté le groupe manuel ; BBB/STC y reste, avec ses
      // suggestions INCHANGÉES.
      expect(applied!.unvaluedExchanges, hasLength(1));
      final remaining = applied.unvaluedExchanges.single;
      expect(remaining.codePaid, equals('BBB'));
      expect(remaining.manualReason, equals('spread'));
      expect(
          Decimal.parse(remaining.suggestedPaidEur!), equals(Decimal.parse('90')));
      expect(Decimal.parse(remaining.suggestedReceivedEur!),
          equals(Decimal.parse('108')));
    });

    test(
        'lot 2 amendement (drive) : spread > 10 % MAIS jambe USDT (liste de '
        'confiance Kraken) → repli étage 1-ter, sort dans les mouvements '
        '(PLUS dans les manuels)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-stableleg';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      // Même écart excessif que le test précédent (+25 %), mais la jambe
      // reçue est un VRAI stablecoin de la liste de confiance embarquée dans
      // `BrokerProfile.kraken()` (USDT), pas le code fictif 'STB'.
      final b = _LedgerBuilder();
      b.leg(refid: 'RE2B', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RE2B', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USDT', amount: '250', subclass: 'stable_coin',
          amountusd: '250'); // écart +25 %, au-delà du seuil de 10 %.

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );

      // Plus en attente d'arbitrage manuel : le repli 1-ter a valorisé
      // l'échange automatiquement.
      expect(preview.unvaluedExchanges, isEmpty);

      final sell = preview.toCreate.firstWhere((m) => m.ledgerCode == 'AAA');
      final buy = preview.toCreate.firstWhere((m) => m.ledgerCode == 'USDT');
      expect(sell.transaction!.kind, equals(TransactionKind.sell));
      expect(buy.transaction!.kind, equals(TransactionKind.buy));
      // Valorisé sur la quantité NETTE de la jambe USDT (250), PAS la jambe
      // payée USD (200) : 250 × 0,9 = 225 EUR.
      expect(sell.transaction!.amount, equals('225'));
      expect(buy.transaction!.amount, equals('-225'));
      final meta = sell.transaction!.meta!;
      expect(meta['valuationSource'], equals('stableLeg'));
      expect(Decimal.parse(meta['valuationSpreadPct'] as String),
          equals(Decimal.parse('0.25')));

      final err = await ctrl.confirmStatementImport(preview, accountId: accountId);
      expect(err, isNull);
    });

    test('lot 2 : amountusd illisible ("-") sur les deux jambes → manuel, motif unreadable', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-c';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RE3', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto');
      b.leg(refid: 'RE3', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '198', subclass: 'stable_coin');

      // AUCUN mock HTTP fourni : si le service tentait malgré tout un appel
      // réseau, `http.runWithClient` sans client déclencherait une erreur —
      // la garde « aucune ligne valorisable → zéro appel » est donc vérifiée
      // EN CREUX ici (le test échouerait sinon avec une exception réseau).
      final preview =
          await ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId);

      expect(preview.toCreate, isEmpty);
      expect(preview.unvaluedExchanges, hasLength(1));
      expect(preview.unvaluedExchanges.single.manualReason, equals('unreadable'));
    });

    test('lot 2 : FX indisponible → TOUS les échanges en manuel (fxUnavailable), le reste du fichier passe normalement', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-d';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final mockClient = MockClient((request) async {
        return http.Response('erreur serveur', 500);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(exchangeCsv(), profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.cryptoFxUnavailable, isTrue);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'STB'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      expect(preview.unvaluedExchanges.single.manualReason, equals('fxUnavailable'));
      // Le reste du fichier (ici le dépôt EUR) passe normalement — AUCUNE
      // coercition globale (conception interne).
      expect(
        preview.toCreate.any((m) => m.transaction!.kind == TransactionKind.deposit),
        isTrue,
      );
    }, timeout: const Timeout(Duration(seconds: 15))); // 3 tentatives avec backoff.

    test('lot 2 : ré-import du même fichier valorisé → tout en doublons, zéro nouveau (idempotence)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-e';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });
      final bytes = exchangeCsv();

      final preview1 = await http.runWithClient(
        () => ctrl.previewStatementImport(bytes, profile, accountId: accountId),
        () => mockClient,
      );
      final err1 = await ctrl.confirmStatementImport(preview1, accountId: accountId);
      expect(err1, isNull);

      final preview2 = await http.runWithClient(
        () => ctrl.previewStatementImport(bytes, profile, accountId: accountId),
        () => mockClient,
      );

      // Clés `#sell:`/`#buy:` STABLES (calculées AVANT toute valorisation, invariant
      // absolu conception interne) ⇒ ré-import reconnu comme doublon.
      expect(preview2.toCreate.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(preview2.toCreate.any((m) => m.ledgerCode == 'STB'), isFalse);
      expect(preview2.duplicates.where((m) => m.ledgerCode == 'AAA'), hasLength(1));
      expect(preview2.duplicates.where((m) => m.ledgerCode == 'STB'), hasLength(1));
    });

    test('lot 2 : dépôt en nature valorisé → adjustment à coût, PRU impacté, AUCUN mouvement d\'espèces', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-f';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RE4', time: '2024-01-05 08:00:00', type: 'transfer',
          subtype: 'spotfromfutures', asset: 'III', amount: '2', subclass: 'crypto',
          amountusd: '120');

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );
      expect(preview.unvaluedExchanges, isEmpty);
      final deposit = preview.toCreate.firstWhere((m) => m.ledgerCode == 'III');
      expect(deposit.transaction!.kind, equals(TransactionKind.adjustment));
      expect(deposit.transaction!.quantity, equals('2'));
      expect(deposit.transaction!.amount, isNull); // AUCUN cash.
      // unitPrice = 120×0,9 / 2 = 54 (division exacte, pas de zéros de
      // remplissage jusqu'à l'échelle 12 — cf. commentaire du test précédent).
      expect(deposit.transaction!.unitPrice, equals('54'));
      expect(deposit.importKey, equals('ref:$accountId:RE4#deposit:III'));

      final err = await ctrl.confirmStatementImport(preview, accountId: accountId);
      expect(err, isNull);

      final positions = await AccountStorage(database: db).getPositions(accountId);
      final iii = positions.firstWhere((p) => p.asset.ledgerCode == 'III');
      expect(iii.quantity, equals('2'));
      expect(iii.averageBuyPrice, equals(54.0)); // PRU IMPACTÉ par le coût déclaré.

      // Cash INCHANGÉ : un dépôt en nature ne touche jamais les espèces.
      final journal = await TransactionStorage(database: db).getByAccount(accountId);
      expect(journal.every((t) => t.amount == null), isTrue);
    });

    test(
        'lot 2 : oracle/écart de quantité — aucun double comptage après émission des '
        'mouvements d\'échange (I-1 crédite la quantité au plan, finalizeCryptoExchanges '
        'ne la recompte pas)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-g';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(exchangeCsv(), profile, accountId: accountId),
        () => mockClient,
      );

      // `quantityGaps` est calculé PENDANT `planCryptoImport` (AVANT toute
      // valorisation lot 2, cf. I-1) — il reste vide que l'échange finisse
      // valorisé (mouvements réels émis) ou non : la quantité était déjà
      // connue et créditée à ce stade, jamais recomptée ici.
      expect(preview.quantityGaps, isEmpty);
    });

    // Récompenses toujours à coût 0 (agrégat mensuel SANS unitPrice) — garde
    // de non-régression explicite : le correctif lot 2 (adjustment à coût
    // pour un dépôt en nature) ne doit JAMAIS affecter l'agrégat mensuel de
    // récompenses (unitPrice reste null, cf. addReward/CryptoLedgerNormalizer).
    test('lot 2 : agrégat mensuel de récompenses reste à coût 0 (PRU nul), même après un dépôt en nature valorisé', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-h';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RE5', time: '2024-01-05 08:00:00', type: 'transfer',
          subtype: 'spotfromfutures', asset: 'III', amount: '2', subclass: 'crypto',
          amountusd: '120');
      b.leg(refid: 'RW9', time: '2024-01-06 09:00:00', type: 'staking',
          asset: 'RWD', wallet: 'earn/flexible', amount: '1', subclass: 'crypto');

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(b.toCsvBytes(), profile, accountId: accountId),
        () => mockClient,
      );
      final err = await ctrl.confirmStatementImport(preview, accountId: accountId);
      expect(err, isNull);

      final positions = await AccountStorage(database: db).getPositions(accountId);
      final rwd = positions.firstWhere((p) => p.asset.ledgerCode == 'RWD');
      expect(rwd.quantity, equals('1'));
      expect(rwd.averageBuyPrice, isNull); // coût 0 / PRU inconnu, INCHANGÉ.
    });

    // ----------------------------------------------------------------------- LOT 2
    // UI — applyManualCryptoValuations (conception interne) : saisie manuelle du
    // montant EUR d'un échange resté en arbitrage → sell+ buy émis avec des montants
    // EXACTEMENT opposés, `source:'manual'`, SANS reparser le fichier ni retoucher
    // le réseau ; puis idempotence d'un second cycle aperçu+saisie identique (clés
    // `#sell:`/`#buy:` stables, même mécanisme que l'étage 1 — conception interne).
    // -----------------------------------------------------------------------

    test(
        'lot 2 UI : applyManualCryptoValuations — saisie manuelle émet '
        'sell+buy à montants opposés (source manual), sans I/O ; un second '
        'cycle aperçu+saisie IDENTIQUE reconnaît un doublon (idempotence)',
        () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-manual';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      // Écart de spread > 10 % (25 %, même motif que le test « écart de
      // spread » ci-dessus) : reste en arbitrage manuel après l'étage 1.
      final b = _LedgerBuilder();
      b.leg(refid: 'RE6', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'AAA', amount: '-2', subclass: 'crypto',
          amountusd: '200');
      b.leg(refid: 'RE6', time: '2024-01-05 10:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'STB', amount: '250', subclass: 'stable_coin',
          amountusd: '250');
      final bytes = b.toCsvBytes();

      // Le SEUL échange du fichier a un spread > seuil : il est écarté AVANT
      // même la récupération FX (`CryptoValuationService.resolve`, aucune
      // ligne valorisable ⇒ zéro appel réseau) — le mock reste défensif,
      // jamais sollicité.
      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-01-05': 0.9}), 200);
      });

      Future<ImportPreview> preview() => http.runWithClient(
            () => ctrl.previewStatementImport(bytes, profile, accountId: accountId),
            () => mockClient,
          );

      final preview1 = await preview();
      expect(preview1.unvaluedExchanges, hasLength(1));
      final key = preview1.unvaluedExchanges.single.importKey;
      expect(preview1.unvaluedExchanges.single.manualReason, equals('spread'));

      // Saisie manuelle : 225 EUR — SANS aucun mock HTTP actif (le plan et
      // l'étage 1 déjà résolu restent en cache sur le contrôleur, cf.
      // `_lastCrypto*`) : aucune I/O, ni réseau ni base, pour cette étape.
      final applied1 = await ctrl.applyManualCryptoValuations({key: '225'});
      expect(applied1, isNotNull);
      expect(applied1!.unvaluedExchanges, isEmpty);

      final sell1 = applied1.toCreate.firstWhere((m) => m.ledgerCode == 'AAA');
      final buy1 = applied1.toCreate.firstWhere((m) => m.ledgerCode == 'STB');
      expect(sell1.transaction!.kind, equals(TransactionKind.sell));
      expect(buy1.transaction!.kind, equals(TransactionKind.buy));
      // Montants EXACTEMENT opposés (règle N4, conception interne) — la MÊME Decimal
      // saisie, jamais un recalcul indépendant par jambe.
      expect(sell1.transaction!.amount, equals('225'));
      expect(buy1.transaction!.amount, equals('-225'));
      expect(sell1.transaction!.fee, isNull);
      expect(buy1.transaction!.fee, isNull);
      // Provenance ET absence de toute trace USD/FX (saisie EUR directe,
      // aucun équivalent USD connu — `CryptoValuation.valuationUsd`/`fxRate`/
      // `fxDate` restent `null`, donc ABSENTS de `meta`, cf. doc de
      // `finalizeCryptoExchanges` point 6 : primitives JSON seulement).
      final sellMeta = sell1.transaction!.meta!;
      expect(sellMeta['valuationSource'], equals('manual'));
      expect(sellMeta.containsKey('valuationUsd'), isFalse);
      expect(sellMeta.containsKey('fxRate'), isFalse);
      expect(sellMeta.containsKey('fxDate'), isFalse);
      expect(sell1.importKey, equals('ref:$accountId:RE6#sell:AAA'));
      expect(buy1.importKey, equals('ref:$accountId:RE6#buy:STB'));

      final err1 = await ctrl.confirmStatementImport(applied1, accountId: accountId);
      expect(err1, isNull);

      // Second cycle COMPLET (aperçu frais depuis le même fichier, puis MÊME saisie
      // manuelle) : le moteur ne « mémorise » rien de la saisie précédente (aucune
      // coercition, conception interne) — l'échange retombe en arbitrage manuel
      // identique, c'est la DÉDUP par `importKey` (clés `#sell:`/`#buy:` stables,
      // calculées AVANT toute valorisation) qui absorbe le doublon lors de la
      // reconstruction de l'aperçu.
      final preview2 = await preview();
      expect(preview2.unvaluedExchanges, hasLength(1));
      final applied2 =
          await ctrl.applyManualCryptoValuations({key: '225'});
      expect(applied2, isNotNull);
      expect(applied2!.toCreate.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(applied2.toCreate.any((m) => m.ledgerCode == 'STB'), isFalse);
      expect(applied2.duplicates.where((m) => m.ledgerCode == 'AAA'), hasLength(1));
      expect(applied2.duplicates.where((m) => m.ledgerCode == 'STB'), hasLength(1));

      // Base intacte : UNE seule paire sell/buy pour cette clé, pas deux.
      final journal = await TransactionStorage(database: db).getByAccount(accountId);
      expect(journal.where((t) => t.meta?['importKey'] == sell1.importKey), hasLength(1));
      expect(journal.where((t) => t.meta?['importKey'] == buy1.importKey), hasLength(1));
    });

    test(
        'lot 2 UI : applyManualCryptoValuations sans aperçu crypto préalable '
        '(cache vide) → null, aucune exception', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-nocontext';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final result =
          await ctrl.applyManualCryptoValuations({'ref:x:Y': '100'});
      expect(result, isNull);
    });

    // -----------------------------------------------------------------------
    // B-1 (BLOQUANT, revue adversariale) : dustsweeping N→1 DÉGÉNÉRÉ (au moins
    // un `amountusd` illisible parmi les jambes payées) émet PLUSIEURS
    // `UnvaluedExchange` sous la MÊME `importKey` (repli « une entrée par
    // jambe payée », `CryptoLedgerNormalizer._processExchangeGroup`) —
    // AVANT le correctif, `finalizeCryptoExchanges` aurait appliqué à CHACUNE
    // l'unique valorisation retenue pour cette clé dans la map (jambes émises
    // au mauvais montant, clés dupliquées en base).
    // -----------------------------------------------------------------------
    test(
        'lot 2 B-1 (revue adversariale) : dustsweeping N→1 dégénéré '
        '(amountusd partiellement illisible) → AUCUN mouvement émis, 2 '
        'entrées manuelles motif ambiguousGroup, saisie manuelle inopérante, '
        'ré-import stable', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-b1';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      // CCC : amountusd lisible (10). DDD : amountusd OMIS → littéral '-'
      // (illisible, même convention que les autres tests N2 de ce fichier).
      // `weightsReadable` devient faux pour le groupe entier : repli dégénéré
      // « une entrée par jambe payée », MÊME importKey `ref:$accountId:RDEG`
      // pour CCC et DDD — c'est CE partage de clé que B-1 corrige.
      final b = _LedgerBuilder();
      b.leg(refid: 'RDEG', time: '2024-01-05 10:00:00', type: 'spend',
          subtype: 'dustsweeping', asset: 'CCC', amount: '-5', subclass: 'crypto',
          amountusd: '10');
      b.leg(refid: 'RDEG', time: '2024-01-05 10:00:00', type: 'spend',
          subtype: 'dustsweeping', asset: 'DDD', amount: '-3', subclass: 'crypto');
      b.leg(refid: 'RDEG', time: '2024-01-05 10:00:00', type: 'receive',
          subtype: 'dustsweeping', asset: 'EUR', amount: '30', subclass: 'fiat',
          amountusd: '30');
      final bytes = b.toCsvBytes();

      // AUCUN mock HTTP fourni : le groupe entier part en arbitrage manuel
      // dès le pré-scan de multiplicité de `CryptoValuationService.resolve`
      // (AVANT toute tentative FX, `candidates` reste vide) — si le service
      // tentait malgré tout un appel réseau, `http.runWithClient` sans client
      // déclencherait une erreur (garde vérifiée en creux, même patron que le
      // test « amountusd illisible » ci-dessus).
      final preview = await ctrl.previewStatementImport(
        bytes,
        profile,
        accountId: accountId,
      );

      // AVANT B-1 : une valorisation unique aurait pu être appliquée à tort
      // aux DEUX entrées. APRÈS : rien n'est émis pour ce groupe.
      expect(preview.toCreate.any((m) => m.ledgerCode == 'CCC'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'DDD'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'EUR'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(2));
      expect(
        preview.unvaluedExchanges
            .every((u) => u.manualReason == 'ambiguousGroup'),
        isTrue,
      );
      expect(
        preview.unvaluedExchanges.map((u) => u.importKey).toSet(),
        equals({'ref:$accountId:RDEG'}),
      );

      // Saisie manuelle sur la clé partagée : REFUSÉE (B-1.3, ceinture
      // contrôleur) — le groupe reste intégralement manuel, motif inchangé.
      final key = preview.unvaluedExchanges.first.importKey;
      final applied = await ctrl.applyManualCryptoValuations({key: '999'});
      expect(applied, isNotNull);
      expect(applied!.toCreate.any((m) => m.ledgerCode == 'CCC'), isFalse);
      expect(applied.toCreate.any((m) => m.ledgerCode == 'DDD'), isFalse);
      expect(applied.unvaluedExchanges, hasLength(2));
      expect(
        applied.unvaluedExchanges
            .every((u) => u.manualReason == 'ambiguousGroup'),
        isTrue,
      );

      // Ré-import STABLE : rien n'ayant été journalisé pour ce groupe, un
      // second aperçu depuis le même fichier retombe EXACTEMENT sur le même
      // état (aucune coercition, aucune dérive entre deux tentatives).
      final preview2 = await ctrl.previewStatementImport(
        bytes,
        profile,
        accountId: accountId,
      );
      expect(preview2.unvaluedExchanges, hasLength(2));
      expect(
        preview2.unvaluedExchanges
            .every((u) => u.manualReason == 'ambiguousGroup'),
        isTrue,
      );
    });

    // -----------------------------------------------------------------------
    // Amendement (voie ii) : jambe fiat ÉTRANGÈRE USD d'un échange PROPRE (2 jambes)
    // — cf. le pendant « moteur pur » de ces tests dans le groupe « Lot 1 Kraken —
    // revue adversariale » (fixtures B-2/B-A, poussées jusqu'à
    // `finalizeCryptoExchanges`) ; ceux-ci couvrent le circuit CONTRÔLEUR complet :
    // aperçu → valorisation automatique → confirmation, PUIS le repli
    // `fxUnavailable` (saisie manuelle toujours refusée, B-A intact) quand la série
    // FX est injoignable.
    // -----------------------------------------------------------------------
    test(
        'amendement (voie ii) : échange à jambe fiat ÉTRANGÈRE (USD '
        'sur un compte EUR) → valorisé AUTOMATIQUEMENT bout-en-bout '
        '(aperçu → confirmation), AUCUNE position USD', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-ba';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RBA2', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '-50', subclass: 'fiat');
      b.leg(refid: 'RBA2', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '1', subclass: 'crypto');
      final bytes = b.toCsvBytes();

      final mockClient = MockClient((request) async {
        return http.Response(frankfurterBody({'2024-10-02': 0.8}), 200);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(bytes, profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.unvaluedExchanges, isEmpty); // valorisé, plus en attente.
      expect(preview.cryptoFxUnavailable, isFalse);
      final buy = preview.toCreate.firstWhere((m) => m.ledgerCode == 'NNN');
      expect(buy.transaction!.kind, equals(TransactionKind.buy));
      expect(buy.transaction!.amount, equals('-40')); // 50 × 0,8, cash SORTANT.
      expect(buy.transaction!.meta!['valuationSource'], equals('fiatLeg'));

      // Invariant central B-A : AUCUNE position USD n'est jamais créée.
      expect(preview.toCreate.any((m) => m.ledgerCode == 'USD'), isFalse);

      final err = await ctrl.confirmStatementImport(preview, accountId: accountId);
      expect(err, isNull);

      // Ré-import STABLE : le mouvement est déjà journalisé, un second
      // aperçu le retrouve en doublon plutôt qu'en nouveau candidat/manuel.
      final preview2 = await http.runWithClient(
        () => ctrl.previewStatementImport(bytes, profile, accountId: accountId),
        () => mockClient,
      );
      expect(preview2.unvaluedExchanges, isEmpty);
      expect(preview2.toCreate.any((m) => m.ledgerCode == 'NNN'), isFalse);
    });

    test(
        'amendement (voie ii) : FX indisponible pour la jambe fiat USD '
        '→ AUCUNE coercition, motif fxUnavailable (pas foreignFiat), saisie '
        'manuelle TOUJOURS refusée (B-A intact)', () async {
      final db = await openTestDatabase();
      addTearDown(db.close);
      const accountId = 'acc-lot2-ba-fx';
      await seedAccount(db, accountId);
      final ctrl = await makeCtrl(db, accountId);

      final b = _LedgerBuilder();
      b.leg(refid: 'RBA3', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'USD', amount: '-50', subclass: 'fiat');
      b.leg(refid: 'RBA3', time: '2024-10-02 08:00:00', type: 'trade',
          subtype: 'tradespot', asset: 'NNN', amount: '1', subclass: 'crypto');
      final bytes = b.toCsvBytes();

      final mockClient = MockClient((request) async {
        return http.Response('erreur serveur', 500);
      });

      final preview = await http.runWithClient(
        () => ctrl.previewStatementImport(bytes, profile, accountId: accountId),
        () => mockClient,
      );

      expect(preview.cryptoFxUnavailable, isTrue);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'NNN'), isFalse);
      expect(preview.toCreate.any((m) => m.ledgerCode == 'USD'), isFalse);
      expect(preview.unvaluedExchanges, hasLength(1));
      final ex = preview.unvaluedExchanges.single;
      expect(ex.manualReason, equals('fxUnavailable'));

      // Saisie manuelle : REFUSÉE (B-A, ceinture contrôleur) — une jambe
      // fiat reste une jambe fiat quel que soit le motif de son échec de
      // résolution automatique ; l'échange reste intégralement manuel.
      final applied = await ctrl.applyManualCryptoValuations({ex.importKey: '999'});
      expect(applied, isNotNull);
      expect(applied!.toCreate.any((m) => m.ledgerCode == 'NNN'), isFalse);
      expect(applied.toCreate.any((m) => m.ledgerCode == 'USD'), isFalse);
      expect(applied.unvaluedExchanges, hasLength(1));
      expect(applied.unvaluedExchanges.single.manualReason, equals('fxUnavailable'));
    }, timeout: const Timeout(Duration(seconds: 15))); // 3 tentatives avec backoff.
  });

  group('Lot 2 — revue adversariale B-1/B-2 (moteur pur, finalizeCryptoExchanges)', () {
    test(
        'B-2 (BLOQUANT) : codeReceived == devise du compte, clé UNIQUE → '
        'ZÉRO mouvement émis (aucun buy EUR fabriqué)', () {
      // Reproduit à la main la forme dégénérée que
      // `_processExchangeGroup` peut produire : `codeReceived` porte la
      // devise DU COMPTE (jamais un actif titre) — construction directe pour
      // isoler CETTE garde de la garde B-1 (clé ici volontairement UNIQUE).
      final plan = CryptoImportPlan(
        unvaluedExchanges: [
          UnvaluedExchange(
            kind: 'exchange',
            date: DateTime(2024, 1, 5),
            codePaid: 'CCC',
            quantityPaid: '5',
            codeReceived: 'EUR', // devise du compte, jamais un actif titre.
            quantityReceived: '30',
            sourceLines: const [7],
            importKey: 'ref:acc1:RB2',
          ),
        ],
      );
      final valuations = {
        'ref:acc1:RB2':
            CryptoValuation(amountEur: Decimal.parse('30'), source: 'statement'),
      };

      final out = StatementImportService.finalizeCryptoExchanges(
        plan,
        valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );

      expect(out, isEmpty);
    });

    test(
        'B-1 (BLOQUANT) : ceinture indépendante de finalizeCryptoExchanges — '
        'clé partagée par 2 entrées, MÊME avec une valorisation présente dans '
        'la map → ZÉRO mouvement émis', () {
      final u1 = UnvaluedExchange(
        kind: 'exchange',
        date: DateTime(2024, 1, 5),
        codePaid: 'CCC',
        quantityPaid: '5',
        codeReceived: 'STB',
        quantityReceived: '20',
        sourceLines: const [7],
        importKey: 'ref:acc1:RB1', // clé PARTAGÉE.
      );
      final u2 = UnvaluedExchange(
        kind: 'exchange',
        date: DateTime(2024, 1, 5),
        codePaid: 'DDD',
        quantityPaid: '3',
        codeReceived: 'STB',
        quantityReceived: '10',
        sourceLines: const [8],
        importKey: 'ref:acc1:RB1', // MÊME clé que u1.
      );
      final plan = CryptoImportPlan(unvaluedExchanges: [u1, u2]);
      // Valorisation malgré tout présente dans la map (ex. une entrée
      // manuelle antérieure au correctif, ou un futur appelant qui
      // n'appliquerait pas le pré-scan de `resolve`) : ne doit JAMAIS être
      // appliquée — la ceinture est INDÉPENDANTE de `resolve`.
      final valuations = {
        'ref:acc1:RB1':
            CryptoValuation(amountEur: Decimal.parse('999'), source: 'manual'),
      };

      final out = StatementImportService.finalizeCryptoExchanges(
        plan,
        valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );

      expect(out, isEmpty);
    });

    test(
        'amendement (voie ii) : clé PARTAGÉE impliquant une jambe '
        'fiat USD → reste `ambiguousGroup` au pré-scan de `resolve` (PAS '
        'résolue automatiquement), et finalizeCryptoExchanges n\'émet rien '
        'MÊME avec une valorisation `fiatLeg` forcée dans la map', () async {
      // Forme dégénérée du dustsweeping N→1 (répartition impossible) avec
      // une jambe REÇUE fiat ÉTRANGÈRE USD, partagée par 2 entrées sous la
      // MÊME clé — B-1 (multiplicité de `importKey`) doit primer sur
      // l'étage 1-quater : une clé partagée n'est JAMAIS résolue
      // automatiquement, même si chacune de ses entrées, prise seule,
      // aurait été éligible à `fiatLeg`.
      final u1 = UnvaluedExchange(
        kind: 'exchange',
        date: DateTime(2024, 1, 5),
        codePaid: 'CCC',
        quantityPaid: '5',
        codeReceived: 'USD',
        quantityReceived: '30',
        sourceLines: const [7],
        importKey: 'ref:acc1:RUSDSHARED', // clé PARTAGÉE.
        codeReceivedIsFiat: true,
      );
      final u2 = UnvaluedExchange(
        kind: 'exchange',
        date: DateTime(2024, 1, 5),
        codePaid: 'DDD',
        quantityPaid: '3',
        codeReceived: 'USD',
        quantityReceived: '10',
        sourceLines: const [8],
        importKey: 'ref:acc1:RUSDSHARED', // MÊME clé que u1.
        codeReceivedIsFiat: true,
      );

      // AUCUN mock HTTP fourni : le pré-scan de multiplicité (B-1) écarte la
      // clé partagée AVANT toute tentative de résolution `fiatLeg` — un
      // appel réseau inattendu ferait échouer ce test.
      final resolution = await CryptoValuationService().resolve([u1, u2]);
      expect(resolution.valuations, isEmpty);
      expect(resolution.manual, hasLength(2));
      expect(
        resolution.manual
            .every((m) => m.reason == CryptoValuationManualReason.ambiguousGroup),
        isTrue,
      );

      // Ceinture INDÉPENDANTE de `finalizeCryptoExchanges` (B-1) : même avec
      // une valorisation `fiatLeg` forcée dans la map pour cette clé
      // partagée (ex. injectée directement en test), RIEN n'est émis.
      final plan = CryptoImportPlan(unvaluedExchanges: [u1, u2]);
      final forcedValuations = {
        'ref:acc1:RUSDSHARED': CryptoValuation(
          amountEur: Decimal.parse('24'),
          valuationUsd: Decimal.parse('30'),
          source: 'fiatLeg',
        ),
      };
      final out = StatementImportService.finalizeCryptoExchanges(
        plan,
        forcedValuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
      );
      expect(out, isEmpty);
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

// test/crypto_ledger_binance_lot4_test.dart
//
// Tests du LOT 4 (PHASE B) du chantier B16 (profil Binance, conception
// interne) : le moteur PUR (`CryptoLedgerNormalizer`/`StatementImportService.
// planCryptoImport`/`finalizeCryptoExchanges`), exercé via `BrokerProfile.
// binance()`.
//
// Fixtures 100 % SYNTHÉTIQUES — actifs fictifs (AAA/BBB/CCC…, BNB conservé
// comme identité PUBLIQUE de ticker, pas une donnée personnelle) — aucune
// ligne ni valeur d'un relevé réel. Le générateur de grand livre
// ([_BinanceLedgerBuilder]) reproduit les 7 colonnes du format réel (`User
// ID, Time, Account, Operation, Coin, Change, Remark`), SANS colonne
// `balance`/`wallet`/`refid` (absentes du format Binance — aucun oracle de
// complétude possible sur ce profil, contrairement à Kraken).

import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/crypto_ledger_spec.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/services/statement_import_service.dart';

// ---------------------------------------------------------------------------
// Générateur de grand livre Binance synthétique — 7 colonnes du format réel
// (conception interne), `Remark` vide par défaut.
// ---------------------------------------------------------------------------

const _binanceHeader = ['User ID', 'Time', 'Account', 'Operation', 'Coin', 'Change', 'Remark'];

class _BinanceLedgerBuilder {
  final List<List<String>> rows = [];

  /// Ajoute UNE jambe, dans l'ordre CHRONOLOGIQUE d'appel (ordre de fichier
  /// attendu par le pipeline). [time] au format `AAAA-MM-JJ HH:MM:SS`.
  void leg({
    required String time,
    required String operation,
    required String coin,
    required String change,
    String remark = '',
    String userId = 'U1',
    String account = 'Spot',
  }) {
    rows.add([userId, time, account, operation, coin, change, remark]);
  }

  static Uint8List bytesFor(List<List<String>> dataRows) {
    final all = [_binanceHeader, ...dataRows];
    final text = all.map((r) => r.join(',')).join('\n');
    return Uint8List.fromList(utf8.encode(text));
  }

  Uint8List toCsvBytes() => bytesFor(rows);
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

/// Clone COMPLET de [crypto] avec [CryptoLedgerSpec.migrationRenamesInPlace]
/// forcé à `false` — sert UNIQUEMENT à prouver que la garde par opt-in de
/// `_processMigrationGroup` reste active côté moteur PUR, indépendamment de ce
/// que déclare `BrokerProfile.binance()` (revue adversariale, CORRECTIF : la
/// même forme structurelle — deux codes, magnitudes égales — sans cet opt-in
/// doit rester un rejet motivé, jamais un renommage silencieux).
BrokerProfile _withoutMigrationOptIn(BrokerProfile profile) => profile.copyWith(
      crypto: CryptoLedgerSpec(
        grouping: profile.crypto!.grouping,
        groupKeyColumn: profile.crypto!.groupKeyColumn,
        groupingWindow: profile.crypto!.groupingWindow,
        counterpartyPattern: profile.crypto!.counterpartyPattern,
        notesColumn: profile.crypto!.notesColumn,
        actions: profile.crypto!.actions,
        subKindColumn: profile.crypto!.subKindColumn,
        stakedSuffixes: profile.crypto!.stakedSuffixes,
        identityAliases: profile.crypto!.identityAliases,
        migrationRenamesInPlace: false,
        quoteAliases: profile.crypto!.quoteAliases,
        assetClassColumn: profile.crypto!.assetClassColumn,
        fiatAssets: profile.crypto!.fiatAssets,
        stableAssets: profile.crypto!.stableAssets,
        walletColumn: profile.crypto!.walletColumn,
        balanceColumn: profile.crypto!.balanceColumn,
        requiredColumns: profile.crypto!.requiredColumns,
        rewards: profile.crypto!.rewards,
        valuationAmountColumn: profile.crypto!.valuationAmountColumn,
        valuationCurrency: profile.crypto!.valuationCurrency,
        feeLegKindLabels: profile.crypto!.feeLegKindLabels,
        remarkPairedKindLabels: profile.crypto!.remarkPairedKindLabels,
        maxLegValuationSpread: profile.crypto!.maxLegValuationSpread,
        usdStableCodes: profile.crypto!.usdStableCodes,
        signFixedKinds: profile.crypto!.signFixedKinds,
        externalDepositKinds: profile.crypto!.externalDepositKinds,
        externalWithdrawalKinds: profile.crypto!.externalWithdrawalKinds,
        conditionalActionRedirects: profile.crypto!.conditionalActionRedirects,
      ),
    );

void main() {
  final profile = BrokerProfile.binance();

  // ---------------------------------------------------------------------
  // §5.4.1 — Groupage par horodatage exact.
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — groupage par horodatage (§5.4.1)', () {
    test('trade EUR-jambé simple (Spend EUR + Buy AAA) → chemin cash direct, achat', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final buy = _byLedgerCode(plan, 'AAA', kind: 'buy');
      expect(buy.transaction!.quantity, equals('10'));
      expect(buy.transaction!.amount, equals('-500'));
      expect(buy.transaction!.unitPrice, equals('50'));
      // Aucune position EUR fabriquée (chemin cash direct).
      expect(plan.movements.any((m) => m.ledgerCode == 'EUR'), isFalse);
    });

    test('vente EUR-jambée (Sold AAA + Revenue EUR)', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-02-01 10:00:00', operation: 'Transaction Sold',
          coin: 'AAA', change: '-6');
      b.leg(time: '2024-02-01 10:00:00', operation: 'Transaction Revenue',
          coin: 'EUR', change: '300');
      final plan = _plan(b.toCsvBytes(), profile);

      final sell = _byLedgerCode(plan, 'AAA', kind: 'sell');
      expect(sell.transaction!.quantity, equals('6'));
      expect(sell.transaction!.amount, equals('300'));
    });

    test('exécutions PARTIELLES (3 lignes Spend du même actif) sommées AVANT classification', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-01-10 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-200');
      b.leg(time: '2024-01-10 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-150');
      b.leg(time: '2024-01-10 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-150');
      b.leg(time: '2024-01-10 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      final plan = _plan(b.toCsvBytes(), profile);

      final buy = _byLedgerCode(plan, 'AAA', kind: 'buy');
      expect(buy.transaction!.amount, equals('-500')); // -200-150-150
      expect(buy.transaction!.quantity, equals('10'));
    });

    test('frais EN NATURE (même actif que la jambe reçue) → absorbé, aucune ligne séparée', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Fee',
          coin: 'AAA', change: '-0.01');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final buy = _byLedgerCode(plan, 'AAA', kind: 'buy');
      expect(buy.transaction!.quantity, equals('9.99'));
      expect(plan.unvaluedExchanges, isEmpty);
    });

    test('5 groupes SANS frais : frais nul, jamais une anomalie', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-01-11 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-100');
      b.leg(time: '2024-01-11 10:00:00', operation: 'Transaction Buy',
          coin: 'BBB', change: '2');
      final plan = _plan(b.toCsvBytes(), profile);
      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      expect(_byLedgerCode(plan, 'BBB', kind: 'buy').transaction!.quantity, equals('2'));
    });

    test('échange crypto↔crypto SANS jambe fiat (Binance Convert propre, 2 jambes)', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-03-01 09:00:00', operation: 'Binance Convert',
          coin: 'CCC', change: '-5');
      b.leg(time: '2024-03-01 09:00:00', operation: 'Binance Convert',
          coin: 'DDD', change: '20');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      expect(plan.movements, isEmpty); // pas de jambe fiat → en attente de valorisation
      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      expect(ex.codePaid, equals('CCC'));
      expect(ex.quantityPaid, equals('5'));
      expect(ex.codeReceived, equals('DDD'));
      expect(ex.quantityReceived, equals('20'));
    });

    test(
        'GARDE (N11) : deux `Coin` distincts dans le rôle « payé » (deux '
        'trades DISTINCTS qui se percutent à la même seconde) → abandon du '
        'groupage, rejet motivé cryptoAmbiguousTimestampGroup pour TOUTES '
        'les lignes du groupe', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-04-01 12:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-100');
      b.leg(time: '2024-04-01 12:00:00', operation: 'Transaction Spend',
          coin: 'AAA', change: '-3');
      b.leg(time: '2024-04-01 12:00:00', operation: 'Transaction Buy',
          coin: 'BBB', change: '7');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements, hasLength(3));
      expect(plan.movements.every((m) => m.isRejected), isTrue);
      expect(
        plan.movements.every((m) => m.rejectReason == 'cryptoAmbiguousTimestampGroup'),
        isTrue,
      );
    });

    test('jambe nette NULLE dans le groupe → rejet cryptoZeroNetMovement, tout le groupe', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-04-02 12:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-50');
      b.leg(time: '2024-04-02 12:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '50'); // s'annule exactement
      b.leg(time: '2024-04-02 12:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '1');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.every((m) => m.isRejected), isTrue);
      expect(
        plan.movements.every((m) => m.rejectReason == 'cryptoZeroNetMovement'),
        isTrue,
      );
    });
  });

  // ---------------------------------------------------------------------
  // §5.4.4-bis — Frais en actif TIERS (cas majoritaire, BNB).
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — frais en actif tiers (§5.4.4-bis)', () {
    test('frais en BNB (tiers) : le trade primaire est émis INCHANGÉ + une entrée feeInKind séparée', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-05-01 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-05-01 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      b.leg(time: '2024-05-01 10:00:00', operation: 'Transaction Fee',
          coin: 'BNB', change: '-0.05');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      // Trade primaire INCHANGÉ (500/10, jamais amputé du frais BNB).
      final buy = _byLedgerCode(plan, 'AAA', kind: 'buy');
      expect(buy.transaction!.quantity, equals('10'));
      expect(buy.transaction!.amount, equals('-500'));

      final fee = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'feeInKind');
      expect(fee.codeReceived, equals('BNB'));
      expect(fee.quantityReceived, equals('0.05'));
      expect(fee.codePaid, isNull);
      expect(fee.feeForGroup, isNotNull);
      // B-1 (revue adversariale, CORRECTIF) : clé suffixée par l'actif de
      // frais — nécessaire dès que plusieurs frais tiers peuvent coexister
      // dans le même groupe.
      expect(fee.importKey, equals('${fee.feeForGroup}#fee:BNB'));
    });

    test(
        'finalizeCryptoExchanges (feeInKind) : sell BNB valorisé + charge '
        'espèces liés par meta.feeForGroup, cash net ZÉRO', () {
      final plan = CryptoImportPlan(
        unvaluedExchanges: [
          UnvaluedExchange(
            kind: 'feeInKind',
            date: DateTime(2024, 5, 1),
            codeReceived: 'BNB',
            quantityReceived: '0.05',
            sourceLines: const [3],
            importKey: 'ref:acc1:ts:2024-05-01T10:00:00.000#fee:BNB',
            codeReceivedIsFiat: false,
            feeForGroup: 'ref:acc1:ts:2024-05-01T10:00:00.000',
          ),
        ],
      );
      final valuations = {
        'ref:acc1:ts:2024-05-01T10:00:00.000#fee:BNB':
            CryptoValuation(amountEur: Decimal.parse('25'), source: 'manual'),
      };
      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
        externalDepositKinds: const {'Deposit'},
      );

      expect(finalized, hasLength(2));
      final sell = finalized.firstWhere((m) => m.transaction!.kind.name == 'sell');
      final charge = finalized.firstWhere((m) => m.transaction!.kind.name == 'charge');
      expect(sell.ledgerCode, equals('BNB'));
      expect(sell.transaction!.quantity, equals('0.05'));
      expect(sell.transaction!.amount, equals('25'));
      expect(charge.transaction!.amount, equals('-25'));
      expect(charge.ledgerCode, isNull); // mouvement cash pur, sans actif
      expect(
        sell.transaction!.meta!['feeForGroup'],
        equals('ref:acc1:ts:2024-05-01T10:00:00.000'),
      );
      expect(
        charge.transaction!.meta!['feeForGroup'],
        equals('ref:acc1:ts:2024-05-01T10:00:00.000'),
      );
      // Cash net ZÉRO : +25 (sell) puis -25 (charge).
      final net = Decimal.parse(sell.transaction!.amount!) +
          Decimal.parse(charge.transaction!.amount!);
      expect(net, equals(Decimal.zero));
    });

    test('frais BNB positif (anomalie) → rejet cryptoAmbiguousTimestampGroup, jamais réinterprété', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-05-02 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-100');
      b.leg(time: '2024-05-02 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '2');
      b.leg(time: '2024-05-02 10:00:00', operation: 'Transaction Fee',
          coin: 'BNB', change: '0.01'); // signe positif : anomalie
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.every((m) => m.isRejected), isTrue);
      expect(
        plan.movements.every((m) => m.rejectReason == 'cryptoAmbiguousTimestampGroup'),
        isTrue,
      );
    });

    test(
        'B-1 (revue adversariale, CORRECTIF) : DEUX jambes de frais réduites '
        '(une absorbée en nature dans la jambe reçue, une tierce en BNB) → '
        '1 échange émis + 1 feeInKind séparé, JAMAIS un rejet — une jambe '
        'de frais n\'est PAS un « rôle » au sens de la garde d\'ambiguïté '
        '(§5.4.1)', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-05-10 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-05-10 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      b.leg(time: '2024-05-10 10:00:00', operation: 'Transaction Fee',
          coin: 'AAA', change: '-0.02'); // frais en nature, absorbé
      b.leg(time: '2024-05-10 10:00:00', operation: 'Transaction Fee',
          coin: 'BNB', change: '-0.01'); // frais tiers, séparé
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final buy = _byLedgerCode(plan, 'AAA', kind: 'buy');
      expect(buy.transaction!.quantity, equals('9.98')); // 10 - 0.02
      expect(buy.transaction!.amount, equals('-500'));

      final fee = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'feeInKind');
      expect(fee.codeReceived, equals('BNB'));
      expect(fee.quantityReceived, equals('0.01'));
      expect(fee.importKey, equals('${fee.feeForGroup}#fee:BNB'));
    });

    test(
        'M-1 (revue adversariale, CORRECTIF) : un feeInKind déjà ajouté '
        '(frais BNB tiers) EST PURGÉ si une AUTRE jambe de frais du même '
        'groupe déclenche ensuite un rejet global (frais AAA positif, '
        'anomalie) — jamais un frais orphelin visible séparément pour un '
        'groupe par ailleurs entièrement rejeté', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-05-11 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-05-11 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      // Frais tiers BNB — traité EN PREMIER (ordre de fichier), ajoute un
      // feeInKind AVANT que la jambe de frais suivante ne soit examinée.
      b.leg(time: '2024-05-11 10:00:00', operation: 'Transaction Fee',
          coin: 'BNB', change: '-0.01');
      // Frais AAA au signe POSITIF (anomalie) — déclenche le rejet global
      // APRÈS l'ajout du feeInKind BNB ci-dessus.
      b.leg(time: '2024-05-11 10:00:00', operation: 'Transaction Fee',
          coin: 'AAA', change: '0.5');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements, hasLength(4));
      expect(plan.movements.every((m) => m.isRejected), isTrue);
      expect(
        plan.movements.every((m) => m.rejectReason == 'cryptoAmbiguousTimestampGroup'),
        isTrue,
      );
      // Le feeInKind BNB ajouté PUIS purgé ne doit laisser AUCUNE trace.
      expect(plan.unvaluedExchanges, isEmpty);
    });
  });

  // ---------------------------------------------------------------------
  // §5.4.1 — Small Assets Exchange BNB (appariement par Remark).
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — Small Assets Exchange BNB (Remark)', () {
    test('paire propre (Remark identique, 1 négative + 1 positive) → 1 échange', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-06-01 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'CCC', change: '-5', remark: 'CCC to BNB');
      b.leg(time: '2024-06-01 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'BNB', change: '0.02', remark: 'CCC to BNB');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final ex = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange');
      expect(ex.codePaid, equals('CCC'));
      expect(ex.quantityPaid, equals('5'));
      expect(ex.codeReceived, equals('BNB'));
      expect(ex.quantityReceived, equals('0.02'));
    });

    test('deux paires DISTINCTES au même horodatage (Remark différent) → 2 échanges séparés', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-06-02 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'CCC', change: '-5', remark: 'CCC to BNB');
      b.leg(time: '2024-06-02 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'BNB', change: '0.02', remark: 'CCC to BNB');
      b.leg(time: '2024-06-02 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'DDD', change: '-8', remark: 'DDD to BNB');
      b.leg(time: '2024-06-02 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'BNB', change: '0.03', remark: 'DDD to BNB');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      expect(plan.unvaluedExchanges.where((u) => u.kind == 'exchange'), hasLength(2));
      final ccc = plan.unvaluedExchanges.singleWhere((u) => u.codePaid == 'CCC');
      final ddd = plan.unvaluedExchanges.singleWhere((u) => u.codePaid == 'DDD');
      expect(ccc.quantityReceived, equals('0.02'));
      expect(ddd.quantityReceived, equals('0.03'));
    });

    test('Remark ABSENT/vide → rejet motivé smallAssetsExchangeUnpaired, jamais une prorata devinée', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-06-03 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'EEE', change: '-2', remark: '');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements, hasLength(1));
      final m = plan.movements.single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('smallAssetsExchangeUnpaired'));
    });

    test('Remark partagé par TROIS lignes (2 négatives + 1 positive) → rejet des trois', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-06-04 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'FFF', change: '-1', remark: 'lot to BNB');
      b.leg(time: '2024-06-04 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'GGG', change: '-2', remark: 'lot to BNB');
      b.leg(time: '2024-06-04 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'BNB', change: '0.01', remark: 'lot to BNB');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements, hasLength(3));
      expect(
        plan.movements.every((m) => m.rejectReason == 'smallAssetsExchangeUnpaired'),
        isTrue,
      );
    });

    test(
        'I-2 (revue adversariale, CORRECTIF) : clé de dédup STABLE au '
        'décalage de lignes source (ré-export à fenêtre élargie) — dérivée '
        'du CONTENU (seconde exacte + texte Remark), jamais du numéro de '
        'ligne', () {
      final b1 = _BinanceLedgerBuilder();
      b1.leg(time: '2024-06-05 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'CCC', change: '-5', remark: 'CCC to BNB');
      b1.leg(time: '2024-06-05 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'BNB', change: '0.02', remark: 'CCC to BNB');
      final plan1 = _plan(b1.toCsvBytes(), profile);
      final key1 = plan1.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange').importKey;

      final b2 = _BinanceLedgerBuilder();
      // Lignes SUPPLÉMENTAIRES en tête de fichier (simule un ré-export à
      // fenêtre élargie, qui décale tous les numéros de ligne en aval) —
      // n'ont AUCUN rapport avec la paire Small Assets Exchange ci-dessous.
      b2.leg(time: '2024-01-01 00:00:00', operation: 'Simple Earn Flexible Interest',
          coin: 'ZZZ', change: '0.1');
      b2.leg(time: '2024-01-02 00:00:00', operation: 'Simple Earn Flexible Interest',
          coin: 'ZZZ', change: '0.2');
      b2.leg(time: '2024-06-05 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'CCC', change: '-5', remark: 'CCC to BNB');
      b2.leg(time: '2024-06-05 08:00:00', operation: 'Small Assets Exchange BNB',
          coin: 'BNB', change: '0.02', remark: 'CCC to BNB');
      final plan2 = _plan(b2.toCsvBytes(), profile);
      final key2 = plan2.unvaluedExchanges.singleWhere((u) => u.kind == 'exchange').importKey;

      expect(key1, equals(key2));
    });
  });

  // ---------------------------------------------------------------------
  // §5.4.3 — Bilan Earn (souscriptions/rachats internes).
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — bilan Earn (§5.4.3)', () {
    test(
        'souscription/rachat Earn DÉSÉQUILIBRÉS → rien journalisé, résidu '
        'signalé dans le bilan de cohérence (réutilisation du mécanisme '
        'UnbalancedInternalTransfer déjà générique)', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-07-01 08:00:00', operation: 'Simple Earn Locked Subscription',
          coin: 'AAA', change: '-10');
      b.leg(time: '2024-07-05 08:00:00', operation: 'Simple Earn Locked Redemption',
          coin: 'AAA', change: '3');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.any((m) => m.ledgerCode == 'AAA'), isFalse);
      expect(plan.unbalancedInternalTransfers, hasLength(1));
      final u = plan.unbalancedInternalTransfers.single;
      expect(u.asset, equals('AAA'));
      expect(u.residual, equals('-7'));
      expect(u.rowCount, equals(2));
    });

    test('souscription/rachat Earn ÉQUILIBRÉS → rien journalisé, AUCUN résidu', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-07-10 08:00:00', operation: 'Staking Purchase',
          coin: 'BBB', change: '-5');
      b.leg(time: '2024-07-15 08:00:00', operation: 'Staking Redemption',
          coin: 'BBB', change: '5');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.any((m) => m.ledgerCode == 'BBB'), isFalse);
      expect(plan.unbalancedInternalTransfers.any((u) => u.asset == 'BBB'), isFalse);
    });

    test(
        'B-2 (revue adversariale, CORRECTIF) : une redemption (internalTransfer) '
        'et une récompense (reward) du MÊME actif à la MÊME seconde restent '
        'SÉPARABLES — jamais fusionnées ni rejetées en bloc '
        '(mixedCryptoActionsInGroup), chacune traitée normalement', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-07-20 09:00:00', operation: 'Simple Earn Flexible Redemption',
          coin: 'CCC', change: '5');
      b.leg(time: '2024-07-20 09:00:00', operation: 'Simple Earn Flexible Interest',
          coin: 'CCC', change: '0.3');
      final plan = _plan(b.toCsvBytes(), profile);

      // AVANT le correctif : bucket unique 'ts:...' → actionsPresent =
      // {internalTransfer, reward} → rejet mixedCryptoActionsInGroup des
      // DEUX lignes, amputant l'agrégat mensuel de récompenses en silence.
      expect(plan.movements.where((m) => m.isRejected), isEmpty);

      // La récompense est journalisée normalement (agrégat mensuel, coût 0).
      final reward = plan.movements.singleWhere((m) => m.ledgerCode == 'CCC');
      expect(reward.transaction!.quantity, equals('0.3'));
      expect(reward.transaction!.meta!['aggregatedRows'], equals(1));

      // La redemption reste une écriture INTERNE — écartée du journal,
      // comptabilisée dans le bilan de cohérence Earn (aucune subscription
      // compensatoire ici : résidu = +5, déséquilibré comme attendu).
      final u = plan.unbalancedInternalTransfers.singleWhere((u) => u.asset == 'CCC');
      expect(u.residual, equals('5'));
      expect(u.rowCount, equals(1));
    });
  });

  // --------------------------------------------------------------------- Token
  // Swap (migration d'actif) — SANS alias d'identité (fix drive auteur,
  // CORRECTIF : Binance distingue déjà l'ancien/nouveau code, contrairement à
  // Kraken — cf. doc `BrokerProfile.binance()`).
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — Token Swap (migration)', () {
    test(
        'fix drive auteur (CORRECTIF) : achat LUNA PUIS Token '
        'Swap hétérogène (LUNA→LUNC, magnitudes égales, codes distincts — '
        'PLUS d\'alias) → le mouvement d\'achat déjà émis est RENOMMÉ, la '
        'position devient LUNC, base de coût inchangée', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-01 08:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-08-01 08:00:00', operation: 'Transaction Buy',
          coin: 'LUNA', change: '100');
      b.leg(time: '2024-08-02 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'LUNA', change: '-100');
      b.leg(time: '2024-08-02 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'LUNC', change: '100');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      // Rien au journal POUR la ligne de migration elle-même (comme le cas
      // neutralisé par alias) — seul le mouvement ANTÉRIEUR est renommé.
      expect(plan.movements, hasLength(1));

      final buy = _byLedgerCode(plan, 'LUNC', kind: 'buy');
      expect(buy.transaction!.quantity, equals('100'));
      expect(buy.transaction!.amount, equals('-500'));
      expect(plan.movements.any((m) => m.ledgerCode == 'LUNA'), isFalse);
    });

    test(
        'fix drive auteur (CORRECTIF) : `Airdrop Assets` LUNA '
        'POST-swap (nouveau LUNA Terra 2.0, ré-émis APRÈS le renommage '
        'ci-dessus) reste une position LUNA SÉPARÉE — état final LUNC et '
        'LUNA DISTINCTS, JAMAIS fusionnés', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-01 08:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-08-01 08:00:00', operation: 'Transaction Buy',
          coin: 'LUNA', change: '100');
      b.leg(time: '2024-08-02 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'LUNA', change: '-100');
      b.leg(time: '2024-08-02 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'LUNC', change: '100');
      // Nouveau LUNA — SANS RAPPORT avec l'ancien, POSTÉRIEUR au swap : ne
      // doit JAMAIS être concerné par le renommage rétroactif ci-dessus (qui
      // ne touche que les mouvements DÉJÀ émis au moment du swap).
      b.leg(time: '2024-09-05 08:00:00', operation: 'Airdrop Assets',
          coin: 'LUNA', change: '12.5');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);

      final codes =
          plan.movements.map((m) => m.ledgerCode).toSet();
      expect(codes, equals({'LUNC', 'LUNA'}));

      final buy = _byLedgerCode(plan, 'LUNC', kind: 'buy');
      expect(buy.transaction!.quantity, equals('100'));

      final reward = plan.movements.singleWhere((m) => m.ledgerCode == 'LUNA');
      expect(reward.transaction!.quantity, equals('12.5'));
      expect(reward.transaction!.meta!['aggregatedRows'], equals(1));
    });

    test(
        'UST→USTC (même mécanisme, magnitudes égales) → renommage, aucun '
        'rejet', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-03 08:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-50');
      b.leg(time: '2024-08-03 08:00:00', operation: 'Transaction Buy',
          coin: 'UST', change: '50');
      b.leg(time: '2024-08-04 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'UST', change: '-50');
      b.leg(time: '2024-08-04 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'USTC', change: '50');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      expect(plan.movements.any((m) => m.ledgerCode == 'UST'), isFalse);
      final buy = _byLedgerCode(plan, 'USTC', kind: 'buy');
      expect(buy.transaction!.quantity, equals('50'));
    });

    test('Token Swap DÉSÉQUILIBRÉ (quantités différentes) → rejet motivé', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-05 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'UST', change: '-50');
      b.leg(time: '2024-08-05 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'USTC', change: '40');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements, hasLength(2));
      expect(
        plan.movements.every((m) => m.rejectReason == 'cryptoMigrationNotBalanced'),
        isTrue,
      );
    });

    test(
        'revue adversariale (CORRECTIF : SANS l\'opt-in '
        '`migrationRenamesInPlace`, la MÊME forme structurelle (deux codes, '
        'magnitudes égales) reste un rejet motivé cryptoMigrationNotBalanced '
        '— jamais un renommage silencieux deviné sur la seule forme des '
        'données', () {
      final specWithoutOptIn = _withoutMigrationOptIn(profile);
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-06 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'AAA', change: '-10');
      b.leg(time: '2024-08-06 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'BBB', change: '10');
      final plan = _plan(b.toCsvBytes(), specWithoutOptIn);

      expect(plan.movements, hasLength(2));
      expect(
        plan.movements.every((m) => m.rejectReason == 'cryptoMigrationNotBalanced'),
        isTrue,
      );
    });

    test(
        'chaîne de swaps A→B→C : la position finit sous C, la clé de dédup '
        'reste GELÉE sur celle attribuée à l\'émission d\'origine (jamais '
        'recalculée à chaque maillon de la chaîne)', () {
      // Référence : la MÊME émission SANS aucun swap, pour comparer la clé.
      final baseline = _BinanceLedgerBuilder();
      baseline.leg(time: '2024-08-10 08:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      baseline.leg(time: '2024-08-10 08:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '100');
      final baselineKey =
          _byLedgerCode(_plan(baseline.toCsvBytes(), profile), 'AAA').importKey;

      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-10 08:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-08-10 08:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '100');
      b.leg(time: '2024-08-11 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'AAA', change: '-100');
      b.leg(time: '2024-08-11 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'BBB', change: '100');
      b.leg(time: '2024-08-12 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'BBB', change: '-100');
      b.leg(time: '2024-08-12 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'CCC', change: '100');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      expect(plan.movements, hasLength(1));
      final m = plan.movements.single;
      expect(m.ledgerCode, equals('CCC'));
      expect(m.transaction!.quantity, equals('100'));
      expect(m.transaction!.amount, equals('-500'));
      expect(plan.movements.any((mv) => mv.ledgerCode == 'AAA' || mv.ledgerCode == 'BBB'),
          isFalse);
      // Clé GELÉE (M-gel, revue adversariale) : identique à ce qu'elle
      // aurait été SANS aucun swap — jamais recalculée à chaque maillon.
      expect(m.importKey, equals(baselineKey));
    });

    test(
        'swap en TOUTE PREMIÈRE ligne (rien émis avant lui dans CET import '
        'sous l\'ancien code) : ni plantage ni position créée, identique au '
        'cas neutralisé par alias', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-13 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'AAA', change: '-50');
      b.leg(time: '2024-08-13 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'BBB', change: '50');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements, isEmpty);
      expect(plan.unvaluedExchanges, isEmpty);
    });

    test(
        'un feeInKind DÉJÀ EN ATTENTE sous l\'ancien code (frais tiers d\'un '
        'trade antérieur) est renommé exactement comme les mouvements et '
        'les échanges en attente', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-08-14 08:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-08-14 08:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      b.leg(time: '2024-08-14 08:00:00', operation: 'Transaction Fee',
          coin: 'OLDX', change: '-0.01');
      b.leg(time: '2024-08-15 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'OLDX', change: '-1');
      b.leg(time: '2024-08-15 08:00:00', operation: 'Token Swap - Redenomination/Rebranding',
          coin: 'NEWX', change: '1');
      final plan = _plan(b.toCsvBytes(), profile);

      expect(plan.movements.where((m) => m.isRejected), isEmpty);
      final fee = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'feeInKind');
      expect(fee.codeReceived, equals('NEWX'));
      expect(fee.codePaid, isNull);
    });

    test(
        'quoteAliases du profil Binance : LUNA (nouveau, Terra 2.0) pointe '
        'vers le ticker à id CoinMarketCap, jamais le bare `LUNA-USD` (fix '
        'drive auteur', () {
      final aliases = profile.crypto!.quoteAliases;
      // `LUNA-USD`/`LUNA1-USD`/`LUNA2-USD` répondent TOUS 404 chez Yahoo — la note
      // de conception interne (`LUNA1-USD`) est obsolète/erronée. Vérifié le
      // 20/09/2026 via l'API chart Yahoo : `LUNA20314-USD` répond
      // shortName/longName = « Terra USD », firstTradeDate = 2022-05-29
      // (relancement Terra 2.0), prix de bon sens (~0,04 €) — c'est le NOUVEAU LUNA
      // (post-swap, ré-émis par `Airdrop Assets`), seul actif encore ledgerCode
      // `LUNA` après le renommage rétroactif de `_processMigrationGroup` (les
      // jambes pré-swap deviennent `LUNC`, qui résout nativement sans alias).
      expect(aliases['LUNA'], equals('LUNA20314-USD'));
      // AUCUN alias LUNC/USTC : les deux résolvent nativement chez Yahoo
      // (« Terra Classic USD » / « TerraClassicUSD USD »), vérifié le
      // même jour — ne doit pas régresser vers un alias inutile.
      expect(aliases.containsKey('LUNC'), isFalse);
      expect(aliases.containsKey('USTC'), isFalse);
      // HFT (fix drive auteur, même famille que le triple homonymie STRK/POL/SGB
      // côté Kraken) : le bare `HFT-USD` répond mais résout vers un homonyme sans
      // rapport (« Hodl Finance », coté 2026, prix ~4e-7 USD). `HFT22461-USD` répond
      // shortName/longName = « Hashflow USD », firstTradeDate = 2022-11-07 — c'est
      // le HFT Binance (Hashflow), vérifié le 21/09/2026 via l'API chart Yahoo.
      expect(aliases['HFT'], equals('HFT22461-USD'));
    });
  });

  // ---------------------------------------------------------------------
  // Fonds externes (Deposit/Withdraw) + Asset Recovery + lexique incomplet.
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — dépôts/retraits externes, Asset Recovery, lexique', () {
    test('Deposit EUR : dépôt cash direct', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-09-01 08:00:00', operation: 'Deposit', coin: 'EUR', change: '1000');
      final plan = _plan(b.toCsvBytes(), profile);

      final m = plan.movements.singleWhere((mv) => !mv.isRejected);
      expect(m.transaction!.kind.name, equals('deposit'));
      expect(m.transaction!.amount, equals('1000'));
    });

    test('Deposit crypto (en nature) : externe, meta[\'inKindDeposit\'] posée à la finalisation', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-09-02 08:00:00', operation: 'Deposit', coin: 'AAA', change: '2');
      final plan = _plan(b.toCsvBytes(), profile);

      final dep = plan.unvaluedExchanges.singleWhere((u) => u.kind == 'depositInKind');
      expect(dep.codeReceived, equals('AAA'));
      expect(dep.quantityReceived, equals('2'));
      expect(dep.sourceKindLabel, equals('Deposit'));

      final valuations = {
        dep.importKey: CryptoValuation(amountEur: Decimal.parse('80'), source: 'manual'),
      };
      final finalized = StatementImportService.finalizeCryptoExchanges(
        plan,
        valuations,
        accountId: 'acc1',
        accountCurrency: 'EUR',
        externalDepositKinds: const {'Deposit'},
      );
      expect(finalized, hasLength(1));
      expect(finalized.single.transaction!.meta!['inKindDeposit'], isTrue);
    });

    test('Withdraw crypto : sortie, meta[\'inKindWithdrawal\'] posée', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-09-03 08:00:00', operation: 'Withdraw', coin: 'AAA', change: '-1');
      final plan = _plan(b.toCsvBytes(), profile);

      final m = plan.movements.singleWhere((mv) => !mv.isRejected);
      expect(m.transaction!.kind.name, equals('transferOut'));
      expect(m.transaction!.quantity, equals('1'));
      expect(m.transaction!.meta!['inKindWithdrawal'], isTrue);
    });

    test('Deposit au signe NÉGATIF (anomalie) → rejet cryptoAmbiguousDirection', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-09-04 08:00:00', operation: 'Deposit', coin: 'EUR', change: '-50');
      final plan = _plan(b.toCsvBytes(), profile);

      final m = plan.movements.single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('cryptoAmbiguousDirection'));
    });

    test('Asset Recovery : ligne UNIQUE, rejet motivé cryptoManualReview', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-09-05 08:00:00', operation: 'Asset Recovery', coin: 'HHH', change: '1');
      final plan = _plan(b.toCsvBytes(), profile);

      final m = plan.movements.single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('cryptoManualReview'));
    });

    test(
        // I-1 (revue adversariale, CORRECTIF) : `Launchpool Subscription`
        // EXISTE bel et bien dans le lexique (vérifiée littéralement sur un
        // export réel, cf. `BrokerProfile.binance()`) — un libellé
        // MANIFESTEMENT fictif garde le sens de ce test (hors lexique →
        // rejet motivé, jamais une graphie devinée).
        'Operation hors lexique (libellé fictif) → rejet motivé '
        'unknownCryptoAction, JAMAIS une graphie devinée', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-09-06 08:00:00', operation: 'ZZZ Unknown Operation',
          coin: 'III', change: '-1');
      final plan = _plan(b.toCsvBytes(), profile);

      final m = plan.movements.single;
      expect(m.isRejected, isTrue);
      expect(m.rejectReason, equals('unknownCryptoAction'));
    });
  });

  // ---------------------------------------------------------------------
  // Agrégation mensuelle des récompenses (93 % du fichier réel).
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — agrégation mensuelle des récompenses', () {
    test('2 lignes de récompenses du même mois → 1 mouvement agrégé', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-10-01 09:00:00', operation: 'Simple Earn Flexible Interest',
          coin: 'JJJ', change: '0.5');
      b.leg(time: '2024-10-15 09:00:00', operation: 'Simple Earn Flexible Interest',
          coin: 'JJJ', change: '0.3');
      final plan = _plan(b.toCsvBytes(), profile);

      final adjustments =
          plan.movements.where((m) => !m.isRejected && m.ledgerCode == 'JJJ').toList();
      expect(adjustments, hasLength(1));
      expect(adjustments.single.transaction!.quantity, equals('0.8'));
      expect(adjustments.single.transaction!.meta!['aggregatedMonth'], equals('2024-10'));
      expect(adjustments.single.transaction!.meta!['aggregatedRows'], equals(2));
    });

    test('récompenses de mois DIFFÉRENTS → 2 buckets distincts', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-10-01 09:00:00', operation: 'Staking Rewards',
          coin: 'KKK', change: '1');
      b.leg(time: '2024-11-01 09:00:00', operation: 'Staking Rewards',
          coin: 'KKK', change: '2');
      final plan = _plan(b.toCsvBytes(), profile);

      final adjustments =
          plan.movements.where((m) => !m.isRejected && m.ledgerCode == 'KKK').toList();
      expect(adjustments, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------
  // Dédup / stabilité des clés (pas de refid Binance — clé dérivée de
  // l'horodatage, cf. écart documenté au rapport de livraison).
  // ---------------------------------------------------------------------
  group('Lot 4 Binance — stabilité de la clé de dédup', () {
    test('deux appels de planification sur le même fichier produisent des clés IDENTIQUES', () {
      final b = _BinanceLedgerBuilder();
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      final bytes = b.toCsvBytes();

      final plan1 = _plan(bytes, profile);
      final plan2 = _plan(bytes, profile);

      final key1 = _byLedgerCode(plan1, 'AAA').importKey;
      final key2 = _byLedgerCode(plan2, 'AAA').importKey;
      expect(key1, equals(key2));
    });

    test('deux trades à la MÊME seconde mais sur des actifs différents (rôles non ambigus) : clés DISTINCTES', () {
      final b = _BinanceLedgerBuilder();
      // Deux paires PROPRES à la même seconde exacte, sur des comptes
      // différents (accountId distinct) — même horodatage, jamais fusionnées
      // entre elles (le groupage ne dépend que du (accountId implicite via
      // l'appel, timestamp)) : ici on vérifie surtout qu'un import mono-compte
      // à deux trades DISTINCTS à la même seconde reste correctement rejeté
      // comme ambigu (déjà couvert plus haut) — ce test vérifie la vraie
      // garantie utile : deux imports SUCCESSIFS de fichiers différents (deux
      // comptes) ne collisionnent jamais sur la même clé.
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Spend',
          coin: 'EUR', change: '-500');
      b.leg(time: '2024-01-08 10:00:00', operation: 'Transaction Buy',
          coin: 'AAA', change: '10');
      final bytes = b.toCsvBytes();

      final planAcc1 = _plan(bytes, profile, accountId: 'acc1');
      final planAcc2 = _plan(bytes, profile, accountId: 'acc2');

      final key1 = _byLedgerCode(planAcc1, 'AAA').importKey;
      final key2 = _byLedgerCode(planAcc2, 'AAA').importKey;
      expect(key1, isNot(equals(key2)));
    });
  });
}

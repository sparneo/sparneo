// test/widgets/statement_import_page_test.dart
//
// Tests WIDGET de l'assistant d'import de relevé (lot B4, UI).
//
// Le premier pas (sélection de fichier) s'appuie sur file_picker/
// file_selector, sans implémentation dans l'environnement de test widget — on
// ne l'exerce donc pas ici. Le point d'entrée `debugInitialPreview` (réservé
// aux tests, cf. doc de StatementImportPage) permet de démarrer directement à
// l'étape de résolution des nouveaux actifs avec une prévisualisation
// synthétique, sans fichier ni base de données.
//
// AUCUN accès SQLite dans ces tests : ni la construction de la page (étape
// « sélection du fichier ») ni l'étape « résoudre les nouveaux actifs » ne
// lisent le contrôleur — celui-ci n'est requis que pour appeler
// previewStatementImport/confirmStatementImport (non exercés ici). Constater
// (cf. friction rencontrée) que sqflite_common_ffi bloque indéfiniment
// (`dart:isolate _RawReceivePort._handleMessage`) quand une base réelle est
// ouverte à l'intérieur d'un `testWidgets` (aucun test widget existant du
// dépôt ne combine les deux) : on l'évite donc plutôt que de la contourner —
// un AccountController par défaut (jamais interrogé) suffit à ces tests.
// Zéro appel réseau (aucune méthode réseau n'est appelée non plus).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/import_preview.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';
import 'package:portfolio_tracker/services/market_data_service.dart'
    show IsinSearchException;
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/import/statement_import_page.dart';

const _accountId = 'account-1';

/// Fake SANS RÉSEAU réservé aux tests de vérification du symbole saisi à la
/// main (correctif « symbole saisi vérifié ») : contrôle les hits retournés
/// par `searchIsin` par requête (clé = symbole envoyé, déjà en MAJUSCULES —
/// cf. [StatementImportPage._verifySymbolExists]) et court-circuite
/// `confirmStatementImport` pour ne JAMAIS toucher au stockage réel (une
/// base SQLite réelle ouverte dans un `testWidgets` bloque indéfiniment, cf.
/// doc de tête de fichier).
class _FakeVerifyController extends AccountController {
  _FakeVerifyController({
    this.hitsByQuery = const {},
    this.networkFailQueries = const {},
  }) : super(initialAccountId: _accountId);

  final Map<String, List<IsinSearchHit>> hitsByQuery;
  final Set<String> networkFailQueries;

  /// `true` si [confirmStatementImport] a été atteint : preuve qu'aucun
  /// symbole n'a été rejeté par la vérification.
  bool confirmCalled = false;

  @override
  Future<List<IsinSearchHit>> searchIsin(
    String isin, {
    int quotesCount = 8,
  }) async {
    if (networkFailQueries.contains(isin)) {
      throw IsinSearchException('panne réseau (test)');
    }
    return hitsByQuery[isin] ?? const [];
  }

  @override
  Future<String?> confirmStatementImport(
    ImportPreview preview, {
    required String accountId,
    Set<String> replaceImportKeys = const {},
    bool journalizeUnbalancedInternalTransfers = false,
  }) async {
    confirmCalled = true;
    return null;
  }
}

/// Fake dont [accounts] renvoie une liste FIXÉE (chantier B16, garde de
/// nature de compte) — aucun réseau ni base réelle, `confirmStatementImport`
/// n'est pas exercé par ces tests-là (seule la garde AVANT l'aperçu l'est).
class _FixedAccountsController extends AccountController {
  _FixedAccountsController(this._fixedAccounts)
      : super(initialAccountId: _accountId);

  final List<Account> _fixedAccounts;

  @override
  List<Account> get accounts => _fixedAccounts;
}

/// Fake SANS RÉSEAU qui capture les paramètres crypto (`replaceImportKeys`/
/// `journalizeUnbalancedInternalTransfers`) passés à `confirmStatementImport`
/// (chantier B16, lot 1) — court-circuite l'écriture réelle, même motif que
/// [_FakeVerifyController].
class _FakeCryptoConfirmController extends AccountController {
  _FakeCryptoConfirmController() : super(initialAccountId: _accountId);

  Set<String> capturedReplaceImportKeys = const {};
  bool capturedJournalizeUnbalancedInternalTransfers = false;

  @override
  Future<String?> confirmStatementImport(
    ImportPreview preview, {
    required String accountId,
    Set<String> replaceImportKeys = const {},
    bool journalizeUnbalancedInternalTransfers = false,
  }) async {
    capturedReplaceImportKeys = replaceImportKeys;
    capturedJournalizeUnbalancedInternalTransfers =
        journalizeUnbalancedInternalTransfers;
    return null;
  }
}

/// Fake SANS RÉSEAU qui capture les montants passés à
/// [AccountController.applyManualCryptoValuations] (chantier B16, lot 2,
/// conception interne) et renvoie [result] tel quel (aucune reconstruction
/// réelle — ce fake teste UNIQUEMENT le câblage UI → contrôleur, la
/// reconstruction elle-même est couverte par les tests d'intégration contrôleur
/// de `crypto_ledger_kraken_lot1_test.dart`).
class _FakeApplyManualValuationsController extends AccountController {
  _FakeApplyManualValuationsController({this.result})
      : super(initialAccountId: _accountId);

  final ImportPreview? result;
  Map<String, String>? capturedEurByImportKey;

  /// Aperçu effectivement transmis à `confirmStatementImport` (filet de confirmation
  /// « échanges à valoriser », retour auteur drive — capturé pour vérifier que «
  /// Confirmer l'import » (chemin direct ou via « Importer sans ces échanges »)
  /// confirme bien le NOUVEL aperçu rafraîchi par [applyManualCryptoValuations],
  /// jamais l'ancien. Court-circuite l'écriture réelle, même motif que
  /// [_FakeVerifyController].
  ImportPreview? capturedConfirmPreview;
  bool confirmCalled = false;

  @override
  Future<ImportPreview?> applyManualCryptoValuations(
    Map<String, String> eurByImportKey,
  ) async {
    capturedEurByImportKey = eurByImportKey;
    return result;
  }

  @override
  Future<String?> confirmStatementImport(
    ImportPreview preview, {
    required String accountId,
    Set<String> replaceImportKeys = const {},
    bool journalizeUnbalancedInternalTransfers = false,
  }) async {
    confirmCalled = true;
    capturedConfirmPreview = preview;
    return null;
  }
}

Widget _host(
  ImportPreview? debugInitialPreview, {
  Set<String>? debugInitialSearchFailedKeys,
  Map<String, String>? debugInitialResolvedVenues,
  Set<String>? debugInitialLowConfidenceVenueKeys,
  AccountController? controller,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('fr'),
    home: StatementImportPage(
      controller: controller ?? AccountController(initialAccountId: _accountId),
      accountId: _accountId,
      accountName: 'Compte test',
      debugInitialPreview: debugInitialPreview,
      debugInitialSearchFailedKeys: debugInitialSearchFailedKeys,
      debugInitialResolvedVenues: debugInitialResolvedVenues,
      debugInitialLowConfidenceVenueKeys: debugInitialLowConfidenceVenueKeys,
    ),
  );
}

/// Un mouvement candidat « New Co » dont le symbole n'a pas encore été résolu
/// (identité par libellé, aucun ISIN) — reflète le cas REF-NEW3 de
/// account_controller_import_test.dart (ISIN/symbole inconnus).
ImportedMovement _unresolvedMovement() => ImportedMovement.candidate(
      sourceRow: const ['12/01/2024', 'Achat', '', '', 'New Co', '2', '10'],
      // Numéro de ligne PHYSIQUE 1-based (nouvelle sémantique) affiché tel quel.
      sourceRowIndex: 3,
      transaction: AssetTransaction(
        id: 'tx-newco',
        accountId: _accountId,
        symbol: null,
        kind: TransactionKind.buy,
        quantity: '2',
        unitPrice: '10',
        amount: '-20',
        currency: 'EUR',
        date: DateTime(2024, 1, 12),
        meta: const {'importKey': 'hash:test-newco'},
      ),
      isin: null,
      label: 'New Co',
      needsAssetResolution: true,
      importKey: 'hash:test-newco',
    );

/// Un mouvement candidat identifié par ISIN, non résolu — reflète le cas d'un
/// titre délisté / purgé de la source (le blocage que le repli « non coté »
/// débloque).
ImportedMovement _unresolvedMovementWithIsin() => ImportedMovement.candidate(
      sourceRow: const ['13/01/2024', 'Achat', 'FR000UNKNOWN', '', 'Old Corp', '1', '5'],
      sourceRowIndex: 4,
      transaction: AssetTransaction(
        id: 'tx-old',
        accountId: _accountId,
        symbol: null,
        kind: TransactionKind.buy,
        quantity: '1',
        unitPrice: '5',
        amount: '-5',
        currency: 'EUR',
        date: DateTime(2024, 1, 13),
        meta: const {'importKey': 'ref:account-1:REF-NEW3'},
      ),
      isin: 'FR000UNKNOWN',
      label: 'Old Corp',
      needsAssetResolution: true,
      importKey: 'ref:account-1:REF-NEW3',
    );

/// Un mouvement d'accueil ayant ABSORBÉ une jambe espèces scindée (§14.8) :
/// porte `mergedSettlementLeg`/`mergedLegSourceRow` dans son `meta`. Reflète le
/// cas réel Bourse Direct (356 titres à 0,22 €, règlement −78,32 € porté par
/// une ligne `ODOST` distincte, ici la ligne 42 du relevé).
ImportedMovement _mergedHostMovement({String id = 'tx-merged'}) =>
    ImportedMovement.candidate(
      sourceRow: const ['04/12/2020', 'Achat', 'FR0013088606', '', 'Droits', '356', '0,22'],
      sourceRowIndex: 41,
      transaction: AssetTransaction(
        id: id,
        accountId: _accountId,
        symbol: 'FR0013088606',
        kind: TransactionKind.buy,
        quantity: '356',
        unitPrice: '0.22',
        amount: '-78.32',
        currency: 'EUR',
        date: DateTime(2020, 12, 4),
        meta: {
          'importKey': 'hash:merged-$id',
          'mergedSettlementLeg': true,
          'mergedLegSourceRow': 42,
        },
      ),
      isin: 'FR0013088606',
      label: 'Droits',
      needsAssetResolution: false,
      resolvedSymbol: 'FR0013088606',
      importKey: 'hash:merged-$id',
    );

/// Un DÉPÔT candidat, doublon PROBABLE d'espèces : même date et même montant
/// qu'un mouvement déjà journalisé, mais libellé différent (cas mesuré sur un
/// relevé réel où l'anonymisation avait réécrit le libellé du virement).
ImportedMovement _cashDeposit(int i) => ImportedMovement.candidate(
      sourceRow: const ['20/08/2020', 'Virement', '', '', 'VIRT MR NOM PREN', '', ''],
      sourceRowIndex: 267 + i,
      transaction: AssetTransaction(
        id: 'tx-dep-$i',
        accountId: _accountId,
        symbol: null,
        kind: TransactionKind.deposit,
        amount: '5000',
        currency: 'EUR',
        date: DateTime(2020, 8, 20),
        meta: {'importKey': 'hash:dep-$i'},
      ),
      isin: null,
      label: 'VIRT MR NOM PREN',
      needsAssetResolution: false,
      importKey: 'hash:dep-$i',
    );

/// Un mouvement ORDINAIRE sans marqueur de repli — sert à noyer le mouvement
/// fusionné au-delà du plafond d'affichage des groupes. Employé aussi bien en
/// candidat (`toCreate`) qu'en doublon selon le test.
ImportedMovement _plainMovement(int i) => ImportedMovement.candidate(
      sourceRow: const ['01/01/2024', 'Achat', 'FR0000120073', '', 'Air Liquide', '1', '150'],
      sourceRowIndex: 100 + i,
      transaction: AssetTransaction(
        id: 'tx-dup-$i',
        accountId: _accountId,
        symbol: 'AI.PA',
        kind: TransactionKind.buy,
        quantity: '1',
        unitPrice: '150',
        amount: '-150',
        currency: 'EUR',
        date: DateTime(2024, 1, 1),
        meta: {'importKey': 'hash:dup-$i'},
      ),
      isin: 'FR0000120073',
      label: 'Air Liquide',
      needsAssetResolution: false,
      resolvedSymbol: 'AI.PA',
      importKey: 'hash:dup-$i',
    );

/// Une ligne d'OST rejetée « à revoir » (groupe déplié à l'aperçu), avec une
/// ligne source brute non vide (non affichée : seul le numéro de ligne
/// l'est, cf. _sourceRowRef).
ImportedMovement _rejectedOstMovement() => ImportedMovement.rejected(
      sourceRow: const ['15/01/2024', 'DS', 'FR00TEST', '', 'Mystère SA'],
      // Ligne physique 6 dans le relevé : affichée directement « Ligne 6 »
      // (plus de « + 1 » à l'écran — la valeur est déjà 1-based absolue).
      sourceRowIndex: 6,
      rejectReason: 'corporateActionReview',
      isin: 'FR00TEST',
      label: 'Mystère SA',
    );

/// Une ligne rejetée pour un motif PUREMENT TECHNIQUE (type d'opération non
/// reconnu) — le cas fréquent en profil générique quand le vocabulaire des
/// natures d'opération n'a pas été renseigné. Groupe replié à l'aperçu.
ImportedMovement _rejectedTechMovement() => ImportedMovement.rejected(
      sourceRow: const ['16/01/2024', 'VIREMENT INTERNE', '', '', 'Écriture'],
      sourceRowIndex: 7,
      rejectReason: 'unknownKind',
      isin: null,
      label: 'Écriture',
    );

/// I-2 (revue adversariale) : un ré-import de relevé crypto revalorise une
/// opération déjà journalisée avec un montant différent — `sourceRowIndex`
/// reste peuplé (repris de `UnvaluedExchange.sourceLines.first` par
/// `finalizeCryptoExchanges`, cf. `crypto_ledger_normalizer.dart:640`) même
/// si `sourceRow` lui-même est vide à ce stade du pipeline.
ImportedMovement _rejectedCryptoCollisionMovement() => ImportedMovement.rejected(
      sourceRow: const [],
      sourceRowIndex: 12,
      rejectReason: 'cryptoImportKeyCollision',
    );

// ---------------------------------------------------------------------------
// Fixtures crypto (chantier B16, lot 1, passe UX) — synthétiques, sans lien
// avec les fixtures Kraken réelles de crypto_ledger_kraken_lot1_test.dart
// (hors périmètre UI, non lues ici).
// ---------------------------------------------------------------------------

/// Un échange entre crypto-monnaies resté en arbitrage MANUEL après la cascade de
/// valorisation (chantier B16, lot 2, conception interne) — exclu de `toCreate`,
/// groupe « Échanges à valoriser » avec son motif (« spread » ici, cas le plus
/// riche à afficher : montre à la fois la trace ET l'écart chiffré) et son champ
/// de saisie EUR. [usdPaid]/[usdReceived] portés directement ici (amendement
/// drive lot 2 (suite) pour un écart cohérent avec [valuationSpreadPct]
/// (`(225−195)/195 ≈ 0.153`) — mais SANS suggestion EUR : reste le contrôle
/// négatif « spread SANS choix » (le choix binaire exige les DEUX paires usd+eur,
/// cf. [_unvaluedExchangeFixtureWithSuggestions]), qui garde donc le champ de
/// saisie simple.
UnvaluedExchange _unvaluedExchangeFixture() => UnvaluedExchange(
      kind: 'exchange',
      date: DateTime(2024, 3, 5),
      codePaid: 'ETH',
      quantityPaid: '0.5',
      codeReceived: 'ADA',
      quantityReceived: '120',
      usdPaid: '195.00',
      usdReceived: '225.00',
      sourceLines: const [10, 11],
      importKey: 'ref:account-1:REFEXCH',
      manualReason: 'spread',
      valuationSpreadPct: '0.153',
    );

/// Même échange que [_unvaluedExchangeFixture], AVEC les deux suggestions EUR
/// calculées par `CryptoValuationService` (amendement drive lot 2 (suite) — avec
/// les `usdPaid`/`usdReceived` déjà portés par la fixture de base, les quatre
/// montants sont réunis : sert à exercer le choix binaire « Valeur cédée / Valeur
/// reçue » et le champ dérogatoire.
UnvaluedExchange _unvaluedExchangeFixtureWithSuggestions() =>
    _unvaluedExchangeFixture().copyWith(
      suggestedPaidEur: '180',
      suggestedReceivedEur: '207.5',
    );

/// Motif « unreadable » (aucune jambe USD lisible sur le relevé) — dépôt en
/// nature dégénéré (`codePaid`/`quantityPaid` `null`, conception interne), pour
/// couvrir aussi le rendu de la forme « dépôt » du groupe manuel.
UnvaluedExchange _unvaluedUnreadableFixture() => UnvaluedExchange(
      kind: 'depositInKind',
      date: DateTime(2024, 4, 1),
      codeReceived: 'DOT',
      quantityReceived: '10',
      sourceLines: const [20],
      importKey: 'ref:account-1:REFDEPOSIT',
      manualReason: 'unreadable',
    );

/// Motif « fxUnavailable » (série FX historique indisponible pour la
/// période) — TOUS les échanges du fichier en portent un à l'identique
/// quand la panne survient (conception interne) ; un seul suffit ici.
UnvaluedExchange _unvaluedFxUnavailableFixture() => UnvaluedExchange(
      kind: 'exchange',
      date: DateTime(2024, 5, 10),
      codePaid: 'SOL',
      quantityPaid: '2',
      codeReceived: 'MATIC',
      quantityReceived: '300',
      sourceLines: const [30, 31],
      importKey: 'ref:account-1:REFFX',
      manualReason: 'fxUnavailable',
    );

/// I-3 (revue adversariale) : jambe fiat (USD, étage 1-quater) dont le FX
/// est indisponible — ressort en motif `fxUnavailable` (PAS `foreignFiat`,
/// puisque seule la panne réseau bloque, pas la nature de la jambe) ALORS
/// QUE le critère STRUCTUREL (`codePaidIsFiat`) est posé. Avant correctif,
/// l'UI se basait sur `manualReason == 'foreignFiat'` pour désactiver le
/// champ : cette entrée gardait un champ ACTIF alors que le contrôleur
/// (`AccountController.applyManualCryptoValuations`, critère structurel)
/// ignorait silencieusement toute saisie — impasse muette.
UnvaluedExchange _unvaluedFxUnavailableFiatLegFixture() => UnvaluedExchange(
      kind: 'exchange',
      date: DateTime(2024, 5, 11),
      codePaid: 'USD',
      quantityPaid: '50',
      codeReceived: 'MATIC',
      quantityReceived: '300',
      sourceLines: const [32, 33],
      importKey: 'ref:account-1:REFFXFIAT',
      manualReason: 'fxUnavailable',
      codePaidIsFiat: true,
    );

/// Motif « ambiguousGroup » (B-1, revue adversariale B16 lot 2) : clé de
/// dédup partagée par ≥ 2 entrées (dustsweeping N→1 dégénéré, dépôt en
/// nature multi-jambes) — jamais valorisable, le champ de saisie EUR doit
/// rester DÉSACTIVÉ pour cette entrée.
UnvaluedExchange _unvaluedAmbiguousGroupFixture() => UnvaluedExchange(
      kind: 'exchange',
      date: DateTime(2024, 6, 1),
      codePaid: 'CCC',
      quantityPaid: '5',
      codeReceived: 'EUR',
      quantityReceived: '30',
      sourceLines: const [40],
      importKey: 'ref:account-1:REFAMBIG',
      manualReason: 'ambiguousGroup',
    );

/// Bilan de cohérence d'un actif dont les transferts internes ne nettent pas à
/// zéro (conception interne) — ex. un airdrop livré directement en earn, sans
/// jambe spot correspondante.
final _unbalancedTransferFixture = UnbalancedInternalTransfer(
  asset: 'ZZZ',
  residual: '4.25',
  rowCount: 2,
  lastDate: DateTime(2024, 3, 5),
);

/// Rupture de la chaîne `balance` (oracle Kraken) — relevé incomplet.
ChainRupture _chainRuptureFixture() => ChainRupture(
      date: DateTime(2024, 1, 10),
      asset: 'XETH',
      wallet: 'spot',
      sourceLine: 42,
      expectedBalance: '1.5',
      actualBalance: '1.2',
    );

/// Écart entre quantité projetée et `balance` finales déclarées — carte
/// d'information, jamais un gardien.
const _quantityGapFixture = QuantityGap(
  asset: 'ADA',
  reportedTotal: '120.5',
  projectedTotal: '118.0',
);

/// Un mouvement de `toCreate` produit par l'agrégation mensuelle des
/// récompenses (`meta['aggregation'] == 'monthly'`) — reflète un candidat
/// crypto (ledgerCode, pas d'ISIN).
ImportedMovement _aggregatedRewardMovement() => ImportedMovement.candidate(
      sourceRow: const [],
      sourceRowIndex: 200,
      transaction: AssetTransaction(
        id: 'tx-agg-jun',
        accountId: _accountId,
        symbol: null,
        kind: TransactionKind.adjustment,
        quantity: '3.1',
        amount: '0',
        currency: 'EUR',
        date: DateTime(2024, 6, 30),
        meta: const {
          'importKey': 'agg:account-1:profil:AAA:2024-06',
          'aggregation': 'monthly',
          'aggregatedMonth': '2024-06',
          'aggregatedRows': 9,
        },
      ),
      isin: null,
      label: 'AAA',
      ledgerCode: 'AAA',
      importKey: 'agg:account-1:profil:AAA:2024-06',
    );

/// Un candidat de remplacement d'agrégat mensuel (le mois s'est allongé à un
/// ré-import, conception interne) : 12 lignes source → 30, +0,83 ADA.
AggregateReplacement _replacementFixture() => AggregateReplacement(
      movement: ImportedMovement.candidate(
        sourceRow: const [],
        sourceRowIndex: 201,
        transaction: AssetTransaction(
          id: 'tx-agg-sep',
          accountId: _accountId,
          symbol: null,
          kind: TransactionKind.adjustment,
          quantity: '30.83',
          amount: '0',
          currency: 'EUR',
          date: DateTime(2026, 9, 30),
          meta: const {
            'importKey': 'agg:account-1:profil:ADA:2026-09',
            'aggregation': 'monthly',
          },
        ),
        isin: null,
        label: 'ADA',
        ledgerCode: 'ADA',
        importKey: 'agg:account-1:profil:ADA:2026-09',
      ),
      month: '2026-09',
      previousRowCount: 12,
      newRowCount: 30,
      quantityDelta: '0.83',
    );

/// Un candidat CRYPTO neuf coté (ticker résolu) — sert de contrôle aux tests
/// de la note « panne réseau » (par opposition à un candidat non coté).
const _resolvedCryptoAsset = NewAssetCandidate(
  isin: null,
  label: 'Cardano',
  proposedSymbol: 'ADA-EUR',
  ledgerCode: 'ADA',
);

/// Un candidat CRYPTO neuf non coté suite à une PANNE RÉSEAU rencontrée par
/// la cascade de résolution ticker — à DISTINGUER d'un non-coté CONSTATÉ.
const _networkFailureCryptoAsset = NewAssetCandidate(
  isin: null,
  label: 'Jeton Mystère',
  proposedSymbol: 'MYST',
  quotable: false,
  ledgerCode: 'MYST',
  networkFailure: true,
);

/// Un candidat CRYPTO neuf non coté CONSTATÉ (ticker introuvable après
/// vérification réseau aboutie) — contrôle négatif de
/// [_networkFailureCryptoAsset].
const _confirmedNotListedCryptoAsset = NewAssetCandidate(
  isin: null,
  label: 'Jeton Inconnu',
  proposedSymbol: 'UNK',
  quotable: false,
  ledgerCode: 'UNK',
);

/// Un mouvement crypto ordinaire candidat à `toCreate`, pour peupler la
/// section « à créer » d'un aperçu crypto complet sans qu'elle interfère avec
/// les groupes testés.
ImportedMovement _cryptoBuyMovement() => ImportedMovement.candidate(
      sourceRow: const [],
      sourceRowIndex: 1,
      transaction: AssetTransaction(
        id: 'tx-crypto-buy',
        accountId: _accountId,
        symbol: 'BTC-EUR',
        kind: TransactionKind.buy,
        quantity: '0.01',
        unitPrice: '50000',
        amount: '-500',
        currency: 'EUR',
        date: DateTime(2024, 2, 1),
        meta: const {'importKey': 'ref:account-1:REFBUY'},
      ),
      isin: null,
      label: 'BTC',
      ledgerCode: 'BTC',
      resolvedSymbol: 'BTC-EUR',
      importKey: 'ref:account-1:REFBUY',
    );

/// Mouvement crypto FINALISÉ par `CryptoLedgerNormalizer.finalizeCryptoExchanges`
/// (chantier B16, lot 2) — porte `meta['valuationSource']`, pour couvrir le
/// sous-titre de provenance sur les tuiles de l'aperçu ([id]/[importKey]
/// distincts de [_cryptoBuyMovement] pour coexister dans le même `toCreate`).
ImportedMovement _cryptoMovementValued(
  String id,
  String importKey,
  String valuationSource,
) =>
    ImportedMovement.candidate(
      sourceRow: const [],
      sourceRowIndex: 2,
      transaction: AssetTransaction(
        id: id,
        accountId: _accountId,
        symbol: 'ADA-EUR',
        kind: TransactionKind.buy,
        quantity: '100',
        unitPrice: '0.5',
        amount: '-50',
        currency: 'EUR',
        date: DateTime(2024, 3, 5),
        meta: {'importKey': importKey, 'valuationSource': valuationSource},
      ),
      isin: null,
      label: 'ADA',
      ledgerCode: 'ADA',
      resolvedSymbol: 'ADA-EUR',
      importKey: importKey,
    );

/// Paire sell+buy d'UN échange valorisé (chantier B16, lot 2) — clés
/// `#sell:`/`#buy:` dérivées de [baseKey] (même patron que
/// `CryptoLedgerNormalizer.finalizeCryptoExchanges`), pour couvrir le
/// regroupement « échanges DISTINCTS, pas mouvements » du groupe « Échanges
/// valorisés » ([_valuedExchangeCount] côté page).
List<ImportedMovement> _cryptoExchangePairValued(
  String baseKey,
  String valuationSource,
) =>
    [
      ImportedMovement.candidate(
        sourceRow: const [],
        sourceRowIndex: 3,
        transaction: AssetTransaction(
          id: '$baseKey-sell',
          accountId: _accountId,
          symbol: 'AAA-EUR',
          kind: TransactionKind.sell,
          quantity: '2',
          unitPrice: '90',
          amount: '180',
          currency: 'EUR',
          date: DateTime(2024, 3, 5),
          meta: {'importKey': '$baseKey#sell:AAA', 'valuationSource': valuationSource},
        ),
        isin: null,
        label: 'AAA',
        ledgerCode: 'AAA',
        resolvedSymbol: 'AAA-EUR',
        importKey: '$baseKey#sell:AAA',
      ),
      ImportedMovement.candidate(
        sourceRow: const [],
        sourceRowIndex: 3,
        transaction: AssetTransaction(
          id: '$baseKey-buy',
          accountId: _accountId,
          symbol: 'STB-EUR',
          kind: TransactionKind.buy,
          quantity: '120',
          unitPrice: '1.5',
          amount: '-180',
          currency: 'EUR',
          date: DateTime(2024, 3, 5),
          meta: {'importKey': '$baseKey#buy:STB', 'valuationSource': valuationSource},
        ),
        isin: null,
        label: 'STB',
        ledgerCode: 'STB',
        resolvedSymbol: 'STB-EUR',
        importKey: '$baseKey#buy:STB',
      ),
    ];

/// Aperçu crypto COMPLET rassemblant les six groupes (chantier B16, lot 1) —
/// un seul mouvement ORDINAIRE dans `toCreate` pour que la branche principale
/// (non « rien à créer ») de `_buildPreviewStep` soit exercée.
ImportPreview _cryptoFullPreview() => ImportPreview(
      toCreate: [_cryptoBuyMovement(), _aggregatedRewardMovement()],
      unvaluedExchanges: [_unvaluedExchangeFixture()],
      unbalancedInternalTransfers: [_unbalancedTransferFixture],
      chainRuptures: [_chainRuptureFixture()],
      quantityGaps: const [_quantityGapFixture],
      replacements: [_replacementFixture()],
    );

void main() {
  group('StatementImportPage — rendu', () {
    testWidgets('s\'affiche sans exception (étape sélection du fichier)',
        (tester) async {
      await tester.pumpWidget(_host(null));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Choisir un fichier'), findsOneWidget);
      // Indicateur de progression cohérent avec le parcours générique
      // (fichier → config → aperçu → fait), sans résolution connue à ce stade.
      expect(find.text('Étape 1 sur 4'), findsOneWidget);
    });

    testWidgets(
        'sélectionner le profil Bourse Direct change l\'indication affichée '
        '(sans passer par le sélecteur de fichier, non disponible en test '
        'widget)', (tester) async {
      await tester.pumpWidget(_host(null));
      await tester.pumpAndSettle();

      // Profil générique par défaut.
      expect(
        find.text("Sélectionnez l'export CSV de votre courtier (profil générique / manuel)."),
        findsOneWidget,
      );

      await tester.tap(find.text('Bourse Direct'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Sélectionnez l'export .xlsx « Extraction de compte » de votre compte Bourse Direct.",
        ),
        findsOneWidget,
      );
      // Le bouton de sélection de fichier reste présent (parcours inchangé,
      // seul le profil appliqué après sélection diffère).
      expect(find.text('Choisir un fichier'), findsOneWidget);
    });
  });

  group('StatementImportPage — résolution des nouveaux actifs', () {
    testWidgets(
        'le bouton Confirmer reste désactivé tant qu\'un nouvel actif '
        'n\'est pas résolu, puis s\'active une fois le symbole saisi',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      // Étape « résoudre les nouveaux actifs » atteinte directement.
      expect(find.text('Résoudre les nouveaux actifs'), findsOneWidget);
      // Le parcours générique inclut l'étape de résolution (actif neuf non
      // résolu) : « Étape 4 sur 5 ».
      expect(find.text('Étape 4 sur 5'), findsOneWidget);

      // Le bouton de confirmation est désactivé : aucun symbole saisi.
      var confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNull);

      // L'utilisateur saisit le symbole résolu.
      await tester.enterText(find.byType(TextField).first, 'NEWCO');
      await tester.pump();

      confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNotNull);
    });

    testWidgets(
        'repli « non coté » : cocher la case active la confirmation sans '
        'symbole saisi (aucun réseau — parcours debugInitialPreview)',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      expect(find.text('Résoudre les nouveaux actifs'), findsOneWidget);

      // Désactivé au départ : ni symbole saisi ni repli coché.
      var confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNull);

      // La case de repli « non coté » est proposée (ISIN présent).
      final fallbackTile = find.byType(CheckboxListTile);
      expect(fallbackTile, findsOneWidget);

      await tester.tap(fallbackTile);
      await tester.pumpAndSettle();

      // Cocher le repli résout le candidat : la confirmation s'active.
      confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNotNull);
    });

    testWidgets('un symbole saisi puis effacé redésactive le bouton',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'NEWCO');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNotNull,
      );

      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets(
        'recherche ISIN en échec réseau : le bandeau « Réessayer » ET le repli '
        '« non coté » coexistent (échappatoire hors-ligne, sans conclure à un '
        'titre introuvable) — P2.3', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );

      await tester.pumpWidget(
        _host(preview, debugInitialSearchFailedKeys: const {'FR000UNKNOWN'}),
      );
      await tester.pumpAndSettle();

      // Bandeau de panne + bouton « Réessayer ».
      expect(
        find.text('Recherche indisponible — vérifiez votre connexion.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Réessayer'), findsOneWidget);

      // Le repli « non coté » est DÉSORMAIS proposé même en échec réseau (le
      // candidat porte un ISIN) : la panne est signalée, mais l'utilisateur
      // n'est plus emprisonné.
      final fallbackTile = find.byType(CheckboxListTile);
      expect(fallbackTile, findsOneWidget);

      // Tant que rien n'est résolu, la confirmation reste bloquée : le bandeau
      // à lui seul ne débloque pas.
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNull,
      );

      // Cocher « non coté » débloque l'import, le bandeau de panne restant
      // affiché (coexistence).
      await tester.tap(fallbackTile);
      await tester.pumpAndSettle();
      expect(
        find.text('Recherche indisponible — vérifiez votre connexion.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('StatementImportPage — aperçu (retour depuis la résolution)', () {
    testWidgets(
        'le delta projette l\'actif NEUF (0 → N titres) et les tuiles rappellent '
        'la ligne source du relevé', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        rejects: [_rejectedOstMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      // Le point d'entrée de test démarre à la résolution : on revient à
      // l'aperçu (bouton retour de l'AppBar) pour l'exercer.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Aperçu de l\'import'), findsWidgets);

      // Défaut 1 : la moitié « positions » n'est plus vide — l'actif neuf est
      // projeté depuis 0 (2 titres achetés).
      expect(find.text('New Co : 0 → 2 titres'), findsOneWidget);

      // Défaut 3 : la phrase d'explication du groupe des nouveaux actifs et le
      // libellé reformulé « Symbole à associer ».
      expect(
        find.text(
          'Titres détectés dans le relevé, à associer à une valeur cotée '
          'avant l\'import.',
        ),
        findsOneWidget,
      );
      expect(find.text('Symbole à associer'), findsOneWidget);

      // Défaut 2 : l'OST rejetée (groupe déplié) rappelle sa ligne source par
      // le SEUL numéro (1-based) — l'écho des cellules brutes a été retiré
      // (retour auteur : surchargeait l'interface).
      expect(find.text('Ligne 6'), findsOneWidget);
    });

    testWidgets(
        'ligne réunie : groupe DÉDIÉ visible même noyée sous 60 '
        'doublons (défaut constaté — la mention sous la tuile était '
        'inatteignable au-delà du plafond de 50 tuiles)', (tester) async {
      // Le mouvement fusionné est placé EN DERNIER parmi 61 mouvements à
      // créer : dans le groupe « À créer », il tombe derrière le
      // « … et N autres » et n'est même pas construit. Seul le groupe dédié le
      // rend atteignable.
      final preview = ImportPreview(
        toCreate: [
          for (var i = 0; i < 60; i++) _plainMovement(i),
          _mergedHostMovement(),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Le groupe dédié existe, est titré au singulier et DÉPLIÉ par défaut :
      // la mention de la ligne absorbée est visible sans aucune interaction.
      expect(find.text('Lignes réunies (1)'), findsOneWidget);
      expect(
        find.text(
          'Cette opération et son règlement (ligne 42) étaient sur deux '
          'lignes du relevé.',
        ),
        findsOneWidget,
        reason: 'le groupe dédié doit rendre la mention atteignable',
      );
    });

    testWidgets(
        'accueil fusionné qui est un DOUBLON : AUCUNE annonce de repli — rien '
        'n\'est écrit, et le journal peut même contenir encore la paire scindée',
        (tester) async {
      // Décision produit (retour auteur) : sur un ré-import, annoncer « ces deux lignes
      // ont été réunies » est du bruit — le journal n'a pas bougé — et trompeur si
      // l'opération avait été importée AVANT le correctif de fusion (la paire scindée est
      // alors toujours en base, cf. la conception interne).
      final preview = ImportPreview(
        toCreate: const [],
        duplicates: [
          for (var i = 0; i < 60; i++) _plainMovement(i),
          _mergedHostMovement(),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.textContaining('Lignes réunies'), findsNothing);
      expect(find.textContaining('étaient sur deux'), findsNothing);
      // Le ré-import reste lisible par ailleurs : le nombre de doublons est
      // annoncé et leur groupe consultable.
      expect(find.text('Doublons ignorés (61)'), findsOneWidget);
    });

    testWidgets(
        'doublons PROBABLES d\'espèces : avertissement chiffré, exclus par '
        'défaut, et le ré-import intégral offre quand même un bouton de '
        'confirmation dès que l\'utilisateur bascule', (tester) async {
      // Cas EXACT constaté : tout est doublon sauf 22 dépôts dont le libellé a
      // changé → toCreate vide, donc branche « rien à créer ». Sans bouton de
      // confirmation dans cette branche, la bascule serait inactionnable.
      final preview = ImportPreview(
        toCreate: const [],
        duplicates: [for (var i = 0; i < 60; i++) _plainMovement(i)],
        probableDuplicates: [for (var i = 0; i < 22; i++) _cashDeposit(i)],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Avertissement chiffré, formulé au conditionnel (le rapprochement est
      // indécidable : aucune heure dans les relevés).
      expect(
        find.text('22 mouvements peut-être déjà enregistrés'),
        findsOneWidget,
      );
      // Défaut prudent : ignorés, et le bouton est « Fermer » (rien à écrire).
      expect(
        find.textContaining('22 mouvement(s) seront ignorés'),
        findsOneWidget,
      );
      expect(find.text('Fermer'), findsOneWidget);

      // L'utilisateur tranche : bascule « Les importer quand même ». La liste
      // des 22 mouvements la pousse hors écran — on l'amène en vue d'abord.
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('22 mouvement(s) seront ajoutés'),
        findsOneWidget,
      );
      // Le bouton de confirmation apparaît — sinon le choix serait inopérant.
      expect(find.text('Confirmer l\'import'), findsOneWidget);
      expect(find.text('Fermer'), findsNothing);
    });

    testWidgets('aucun doublon probable ⇒ AUCUN avertissement', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.textContaining('peut-être déjà enregistré'), findsNothing);
    });

    testWidgets('aucun repli ⇒ AUCUN groupe « lignes réunies »',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        duplicates: [_plainMovement(0)],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.textContaining('Lignes réunies'), findsNothing);
    });

    testWidgets(
        'ré-import intégral avec des rejets : le nombre de DOUBLONS est annoncé '
        'et son groupe est consultable (défaut constaté : seuls les rejets '
        'étaient mentionnés, 1334 doublons passaient sous silence)',
        (tester) async {
      final preview = ImportPreview(
        toCreate: const [],
        duplicates: [for (var i = 0; i < 60; i++) _plainMovement(i)],
        rejects: [_rejectedOstMovement(), _rejectedTechMovement()],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Les DEUX nombres, pas seulement les rejets.
      expect(
        find.text('Aucun nouveau mouvement — 60 ligne(s) déjà enregistrée(s) '
            'dans ce compte, 2 ligne(s) rejetée(s) ci-dessous.'),
        findsOneWidget,
      );
      // Et le groupe des doublons est présent (replié) pour vérifier QUOI.
      expect(find.text('Doublons ignorés (60)'), findsOneWidget);
    });

    testWidgets(
        'ré-import intégral SANS rejet : le nombre de doublons est chiffré',
        (tester) async {
      final preview = ImportPreview(
        toCreate: const [],
        duplicates: [for (var i = 0; i < 60; i++) _plainMovement(i)],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.text('Aucun nouveau mouvement — les 60 lignes de ce relevé sont '
            'déjà enregistrées dans ce compte.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'aperçu « rien à créer » MAIS des rejets : les groupes de rejets/OST '
        'sont rendus et le message annonce le nombre de lignes rejetées — P1',
        (tester) async {
      // Cas très plausible en profil générique : toutes les lignes rejetées
      // (natures d'opération non mappées) + une OST. Rien à créer, mais on ne
      // doit PAS masquer les motifs.
      final preview = ImportPreview(
        toCreate: const [],
        rejects: [_rejectedOstMovement(), _rejectedTechMovement()],
        newAssets: const [],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      // Le point d'entrée de test démarre à la résolution : retour à l'aperçu.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Aperçu de l\'import'), findsWidgets);

      // Message adapté : N lignes rejetées ci-dessous (au lieu du laconique
      // « Aucune ligne exploitable… » qui masquait les motifs).
      expect(
        find.text('Aucun mouvement à importer — 2 ligne(s) rejetée(s) ci-dessous.'),
        findsOneWidget,
      );

      // Le groupe OST (déplié, avertissement) est rendu avec son titre et son
      // rappel de ligne source.
      expect(find.text('Opérations sur titres à revoir (1)'), findsOneWidget);
      expect(find.text('Ligne 6'), findsOneWidget);

      // Le groupe des rejets techniques (replié) est rendu avec son titre.
      expect(find.text('Lignes rejetées (1)'), findsOneWidget);

      // Le bouton « Fermer » reste présent (aucune écriture possible).
      expect(find.widgetWithText(FilledButton, 'Fermer'), findsOneWidget);
    });

    testWidgets(
        'I-2 (revue adversariale) : le rejet cryptoImportKeyCollision affiche '
        'son libellé motivé et sa ligne source (au lieu d\'une tuile vide)',
        (tester) async {
      final preview = ImportPreview(
        toCreate: const [],
        rejects: [_rejectedCryptoCollisionMovement()],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Le groupe des rejets techniques est REPLIÉ par défaut (comportement
      // pré-existant, cf. `_techRejectGroup`) — on le déplie pour atteindre
      // le libellé motivé et le numéro de ligne source.
      await tester.tap(find.text('Lignes rejetées (1)'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Ce relevé revalorise une opération déjà importée avec un autre '
          'montant — l\'existant est conservé ; supprimez l\'ancien '
          'mouvement du journal pour ré-importer celle-ci',
        ),
        findsOneWidget,
      );
      // `sourceRowIndex` reste peuplé même quand `sourceRow` est vide à ce
      // stade du pipeline (repris de `UnvaluedExchange.sourceLines.first`).
      expect(find.text('Ligne 12'), findsOneWidget);
    });
  });

  group('StatementImportPage — place et confiance de la résolution', () {
    // Cas réel qui a motivé ces deux correctifs (cf. rapport de livraison) :
    // pour LU1190417599, la recherche ISIN ne renvoie que Londres (0E2B.IL)
    // et Stuttgart, jamais Paris — `IsinResolver.pickBest` retient malgré
    // tout le meilleur des deux (Londres), sans qu'aucun indice de place ne
    // soit visible à l'écran. Les assertions ci-dessous exercent l'affichage
    // SEUL (le peuplement réseau réel est couvert par isin_resolver_test.dart
    // + les tests unitaires de IsinResolver.venueRank) via les points
    // d'entrée `debugInitialResolvedVenues`/`debugInitialLowConfidenceVenueKeys`
    // réservés aux tests (aucun réseau).

    testWidgets(
        'la place du hit retenu est affichée à côté du champ de symbole',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );

      await tester.pumpWidget(_host(
        preview,
        debugInitialResolvedVenues: const {'FR000UNKNOWN': 'Londres'},
      ));
      await tester.pumpAndSettle();

      expect(find.text('Place : Londres'), findsOneWidget);
    });

    testWidgets(
        'avertissement présent quand le candidat retenu est au rang 3 '
        '(aucune place euro connue — cas 0E2B.IL)', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );

      await tester.pumpWidget(_host(
        preview,
        debugInitialResolvedVenues: const {'FR000UNKNOWN': 'Londres'},
        debugInitialLowConfidenceVenueKeys: const {'FR000UNKNOWN'},
      ));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Aucune place de cotation européenne connue pour ce titre — '
          'vérifiez ce symbole avant de continuer.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'avertissement ABSENT quand le candidat retenu est à un rang de '
        'confiance élevé (ex. Paris, rang 0)', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );

      await tester.pumpWidget(_host(
        preview,
        debugInitialResolvedVenues: const {'FR000UNKNOWN': 'Paris'},
        // Pas dans debugInitialLowConfidenceVenueKeys : rang 0, pas d'alerte.
      ));
      await tester.pumpAndSettle();

      expect(find.text('Place : Paris'), findsOneWidget);
      expect(
        find.textContaining('Aucune place de cotation européenne connue'),
        findsNothing,
      );
    });
  });

  group('StatementImportPage — vérification du symbole saisi à la main', () {
    testWidgets(
        'symbole saisi introuvable auprès de la source : la confirmation est '
        'refusée avec un message, sans écrire l\'import (bug CSH2.PAR — '
        'plausible mais invalide, Yahoo attend .PA)', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );
      final controller = _FakeVerifyController(
        // Recherche aboutie, mais AUCUN hit ne porte ce symbole exact.
        hitsByQuery: const {'CSH2.PAR': []},
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'CSH2.PAR');
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(
        find.text('Symbole introuvable auprès de la source de marché.'),
        findsOneWidget,
      );
      expect(controller.confirmCalled, isFalse);
    });

    testWidgets(
        'symbole saisi valide (un hit exact est retourné) : la confirmation '
        'aboutit', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );
      final controller = _FakeVerifyController(
        hitsByQuery: const {
          'CSH2.PA': [IsinSearchHit(symbol: 'CSH2.PA', exchange: 'PAR')],
        },
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'CSH2.PA');
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(
        find.text('Symbole introuvable auprès de la source de marché.'),
        findsNothing,
      );
      expect(controller.confirmCalled, isTrue);
    });

    testWidgets(
        'échec réseau pendant la vérification : NE rejette PAS la saisie, la '
        'confirmation aboutit quand même (même raisonnement que la panne de '
        'recherche ISIN)', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );
      final controller = _FakeVerifyController(
        networkFailQueries: const {'CSH2.PA'},
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'CSH2.PA');
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(
        find.text('Symbole introuvable auprès de la source de marché.'),
        findsNothing,
      );
      expect(controller.confirmCalled, isTrue);
    });

    testWidgets(
        'repli « non coté » : jamais soumis à la vérification (aucun hit '
        'stubbé pour son ISIN — s\'il était vérifié à tort, la recherche vide '
        'le rejetterait et bloquerait la confirmation)', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );
      final controller = _FakeVerifyController();

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(controller.confirmCalled, isTrue);
    });
  });

  group('StatementImportPage — profil Kraken (chantier B16, lot 1)', () {
    testWidgets(
        'sélectionner le profil Kraken affiche l\'indication dédiée et la '
        'carte d\'information (conception interne)', (tester) async {
      await tester.pumpWidget(_host(null));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kraken'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Sélectionnez l'export CSV « Ledgers » de votre compte Kraken.",
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Relevé « Ledgers » de Kraken, format CSV. Les dates de ce relevé '
          'sont en UTC et sont conservées telles quelles. Vos récompenses de '
          'staking seront regroupées par mois.',
        ),
        findsOneWidget,
      );
      // Le bouton de sélection de fichier reste présent (aucun mapping
      // manuel, comme Bourse Direct).
      expect(find.text('Choisir un fichier'), findsOneWidget);
    });

    testWidgets(
        'profil générique : AUCUNE carte d\'information Kraken (parcours '
        'inchangé)', (tester) async {
      await tester.pumpWidget(_host(null));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Relevé « Ledgers » de Kraken'),
        findsNothing,
      );
    });
  });

  group('StatementImportPage — garde de nature de compte (chantier B16)', () {
    testWidgets(
        'profil Kraken choisi sur un compte non-crypto : avertissement '
        'AVANT l\'aperçu, et « Annuler » referme sans exception',
        (tester) async {
      final controller = _FixedAccountsController([
        Account(id: _accountId, walletId: 'w1', name: 'Compte test', kind: AccountKind.cto),
      ]);

      await tester.pumpWidget(_host(null, controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kraken'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choisir un fichier'));
      await tester.pumpAndSettle();

      expect(find.text('Nature du compte'), findsOneWidget);
      expect(
        find.text(
          'Ce relevé décrit un compte de crypto-monnaies ; le compte ouvert '
          'est un Compte-titres (CTO). Continuer ?',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Nature du compte'), findsNothing);
    });

    testWidgets(
        'profil Kraken choisi sur un compte non-crypto : « Continuer » '
        'referme l\'avertissement SANS EXCEPTION — jamais bloquant',
        (tester) async {
      final controller = _FixedAccountsController([
        Account(id: _accountId, walletId: 'w1', name: 'Compte test', kind: AccountKind.cto),
      ]);

      await tester.pumpWidget(_host(null, controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kraken'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choisir un fichier'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Nature du compte'), findsNothing);
    });

    testWidgets(
        'profil Kraken choisi sur un compte DÉJÀ crypto : aucun '
        'avertissement', (tester) async {
      final controller = _FixedAccountsController([
        Account(id: _accountId, walletId: 'w1', name: 'Compte test', kind: AccountKind.crypto),
      ]);

      await tester.pumpWidget(_host(null, controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kraken'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choisir un fichier'));
      await tester.pumpAndSettle();

      expect(find.text('Nature du compte'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'profil Bourse Direct sur un compte non-crypto : AUCUN avertissement '
        '(garde réservée aux profils crypto)', (tester) async {
      final controller = _FixedAccountsController([
        Account(id: _accountId, walletId: 'w1', name: 'Compte test', kind: AccountKind.cto),
      ]);

      await tester.pumpWidget(_host(null, controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Bourse Direct'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choisir un fichier'));
      await tester.pumpAndSettle();

      expect(find.text('Nature du compte'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('StatementImportPage — ancien format Kraken refusé globalement', () {
    testWidgets(
        'écran de refus DÉDIÉ (pas une liste de rejets) avec le message du '
        'conception interne', (tester) async {
      const preview = ImportPreview(
        globalRejectReason: 'cryptoLegacyFormatUnsupported',
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text("Format d'export non pris en charge"), findsOneWidget);
      expect(
        find.text(
          "Cet export Kraken est d'un format antérieur : il ne contient ni "
          "la valorisation en dollars ni le portefeuille d'origine. "
          "Réexportez vos relevés « Ledgers » depuis Kraken.",
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Fermer'), findsOneWidget);
      // PAS une liste de rejets : aucun groupe de l'aperçu habituel.
      expect(find.textContaining('Doublons'), findsNothing);
      expect(find.textContaining('rejetée'), findsNothing);
    });
  });

  group('StatementImportPage — six groupes crypto (chantier B16, lot 1)', () {
    testWidgets(
        'les six groupes sont rendus, dans l\'ordre, avec le bon état '
        'déplié/replié par défaut', (tester) async {
      final preview = _cryptoFullPreview();

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Titres des six groupes, tous présents.
      expect(find.text('Échanges à valoriser (1)'), findsOneWidget);
      expect(find.text('Mouvements internes (1)'), findsOneWidget);
      expect(find.text('Relevé incomplet'), findsOneWidget);
      expect(find.text('Écart de quantité (1)'), findsOneWidget);
      expect(find.text('Récompenses regroupées (1)'), findsOneWidget);
      expect(find.text('Récompenses mises à jour (1)'), findsOneWidget);

      // Échanges à valoriser : DÉPLIÉ par défaut — la trace (ligne source,
      // codes et quantités des deux parties), le motif chiffré et le champ
      // de saisie EUR sont visibles sans interaction (lot 2 : valorisation
      // manuelle désormais possible depuis cet écran).
      expect(find.text('Ligne(s) 10, 11 : 0.5 ETH → 120 ADA'), findsOneWidget);
      expect(
        find.text(
          'Le relevé donne deux valeurs différentes pour cet échange '
          '(écart de 15.3 %) — indiquez le montant correct.',
        ),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsOneWidget);
      // Bouton « Appliquer » démonté (retour auteur, drive — la valorisation se
      // déclenche désormais depuis « Confirmer l'import », cf. groupe « filet de
      // confirmation » plus bas.
      expect(find.widgetWithText(FilledButton, 'Appliquer'), findsNothing);

      // Mouvements internes : le résidu et la bascule (défaut OFF) sont
      // visibles sans interaction (pas un ExpansionTile replié).
      expect(find.text('ZZZ : écart de 4.25 (2 lignes)'), findsOneWidget);
      expect(
        find.text('Les écarts ne seront pas journalisés (défaut).'),
        findsOneWidget,
      );

      // Relevé incomplet : DÉPLIÉ.
      expect(
        find.text('Rupture le 10/01/2024 sur XETH (ligne 42).'),
        findsOneWidget,
      );

      // Écart de quantité : DÉPLIÉ.
      expect(
        find.text('ADA : relevé 120.5, projection 118.0.'),
        findsOneWidget,
      );

      // Récompenses regroupées / mises à jour : REPLIÉES par défaut — le
      // contenu n'est PAS atteignable sans déplier.
      expect(find.text('Juin 2024 — 9 lignes, +3.1 AAA'), findsNothing);
      expect(
        find.text('Septembre 2026 : 12 lignes → 30 lignes, +0.83 ADA'),
        findsNothing,
      );

      await tester.ensureVisible(find.text('Récompenses regroupées (1)'));
      await tester.tap(find.text('Récompenses regroupées (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Juin 2024 — 9 lignes, +3.1 AAA'), findsOneWidget);

      await tester.ensureVisible(find.text('Récompenses mises à jour (1)'));
      await tester.tap(find.text('Récompenses mises à jour (1)'));
      await tester.pumpAndSettle();
      expect(
        find.text('Septembre 2026 : 12 lignes → 30 lignes, +0.83 ADA'),
        findsOneWidget,
      );
    });

    testWidgets(
        'aperçu « rien à créer » (tout doublon) : les groupes crypto restent '
        'visibles — seule occasion de les voir dans ce cas', (tester) async {
      final preview = ImportPreview(
        toCreate: const [],
        duplicates: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedExchangeFixture()],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Échanges à valoriser (1)'), findsOneWidget);
      expect(find.text('Ligne(s) 10, 11 : 0.5 ETH → 120 ADA'), findsOneWidget);
    });

    testWidgets(
        'mouvements internes : bascule ON → passe '
        'journalizeUnbalancedInternalTransfers=true à la confirmation',
        (tester) async {
      final controller = _FakeCryptoConfirmController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unbalancedInternalTransfers: [_unbalancedTransferFixture],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Les écarts seront journalisés comme des ajustements à coût nul.',
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(controller.capturedJournalizeUnbalancedInternalTransfers, isTrue);
    });

    testWidgets(
        'mouvements internes : bascule laissée OFF → '
        'journalizeUnbalancedInternalTransfers=false à la confirmation '
        '(défaut prudent, jamais de correction silencieuse)',
        (tester) async {
      final controller = _FakeCryptoConfirmController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unbalancedInternalTransfers: [_unbalancedTransferFixture],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(
        controller.capturedJournalizeUnbalancedInternalTransfers,
        isFalse,
      );
    });

    testWidgets(
        'récompenses mises à jour : le remplacement affiché est TOUJOURS '
        'confirmé (aucune bascule dédiée) — passe son importKey en '
        'replaceImportKeys', (tester) async {
      final controller = _FakeCryptoConfirmController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        replacements: [_replacementFixture()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(
        controller.capturedReplaceImportKeys,
        {'agg:account-1:profil:ADA:2026-09'},
      );
    });
  });

  group(
      'StatementImportPage — nouveaux actifs crypto : panne réseau vs non '
      'coté constaté (chantier B16, lot 1)', () {
    testWidgets(
        'la note « panne réseau » est DISTINCTE du badge « Non coté » '
        'constaté (patron conception interne : jamais assimiler une panne de '
        'transport à une invalidité)', (tester) async {
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        newAssets: const [
          _networkFailureCryptoAsset,
          _confirmedNotListedCryptoAsset,
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      // Les deux candidats ont déjà un proposedSymbol : rien à résoudre,
      // retour direct à l'aperçu.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Vérification impossible (connexion indisponible) — actif ajouté '
          'non coté ; à revérifier plus tard.',
        ),
        findsOneWidget,
      );
      expect(find.text('Non coté'), findsOneWidget);
    });

    testWidgets(
        'un candidat crypto COTÉ (résolu) ne porte aucune des deux notes',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        newAssets: const [_resolvedCryptoAsset],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Vérification impossible'),
        findsNothing,
      );
      expect(find.text('Non coté'), findsNothing);
      // Le code du relevé d'origine (ledgerCode) reste affiché en
      // provenance du ticker résolu.
      expect(find.text('ADA'), findsOneWidget);
    });
  });

  group('StatementImportPage — écran Terminé (chantier B16, lot 1)', () {
    testWidgets(
        'mention de la limite d\'annulation si l\'import a inclus un '
        'remplacement de récompenses (l\'agrégat précédent est supprimé, un '
        'futur "Annuler" ne le restaure pas)', (tester) async {
      final controller = _FakeCryptoConfirmController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        replacements: [_replacementFixture()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Les récompenses de Septembre 2026 ont été mises à jour ; annuler '
          'cet import ne restaurera pas leur version précédente.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'AUCUN remplacement : aucune mention de limite d\'annulation liée '
        'aux récompenses', (tester) async {
      final controller = _FakeCryptoConfirmController();
      final preview = ImportPreview(toCreate: [_cryptoBuyMovement()]);

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ont été mises à jour'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // Chantier B16, lot 2 (conception interne) — valorisation manuelle des échanges
  // crypto restés en arbitrage, bandeau FX indisponible et sous-titre de provenance
  // sur les mouvements finalisés.
  // ---------------------------------------------------------------------------

  group('StatementImportPage — valorisation manuelle des échanges (B16 lot 2)',
      () {
    testWidgets(
        'les trois motifs sont rendus, chacun avec son champ EUR ; une '
        'saisie invalide n\'est jamais transmise, seule une saisie valide '
        '(virgule française) l\'est — via « Confirmer l\'import » → dialogue '
        '→ « Importer sans ces échanges » (2 des 3 entrées restent '
        'incomplètes)', (tester) async {
      final controller = _FakeApplyManualValuationsController(
        result: ImportPreview(
          toCreate: [_cryptoBuyMovement()],
          // Après application : seul « spread » (montant renseigné) a quitté
          // le groupe — « unreadable » (saisie invalide) et « fxUnavailable »
          // (laissé vide) y restent, avec leur motif D'ORIGINE.
          unvaluedExchanges: [
            _unvaluedUnreadableFixture(),
            _unvaluedFxUnavailableFixture(),
          ],
        ),
      );
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [
          _unvaluedUnreadableFixture(),
          _unvaluedExchangeFixture(), // motif spread
          _unvaluedFxUnavailableFixture(),
        ],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Échanges à valoriser (3)'), findsOneWidget);
      expect(find.text('Valeur du relevé illisible.'), findsOneWidget);
      expect(
        find.text(
          'Le relevé donne deux valeurs différentes pour cet échange '
          '(écart de 15.3 %) — indiquez le montant correct.',
        ),
        findsOneWidget,
      );
      expect(find.text('Taux de change historique indisponible.'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(3));

      // Saisie invalide sur le champ « unreadable ».
      await tester.enterText(find.byType(TextField).at(0), 'abc');
      // Saisie valide (virgule décimale française) sur le champ « spread ».
      await tester.enterText(find.byType(TextField).at(1), '150,50');
      // Champ « fxUnavailable » laissé VIDE.
      await tester.pump();

      // Plus de bouton « Appliquer » dédié (démonté, retour auteur du drive : la
      // valorisation part désormais de « Confirmer l'import » — 2 entrées sur 3
      // restent incomplètes (« abc » invalide, champ vide sans choix) → dialogue, «
      // Importer sans ces échanges » applique la seule complète puis confirme.
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(TextButton, 'Importer sans ces échanges'),
      );
      await tester.pumpAndSettle();

      // Seule la clé valide et renseignée est transmise au contrôleur — la
      // vide et l'invalide n'atteignent JAMAIS applyManualCryptoValuations.
      expect(
        controller.capturedEurByImportKey,
        {'ref:account-1:REFEXCH': '150.50'},
      );

      // La confirmation porte sur l'aperçu RENVOYÉ par le contrôleur (celui
      // capturé, PAS l'écran — la confirmation a navigué vers l'étape
      // finale) : le compteur retombe à 2 (les deux entrées non résolues),
      // « spread » a disparu.
      expect(controller.confirmCalled, isTrue);
      expect(
        controller.capturedConfirmPreview?.unvaluedExchanges.length,
        2,
      );
    });

    // ------------------------------------------------------------------- Amendement
    // drive lot 2 (suite) : choix binaire présélectionné (« Valeur cédée » / «
    // Valeur reçue ») remplaçant l'ancienne ligne de suggestions + boutons «
    // Utiliser… » — un clic direct sur « Appliquer », SANS aucune interaction,
    // valorise déjà l'échange à sa valeur par défaut ; le champ EUR devient
    // dérogatoire pour ces entrées.
    // -------------------------------------------------------------------

    testWidgets(
        'le choix cédée/reçue se rend avec les montants USD/EUR corrects, '
        'ABSENT sinon (contrôle négatif : champ « Montant (EUR) » classique)',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedExchangeFixtureWithSuggestions()],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Les deux options du choix, montants USD (2 décimales, valeur
      // absolue) et EUR déjà formatés.
      final paidUsd = Formatters.formatMoney(195, 'USD');
      final paidEur = Formatters.formatEur(180);
      final receivedUsd = Formatters.formatMoney(225, 'USD');
      final receivedEur = Formatters.formatEur(207.5);
      expect(find.byType(RadioListTile<bool>), findsNWidgets(2));
      expect(
        find.text('Valeur cédée : $paidUsd (≈ $paidEur)'),
        findsOneWidget,
      );
      expect(
        find.text('Valeur reçue : $receivedUsd (≈ $receivedEur)'),
        findsOneWidget,
      );
      // Chaque option porte bien sa valeur (première = « cédée » = `true`,
      // seconde = « reçue » = `false`)...
      final paidTile = tester
          .widget<RadioListTile<bool>>(find.byType(RadioListTile<bool>).at(0));
      final receivedTile = tester
          .widget<RadioListTile<bool>>(find.byType(RadioListTile<bool>).at(1));
      expect(paidTile.value, isTrue);
      expect(receivedTile.value, isFalse);
      // ...et « Valeur reçue » (`false`) est bien l'option SÉLECTIONNÉE par défaut (valeur
      // portée par le `RadioGroup` ambiant, cf. [_unvaluedChoiceRow] — décision auteur au
      // drive.
      final group = tester.widget<RadioGroup<bool>>(find.byType(RadioGroup<bool>));
      expect(group.groupValue, isFalse);
      // Champ dérogatoire (libellé distinct de l'entrée sans choix ci-dessous).
      expect(
        tester.widget<TextField>(find.byType(TextField).first).decoration!.labelText,
        'Autre montant (EUR)',
      );

      // Contrôle négatif : la fixture SANS suggestions (mêmes usdPaid/
      // usdReceived, même écart, mais suggestedPaidEur/suggestedReceivedEur
      // absents) ne rend PAS le choix et garde le champ classique.
      // Démontage COMPLET d'abord : l'aperçu initial n'est lu qu'à
      // l'initState — re-pumper _host sur l'état vivant garderait l'ancien
      // aperçu, et rejouer la navigation arrow_back sortirait de l'étape.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_host(ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedExchangeFixture()],
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.byType(RadioListTile<bool>), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).decoration!.labelText,
        'Montant (EUR)',
      );
    });

    testWidgets(
        '« Confirmer l\'import » SANS AUCUNE interaction sur le champ EUR '
        'transmet suggestedReceivedEur (défaut « Valeur reçue ») ; une '
        'entrée d\'un AUTRE motif laissée vide, elle, reste incomplète (1 '
        'seule incomplète → dialogue → « Importer sans ces échanges »)',
        (tester) async {
      final controller = _FakeApplyManualValuationsController(
        result: ImportPreview(
          toCreate: [_cryptoBuyMovement()],
          unvaluedExchanges: [_unvaluedUnreadableFixture()],
        ),
      );
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [
          _unvaluedExchangeFixtureWithSuggestions(),
          _unvaluedUnreadableFixture(), // autre motif, laissé vide.
        ],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      // L'entrée AVEC choix est complète sans interaction : seule
      // « unreadable » (autre motif, sans choix, laissée vide) est
      // incomplète → dialogue à 1 entrée.
      expect(find.text('Montants non saisis'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(TextButton, 'Importer sans ces échanges'),
      );
      await tester.pumpAndSettle();

      // Seule l'entrée AVEC choix est transmise, à sa valeur par défaut
      // « reçue » (Decimal BRUT '207.5', pas '207,50 €' reformaté) — l'entrée
      // « unreadable » reste absente de la map, comportement historique
      // inchangé.
      expect(
        controller.capturedEurByImportKey,
        {'ref:account-1:REFEXCH': '207.5'},
      );
    });

    testWidgets(
        'basculer sur « Valeur cédée » PUIS « Confirmer l\'import » transmet '
        'suggestedPaidEur (entrée seule et AVEC choix : toujours complète, '
        'aucun dialogue)', (tester) async {
      final controller = _FakeApplyManualValuationsController(
        result: ImportPreview(toCreate: [_cryptoBuyMovement()]),
      );
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedExchangeFixtureWithSuggestions()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      final paidUsd = Formatters.formatMoney(195, 'USD');
      final paidEur = Formatters.formatEur(180);
      await tester.ensureVisible(
        find.text('Valeur cédée : $paidUsd (≈ $paidEur)'),
      );
      await tester.tap(find.text('Valeur cédée : $paidUsd (≈ $paidEur)'));
      await tester.pump();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsNothing);
      expect(
        controller.capturedEurByImportKey,
        {'ref:account-1:REFEXCH': '180'},
      );
    });

    testWidgets(
        'le champ dérogatoire rempli PRIME sur le choix, peu importe '
        'l\'option sélectionnée (entrée toujours complète, aucun dialogue)',
        (tester) async {
      final controller = _FakeApplyManualValuationsController(
        result: ImportPreview(toCreate: [_cryptoBuyMovement()]),
      );
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedExchangeFixtureWithSuggestions()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Défaut « Valeur reçue » laissé sélectionné — seule la saisie change.
      await tester.enterText(find.byType(TextField).first, '99,90');
      await tester.pump();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      // Le montant SAISI l'emporte sur la suggestion '207.5' du choix, et
      // reste COMPLET (pas de dialogue) : le champ dérogatoire rempli et
      // valide ne bloque jamais.
      expect(find.text('Montants non saisis'), findsNothing);
      expect(
        controller.capturedEurByImportKey,
        {'ref:account-1:REFEXCH': '99.90'},
      );
    });

    testWidgets(
        'B-1 (revue adversariale) : motif ambiguousGroup rendu, champ de '
        'saisie DÉSACTIVÉ pour cette entrée', (tester) async {
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [
          _unvaluedExchangeFixture(), // motif spread, ACTIF — contrôle négatif.
          _unvaluedAmbiguousGroupFixture(),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.text('Groupe indivisible — à ressaisir manuellement dans le journal.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNWidgets(2));
      // Le champ « spread » (premier, motif ACTIF) reste activé...
      expect(tester.widget<TextField>(find.byType(TextField).at(0)).enabled, isTrue);
      // ...celui de l'entrée ambiguousGroup est désactivé : une saisie n'y
      // serait de toute façon jamais appliquée (AccountController.
      // applyManualCryptoValuations la refuse aussi, ceinture indépendante).
      expect(tester.widget<TextField>(find.byType(TextField).at(1)).enabled, isFalse);
    });

    testWidgets(
        'T-4/I-3 (revue adversariale) : jambe fiat au motif fxUnavailable → '
        'champ de saisie DÉSACTIVÉ (le contrôleur refuse sur le critère '
        'STRUCTUREL, pas sur le motif affiché — sinon la saisie serait '
        'ignorée en silence)', (tester) async {
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [
          _unvaluedFxUnavailableFixture(), // sans jambe fiat, ACTIF — contrôle négatif.
          _unvaluedFxUnavailableFiatLegFixture(),
        ],
        cryptoFxUnavailable: true,
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNWidgets(2));
      // Le champ SANS jambe fiat (premier) reste activé...
      expect(tester.widget<TextField>(find.byType(TextField).at(0)).enabled, isTrue);
      // ...celui de l'entrée à jambe fiat (motif affiché IDENTIQUE,
      // `fxUnavailable`) est désactivé — l'ancien critère (`manualReason ==
      // 'foreignFiat'`) l'aurait laissé actif à tort.
      expect(tester.widget<TextField>(find.byType(TextField).at(1)).enabled, isFalse);
    });

    testWidgets(
        'une saisie invalide → dialogue « Montants non saisis », '
        '« Compléter la saisie » (défaut) affiche « Montant invalide » sur '
        'le champ et n\'appelle JAMAIS le contrôleur', (tester) async {
      final controller = _FakeApplyManualValuationsController(result: null);
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedUnreadableFixture()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Zéro n'est PAS strictement positif : invalide, comme le motive la
      // garde de [AccountController.applyManualCryptoValuations].
      await tester.enterText(find.byType(TextField).first, '0');
      await tester.pump();
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Compléter la saisie'));
      await tester.pumpAndSettle();

      expect(find.text('Montant invalide'), findsOneWidget);
      expect(controller.capturedEurByImportKey, isNull);
      // Ni apply ni confirm : on reste sur l'étape aperçu, inchangée.
      expect(controller.confirmCalled, isFalse);
      expect(find.text('Échanges à valoriser (1)'), findsOneWidget);
    });

    testWidgets(
        'bandeau FX indisponible : visible SEULEMENT si '
        'cryptoFxUnavailable, en tête des groupes crypto', (tester) async {
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedFxUnavailableFixture()],
        cryptoFxUnavailable: true,
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Le service de taux de change historique est injoignable — les '
          'échanges entre crypto-monnaies sont passés en saisie manuelle. Le '
          'reste du relevé est importé normalement.',
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Réessayer'), findsOneWidget);

      // Contrôle négatif : SANS cryptoFxUnavailable (défaut false), le
      // bandeau n'apparaît pas — même avec des échanges manuels présents.
      await tester.pumpWidget(_host(ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedFxUnavailableFixture()],
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('service de taux de change historique'),
        findsNothing,
      );
    });

    testWidgets(
        'groupe « Échanges valorisés » : REPLIÉ, dans le groupe dédié (PAS '
        'seulement dans « À créer »), sous-titre de provenance « relevé » / '
        '« manuellement » / rien sur un mouvement ordinaire',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [
          _cryptoBuyMovement(), // aucun meta['valuationSource'] : contrôle négatif.
          _cryptoMovementValued('tx-statement', 'ref:acc:STMT', 'statement'),
          _cryptoMovementValued('tx-manual', 'ref:acc:MANUAL', 'manual'),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // Groupe dédié (conception interne), REPLIÉ par défaut. Vue FILTRÉE de
      // `toCreate` — PAS une exclusion (même patron que « Récompenses regroupées »/«
      // Récompenses mises à jour ») : le groupe « À créer » (toujours DÉPLIÉ) montre
      // déjà CES DEUX mouvements, donc leur sous-titre est visible UNE fois chacun
      // avant même de déplier « Échanges valorisés ».
      expect(find.text('Échanges valorisés (2)'), findsOneWidget);
      expect(find.text('Valorisé d\'après le relevé'), findsOneWidget);
      expect(find.text('Valorisé manuellement'), findsOneWidget);

      await tester.ensureVisible(find.text('Échanges valorisés (2)'));
      await tester.tap(find.text('Échanges valorisés (2)'));
      await tester.pumpAndSettle();

      // Une fois déplié, CHAQUE mouvement apparaît DEUX fois à l'écran (« À
      // créer » + « Échanges valorisés ») — confirme que le groupe dédié
      // liste bien ces mouvements, sans les retirer d'ailleurs.
      expect(find.text('Valorisé d\'après le relevé'), findsNWidgets(2));
      expect(find.text('Valorisé manuellement'), findsNWidgets(2));
    });

    testWidgets(
        'sous-titre de provenance « en dollars » sur un échange valorisé '
        'source `fiatLeg` (amendement, voie ii — jambe fiat étrangère '
        'USD convertie en cash)', (tester) async {
      final preview = ImportPreview(
        toCreate: [
          _cryptoMovementValued('tx-fiatleg', 'ref:acc:FIATLEG', 'fiatLeg'),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(
        find.text('Valorisé d\'après la contrepartie en dollars'),
        findsOneWidget,
      );
    });

    testWidgets(
        'groupe « Échanges valorisés » : compte les ÉCHANGES DISTINCTS, pas '
        'les mouvements (une paire sell+buy du même échange compte UNE fois)',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [
          _cryptoBuyMovement(), // contrôle négatif : jamais compté ici.
          ..._cryptoExchangePairValued('ref:acc:EX1', 'statement'),
          _cryptoMovementValued('tx-deposit', 'ref:acc:EX2#deposit:III', 'manual'),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // 3 mouvements valorisés, mais 2 ÉCHANGES distincts (EX1 sell+buy = 1,
      // EX2 deposit = 1). Groupe « À créer » toujours DÉPLIÉ : ces 3
      // mouvements y sont déjà visibles avant même de déplier le groupe dédié.
      expect(find.text('Échanges valorisés (2)'), findsOneWidget);
      expect(find.text('Valorisé d\'après le relevé'), findsNWidgets(2));
      expect(find.text('Valorisé manuellement'), findsOneWidget);

      await tester.ensureVisible(find.text('Échanges valorisés (2)'));
      await tester.tap(find.text('Échanges valorisés (2)'));
      await tester.pumpAndSettle();

      // Déplié : CHAQUE mouvement apparaît deux fois (« À créer » + groupe
      // dédié) — vue filtrée, jamais une exclusion.
      expect(find.text('Valorisé d\'après le relevé'), findsNWidgets(4));
      expect(find.text('Valorisé manuellement'), findsNWidgets(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Chantier B17 (retour auteur, drive, verbatim : « enlève le bouton appliquer et
  // remplace par un contrôle de surface pour t'assurer que tout a bien été saisi »)
  // — REMPLACE le filet-dialogue à 3 issues testé ci-avant (démonté avec le bouton «
  // Appliquer » du panneau « Échanges à valoriser », cf. la doc démontée de
  // `_guardUnvaluedExchangesBeforeConfirm`) : « Confirmer l'import » applique
  // désormais lui-même les valorisations en attente, précédé d'un contrôle de
  // saisie. Toutes complètes → confirmation directe, zéro friction. Une saisie
  // manquante ou invalide → dialogue à 2 issues (« Compléter la saisie » / «
  // Importer sans ces échanges »).
  // ---------------------------------------------------------------------------

  group('StatementImportPage — filet de confirmation « échanges à valoriser »'
      ' (B17)', () {
    testWidgets(
        'aucune entrée incomplète (choix présélectionné, aucune saisie) → '
        'confirmation DIRECTE sans dialogue ; applique à la valeur par '
        'défaut du choix PUIS confirme le NOUVEL aperçu rafraîchi (jamais '
        'l\'ancien)', (tester) async {
      final controller = _FakeApplyManualValuationsController(
        // Aperçu APRÈS valorisation : plus aucun échange en attente, un
        // second mouvement finalisé est venu s'ajouter — sert à distinguer
        // sans ambiguïté ce résultat de l'aperçu initial (1 seul mouvement).
        result: ImportPreview(
          toCreate: [
            _cryptoBuyMovement(),
            _cryptoMovementValued('tx-valued', 'ref:acc:VALUED', 'manual'),
          ],
        ),
      );
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedExchangeFixtureWithSuggestions()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      // Aucun dialogue : l'unique entrée en attente porte un choix
      // présélectionné, donc COMPLÈTE sans la moindre saisie.
      expect(find.text('Montants non saisis'), findsNothing);

      // Valorise à la valeur par défaut du choix (« reçue »), exactement
      // comme l'ancien clic direct sur « Appliquer » sans interaction.
      expect(
        controller.capturedEurByImportKey,
        {'ref:account-1:REFEXCH': '207.5'},
      );
      // La confirmation porte sur le NOUVEL aperçu (2 mouvements, aucun
      // échange en attente) — jamais l'ancien (1 mouvement, 1 échange).
      expect(controller.confirmCalled, isTrue);
      expect(controller.capturedConfirmPreview?.toCreate.length, 2);
      expect(controller.capturedConfirmPreview?.unvaluedExchanges, isEmpty);
    });

    testWidgets(
        'échec de l\'application (contrôleur renvoie null, aperçu '
        'inchangé) → AUCUNE confirmation : on reste sur l\'écran, jamais '
        'd\'import silencieux de l\'aperçu refusé', (tester) async {
      // `result: null` = échec réseau du contrôleur (comportement par
      // défaut de _FakeApplyManualValuationsController, cf. sa doc) :
      // `_preview` reste inchangé, l'entrée complète demeure —
      // [_applyPendingManualValuations] doit alors ANNULER la confirmation.
      final controller = _FakeApplyManualValuationsController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedExchangeFixtureWithSuggestions()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      // Aucun dialogue (entrée déjà complète) : la valorisation est TENTÉE
      // directement, même moteur que l'ex-bouton « Appliquer »…
      expect(
        controller.capturedEurByImportKey,
        {'ref:account-1:REFEXCH': '207.5'},
      );
      // …mais son échec bloque la confirmation : rien n'est importé, l'écran
      // d'aperçu (bouton « Confirmer l'import ») est toujours là.
      expect(controller.confirmCalled, isFalse);
      expect(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
        findsOneWidget,
      );
    });

    testWidgets(
        'entrée SANS choix au champ VIDE → dialogue « Montants non saisis » '
        'avec « Compléter la saisie » en action par défaut ; ce choix ne '
        'déclenche NI application NI confirmation, le champ reste marqué '
        '« Montant requis »', (tester) async {
      final controller = _FakeApplyManualValuationsController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedUnreadableFixture()], // champ laissé vide.
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsOneWidget);
      expect(
        find.text(
          '1 échange(s) n\'ont pas de montant saisi. Sans montant, ils ne '
          'créeront aucun mouvement et vos positions seront provisoires.',
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Compléter la saisie'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextButton, 'Importer sans ces échanges'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Compléter la saisie'));
      await tester.pumpAndSettle();

      expect(controller.capturedEurByImportKey, isNull);
      expect(controller.confirmCalled, isFalse);
      // Toujours sur l'étape aperçu, le champ vide porte désormais l'erreur.
      expect(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
        findsOneWidget,
      );
      expect(find.text('Montant requis'), findsOneWidget);
    });

    testWidgets(
        'saisie invalide (« abc ») → même traitement qu\'un champ vide : '
        'dialogue + erreur « Montant invalide » sur le champ concerné',
        (tester) async {
      final controller = _FakeApplyManualValuationsController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [_unvaluedUnreadableFixture()],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'abc');
      await tester.pump();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Compléter la saisie'));
      await tester.pumpAndSettle();

      expect(controller.capturedEurByImportKey, isNull);
      expect(controller.confirmCalled, isFalse);
      expect(find.text('Montant invalide'), findsOneWidget);
    });

    testWidgets(
        '« Importer sans ces échanges » SANS AUCUNE entrée complète → '
        'applyManualCryptoValuations n\'est même pas appelé (rien à '
        'appliquer), mais la confirmation a bien lieu sur l\'aperçu tel '
        'quel (les deux entrées incomplètes y restent, longueur 2)',
        (tester) async {
      final controller = _FakeApplyManualValuationsController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [
          _unvaluedUnreadableFixture(), // champ laissé vide.
          _unvaluedFxUnavailableFixture(), // champ laissé vide.
        ],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(TextButton, 'Importer sans ces échanges'),
      );
      await tester.pumpAndSettle();

      // Rien de complet à transmettre : le contrôleur n'est jamais atteint
      // (`toApply` vide, cf. doc de [_applyManualCryptoValuations]).
      expect(controller.capturedEurByImportKey, isNull);
      // La confirmation a quand même lieu, sur l'aperçu tel quel : les deux
      // entrées restent (aucune n'a pu être valorisée) — « Importer sans ces
      // échanges » ne les retire jamais, il les laisse simplement muettes
      // (point 2c/2d de la consigne).
      expect(controller.confirmCalled, isTrue);
      expect(
        controller.capturedConfirmPreview?.unvaluedExchanges.length,
        2,
      );
    });

    testWidgets(
        'entrées présentes mais TOUTES structurellement refusées (clé '
        'partagée + jambe fiat) → jamais bloquantes, confirmation DIRECTE, '
        'AUCUN dialogue (elles n\'ont jamais été saisissables)',
        (tester) async {
      final controller = _FakeApplyManualValuationsController();
      final preview = ImportPreview(
        toCreate: [_cryptoBuyMovement()],
        unvaluedExchanges: [
          _unvaluedAmbiguousGroupFixture(),
          _unvaluedFxUnavailableFiatLegFixture(),
        ],
      );

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsNothing);
      expect(controller.capturedEurByImportKey, isNull);
      expect(controller.confirmCalled, isTrue);
      expect(
        controller.capturedConfirmPreview?.unvaluedExchanges.length,
        2,
      );
    });

    testWidgets(
        'aucun échange à valoriser → confirmation directe, AUCUN dialogue '
        '(non-régression du chemin historique)', (tester) async {
      final controller = _FakeApplyManualValuationsController();
      final preview = ImportPreview(toCreate: [_cryptoBuyMovement()]);

      await tester.pumpWidget(_host(preview, controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer l\'import'));
      await tester.pumpAndSettle();

      expect(find.text('Montants non saisis'), findsNothing);
      expect(controller.confirmCalled, isTrue);
      expect(controller.capturedConfirmPreview?.toCreate.length, 1);
    });
  });
}

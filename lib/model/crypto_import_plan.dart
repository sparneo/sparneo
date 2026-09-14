// lib/model/crypto_import_plan.dart
//
// DTO de sortie de la couche PURE `CryptoLedgerNormalizer.planCryptoImport`
// (chantier B16, lot 1 — conception interne) : tout ce qu'un relevé crypto
// produit AU-DELÀ des `ImportedMovement` classiques (échanges en attente de
// valorisation, bilan des transferts internes, garde de l'oracle `balance`).
// Reste une donnée pure — comme `ParsedStatement`
// (statement_import_service.dart), aucune logique ici.

import 'package:portfolio_tracker/model/imported_movement.dart';

/// Échange (ou entrée en nature dégénérée) qui ne peut PAS être journalisé sans
/// valorisation externe (modèle (b) fichier-d'abord, conception interne) — exclu
/// de `toCreate`/`movements`, exposé pour arbitrage manuel (lot 2).
///
/// Deux formes :
///  - ÉCHANGE (`kind == 'exchange'`) : [codePaid]/[quantityPaid] ET
///    [codeReceived]/[quantityReceived] renseignés (crypto↔crypto,
///    crypto↔stable, dustsweeping avec `amountusd` illisible…) ;
///  - DÉPÔT EN NATURE dégénéré (`kind == 'depositInKind'`) : [codePaid] et
///    [quantityPaid] `null` (aucune jambe payée, l'actif « vient d'ailleurs » —
///    conception interne, `depositIn`/entrée en nature).
class UnvaluedExchange {
  final String kind; // 'exchange' | 'depositInKind'
  final DateTime date;
  final String? codePaid;
  final String? quantityPaid;
  final String codeReceived;
  final String quantityReceived;

  /// Valorisation USD des jambes SI numérique (colonne
  /// [CryptoLedgerSpec.valuationAmountColumn]) — `null` si absente ou
  /// illisible (ex. littéral `-`, conception interne).
  final String? usdPaid;
  final String? usdReceived;

  /// Numéros de ligne SOURCE (1-based) des jambes d'origine, pour
  /// l'affichage (« Échanges à valoriser », lignes N/M).
  final List<int> sourceLines;

  /// Clé de dédup STABLE, calculée AVANT toute valorisation (invariant absolu,
  /// conception interne) : `ref:<accountId>:<refid>` — le futur
  /// `finalizeCryptoExchanges` (lot 2) y ajoute le rôle (`#sell:<code>` /
  /// `#buy:<code>`) une fois les mouvements réels émis.
  final String importKey;

  const UnvaluedExchange({
    required this.kind,
    required this.date,
    this.codePaid,
    this.quantityPaid,
    required this.codeReceived,
    required this.quantityReceived,
    this.usdPaid,
    this.usdReceived,
    required this.sourceLines,
    required this.importKey,
  });
}

/// Bilan de cohérence d'un actif de base dont les mouvements
/// `internalTransfer` (spot↔staking/earn…) ne nettent PAS à zéro (conception
/// interne — ex. un airdrop livré directement en earn, sans jambe spot
/// correspondante). Écarté du journal par construction — jamais de
/// correction automatique.
class UnbalancedInternalTransfer {
  final String asset; // code de base, APRÈS alias
  final String residual; // Decimal signé (Σ(amount−fee))
  final int rowCount;

  /// Date de la DERNIÈRE jambe du groupe non équilibré (posée par le moteur,
  /// ordre chronologique robuste — pas l'ordre d'itération des groupes) —
  /// sert à dater le mouvement d'ajustement si l'utilisateur choisit de le
  /// journaliser (revue adversariale I-2 : `DateTime.now()` daterait le
  /// geste d'IMPORT, pas le relevé).
  final DateTime lastDate;

  /// Symbole de marché résolu par la cascade ledgerCode→ticker
  /// (`AccountController._resolveCryptoTicker`, conception interne), posé par
  /// [AccountController._previewCryptoImport] — `null` au sortir du moteur PUR
  /// (`CryptoLedgerNormalizer` ne fait aucune I/O réseau). La confirmation
  /// consomme CE champ tel quel (zéro réseau au confirm, I-2) plutôt que de
  /// refaire sa propre résolution restreinte aux positions préexistantes (ancien
  /// comportement : silencieusement ignoré au premier import, cas nominal).
  final String? resolvedSymbol;

  /// Clé de REMPLACEMENT stable (`internalresidual:accountId:profileId: asset`),
  /// posée EN MÊME TEMPS que [resolvedSymbol] — un ré-import qui retrouve le même
  /// résidu (même compte, même PROFIL, même actif) REMPLACE l'ajustement déjà en
  /// base au lieu de l'empiler (I-2 : idempotence), via le même mécanisme
  /// `LedgerService.importMovements( replaceImportKeys:)` que les agrégats
  /// mensuels de récompenses (`meta['replaceable'] == true`, conception interne).
  /// Le profil DOIT figurer dans la clé (contre-vérification, revue adversariale)
  /// : deux profils crypto distincts sur le MÊME compte ne doivent jamais se voler
  /// la clé d'un résidu portant le même code d'actif.
  final String? replaceImportKey;

  const UnbalancedInternalTransfer({
    required this.asset,
    required this.residual,
    required this.rowCount,
    required this.lastDate,
    this.resolvedSymbol,
    this.replaceImportKey,
  });

  UnbalancedInternalTransfer copyWith({
    String? resolvedSymbol,
    String? replaceImportKey,
  }) =>
      UnbalancedInternalTransfer(
        asset: asset,
        residual: residual,
        rowCount: rowCount,
        lastDate: lastDate,
        resolvedSymbol: resolvedSymbol ?? this.resolvedSymbol,
        replaceImportKey: replaceImportKey ?? this.replaceImportKey,
      );
}

/// Rupture de la chaîne `balance` (oracle Kraken, conception interne) : le rejeu
/// cumulatif `b' = b + amount − fee` par (actif BRUT, wallet) ne recolle pas
/// avec la colonne `balance` déclarée à cette ligne — signe d'un relevé
/// INCOMPLET (fenêtre manquante), jamais corrigé automatiquement.
class ChainRupture {
  final DateTime date;
  final String asset; // code BRUT (pré-alias) — portée réelle de `balance`
  final String? wallet;
  final int sourceLine;
  final String expectedBalance;
  final String actualBalance;

  const ChainRupture({
    required this.date,
    required this.asset,
    this.wallet,
    required this.sourceLine,
    required this.expectedBalance,
    required this.actualBalance,
  });
}

/// Écart entre la quantité PROJETÉE par le plan d'import (mouvements +
/// candidats, ET les échanges en attente de valorisation — CRÉDITÉS ici
/// alors même qu'ils ne journalisent rien, cf. `CryptoLedgerNormalizer.
/// _computeQuantityGaps` I-1 : un échange sans jambe fiat ne doit JAMAIS
/// faire remonter un écart, la quantité est connue dès ce lot, seule sa
/// VALORISATION manque encore) et la somme des `balance` finales des
/// wallets d'un même actif de base (APRÈS alias). Carte d'information,
/// jamais un gardien : un résidu de transfert interne non équilibré
/// (§5.1.5) en est un exemple résiduel, volontairement PAS absorbé ici.
class QuantityGap {
  final String asset; // code de base, APRÈS alias
  final String reportedTotal; // Σ balance finales (rejeu)
  final String projectedTotal; // quantité projetée par le plan

  const QuantityGap({
    required this.asset,
    required this.reportedTotal,
    required this.projectedTotal,
  });
}

/// Résultat PUR de `CryptoLedgerNormalizer.planCryptoImport` — zéro I/O,
/// aucune connaissance du journal déjà en base (c'est `AccountController` qui
/// croise ce plan avec l'existant pour produire l'`ImportPreview` final :
/// doublons, remplacements d'agrégats, résolution d'actif réseau).
class CryptoImportPlan {
  /// Non-null UNIQUEMENT si le fichier est refusé GLOBALEMENT (N1 : ancien
  /// format Kraken sans `wallet`/`subclass`/`amountusd`) — dans ce cas, TOUS
  /// les autres champs restent vides : aucune ligne n'est traitée.
  final String? globalRejectReason;

  /// Mouvements normalisés (candidats + rejets), même forme que
  /// `StatementImportService.normalize` — n'inclut PAS les échanges non
  /// valorisés (ce sont des [UnvaluedExchange], pas des [ImportedMovement]).
  final List<ImportedMovement> movements;

  final List<UnvaluedExchange> unvaluedExchanges;
  final List<UnbalancedInternalTransfer> unbalancedInternalTransfers;
  final List<ChainRupture> chainRuptures;
  final List<QuantityGap> quantityGaps;

  /// Nombre de lignes SOURCE consommées par l'agrégation mensuelle des
  /// récompenses (pas le nombre de buckets) — pour l'affichage (ex. « N
  /// lignes de récompenses regroupées en M mouvements »).
  final int aggregatedRewardSourceRows;

  const CryptoImportPlan({
    this.globalRejectReason,
    this.movements = const [],
    this.unvaluedExchanges = const [],
    this.unbalancedInternalTransfers = const [],
    this.chainRuptures = const [],
    this.quantityGaps = const [],
    this.aggregatedRewardSourceRows = 0,
  });

  const CryptoImportPlan.rejectedGlobally(String reason)
      : globalRejectReason = reason,
        movements = const [],
        unvaluedExchanges = const [],
        unbalancedInternalTransfers = const [],
        chainRuptures = const [],
        quantityGaps = const [],
        aggregatedRewardSourceRows = 0;
}

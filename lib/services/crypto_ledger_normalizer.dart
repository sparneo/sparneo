// lib/services/crypto_ledger_normalizer.dart
//
// Pipeline PUR de normalisation d'un GRAND LIVRE crypto (chantier B16, lot 1 —
// conception interne). Classe statique, ZÉRO I/O (ni disque, ni réseau, ni
// base), symétrique de `StatementImportService` dont elle reprend le point
// d'insertion : `StatementImportService.normalize`/`planCryptoImport` délèguent
// ici quand `BrokerProfile.crypto != null`.
//
// DIFFÉRENCE STRUCTURELLE avec un relevé titre (conception interne) : une ligne
// de grand livre crypto est une JAMBE (un mouvement d'UN actif), pas une
// OPÉRATION — deux jambes d'un même `refid` forment un échange. Le pipeline
// applique donc, sur les lignes brutes déjà ordonnées chronologiquement :
//   [2bis] alias d'identité (stakedSuffixes puis identityAliases) [2ter]
//   groupage des jambes (`LegGroupingStrategy`) [2qua] agrégation mensuelle
//   des récompenses [3] résolution de l'ACTION par ligne/groupe
//   (`CryptoLedgerAction`)
// puis émet directement des `AssetTransaction` — CE FICHIER NE PASSE JAMAIS
// par `StatementImportService._normalizeRow` (chemin titres, kindLexicon par
// libellé simple) : le vocabulaire crypto (`CryptoLedgerSpec.actions`, clé
// composite `type/subtype`) est entièrement distinct.
//
// DUPLICATION ASSUMÉE : `_parseCryptoDate`/`_parseCryptoDecimal` reprennent en
// miniature `StatementImportService._parseDate`/`_parseAmount` — ces méthodes
// sont PRIVÉES à leur fichier (décision architecturale interne : le pipeline
// crypto vit dans un fichier séparé), donc inaccessibles ici. Le sous-ensemble
// nécessaire aux trois formats crypto (année d'abord, suffixe horaire UTC/GMT,
// décimale point) est plus simple que le cas général titres (pas de `compactYmd`)
// : la duplication reste petite et testée indépendamment. Le symbole monétaire
// ANCRÉ tête/queue (`$`/`€`/`£`, conception interne) a rejoint ce sous-ensemble
// au lot 3 (Coinbase) — absent chez Kraken/Binance, sans effet sur ces deux
// profils.
//
// POLITIQUE B4 partout : additif, idempotent, aperçu avant écriture, JAMAIS
// de coercition — une nature/format non reconnu est un REJET MOTIVÉ, jamais
// une approximation silencieuse.

import 'package:decimal/decimal.dart';

import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/crypto_import_plan.dart';
import 'package:portfolio_tracker/model/crypto_ledger_spec.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';

/// Représentation intermédiaire d'UNE jambe (ligne de grand livre), après
/// extraction des colonnes mappées et parsing — jamais exposée hors de ce
/// fichier.
class _Leg {
  final int sourceIndex; // n° de ligne PHYSIQUE 1-based
  final List<String> source;
  final DateTime date;

  /// Horodatage PRÉCIS (jusqu'à la seconde si le relevé la fournit) — À L'USAGE
  /// EXCLUSIF de la fenêtre de tolérance [CryptoLedgerSpec. groupingWindow]
  /// ([LegGroupingStrategy.counterpartyNote], chantier B16 lot 3, conception
  /// interne). DISTINCT de [date] (granularité JOUR, volontairement conservée
  /// ainsi PARTOUT AILLEURS dans ce pipeline — agrégation mensuelle, ordre
  /// chronologique global, `AssetTransaction. date`… — cf. les commentaires de
  /// `_RewardBucket`/`addReward` sur cette granularité ASSUMÉE) : y toucher
  /// aurait un rayon d'effet bien plus large que le seul besoin d'appariement
  /// Coinbase. Repli (relevé sans heure sur CETTE ligne) : minuit UTC du jour de
  /// [date] — TOUJOURS le référentiel UTC, JAMAIS `date` telle quelle (M-r1,
  /// contre-revue, CORRECTIF : `date` est construite par le constructeur LOCAL,
  /// cf. `_parseCryptoDate` — un repli qui la renvoyait directement mélangeait
  /// les référentiels sur un fichier MIXTE, une jambe avec heure comparée à une
  /// jambe sans heure, décalant la fenêtre `groupingWindow` de l'offset local
  /// entier). Le repli n'est donc PAS un simple « diff en jours pleins » : sous
  /// ce format (Coinbase fournit systématiquement une heure), il n'est en
  /// pratique jamais exercé, mais reste correct (minuit UTC) si un futur profil
  /// `counterpartyNote` omettait l'heure sur certaines lignes.
  final DateTime preciseDate;

  final String kindLabel;
  final String? subKind;
  final String rawAsset; // code TEL QUE DANS LE FICHIER, avant alias
  final Decimal quantity; // colonne `amount`, BRUTE (signée)
  final Decimal fee; // colonne `fee`, toujours ≥ 0 par convention Kraken
  final String? wallet;
  final Decimal? balance; // oracle — null si absente/illisible
  final String? assetClass; // 'fiat' / 'stable_coin' / … (subclass)
  final Decimal? valuationUsd; // amountusd — null si absente/illisible (N2)
  final String? operationReference;

  /// Montant de RÈGLEMENT porté par CETTE MÊME ligne (`MovementField.
  /// amount`, ex. `Subtotal` Coinbase) — DISTINCT de [valuationUsd] par le
  /// PROPOS (celui-ci sert au chemin fiat DIRECT d'un `Buy`/`Sell` collapsé
  /// sur une seule ligne, cf. `CryptoLedgerNormalizer._processFiatTrade`),
  /// même si les deux colonnes SOURCE coïncident chez Coinbase (`Subtotal`
  /// alimente les deux). `null` pour un profil qui ne mappe pas
  /// `MovementField.amount` (Kraken) — repli neutre, aucun effet.
  final Decimal? amount;

  /// Devise de [amount] (`MovementField.currency`, ex. `Price Currency`
  /// Coinbase) — garde §5.3.4 : seule une valeur ÉGALE à la devise du
  /// compte autorise le chemin fiat direct. `null` si le profil ne mappe
  /// pas `MovementField.currency`.
  final String? amountCurrency;

  /// Texte libre de la colonne [CryptoLedgerSpec.notesColumn] (ex. `Notes`
  /// Coinbase) — `null` si le profil ne déclare pas cette colonne.
  final String? notes;

  /// Cellules des colonnes ANNEXES référencées par
  /// [CryptoLedgerSpec.conditionalActionRedirects] (ex. `Sender Address`),
  /// résolues une fois par nom de colonne — vide pour un profil qui n'en
  /// déclare aucune (Kraken).
  final Map<String, String?> conditionalColumns;

  /// Séquence MONOTONE dans l'ordre chronologique de traitement (posée en
  /// `meta['seq']` des mouvements émis, départage intraday — même rôle que
  /// `StatementImportService`).
  final int seq;

  /// Code d'actif APRÈS alias d'identité (2bis) — rempli en pass 2, jamais
  /// avant.
  late final String baseAsset;

  /// Action résolue (2ter, avant groupage sémantique) — `null` = nature
  /// inconnue du profil (rejet).
  CryptoLedgerAction? action;

  _Leg({
    required this.sourceIndex,
    required this.source,
    required this.date,
    required this.preciseDate,
    required this.kindLabel,
    required this.subKind,
    required this.rawAsset,
    required this.quantity,
    required this.fee,
    required this.wallet,
    required this.balance,
    required this.assetClass,
    required this.valuationUsd,
    required this.operationReference,
    required this.amount,
    required this.amountCurrency,
    required this.notes,
    required this.conditionalColumns,
    required this.seq,
  });

  /// Effet NET de la ligne sur la quantité de [rawAsset] (conception interne :
  /// brut, net = amount − fee, TOUJOURS — le frais est toujours en nature dans
  /// l'actif de la ligne).
  Decimal get net => quantity - fee;
}

/// Bucket d'agrégation mensuelle des récompenses (conception interne),
/// clé `(baseAsset, mois)`.
class _RewardBucket {
  final String baseAsset;
  final String month; // 'AAAA-MM'
  Decimal netSum = Decimal.zero;
  Decimal feeInKind = Decimal.zero;
  int rowCount = 0;
  DateTime? firstDate;
  DateTime? lastDate;
  int? firstSeq;
  int? lastSeq;

  /// Somme de `_Leg.valuationUsd` des lignes du bucket (chantier B16 lot 3,
  /// conception interne — Coinbase `Reward Income`, `Subtotal` USD EN META
  /// SEULEMENT, jamais utilisé pour le coût — les récompenses restent à coût 0).
  /// `null` dès qu'UNE ligne du bucket n'a pas de valorisation lisible (jamais
  /// une somme PARTIELLE trompeuse, B4).
  Decimal? valuationUsdSum = Decimal.zero;

  _RewardBucket(this.baseAsset, this.month);
}

/// Contrepartie CIBLE extraite du texte libre `Notes` d'une jambe `Convert`
/// sortante (chantier B16 lot 3, conception interne) — `qty`/`asset` du motif
/// [CryptoLedgerSpec.counterpartyPattern], jamais exposée hors de ce fichier.
class _ConvertTarget {
  final Decimal qty;
  final String asset;

  const _ConvertTarget({required this.qty, required this.asset});
}

/// Pipeline PUR de normalisation d'un grand livre crypto. Voir doc de fichier.
class CryptoLedgerNormalizer {
  CryptoLedgerNormalizer._(); // classe statique, jamais instanciée

  /// Point d'entrée PUR : normalise les [rows] (déjà décodées/parsées par
  /// `StatementImportService.parseWithLineNumbers`, en-tête inclus si
  /// `profile.hasHeaderRow`) selon [profile] (dont `profile.crypto` DOIT être
  /// non-null — appelant fautif sinon, cf. garde ci-dessous).
  static CryptoImportPlan planCryptoImport(
    List<List<String>> rows,
    BrokerProfile profile, {
    required String accountCurrency,
    required String accountId,
    List<int>? sourceLines,
  }) {
    final crypto = profile.crypto;
    if (crypto == null || rows.isEmpty) return const CryptoImportPlan();

    final header = profile.hasHeaderRow ? rows.first : null;

    // ---- Refus GLOBAL motivé (N1, ancien format Kraken) ----
    for (final required in crypto.requiredColumns) {
      if (_byNameIndex(header, required) == null) {
        return const CryptoImportPlan.rejectedGlobally(
          'cryptoLegacyFormatUnsupported',
        );
      }
    }

    final dataRows = profile.hasHeaderRow ? rows.skip(1).toList() : rows;
    final headerOffset = profile.hasHeaderRow ? 1 : 0;

    int sourceLineFor(int dataRowIdx) {
      if (sourceLines == null) return dataRowIdx;
      final absIdx = dataRowIdx + headerOffset;
      return absIdx >= 0 && absIdx < sourceLines.length
          ? sourceLines[absIdx]
          : dataRowIdx;
    }

    // ---- Résolution des colonnes ----
    final dateIdx = _fieldIndex(header, profile, MovementField.date);
    final kindIdx = _fieldIndex(header, profile, MovementField.kindLabel);
    final assetIdx = _fieldIndex(header, profile, MovementField.symbol);
    final qtyIdx = _fieldIndex(header, profile, MovementField.quantity);
    final feeIdx = _fieldIndex(header, profile, MovementField.fee);
    final refIdx =
        _fieldIndex(header, profile, MovementField.operationReference);
    final subKindIdx = _byNameIndex(header, crypto.subKindColumn);
    final walletIdx = _byNameIndex(header, crypto.walletColumn);
    final balanceIdx = _byNameIndex(header, crypto.balanceColumn);
    final classIdx = _byNameIndex(header, crypto.assetClassColumn);
    final valuationIdx = _byNameIndex(header, crypto.valuationAmountColumn);
    // `MovementField.amount`/`currency` : SANS équivalent Kraken (`null` pour
    // tout profil qui ne les mappe pas, ex. `BrokerProfile.kraken`) — servent au
    // seul chemin `_processFiatTrade` (lot 3, Buy/Sell Coinbase collapsés sur une
    // ligne unique, conception interne).
    final amountIdx = _fieldIndex(header, profile, MovementField.amount);
    final currencyIdx = _fieldIndex(header, profile, MovementField.currency);
    final notesIdx = _byNameIndex(header, crypto.notesColumn);

    // ---- Refus GLOBAL motivé (M-3, revue adversariale) : colonne Notes
    // ATTENDUE par le profil (`crypto.notesColumn` non nul, ex. `Notes`
    // Coinbase) mais ABSENTE de l'en-tête réel — message DÉDIÉ, distinct de
    // « langue non reconnue » (ci-dessous), qui autrement induirait en erreur
    // (SANS colonne Notes, chaque tentative d'extraction échoue de toute
    // façon, mais la cause n'est pas linguistique). Évalué EN PREMIER,
    // indépendamment de la présence de lignes `Convert` dans le fichier.
    if (crypto.grouping == LegGroupingStrategy.counterpartyNote &&
        crypto.notesColumn != null &&
        notesIdx == null) {
      return const CryptoImportPlan.rejectedGlobally(
        'cryptoConvertNotesColumnMissing',
      );
    }
    // Colonnes ANNEXES référencées par les redirections déclaratives
    // (`Sender Address` Coinbase…) — résolues UNE fois, jamais par ligne.
    final conditionalColumnIndices = <String, int?>{
      for (final redirect in crypto.conditionalActionRedirects)
        redirect.matchColumn: _byNameIndex(header, redirect.matchColumn),
    };

    // ---- PASSE 1 : extraction brute + parsing, ordre du FICHIER ----
    final legs = <_Leg>[];
    final earlyRejects = <ImportedMovement>[];
    for (var i = 0; i < dataRows.length; i++) {
      final row = dataRows[i];
      if (row.every((c) => c.trim().isEmpty)) continue; // ligne vide, ignorée

      final srcIndex = sourceLineFor(i);
      ImportedMovement reject(String reason) => ImportedMovement.rejected(
            sourceRow: row,
            sourceRowIndex: srcIndex,
            rejectReason: reason,
          );

      final kindRaw = _cell(row, kindIdx);
      final assetRaw = _cell(row, assetIdx);
      final dateRaw = _cell(row, dateIdx);
      final qtyRaw = _cell(row, qtyIdx);

      if (kindRaw == null) {
        earlyRejects.add(reject('missingCryptoKind'));
        continue;
      }
      if (assetRaw == null) {
        earlyRejects.add(reject('missingCryptoAsset'));
        continue;
      }
      final date = _parseCryptoDate(dateRaw, profile.dateFormat);
      if (date == null) {
        earlyRejects.add(reject('invalidCryptoDate'));
        continue;
      }
      // Repli en UTC (M-r1, contre-revue, CORRECTIF) — `date` est du
      // référentiel LOCAL (`_parseCryptoDate`, constructeur `DateTime`
      // nu) : la renvoyer telle quelle aurait mélangé les référentiels sur
      // un fichier MIXTE (une jambe datée avec heure → `DateTime.utc` via
      // `_parseCryptoTimeOfDay`, l'autre sans heure → `date` LOCAL),
      // décalant `groupingWindow` de l'offset local entier (mesuré : 2 h
      // 00 min 05 s au lieu de 5 s sous Europe/Paris). `DateTime.utc` sur
      // les mêmes année/mois/jour fixe le même référentiel dans les deux
      // branches.
      final preciseDate = _parseCryptoTimeOfDay(dateRaw, date) ??
          DateTime.utc(date.year, date.month, date.day);
      if (qtyRaw == null) {
        earlyRejects.add(reject('missingCryptoQuantity'));
        continue;
      }
      final quantity = _parseCryptoDecimal(qtyRaw, profile.decimalSeparator);
      if (quantity == null) {
        earlyRejects.add(reject('invalidCryptoQuantity'));
        continue;
      }
      final feeRaw = _cell(row, feeIdx);
      final fee = feeRaw == null
          ? Decimal.zero
          : _parseCryptoDecimal(feeRaw, profile.decimalSeparator);
      if (fee == null) {
        earlyRejects.add(reject('invalidCryptoFee'));
        continue;
      }

      final balanceRaw = _cell(row, balanceIdx);
      final valuationRaw = _cell(row, valuationIdx);
      final amountRaw = _cell(row, amountIdx);
      final amountCurrencyRaw = _cell(row, currencyIdx);

      // GARDE « Price Currency » (B-2, revue adversariale, CORRECTIF) : la
      // colonne [crypto.valuationAmountColumn] (ex. `Subtotal` Coinbase) est
      // DOCUMENTÉE comme étant en [CryptoLedgerSpec.valuationCurrency] (ex.
      // `USD`) — mais un relevé qui MAPPE `MovementField.currency` (`Price
      // Currency`) peut porter une devise DIFFÉRENTE sur CETTE ligne (ex. un
      // compte dont Coinbase a facturé en EUR). AVANT ce correctif, `leg.
      // valuationUsd` était pris tel quel dans ce cas — un compte EUR aurait
      // vu son propre `Subtotal` EUR traité comme du USD par la cascade de
      // valorisation (`usdPaid`/`usdReceived` d'un `Convert`, `usdReceived`
      // d'un dépôt en nature, `meta['valuationUsd']` d'un retrait) : ×taux
      // USD→EUR appliqué à un montant DÉJÀ en EUR, falsification silencieuse
      // (~14 % dans l'exemple de la revue). Seule une colonne `currency`
      // RENSEIGNÉE ET DIFFÉRENTE (comparaison insensible à la casse) annule
      // la valorisation — `null` (illisible/absente) reste neutre, comme
      // avant ce correctif : la ligne retombe alors en arbitrage manuel
      // visible (`UnvaluedExchange` sans `usdPaid`/`usdReceived`, jamais un
      // montant faux).
      final priceCurrencyMismatch = currencyIdx != null &&
          amountCurrencyRaw != null &&
          amountCurrencyRaw.toUpperCase() != crypto.valuationCurrency.toUpperCase();

      legs.add(_Leg(
        sourceIndex: srcIndex,
        source: row,
        date: date,
        preciseDate: preciseDate,
        kindLabel: kindRaw,
        subKind: _cell(row, subKindIdx),
        rawAsset: assetRaw,
        quantity: quantity,
        fee: fee,
        wallet: _cell(row, walletIdx),
        // Illisible (ex. littéral `-`, N2) → `null`, jamais un rejet de ligne
        // (la ligne reste traitée, seule la valorisation est indisponible).
        balance: balanceRaw == null
            ? null
            : _parseCryptoDecimal(balanceRaw, profile.decimalSeparator),
        assetClass: _cell(row, classIdx),
        valuationUsd: priceCurrencyMismatch
            ? null
            : (valuationRaw == null
                ? null
                : _parseCryptoDecimal(valuationRaw, profile.decimalSeparator)),
        operationReference: _cell(row, refIdx),
        amount: amountRaw == null
            ? null
            : _parseCryptoDecimal(amountRaw, profile.decimalSeparator),
        amountCurrency: amountCurrencyRaw,
        notes: _cell(row, notesIdx),
        conditionalColumns: {
          for (final entry in conditionalColumnIndices.entries)
            entry.key: _cell(row, entry.value),
        },
        seq: 0, // réassigné après le tri chronologique, cf. plus bas
      ));
    }

    // ---- Détection du sens chronologique (miroir de
    // StatementImportService._chronologicalOrder) ----
    if (legs.length >= 2 && legs.last.date.isBefore(legs.first.date)) {
      final reversed = legs.reversed.toList();
      legs
        ..clear()
        ..addAll(reversed);
    }

    // Réassignation de `seq` dans l'ordre chronologique final (rejets de
    // parsing EXCLUS de la séquence — ils ne portent aucun mouvement).
    for (var i = 0; i < legs.length; i++) {
      legs[i] = _withSeq(legs[i], i);
    }

    // ---- [2bis] Alias d'identité — AVANT le groupage (conception interne) ----
    for (final leg in legs) {
      leg.baseAsset = _applyAlias(leg.rawAsset, crypto);
    }

    // ---- Résolution de l'ACTION par ligne (repli type/subtype → type) ----
    for (final leg in legs) {
      leg.action = _resolveAction(leg, crypto);
    }

    // ---- Refus GLOBAL motivé (langue non reconnue, chantier B16 lot 3, conception
    // interne) — [LegGroupingStrategy.counterpartyNote] UNIQUEMENT : le motif
    // [CryptoLedgerSpec.counterpartyPattern] ne matche AUCUNE ligne `Convert`
    // SORTANTE (quantité négative) du fichier entier → message DÉDIÉ, jamais 19
    // rejets muets ligne à ligne (une seule ligne qui matche suffit à écarter ce
    // diagnostic ; les autres échecs individuels restent des rejets motivés
    // `convertNotesUnparsed`, cf. la boucle de groupage plus bas).
    //
    // SEUIL ≥ 2 (M-3, revue adversariale, CORRECTIF) : SOUS ce seuil (0 ou 1
    // sortante non matchée), le diagnostic « langue non reconnue » est
    // disproportionné — un unique fichier synthétique/test à une seule
    // conversion malformée partait en refus GLOBAL alors qu'un simple rejet
    // ligne à ligne motivé (`convertNotesUnparsed`) suffit à le signaler
    // SANS priver le reste du fichier de son import. `negativeConverts.
    // every(...)` restant `true` implique que TOUTES les sortantes ont
    // échoué : la longueur de la liste EST donc le compte de non-matchées,
    // pas seulement son plancher.
    if (crypto.grouping == LegGroupingStrategy.counterpartyNote &&
        crypto.counterpartyPattern != null) {
      final negativeConverts = legs.where((l) =>
          l.action == CryptoLedgerAction.exchangeLeg &&
          l.quantity.sign < 0);
      if (negativeConverts.length >= 2 &&
          negativeConverts.every((l) =>
              crypto.counterpartyPattern!.firstMatch(l.notes ?? '') ==
              null)) {
        return const CryptoImportPlan.rejectedGlobally(
          'cryptoConvertNotesLanguageUnrecognized',
        );
      }
    }

    // ---- Oracle `balance` (§5.1.10) — rejeu sur l'actif BRUT/wallet, TOUTES
    // les jambes (indépendant de l'action résolue : le fichier est ou n'est
    // pas auto-cohérent, quelle que soit notre compréhension des codes) ----
    final chainRuptures = <ChainRupture>[];
    final finalBalanceByRawKey = <String, Decimal>{};
    for (final leg in legs) {
      if (leg.balance == null || leg.wallet == null) continue;
      final key = '${leg.rawAsset}|${leg.wallet}';
      final prev = finalBalanceByRawKey[key] ?? Decimal.zero;
      final expected = prev + leg.net;
      if (expected != leg.balance) {
        chainRuptures.add(ChainRupture(
          date: leg.date,
          asset: leg.rawAsset,
          wallet: leg.wallet,
          sourceLine: leg.sourceIndex,
          expectedBalance: expected.toString(),
          actualBalance: leg.balance.toString(),
        ));
      }
      // Resynchronisation sur la valeur DÉCLARÉE (jamais la valeur calculée) :
      // une rupture reste locale à la ligne où elle est détectée, au lieu de
      // se propager en cascade sur tout le reste du fichier.
      finalBalanceByRawKey[key] = leg.balance!;
    }

    final movements = <ImportedMovement>[...earlyRejects];
    final unvaluedExchanges = <UnvaluedExchange>[];
    final internalTransferTally = <String, Decimal>{};
    final internalTransferRows = <String, int>{};
    final internalTransferLastDate = <String, DateTime>{};
    final rewardBuckets = <String, _RewardBucket>{};

    void reject(_Leg leg, String reason) {
      movements.add(ImportedMovement.rejected(
        sourceRow: leg.source,
        sourceRowIndex: leg.sourceIndex,
        rejectReason: reason,
      ));
    }

    // ---- [2ter] Groupage des jambes — APRÈS la déclaration de `reject`
    // (l'appariement `counterpartyNote` rejette directement les jambes
    // Convert non appariées, cf. `_groupByCounterpartyNote`) ----
    final groups = _groupLegs(legs, crypto, profile.decimalSeparator, reject);

    void addReward(_Leg leg) {
      final month =
          '${leg.date.year.toString().padLeft(4, '0')}-${leg.date.month.toString().padLeft(2, '0')}';
      final key = '${leg.baseAsset}|$month';
      final bucket =
          rewardBuckets.putIfAbsent(key, () => _RewardBucket(leg.baseAsset, month));
      bucket.netSum += leg.net;
      bucket.feeInKind += leg.fee;
      bucket.rowCount++;
      // Cf. la doc de `_RewardBucket.valuationUsdSum` : somme EXACTE si
      // TOUTES les lignes du bucket ont une valorisation lisible, `null`
      // dès la première absente (jamais une somme partielle).
      if (leg.valuationUsd == null || bucket.valuationUsdSum == null) {
        bucket.valuationUsdSum = null;
      } else {
        bucket.valuationUsdSum = bucket.valuationUsdSum! + leg.valuationUsd!;
      }
      // Comparaison ROBUSTE sur `seq` (jamais sur `date` seule) : l'ordre
      // d'itération des GROUPES (par `refid`) n'implique pas que les jambes
      // d'un même bucket (actif, mois) soient visitées en ordre
      // chronologique strict entre groupes différents — revue adversariale,
      // mineur. `seq` est réassigné en PASSE 1 dans l'ordre chronologique
      // FINAL du fichier (ligne ~254) : il totalement-ordonne les jambes,
      // contrairement à `date` (granularité JOUR, ties possibles), donc
      // trancher premier/dernier sur `seq` est strictement plus précis qu'un
      // enchaînement de comparaisons de `date` — et garde `firstDate`
      // synchronisé avec `firstSeq` (nécessaire au fix ci-dessous : dater
      // l'agrégat sur la PREMIÈRE ligne, jamais la dernière).
      if (bucket.firstSeq == null || leg.seq < bucket.firstSeq!) {
        bucket.firstSeq = leg.seq;
        bucket.firstDate = leg.date;
      }
      if (bucket.lastSeq == null || leg.seq > bucket.lastSeq!) {
        bucket.lastSeq = leg.seq;
        bucket.lastDate = leg.date;
      }
    }

    for (final entry in groups.entries) {
      final refid = entry.key;
      final rawLegs = entry.value;

      final activeLegs = <_Leg>[];
      for (final leg in rawLegs) {
        if (leg.action == null) {
          reject(leg, 'unknownCryptoAction');
          continue;
        }
        if (leg.action == CryptoLedgerAction.manualReview) {
          reject(leg, 'cryptoManualReview');
          continue;
        }
        activeLegs.add(leg);
      }
      if (activeLegs.isEmpty) continue;

      final actionsPresent = activeLegs.map((l) => l.action!).toSet();
      if (actionsPresent.length > 1) {
        for (final leg in activeLegs) {
          reject(leg, 'mixedCryptoActionsInGroup');
        }
        continue;
      }

      final action = actionsPresent.single;
      switch (action) {
        case CryptoLedgerAction.reward:
          if (crypto.rewards == RewardAggregation.monthly) {
            for (final leg in activeLegs) {
              addReward(leg);
            }
          } else {
            for (final leg in activeLegs) {
              movements.add(_emitRewardIndividual(
                leg,
                accountId: accountId,
                accountCurrency: accountCurrency,
              ));
            }
          }
          break;

        case CryptoLedgerAction.internalTransfer:
          for (final leg in activeLegs) {
            internalTransferTally[leg.baseAsset] =
                (internalTransferTally[leg.baseAsset] ?? Decimal.zero) +
                    leg.net;
            internalTransferRows[leg.baseAsset] =
                (internalTransferRows[leg.baseAsset] ?? 0) + 1;
            // Comparaison ROBUSTE (même raisonnement que `addReward`,
            // mineur) : l'ordre d'itération des GROUPES (par `refid`)
            // n'implique pas l'ordre chronologique entre groupes différents
            // touchant le même actif.
            final prevLast = internalTransferLastDate[leg.baseAsset];
            if (prevLast == null || !leg.date.isBefore(prevLast)) {
              internalTransferLastDate[leg.baseAsset] = leg.date;
            }
          }
          break;

        case CryptoLedgerAction.assetMigration:
          _processMigrationGroup(activeLegs, reject);
          break;

        case CryptoLedgerAction.depositIn:
        case CryptoLedgerAction.withdrawalOut:
          // Opération ANNULÉE (drive lot 1) : Kraken re-crédite un retrait
          // échoué sous le MÊME refid (jambe miroir, frais remboursé en
          // négatif). Prises isolément, la jambe négative sortirait pour de
          // vrai et la positive serait rejetée (signe contredisant le type)
          // — projection faussée d'autant. Le net à zéro PAR ACTIF sous un
          // refid commun identifie l'annulation sans rien deviner : même
          // motif de rejet que la jambe individuelle nette nulle.
          final netByRawAsset = <String, Decimal>{};
          for (final leg in activeLegs) {
            netByRawAsset[leg.rawAsset] =
                (netByRawAsset[leg.rawAsset] ?? Decimal.zero) + leg.net;
          }
          final roleOccurrences = <String, int>{};
          for (final leg in activeLegs) {
            if (netByRawAsset[leg.rawAsset] == Decimal.zero) {
              reject(leg, 'cryptoZeroNetMovement');
              continue;
            }
            _processDepositOrWithdrawal(
              leg,
              refid: refid,
              accountId: accountId,
              accountCurrency: accountCurrency,
              crypto: crypto,
              movements: movements,
              unvaluedExchanges: unvaluedExchanges,
              roleOccurrences: roleOccurrences,
              reject: reject,
            );
          }
          break;

        case CryptoLedgerAction.exchangeLeg:
          _processExchangeGroup(
            activeLegs,
            refid: refid,
            accountId: accountId,
            accountCurrency: accountCurrency,
            crypto: crypto,
            movements: movements,
            unvaluedExchanges: unvaluedExchanges,
            reject: reject,
          );
          break;

        case CryptoLedgerAction.fiatBuy:
        case CryptoLedgerAction.fiatSell:
          // Toujours des groupes SINGLETON (`_groupByCounterpartyNote`
          // n'apparie jamais ces natures) — une ligne = une opération
          // complète (quantité crypto + montant de règlement), à la
          // différence de `exchangeLeg` qui a besoin d'une contrepartie.
          for (final leg in activeLegs) {
            _processFiatTrade(
              leg,
              action,
              refid: refid,
              accountId: accountId,
              accountCurrency: accountCurrency,
              movements: movements,
              unvaluedExchanges: unvaluedExchanges,
              reject: reject,
            );
          }
          break;

        case CryptoLedgerAction.manualReview:
          // Filtré plus haut (jamais dans activeLegs) — case gardée pour
          // l'exhaustivité du switch.
          break;
      }
    }

    // ---- [2qua] Finalisation de l'agrégation mensuelle ----
    var aggregatedRewardSourceRows = 0;
    for (final bucket in rewardBuckets.values) {
      aggregatedRewardSourceRows += bucket.rowCount;
      final importKey =
          'agg:$accountId:${profile.id}:${bucket.baseAsset}:${bucket.month}';
      final meta = <String, dynamic>{
        'corporateAction': 'stakingReward',
        'aggregation': 'monthly',
        // Généralisation I-2 (revue adversariale) : le mécanisme de
        // remplacement ciblé de `LedgerService.importMovements` reconnaît
        // maintenant `aggregation=='monthly'` OU `replaceable==true` — cet
        // agrégat porte les deux, le résidu de transfert interne (posé côté
        // contrôleur, cf. `UnbalancedInternalTransfer.replaceImportKey`) ne
        // porte que le second.
        'replaceable': true,
        'aggregatedMonth': bucket.month,
        'aggregatedRows': bucket.rowCount,
        'aggregatedFrom': _isoDay(bucket.firstDate!),
        'aggregatedTo': _isoDay(bucket.lastDate!),
        'aggregatedFeeInKind': bucket.feeInKind.toString(),
        // Cf. `_RewardBucket.valuationUsdSum` — INFORMATIF seulement (le
        // coût de la récompense reste 0), absent si une seule ligne du
        // bucket manquait de valorisation lisible.
        if (bucket.valuationUsdSum != null)
          'aggregatedValuationUsd': bucket.valuationUsdSum!.toString(),
        'ledgerCode': bucket.baseAsset,
        // Datation et `seq` sur la PREMIÈRE ligne du mois (`firstDate`/
        // `firstSeq`), PAS la dernière : la projection (`replayLedger`,
        // position_projection.dart) borne le solde courant à zéro (clamp
        // anti-survente). Un agrégat daté `lastDate` crédite les récompenses
        // du mois APRÈS toute vente/désallocation survenue plus tôt dans le
        // même mois alors que ces récompenses étaient déjà acquises — la
        // vente plonge alors le solde sous zéro, le clamp mange la
        // différence, et le solde final se retrouve SURÉVALUÉ du montant des
        // récompenses antérieures à la vente. Créditer au plus tôt (début de
        // mois) est toujours sûr vis-à-vis du clamp : une vente ne peut en
        // réalité consommer que des récompenses déjà créditées. Contrepartie
        // ASSUMÉE de l'agrégation mensuelle : le solde intra-mois est
        // temporairement SURÉVALUÉ entre `firstDate` et `lastDate` (toutes
        // les récompenses du mois sont réputées acquises dès la première),
        // mais le solde de FIN de mois — et tout rejeu qui dépasse
        // `lastDate` — reste exact.
        'seq': bucket.firstSeq,
        'importKey': importKey,
      };
      final tx = AssetTransaction(
        id: AssetTransaction.generateId(),
        accountId: accountId,
        symbol: null,
        kind: TransactionKind.adjustment,
        quantity: bucket.netSum.toString(),
        unitPrice: null,
        amount: null,
        currency: accountCurrency,
        date: bucket.firstDate!,
        meta: meta,
      );
      movements.add(ImportedMovement.candidate(
        sourceRow: const [],
        sourceRowIndex: -1,
        transaction: tx,
        ledgerCode: bucket.baseAsset,
        needsAssetResolution: true,
        importKey: importKey,
      ));
    }

    // ---- Bilan de cohérence des transferts internes (§5.1.5) ----
    final unbalancedInternalTransfers = <UnbalancedInternalTransfer>[];
    internalTransferTally.forEach((asset, residual) {
      if (residual == Decimal.zero) return;
      unbalancedInternalTransfers.add(UnbalancedInternalTransfer(
        asset: asset,
        residual: residual.toString(),
        rowCount: internalTransferRows[asset] ?? 0,
        lastDate: internalTransferLastDate[asset]!,
      ));
    });

    // ---- Garde de projection (§5.1.10, seconde carte) ----
    // Le FIAT (EUR…) n'est PAS une « position » : sa balance Kraken existe
    // (colonne balance renseignée pour toutes les lignes, y compris cash)
    // mais aucun mouvement crypto n'est projeté pour lui (dépôts/retraits
    // fiat sont du cash pur, `ledgerCode == null`) — sans cette exclusion,
    // CHAQUE compte afficherait un « écart de quantité » fantôme sur sa
    // devise de règlement.
    final fiatRawAssets = <String>{
      for (final leg in legs)
        if (_isFiat(leg, crypto)) leg.rawAsset,
    };
    // SANS oracle `balance` (`crypto.balanceColumn == null`, ex. Coinbase —
    // chantier B16 lot 3, conception interne), il n'existe AUCUNE valeur «
    // rapportée » de référence : `finalBalanceByRawKey` reste vide pour TOUS les
    // actifs, et comparer un rapporté à 0 par défaut à la quantité PROJETÉE
    // fabriquerait un « écart » fantôme sur CHAQUE actif importé — exactement
    // l'inverse de la garde Kraken ci-dessus (qui exclut le fiat d'une carte par
    // ailleurs légitime). Le profil ANNONCE l'absence d'oracle (aucune carte,
    // jamais une carte fausse) : aucune carte du tout plutôt qu'une carte 100 %
    // fausse positifs.
    final quantityGaps = crypto.balanceColumn == null
        ? const <QuantityGap>[]
        : _computeQuantityGaps(
            movements,
            unvaluedExchanges,
            finalBalanceByRawKey,
            crypto,
            fiatRawAssets,
          );

    return CryptoImportPlan(
      movements: movements,
      unvaluedExchanges: unvaluedExchanges,
      unbalancedInternalTransfers: unbalancedInternalTransfers,
      chainRuptures: chainRuptures,
      quantityGaps: quantityGaps,
      aggregatedRewardSourceRows: aggregatedRewardSourceRows,
    );
  }

  /// Transforme les [UnvaluedExchange] de [plan] DONT une valorisation est
  /// disponible dans [valuations] (clé = `UnvaluedExchange.importKey`, cf.
  /// `CryptoValuationService.resolve`) en mouvements complets `sell`+`buy` (kind
  /// `'exchange'`) ou `adjustment` à coût (kind `'depositInKind'`) — chantier
  /// B16, lot 2, conception interne PUR : aucune I/O, la résolution
  /// FX/lisibilité/spread a DÉJÀ eu lieu en amont (`CryptoValuationService`,
  /// appelée par `AccountController`).
  ///
  /// Un [UnvaluedExchange] SANS entrée dans [valuations] (arbitrage manuel —
  /// spread excessif, jambes illisibles, FX indisponible…) n'émet RIEN ici :
  /// il reste exclusivement dans `plan.unvaluedExchanges`, jamais dans le
  /// résultat de cette méthode (l'appelant les distingue par simple
  /// différence d'ensemble, cf. `AccountController._previewCryptoImport`).
  /// Deux gardes SUPPLÉMENTAIRES, avant toute émission (voir leurs
  /// commentaires au fil du corps) : B-1 (clé `importKey` partagée par ≥ 2
  /// entrées, jamais émise même valorisée) et B-2 (jambe payée/reçue au code
  /// de la devise du compte, jamais émise — buy/position `EUR` fabriqué).
  ///
  /// RÈGLE N4 (piège conception interne) — UNE valeur par opération : pour un
  /// échange, `amount(sell)` et `amount(buy)` sont la MÊME [Decimal]
  /// (`valuation.amountEur`) en signes EXACTEMENT opposés — négation LITTÉRALE,
  /// jamais un recalcul indépendant depuis chaque jambe — pour un cash net
  /// rigoureusement nul.
  ///
  /// `fee` reste TOUJOURS `null` sur les mouvements émis ici : les frais en
  /// nature sont déjà absorbés dans les quantités NETTES portées par
  /// [UnvaluedExchange] (`quantityPaid`/`quantityReceived`, calculées en amont
  /// par `planCryptoImport` comme `amount − fee`) — les compter une seconde fois
  /// via le champ `fee` compterait double (conception interne).
  ///
  /// [accountCurrency] fixe `currency`/`settlementCurrency` des mouvements émis :
  /// le COÛT issu du journal crypto est TOUJOURS exprimé dans la devise DU COMPTE
  /// (`valuation.amountEur`, converti via la série FX historique), JAMAIS dans une
  /// devise de cotation native — c'est ce qui lève la réserve PRU/`-USD` du lot 1
  /// (conception interne) : la COTATION d'un actif résolu en `<code>-USD` (étage 4
  /// de la cascade `AccountController._resolveCryptoTicker`) continue de se
  /// convertir à l'affichage, mais le PRU dérivé de CES mouvements n'a plus jamais
  /// besoin de l'être, puisqu'il n'est jamais natif USD.
  ///
  /// EXCEPTION — jambe fiat ÉTRANGÈRE USD (amendement, voie (ii),
  /// `CryptoValuation.source == 'fiatLeg'`, cf. `CryptoValuationService`) : modèle
  /// d'ÉMISSION DIFFÉRENT de la règle N4 ci-dessus. La jambe USD N'EST JAMAIS UNE
  /// POSITION (B-A toujours en vigueur, AUCUN mouvement émis pour elle) — on émet
  /// la SEULE jambe crypto avec du cash RÉEL, exactement comme un trade à jambe
  /// fiat ordinaire du lot 1 (`_processExchangeGroup`, branche `nonFiatLegs.length
  /// == 1`) : `sell` (crypto payée, USD reçu, cash ENTRANT positif) ou `buy` (USD
  /// payé, crypto reçue, cash SORTANT négatif), montant = quantité nette de la
  /// jambe USD × taux du jour.
  ///
  /// [externalDepositKinds] (refactor B16 lot 3, préparation Coinbase) : le
  /// vocabulaire des natures SOURCE reconnues comme VRAI apport externe
  /// (`UnvaluedExchange.sourceKindLabel`, cf. la branche `depositInKind`
  /// ci-dessous, doc de `CryptoLedgerSpec.externalDepositKinds`) — l'appelant
  /// DOIT passer `profile.crypto!.externalDepositKinds` (jamais un littéral
  /// codé ici). REQUIS (pas de défaut) : cette méthode PURE n'a par ailleurs
  /// aucun accès à [CryptoLedgerSpec] via [plan] (`CryptoImportPlan` ne porte
  /// pas le profil), d'où ce paramètre plutôt qu'une lecture globale — un
  /// défaut aurait fait retomber silencieusement un futur profil (Coinbase)
  /// qui oublierait de le passer sur le vocabulaire Kraken.
  static List<ImportedMovement> finalizeCryptoExchanges(
    CryptoImportPlan plan,
    Map<String, CryptoValuation> valuations, {
    required String accountId,
    required String accountCurrency,
    required Set<String> externalDepositKinds,
  }) {
    final out = <ImportedMovement>[];

    // B-1 (BLOQUANT, revue adversariale) : ceinture INDÉPENDANTE du pré-scan
    // de `CryptoValuationService.resolve` — une clé partagée par ≥ 2
    // `UnvaluedExchange` (dustsweeping N→1 dégénéré à `amountusd`
    // partiellement illisible, ou dépôt en nature multi-jambes, cf.
    // `_processExchangeGroup`/`_processDepositOrWithdrawal`) ne doit JAMAIS
    // être émise ici, MÊME si une valorisation traîne malgré tout dans
    // [valuations] pour cette clé (y compris une valorisation MANUELLE) :
    // cette méthode itère sur les ENTRÉES et appliquerait sinon à CHACUNE
    // l'UNIQUE valorisation retenue pour la clé — jambes émises au mauvais
    // montant, clés `importKey` dupliquées en base (dédup en aval par
    // importKey, pas de garde intra-lot).
    final keyCounts = <String, int>{};
    for (final u in plan.unvaluedExchanges) {
      keyCounts[u.importKey] = (keyCounts[u.importKey] ?? 0) + 1;
    }

    for (final u in plan.unvaluedExchanges) {
      if ((keyCounts[u.importKey] ?? 0) >= 2) {
        continue; // clé partagée — jamais émis (B-1), reste manuel/visible.
      }

      // B-2 (BLOQUANT, revue adversariale) : garde EXPLICITE et INDÉPENDANTE
      // de B-1 — dans la branche dégénérée du dustsweeping N→1 (répartition
      // au prorata impossible, `amountusd` illisible quelque part dans le
      // groupe), `codeReceived` peut valoir le CODE FIAT DU COMPTE (la jambe
      // fiat du groupe, jamais un actif crypto). Émettre quand même
      // fabriquerait un `buy` d'actif `EUR` : position inventée, espèces
      // jamais créditées (la jambe `sell` de la contrepartie ne compense
      // rien). Toute jambe (payée OU reçue) dont le code égale la devise du
      // compte reste donc manuelle, comparaison insensible à la casse.
      //
      // CORRECTIF I-1 (revue adversariale, BLOQUANT) : cette garde DOIT
      // s'exécuter AVANT la branche fiat ci-dessous — sinon l'exception
      // 1-quater (`_finalizeFiatLegExchange`) peut émettre un mouvement pour
      // une entrée dont la jambe « crypto » restante porte en réalité LE CODE
      // DE LA DEVISE DU COMPTE (ex. relevé forgé : USD payé, jambe reçue
      // classée crypto par la colonne subclass mais codée littéralement
      // `EUR` sur un compte `EUR`) — `codeReceivedIsFiat` vaut `false` pour
      // cette jambe (reclassée crypto en amont), donc la garde B-A ci-dessous
      // ne la voit pas comme fiat et laisserait passer l'exception, qui
      // fabriquerait une position crypto `EUR` + un débit cash non compensé.
      // L'exception 1-quater DOIT donc passer sous cette garde exactement
      // comme les autres chemins d'émission. Ordre désormais : B-1 → B-2 →
      // B-A.
      if (u.codeReceived.toUpperCase() == accountCurrency.toUpperCase() ||
          (u.codePaid?.toUpperCase() == accountCurrency.toUpperCase())) {
        continue; // devise du compte en jambe titre — jamais émis (B-2).
      }

      // B-A (BLOQUANT, contre-vérification lot 2) : ceinture INDÉPENDANTE du
      // pré-scan de `CryptoValuationService.resolve` — une entrée dont l'une
      // des deux jambes est FIAT (typiquement étrangère à la devise du
      // compte, ex. `GBP` sur un compte `EUR`, cf. `_processExchangeGroup`
      // branche `fiatLegs.isEmpty`) ne doit JAMAIS être émise pour ELLE-MÊME,
      // MÊME si une valorisation traîne malgré tout dans [valuations] pour
      // cette clé (y compris une valorisation MANUELLE saisie avant ce
      // correctif, ou injectée directement en test) : émettre un mouvement
      // DE la jambe fiat fabriquerait un `sell`/`buy` du CODE FIAT lui-même —
      // position crypto `USD`/`GBP` inventée, silencieuse (B-2 ci-dessus ne
      // compare qu'à la devise DU COMPTE, pas à la nature fiat de la jambe).
      //
      // EXCEPTION (amendement, voie (ii)) : si `CryptoValuationService. resolve` a
      // résolu CETTE entrée au titre de l'étage 1-quater (`source == 'fiatLeg'` —
      // jambe fiat ÉTRANGÈRE USD d'un échange PROPRE à 2 jambes), on émet la SEULE
      // jambe CRYPTO avec du cash RÉEL — jamais un mouvement pour la jambe fiat, B-A
      // reste donc intact pour elle. CORRECTIF I-2 (revue adversariale) : exclusivité
      // EXACTE (une seule jambe fiat, pas deux) et code de la jambe crypto NON-NUL —
      // vérifiés avant émission, voir [_finalizeFiatLegExchange].
      if (u.codePaidIsFiat || u.codeReceivedIsFiat) {
        final fiatLegValuation = valuations[u.importKey];
        final cryptoCode =
            u.codePaidIsFiat ? u.codeReceived : u.codePaid;
        if (u.kind == 'exchange' &&
            u.codePaidIsFiat != u.codeReceivedIsFiat &&
            cryptoCode != null &&
            fiatLegValuation != null &&
            fiatLegValuation.source == 'fiatLeg') {
          out.add(_finalizeFiatLegExchange(
            u,
            fiatLegValuation,
            accountId: accountId,
            accountCurrency: accountCurrency,
          ));
        }
        continue; // jambe fiat — jamais de mouvement émis POUR ELLE (B-A).
      }

      final valuation = valuations[u.importKey];
      if (valuation == null) continue; // arbitrage manuel — rien à émettre.

      final meta = _valuationMeta(u, valuation);
      final sourceRowIndex = u.sourceLines.isNotEmpty ? u.sourceLines.first : -1;

      switch (u.kind) {
        case 'exchange':
          final codePaid = u.codePaid!;
          final codeReceived = u.codeReceived;
          final quantityPaid = Decimal.parse(u.quantityPaid!);
          final quantityReceived = Decimal.parse(u.quantityReceived);
          final amountEur = valuation.amountEur; // TOUJOURS positif.

          final sellUnitPrice =
              (amountEur / quantityPaid).toDecimal(scaleOnInfinitePrecision: 12);
          final sellImportKey = '${u.importKey}#sell:$codePaid';
          out.add(ImportedMovement.candidate(
            sourceRow: const [],
            sourceRowIndex: sourceRowIndex,
            transaction: AssetTransaction(
              id: AssetTransaction.generateId(),
              accountId: accountId,
              symbol: null,
              kind: TransactionKind.sell,
              quantity: quantityPaid.toString(),
              unitPrice: sellUnitPrice.toString(),
              amount: amountEur.toString(), // +V_eur
              currency: accountCurrency,
              settlementCurrency: accountCurrency,
              date: u.date,
              meta: {...meta, 'importKey': sellImportKey},
            ),
            ledgerCode: codePaid,
            needsAssetResolution: true,
            importKey: sellImportKey,
          ));

          final buyUnitPrice = (amountEur / quantityReceived)
              .toDecimal(scaleOnInfinitePrecision: 12);
          final buyImportKey = '${u.importKey}#buy:$codeReceived';
          out.add(ImportedMovement.candidate(
            sourceRow: const [],
            sourceRowIndex: sourceRowIndex,
            transaction: AssetTransaction(
              id: AssetTransaction.generateId(),
              accountId: accountId,
              symbol: null,
              kind: TransactionKind.buy,
              quantity: quantityReceived.toString(),
              unitPrice: buyUnitPrice.toString(),
              // Négation LITTÉRALE de la même Decimal que la jambe sell
              // ci-dessus (règle N4) — jamais un recalcul indépendant.
              amount: (-amountEur).toString(),
              currency: accountCurrency,
              settlementCurrency: accountCurrency,
              date: u.date,
              meta: {...meta, 'importKey': buyImportKey},
            ),
            ledgerCode: codeReceived,
            needsAssetResolution: true,
            importKey: buyImportKey,
          ));
          break;

        case 'depositInKind':
          final codeReceived = u.codeReceived;
          final quantityReceived = Decimal.parse(u.quantityReceived);
          final amountEur = valuation.amountEur;
          final unitPrice = (amountEur / quantityReceived)
              .toDecimal(scaleOnInfinitePrecision: 12);
          final depositImportKey = '${u.importKey}#deposit:$codeReceived';
          // Problème 1 (retour auteur, drive B16, verbatim : « les cryptos suivantes
          // listées dans dépôt ne sont pas des dépôts ») : le modèle d'émission
          // `depositInKind` couvre AUSSI les jambes entrantes de poussière `transfer*`
          // redirigées par SIGNE (`_processDepositOrWithdrawal`) — des écritures INTERNES
          // de la plateforme (résidu de migration, restes de délistage, retour futures),
          // jamais un apport EXTERNE de l'utilisateur. Le vocabulaire des VRAIS dépôts
          // vient du PROFIL ([externalDepositKinds], paramètre de cette méthode — cf. sa
          // doc pour le défaut Kraken) — décision portée par `sourceKindLabel` (posé par
          // le moteur PUR, jamais une inspection UI, cf. doc de
          // `UnvaluedExchange.sourceKindLabel`).
          final isGenuineDeposit =
              externalDepositKinds.contains(u.sourceKindLabel);
          out.add(ImportedMovement.candidate(
            sourceRow: const [],
            sourceRowIndex: sourceRowIndex,
            transaction: AssetTransaction(
              id: AssetTransaction.generateId(),
              accountId: accountId,
              symbol: null,
              kind: TransactionKind.adjustment,
              quantity: quantityReceived.toString(),
              unitPrice: unitPrice.toString(),
              amount: null, // AUCUN cash : un dépôt ne touche pas les espèces.
              currency: accountCurrency,
              date: u.date,
              meta: {
                ...meta,
                // Demande auteur, drive B16 (« voir les dépôts en crypto ») : clé DÉDIÉE —
                // `meta['valuationSource']` seul ne distingue PAS ce dépôt en nature d'une
                // jambe `sell`/`buy` d'échange (les deux portent la même valeur, cf.
                // `_valuationMeta`). Sans elle, `filterJournal` ne pourrait pas faire remonter
                // CET `adjustment` précis sous la puce « Dépôt » sans fuiter les autres
                // (agrégats de récompenses, résidus de transferts internes). Posée UNIQUEMENT
                // pour un VRAI dépôt externe (`isGenuineDeposit` — Problème 1 ci-dessus) : une
                // jambe `transfer*` interne reste au journal sous « Tous », jamais sous « Dépôt
                // ».
                if (isGenuineDeposit) 'inKindDeposit': true,
                // Problème 2 (retour auteur, même drive) : `amountEur` est
                // TOUJOURS un montant EUR exact — issu de la série FX
                // historique (étage 1 « fichier ») OU saisi directement en
                // EUR par l'utilisateur (valorisation MANUELLE, champ dédié
                // « Montant (EUR) », cf. `AccountController.
                // applyManualCryptoValuations`) — quelle que soit la devise
                // qui finit par étiqueter ce mouvement (`currency` ci-dessus
                // PUIS, en aval, la cascade de résolution ledgerCode→ticker,
                // `AccountController._resolveCryptoTicker`, qui peut la
                // réécrire en `USD` pour un actif sans cotation EUR — sans
                // rapport avec la devise DU COMPTE ni avec CE montant). Posée
                // ICI, au point d'émission, pour que l'affichage (`_inKind
                // DepositEurApprox`) dispose d'un montant FIABLE sans jamais
                // avoir à deviner une conversion depuis `qty × prix` — la
                // valorisation MANUELLE, en particulier, n'a JAMAIS de
                // `fxRate` (`CryptoValuation(source: 'manual')` n'en pose
                // aucun), ce qui faisait planter tout repli qty×prix×fxRate.
                'valueEur': amountEur.toString(),
                'importKey': depositImportKey,
              },
            ),
            ledgerCode: codeReceived,
            needsAssetResolution: true,
            importKey: depositImportKey,
          ));
          break;
      }
    }

    return out;
  }

  /// Méta de traçabilité COMMUNE à tout mouvement crypto finalisé (exchange N4,
  /// depositInKind, ou jambe fiat étrangère de [_finalizeFiatLegExchange]
  /// ci-dessous) — factorisée depuis le corps de [finalizeCryptoExchanges] pour
  /// être réutilisée sans dupliquer la garde de nullabilité.
  /// `valuationUsd`/`fxRate`/`fxDate` sont NULLABLES sur [CryptoValuation] pour
  /// couvrir le crochet `source:'manual'` (saisie EUR directe, sans équivalent
  /// USD/FX) — absents de `meta` plutôt que sérialisés en chaîne `'null'`
  /// (primitives JSON seulement, conception interne).
  static Map<String, dynamic> _valuationMeta(
    UnvaluedExchange u,
    CryptoValuation valuation,
  ) {
    return {
      'valuationSource': valuation.source,
      if (valuation.valuationUsd != null)
        'valuationUsd': valuation.valuationUsd.toString(),
      if (valuation.fxRate != null) 'fxRate': valuation.fxRate.toString(),
      if (valuation.fxDate != null) 'fxDate': _isoDay(valuation.fxDate!),
      if (valuation.spreadPct != null)
        'valuationSpreadPct': valuation.spreadPct,
      if (u.seq != null) 'seq': u.seq,
    };
  }

  /// Finalise un [UnvaluedExchange] résolu à l'étage 1-quater (amendement, voie
  /// (ii), `valuation.source == 'fiatLeg'`, cf. `CryptoValuationService`) : échange
  /// PROPRE à 2 jambes, une crypto + une fiat ÉTRANGÈRE USD. Modèle d'ÉMISSION
  /// DIFFÉRENT de la règle N4 (sell+buy à montants opposés, aucun cash réel) — ici
  /// la jambe USD N'EST JAMAIS UNE POSITION (appelant : B-A ne laisse passer CETTE
  /// méthode que pour émettre la jambe CRYPTO, jamais la jambe fiat elle-même) : on
  /// émet la SEULE jambe crypto avec du cash RÉEL, exactement comme un trade à
  /// jambe fiat ordinaire du lot 1 (`_processExchangeGroup`, branche
  /// `nonFiatLegs.length == 1`).
  ///
  /// Sens : crypto PAYÉE (USD REÇU) → `sell`, cash ENTRANT (montant positif,
  /// même convention que `StatementImportService` pour un trade ordinaire) ;
  /// USD PAYÉ (crypto REÇUE) → `buy`, cash SORTANT (montant négatif).
  /// `fee` reste `null` : comme pour la règle N4, le frais en nature est déjà
  /// absorbé dans la quantité NETTE de la jambe crypto (`quantityPaid`/
  /// `quantityReceived`, calculée en amont comme `amount − fee`).
  static ImportedMovement _finalizeFiatLegExchange(
    UnvaluedExchange u,
    CryptoValuation valuation, {
    required String accountId,
    required String accountCurrency,
  }) {
    // Exactement une jambe fiat par construction (`CryptoValuationService.
    // resolve` ne produit `source:'fiatLeg'` que pour ce cas) : la jambe
    // RESTANTE (non-fiat) est la crypto à journaliser.
    //
    // CORRECTIF I-2 (revue adversariale) : ceinture INDÉPENDANTE de celle de
    // l'appelant (`finalizeCryptoExchanges`, condition d'exception ci-dessus)
    // — même défense en profondeur que B-1/B-2/B-A. Sans exclusivité
    // STRICTE (`codePaidIsFiat != codeReceivedIsFiat`), une entrée à DEUX
    // jambes fiat désignerait `codeReceived`/`codePaid` comme « la » jambe
    // crypto alors qu'aucune ne l'est. Sans le contrôle de nullité, un
    // `codePaid == null` (jambe payée absente, cas dépôt en nature) ferait
    // crasher l'aperçu sur le `!` — remplacé par une erreur explicite,
    // jamais un null-check operator opaque.
    final fiatPaid = u.codePaidIsFiat;
    if (u.codePaidIsFiat == u.codeReceivedIsFiat) {
      throw ArgumentError(
        'finalizeFiatLegExchange appelé sur une entrée sans exactement une '
        'jambe fiat (importKey=${u.importKey}) — invariant violé, '
        'l\'appelant doit garantir codePaidIsFiat != codeReceivedIsFiat.',
      );
    }
    final cryptoCode = fiatPaid ? u.codeReceived : u.codePaid;
    if (cryptoCode == null) {
      throw ArgumentError(
        'finalizeFiatLegExchange appelé sans code crypto exploitable '
        '(importKey=${u.importKey}) — invariant violé, l\'appelant doit '
        'garantir un codePaid non-null quand codeReceivedIsFiat.',
      );
    }
    final cryptoQuantity =
        Decimal.parse(fiatPaid ? u.quantityReceived : u.quantityPaid!);
    final amountEur = valuation.amountEur; // TOUJOURS positif.

    final kind = fiatPaid ? TransactionKind.buy : TransactionKind.sell;
    final unitPrice =
        (amountEur / cryptoQuantity).toDecimal(scaleOnInfinitePrecision: 12);
    final role = '${fiatPaid ? 'buy' : 'sell'}:$cryptoCode';
    final legImportKey = '${u.importKey}#$role';
    final meta = _valuationMeta(u, valuation);
    final sourceRowIndex = u.sourceLines.isNotEmpty ? u.sourceLines.first : -1;

    return ImportedMovement.candidate(
      sourceRow: const [],
      sourceRowIndex: sourceRowIndex,
      transaction: AssetTransaction(
        id: AssetTransaction.generateId(),
        accountId: accountId,
        symbol: null,
        kind: kind,
        quantity: cryptoQuantity.toString(),
        unitPrice: unitPrice.toString(),
        // Cash RÉEL (pas une négation N4) : ENTRANT pour un sell (USD reçu),
        // SORTANT pour un buy (USD payé) — même convention de signe qu'un
        // trade à jambe fiat ordinaire (`StatementImportService`).
        amount: (fiatPaid ? -amountEur : amountEur).toString(),
        currency: accountCurrency,
        settlementCurrency: accountCurrency,
        date: u.date,
        meta: {...meta, 'importKey': legImportKey},
      ),
      ledgerCode: cryptoCode,
      needsAssetResolution: true,
      importKey: legImportKey,
    );
  }

  // ---------------------------------------------------------------------
  // Groupage (2ter)
  // ---------------------------------------------------------------------

  static Map<String, List<_Leg>> _groupLegs(
    List<_Leg> legs,
    CryptoLedgerSpec crypto,
    DecimalSeparator decimalSeparator,
    void Function(_Leg, String) reject,
  ) {
    switch (crypto.grouping) {
      case LegGroupingStrategy.operationReference:
        final groups = <String, List<_Leg>>{};
        for (final leg in legs) {
          final ref = leg.operationReference;
          final key = (ref != null && ref.isNotEmpty)
              ? ref
              : 'solo:${leg.sourceIndex}';
          (groups[key] ??= <_Leg>[]).add(leg);
        }
        return groups;
      case LegGroupingStrategy.sameTimestamp:
        throw UnsupportedError(
          'LegGroupingStrategy.sameTimestamp (groupage Binance par '
          'horodatage exact) est réservé au lot 4 — non implémenté.',
        );
      case LegGroupingStrategy.counterpartyNote:
        return _groupByCounterpartyNote(legs, crypto, decimalSeparator, reject);
    }
  }

  /// Appariement DÉTERMINISTE des jambes `Convert` (chantier B16 lot 3, conception
  /// interne) : la jambe SORTANTE (quantité négative) extrait sa contrepartie
  /// attendue `(qty_cible, ticker_cible)` du texte libre
  /// [CryptoLedgerSpec.notesColumn] via [CryptoLedgerSpec.counterpartyPattern]
  /// (groupes nommés `qty`/`asset`), puis cherche parmi les jambes ENTRANTES
  /// (quantité positive) l'UNIQUE candidate de même actif BRUT et de quantité
  /// EXACTEMENT égale (comparaison `Decimal`, jamais `double`), dans la fenêtre
  /// [CryptoLedgerSpec.groupingWindow]. Trois contraintes CUMULATIVES, chacune un
  /// rejet motivé distinct en cas d'échec — JAMAIS de repli heuristique (une jambe
  /// non appariée journalisée seule fabriquerait une sortie/entrée imaginaire et
  /// casserait le PRU) :
  ///   - motif imparsable sur la sortante → `convertNotesUnparsed` ;
  ///   - aucune candidate (quantité non exacte OU hors fenêtre) →
  ///     `convertNoMatch` ;
  ///   - pluralité — PLUSIEURS candidates pour une sortante, OU plusieurs
  ///     sortantes revendiquant la MÊME entrante (unicité 1-1 STRICTE dans
  ///     les deux sens) → `convertAmbiguousMatch`, abandon des DEUX côtés.
  ///
  /// Les lignes NON-`Convert` (Receive/Send/Reward Income/Buy/Sell…) ne
  /// s'apparient jamais : chacune forme sa PROPRE clé de groupe (comme le
  /// repli `solo:` de [LegGroupingStrategy.operationReference]) — leur
  /// action respective se traite déjà ligne à ligne dans la boucle
  /// principale de `planCryptoImport`, indépendamment de la taille du
  /// groupe.
  ///
  /// Clé de groupe d'une paire réussie : l'`ID` (référence d'opération) de la jambe
  /// SORTANTE — convention conception interne (`ref:accountId:ID#rôle`), déjà
  /// assurée par [_processExchangeGroup] qui reçoit cette clé comme `refid`.
  static Map<String, List<_Leg>> _groupByCounterpartyNote(
    List<_Leg> legs,
    CryptoLedgerSpec crypto,
    DecimalSeparator decimalSeparator,
    void Function(_Leg, String) reject,
  ) {
    final groups = <String, List<_Leg>>{};
    final convertLegs = <_Leg>[];
    for (final leg in legs) {
      if (leg.action == CryptoLedgerAction.exchangeLeg) {
        convertLegs.add(leg);
        continue;
      }
      final ref = leg.operationReference;
      final key =
          (ref != null && ref.isNotEmpty) ? ref : 'solo:${leg.sourceIndex}';
      // ACCUMULE (I-3, revue adversariale, CORRECTIF) — jamais un
      // remplacement (`groups[key] = [leg]` PERDAIT silencieusement toute
      // ligne précédente partageant la même clé, ex. un `ID` dupliqué par le
      // courtier) : même idiome que la stratégie sœur
      // [LegGroupingStrategy.operationReference] ci-dessus.
      (groups[key] ??= <_Leg>[]).add(leg);
    }
    if (convertLegs.isEmpty) return groups;

    final pattern = crypto.counterpartyPattern;
    final negatives = convertLegs.where((l) => l.quantity.sign < 0).toList();
    final positives = convertLegs.where((l) => l.quantity.sign >= 0).toList();

    // Extraction de la contrepartie — UNIQUEMENT sur les sortantes (§2
    // point 1). Échec de motif = rejet DIRECT, jamais de tentative
    // d'appariement sur une info absente.
    final targets = <_Leg, _ConvertTarget>{};
    for (final neg in negatives) {
      final match = pattern?.firstMatch(neg.notes ?? '');
      final qtyRaw = match?.namedGroup('qty');
      final assetRaw = match?.namedGroup('asset');
      final qty = qtyRaw == null ? null : _parseNoteQuantity(qtyRaw, decimalSeparator);
      if (match == null || qty == null || assetRaw == null || assetRaw.isEmpty) {
        reject(neg, 'convertNotesUnparsed');
        continue;
      }
      targets[neg] = _ConvertTarget(qty: qty, asset: assetRaw);
    }

    // Candidats par sortante : entrantes de même actif BRUT (avant alias —
    // le texte de la note cite le ticker TEL QU'IL APPARAÎT sur le relevé)
    // et de quantité EXACTEMENT égale, dans la fenêtre de tolérance.
    final candidatesOf = <_Leg, List<_Leg>>{};
    for (final entry in targets.entries) {
      final target = entry.value;
      candidatesOf[entry.key] = positives.where((pos) {
        if (pos.rawAsset != target.asset) return false;
        if (pos.quantity != target.qty) return false;
        // `preciseDate` (jusqu'à la seconde), JAMAIS `date` (granularité
        // JOUR) — cf. la doc de `_Leg.preciseDate`.
        return pos.preciseDate.difference(entry.key.preciseDate).abs() <=
            crypto.groupingWindow;
      }).toList();
    }

    // Unicité 1-1 STRICTE côté ENTRANTE : combien de sortantes (à candidate
    // UNIQUE) revendiquent chaque entrante.
    final claimsOnPositive = <_Leg, List<_Leg>>{};
    for (final entry in candidatesOf.entries) {
      if (entry.value.length == 1) {
        (claimsOnPositive[entry.value.single] ??= <_Leg>[]).add(entry.key);
      }
    }

    // Entrantes IMPLIQUÉES dans une ambiguïté « côté sortante » (M-1, revue
    // adversariale, CORRECTIF) : une sortante à PLUSIEURS candidates (`entry.
    // value.length > 1`, ci-dessus EXCLUE de `claimsOnPositive`) abandonne
    // les deux côtés — mais AVANT ce correctif, ses candidates ne portaient
    // ZÉRO revendication (absentes de `claimsOnPositive`) et retombaient
    // donc, plus bas, sur `convertNoMatch` (« aucune candidate ») au lieu de
    // `convertAmbiguousMatch` (« plusieurs candidates, on a dû choisir entre
    // elles ») — motif TROMPEUR : ces entrantes N'ONT PAS été ignorées, elles
    // ont concouru pour la même sortante et ont PERDU à égalité. Toute
    // entrante figurant dans la liste de candidates d'UNE sortante ambiguë
    // porte donc désormais le même motif que cette sortante, qu'elle soit
    // par ailleurs revendiquée ou non.
    final ambiguousPositives = <_Leg>{};
    for (final entry in candidatesOf.entries) {
      if (entry.value.length > 1) {
        ambiguousPositives.addAll(entry.value);
      }
    }

    final pairedPositives = <_Leg>{};
    for (final neg in negatives) {
      final target = targets[neg];
      if (target == null) continue; // déjà rejetée (note imparsable)
      final candidates = candidatesOf[neg]!;
      if (candidates.length > 1) {
        reject(neg, 'convertAmbiguousMatch');
        continue;
      }
      if (candidates.isEmpty) {
        reject(neg, 'convertNoMatch');
        continue;
      }
      final pos = candidates.single;
      if ((claimsOnPositive[pos]?.length ?? 0) > 1) {
        // Pluralité côté ENTRANTE (≥ 2 sortantes revendiquent la même
        // candidate) — abandon des DEUX côtés, lignes inchangées.
        reject(neg, 'convertAmbiguousMatch');
        continue;
      }
      pairedPositives.add(pos);
      final key = (neg.operationReference != null && neg.operationReference!.isNotEmpty)
          ? neg.operationReference!
          : 'solo:${neg.sourceIndex}';
      // ACCUMULE (I-3, même correctif que ci-dessus) — une clé `ID` déjà
      // occupée par une ligne NON-Convert (cas dégénéré, `ID` dupliqué par
      // le courtier) ne doit pas non plus disparaître silencieusement.
      (groups[key] ??= <_Leg>[])
        ..add(neg)
        ..add(pos);
    }

    for (final pos in positives) {
      if (pairedPositives.contains(pos)) continue;
      final claimants = claimsOnPositive[pos]?.length ?? 0;
      final ambiguous = claimants > 1 || ambiguousPositives.contains(pos);
      reject(pos, ambiguous ? 'convertAmbiguousMatch' : 'convertNoMatch');
    }

    return groups;
  }

  /// Quantité extraite d'un texte libre (`Notes`) — reprend en miniature
  /// [_parseCryptoDecimal] : la valeur capturée par [CryptoLedgerSpec.
  /// counterpartyPattern] (groupe `qty`) peut porter un séparateur de
  /// milliers occasionnel (virgule si la décimale du profil est le point,
  /// point si elle est la virgule) — retiré avant parsing, jamais confondu
  /// avec la décimale elle-même.
  static Decimal? _parseNoteQuantity(String raw, DecimalSeparator sep) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (sep == DecimalSeparator.comma) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
    return Decimal.tryParse(s);
  }

  // ---------------------------------------------------------------------
  // Traitement par action (§C)
  // ---------------------------------------------------------------------

  /// Natures dont le TYPE fixe DÉJÀ la direction sans ambiguïté ET les codes
  /// `transfer*` ambigus (direction fixée par le SIGNE net, pas par le type —
  /// conception interne).
  ///
  /// Le vocabulaire des natures non-ambiguës vient du PROFIL
  /// ([CryptoLedgerSpec.signFixedKinds]), jamais du moteur : `deposit`/
  /// `withdrawal` (Kraken) en sont l'EXEMPLE — leur TYPE fixe déjà la
  /// direction (contrairement aux codes `transfer*`, absents de cette table,
  /// redirigés par signe) — un signe qui CONTREDIT le signe DÉCLARÉ pour une
  /// nature de cette table est une anomalie du relevé, jamais silencieusement
  /// réinterprétée (B4 : jamais de coercition ; mineur, revue adversariale).
  static void _processDepositOrWithdrawal(
    _Leg leg, {
    required String refid,
    required String accountId,
    required String accountCurrency,
    required CryptoLedgerSpec crypto,
    required List<ImportedMovement> movements,
    required List<UnvaluedExchange> unvaluedExchanges,
    required Map<String, int> roleOccurrences,
    required void Function(_Leg, String) reject,
  }) {
    final net = leg.net;
    if (net == Decimal.zero) {
      reject(leg, 'cryptoZeroNetMovement');
      return;
    }

    final expectedPositive = crypto.signFixedKinds[leg.kindLabel];
    if (expectedPositive != null) {
      if ((net.sign > 0) != expectedPositive) {
        reject(leg, 'cryptoAmbiguousDirection');
        return;
      }
    }

    if (_isFiat(leg, crypto)) {
      // Fiat ÉTRANGER à la devise du compte (ex. USD sur un compte EUR) :
      // aucune conversion disponible au lot 1 — l'écrire AU PAIR serait une
      // falsification silencieuse du cash (B-2, revue adversariale). Rejet
      // motivé ; le lot 2 valorisera via la série FX historique.
      if (leg.rawAsset.toUpperCase() != accountCurrency.toUpperCase()) {
        reject(leg, 'cryptoForeignFiatUnsupported');
        return;
      }
      final kind = net.sign > 0 ? TransactionKind.deposit : TransactionKind.withdrawal;
      final role = kind == TransactionKind.deposit
          ? 'deposit:${leg.rawAsset}'
          : 'withdrawal:${leg.rawAsset}';
      final importKey =
          'ref:$accountId:$refid#${_disambiguate(roleOccurrences, role)}';
      final tx = AssetTransaction(
        id: AssetTransaction.generateId(),
        accountId: accountId,
        symbol: null,
        kind: kind,
        amount: net.toString(),
        currency: leg.rawAsset,
        settlementCurrency: accountCurrency,
        date: leg.date,
        meta: {'seq': leg.seq, 'importKey': importKey},
      );
      movements.add(ImportedMovement.candidate(
        sourceRow: leg.source,
        sourceRowIndex: leg.sourceIndex,
        transaction: tx,
        importKey: importKey,
      ));
      return;
    }

    // EN NATURE.
    if (net.sign > 0) {
      // Entrée en nature : besoin de valorisation (forme dégénérée, pas de
      // jambe payée) — §5.2.1 depositIn en nature.
      unvaluedExchanges.add(UnvaluedExchange(
        kind: 'depositInKind',
        date: leg.date,
        codeReceived: leg.baseAsset,
        quantityReceived: net.toString(),
        usdReceived: leg.valuationUsd?.toString(),
        sourceLines: [leg.sourceIndex],
        importKey: 'ref:$accountId:$refid',
        seq: leg.seq,
        // EN NATURE (branche ci-dessus, `_isFiat` déjà écartée plus haut) :
        // jamais fiat — explicite plutôt qu'implicite sur le défaut (B-A,
        // contre-vérification lot 2, tous les points de construction).
        codeReceivedIsFiat: false,
        // Problème 1 (drive B16 : `leg.kindLabel` est le type BRUT
        // (`deposit`/`transfer`, JAMAIS le composite avec sous-type — un
        // `transfer/spotfromfutures` porte `kindLabel == 'transfer'`) — c'est
        // exactement ce qu'il faut à `finalizeCryptoExchanges` pour distinguer un VRAI
        // dépôt externe (`deposit`) d'une écriture interne de plateforme (toute la
        // famille `transfer*`, redirigée ici par signe) avant de poser
        // `meta['inKindDeposit']`.
        sourceKindLabel: leg.kindLabel,
      ));
      return;
    }

    // Sortie en nature : transferOut, quantité = |net| (le frais de retrait
    // sort aussi), aucun cash, aucune valorisation requise (le mouvement
    // journalisé reste complet SANS elle — B4, jamais bloquant).
    final quantity = net.abs();
    final role = 'transferOut:${leg.baseAsset}';
    final importKey =
        'ref:$accountId:$refid#${_disambiguate(roleOccurrences, role)}';
    final tx = AssetTransaction(
      id: AssetTransaction.generateId(),
      accountId: accountId,
      symbol: null,
      kind: TransactionKind.transferOut,
      quantity: quantity.toString(),
      currency: accountCurrency,
      date: leg.date,
      meta: {
        'seq': leg.seq,
        'importKey': importKey,
        // Retour auteur (symétrique EXACT du Problème 1 côté dépôt, commit 78198a4) :
        // la puce « Retrait » ramassait aussi les poussières de délistage
        // (`transfer/delistingconversion`, type BRUT `transfer`) — des écritures
        // INTERNES de plateforme redirigées ICI par SIGNE, jamais un vrai retrait vers
        // un wallet externe. Le vocabulaire des types EXTERNES vient du PROFIL
        // ([CryptoLedgerSpec.externalWithdrawalKinds]), jamais du moteur : seule une
        // ligne SOURCE de type BRUT `withdrawal` (Kraken, `leg.kindLabel`, JAMAIS le
        // composite avec sous-type) y figure — décision portée par cette clé DÉDIÉE,
        // lue par `filterJournal` (`account_journal_page.dart`) pour restreindre son
        // cas spécial withdrawal/transferOut. Absente pour toute jambe `transfer*` : le
        // mouvement (quantité, coût) reste inchangé, seule la puce l'ignore.
        if (crypto.externalWithdrawalKinds.contains(leg.kindLabel))
          'inKindWithdrawal': true,
        // Demande auteur, drive B16 (« voir la quantité de crypto retirée et
        // l'équivalent en cash ») : la valeur USD de LA JAMBE (colonne `amountusd`,
        // même source que pour un échange, cf. `_Leg. valuationUsd`) est posée ICI en
        // valeur ABSOLUE quand elle est LISIBLE —
        // `AccountController._previewCryptoImport` la convertit ensuite en EUR via la
        // série FX historique (`meta['valueEur']`). Jamais bloquant : illisible
        // (littéral `-`, N2) → cette clé est simplement absente, le mouvement reste
        // inchangé (B4 : aucune coercition).
        if (leg.valuationUsd != null)
          'valuationUsd': leg.valuationUsd!.abs().toString(),
      },
    );
    movements.add(ImportedMovement.candidate(
      sourceRow: leg.source,
      sourceRowIndex: leg.sourceIndex,
      transaction: tx,
      ledgerCode: leg.baseAsset,
      needsAssetResolution: true,
      importKey: importKey,
    ));
  }

  /// Traite une ligne `Buy`/`Sell` (chantier B16 lot 3, conception interne —
  /// Coinbase) : contrairement à `Convert`/Kraken, TOUT est déjà sur la MÊME
  /// ligne (quantité crypto via `MovementField.quantity`, montant de règlement
  /// via `MovementField.amount`, devise de ce montant via
  /// `MovementField.currency`) — aucune contrepartie à chercher.
  ///
  /// GARDE « Price Currency » (§5.3.4, revue adversariale du design
  /// OBLIGATOIRE) : les valorisations fichier sont dans la devise DE LA
  /// LIGNE (`leg.amountCurrency`), pas forcément celle du compte. Le chemin
  /// fiat DIRECT (montant pris tel quel, comme un trade Kraken à jambe
  /// fiat) n'est empruntable QUE si `leg.amountCurrency == accountCurrency`
  /// — sinon la ligne part comme un `UnvaluedExchange` à jambe fiat
  /// ÉTRANGÈRE, résolu par la MÊME cascade que l'étage 1-quater existant
  /// (`CryptoValuationService`, `CryptoValuation.source == 'fiatLeg'` —
  /// automatique seulement si cette devise est littéralement `USD`, sinon
  /// arbitrage manuel `foreignFiat`, comme toute autre jambe fiat
  /// étrangère). Sans cette garde, un compte EUR importerait un `Subtotal`
  /// USD comme des euros — falsification silencieuse du cash.
  static void _processFiatTrade(
    _Leg leg,
    CryptoLedgerAction action, {
    required String refid,
    required String accountId,
    required String accountCurrency,
    required List<ImportedMovement> movements,
    required List<UnvaluedExchange> unvaluedExchanges,
    required void Function(_Leg, String) reject,
  }) {
    final quantity = leg.quantity;
    if (quantity == Decimal.zero) {
      reject(leg, 'cryptoZeroNetMovement');
      return;
    }
    final cashAmount = leg.amount?.abs();
    final cashCurrency = leg.amountCurrency;
    if (cashAmount == null || cashCurrency == null || cashAmount == Decimal.zero) {
      reject(leg, 'cryptoFiatTradeUnreadableAmount');
      return;
    }
    final isSell = action == CryptoLedgerAction.fiatSell;

    if (cashCurrency.toUpperCase() == accountCurrency.toUpperCase()) {
      // Chemin fiat DIRECT — même modèle qu'un trade Kraken à jambe fiat
      // (`_processExchangeGroup`, branche `nonFiatLegs.length == 1`) :
      // `sell` crédite le cash (montant positif), `buy` le débite.
      final kind = isSell ? TransactionKind.sell : TransactionKind.buy;
      final signedAmount = isSell ? cashAmount : -cashAmount;
      final unitPrice =
          (cashAmount / quantity.abs()).toDecimal(scaleOnInfinitePrecision: 12);
      final role = '${isSell ? 'sell' : 'buy'}:${leg.baseAsset}';
      final importKey = 'ref:$accountId:$refid#$role';
      final tx = AssetTransaction(
        id: AssetTransaction.generateId(),
        accountId: accountId,
        symbol: null,
        kind: kind,
        quantity: quantity.abs().toString(),
        unitPrice: unitPrice.toString(),
        amount: signedAmount.toString(),
        // `accountCurrency` (M-4, revue adversariale, CORRECTIF), PAS
        // `cashCurrency` : ce dernier est la casse BRUTE de la cellule
        // `Price Currency` (ex. `usd` en minuscules) — la comparaison
        // ci-dessus est déjà insensible à la casse, mais émettre la valeur
        // brute aurait tout de même laissé passer un mouvement étiqueté
        // `usd` plutôt que `USD`, incohérent avec le reste du pipeline (qui
        // normalise systématiquement sur la devise DU COMPTE).
        currency: accountCurrency,
        settlementCurrency: accountCurrency,
        date: leg.date,
        meta: {'seq': leg.seq, 'importKey': importKey},
      );
      movements.add(ImportedMovement.candidate(
        sourceRow: leg.source,
        sourceRowIndex: leg.sourceIndex,
        transaction: tx,
        ledgerCode: leg.baseAsset,
        needsAssetResolution: true,
        importKey: importKey,
      ));
      return;
    }

    // Price Currency ÉTRANGÈRE à la devise du compte : cascade de
    // valorisation, comme un échange à jambe fiat étrangère — jamais un
    // montant pris au pair (B-2, même garde que `_processExchangeGroup`).
    final importKey = 'ref:$accountId:$refid';
    unvaluedExchanges.add(UnvaluedExchange(
      kind: 'exchange',
      date: leg.date,
      codePaid: isSell ? leg.baseAsset : cashCurrency,
      quantityPaid: (isSell ? quantity.abs() : cashAmount).toString(),
      codeReceived: isSell ? cashCurrency : leg.baseAsset,
      quantityReceived: (isSell ? cashAmount : quantity.abs()).toString(),
      // `usdPaid`/`usdReceived` ne portent QUE la valorisation USD
      // DOCUMENTÉE de la jambe crypto (`leg.valuationUsd`, colonne
      // `CryptoLedgerSpec.valuationAmountColumn`) — jamais le montant de la
      // jambe fiat elle-même (`cashAmount`), dont la devise réelle
      // ([cashCurrency]) n'est PAS forcément USD malgré le nom du champ ;
      // c'est `quantityPaid`/`quantityReceived` (toujours exacts, ci-dessus)
      // que l'étage 1-quater (`CryptoValuationService`) consulte pour la
      // jambe fiat, jamais ces deux champs.
      usdPaid: isSell ? leg.valuationUsd?.toString() : null,
      usdReceived: isSell ? null : leg.valuationUsd?.toString(),
      sourceLines: [leg.sourceIndex],
      importKey: importKey,
      seq: leg.seq,
      codePaidIsFiat: !isSell,
      codeReceivedIsFiat: isSell,
    ));
  }

  static void _processMigrationGroup(
    List<_Leg> legs,
    void Function(_Leg, String) reject,
  ) {
    final byBase = <String, Decimal>{};
    for (final leg in legs) {
      byBase[leg.baseAsset] = (byBase[leg.baseAsset] ?? Decimal.zero) + leg.net;
    }
    final balanced = byBase.values.every((v) => v == Decimal.zero);
    if (balanced) return; // rien au journal — neutralisée par l'alias.
    for (final leg in legs) {
      reject(leg, 'cryptoMigrationNotBalanced');
    }
  }

  static void _processExchangeGroup(
    List<_Leg> legs, {
    required String refid,
    required String accountId,
    required String accountCurrency,
    required CryptoLedgerSpec crypto,
    required List<ImportedMovement> movements,
    required List<UnvaluedExchange> unvaluedExchanges,
    required void Function(_Leg, String) reject,
  }) {
    if (legs.any((l) => l.net == Decimal.zero)) {
      for (final leg in legs) {
        reject(leg, 'cryptoZeroNetMovement');
      }
      return;
    }

    // Seule une jambe fiat DANS LA DEVISE DU COMPTE peut emprunter le chemin
    // cash direct (B-2, revue adversariale) — une jambe fiat ÉTRANGÈRE (ex.
    // USD sur un compte EUR) écrite au pair serait une falsification
    // silencieuse ; elle est donc traitée comme n'importe quelle autre
    // jambe non-cash ci-dessous (échange sans jambe fiat exploitable →
    // `UnvaluedExchange`, jamais un montant inventé).
    final fiatLegs =
        legs.where((l) => _isAccountFiat(l, crypto, accountCurrency)).toList();
    if (fiatLegs.length > 1) {
      for (final leg in legs) {
        reject(leg, 'ambiguousExchangeGroup');
      }
      return;
    }

    // R-1 (revue adversariale, contre-vérification) : trou ouvert par B-2.
    // `fiatLegs` ne compte QUE les jambes fiat DANS la devise du compte —
    // une jambe fiat ÉTRANGÈRE (USD sur un compte EUR) n'y figure donc pas,
    // et retombait plus bas dans `nonFiatLegs` (calculé par simple exclusion
    // de `fiatLeg`, pas par nature) : un groupe EUR↔USD passait alors dans
    // la branche buy/sell avec la jambe USD traitée comme un actif TITRE
    // (`ledgerCode:'USD'`) — position `crypto:USD` fabriquée, puis écart de
    // quantité fantôme sur USD (`fiatRawAssets` utilise `_isFiat` pur, donc
    // exclut USD de son exclusion). Deux gardes INDÉPENDANTES, avant tout
    // calcul de `nonFiatLegs` :
    final foreignFiat = legs.where(
        (l) => _isFiat(l, crypto) && !_isAccountFiat(l, crypto, accountCurrency));
    // (a) fiat↔fiat (ex. EUR↔USD) : ni cash convertible (aucune jambe TITRE
    // à valoriser), ni échange d'actifs — hors modèle des deux branches
    // ci-dessous, rejet motivé.
    if (foreignFiat.isNotEmpty && legs.every((l) => _isFiat(l, crypto))) {
      for (final leg in legs) {
        reject(leg, 'cryptoForeignFiatUnsupported');
      }
      return;
    }
    // (b) une jambe fiat ÉTRANGÈRE ne doit JAMAIS être réinterprétée comme
    // une jambe TITRE émise (buy/sell À CÔTÉ d'une jambe fiat du compte, ou
    // dustsweeping N→1 avec une jambe fiat étrangère mêlée) — rejet motivé,
    // jamais une position fabriquée.
    if (fiatLegs.isNotEmpty && foreignFiat.isNotEmpty) {
      for (final leg in legs) {
        reject(leg, 'cryptoForeignFiatUnsupported');
      }
      return;
    }

    final date = legs.map((l) => l.date).reduce((a, b) => a.isBefore(b) ? a : b);
    final seq = legs.map((l) => l.seq).reduce((a, b) => a < b ? a : b);
    final sourceLines = legs.map((l) => l.sourceIndex).toList();

    if (fiatLegs.isEmpty) {
      // ÉCHANGE SANS JAMBE FIAT (modèle b, valorisation fichier-d'abord —
      // hors périmètre lot 1) : exactement 2 jambes attendues (payée +
      // reçue) ; toute autre forme (>2 jambes sans fiat) reste ambiguë ici.
      if (legs.length != 2) {
        for (final leg in legs) {
          reject(leg, 'ambiguousExchangeGroup');
        }
        return;
      }
      final paid = legs.firstWhere((l) => l.net.sign < 0, orElse: () => legs[0]);
      final received = legs.firstWhere((l) => l.net.sign > 0, orElse: () => legs[1]);
      if (paid.net.sign >= 0 || received.net.sign <= 0) {
        for (final leg in legs) {
          reject(leg, 'ambiguousExchangeGroup');
        }
        return;
      }
      unvaluedExchanges.add(UnvaluedExchange(
        kind: 'exchange',
        date: date,
        codePaid: paid.baseAsset,
        quantityPaid: paid.net.abs().toString(),
        codeReceived: received.baseAsset,
        quantityReceived: received.net.toString(),
        usdPaid: paid.valuationUsd?.toString(),
        usdReceived: received.valuationUsd?.toString(),
        sourceLines: sourceLines,
        importKey: 'ref:$accountId:$refid',
        seq: seq,
        // B-A (BLOQUANT, contre-vérification lot 2) : CETTE branche est
        // exactement celle où une jambe fiat ÉTRANGÈRE (ex. `USD` sur un
        // compte `EUR`) peut se retrouver ici — `fiatLegs` ne retient que le
        // fiat DANS la devise du compte (`_isAccountFiat`), donc un `NNN↔USD`
        // atterrit dans CETTE branche avec `paid`/`received` posés par simple
        // SIGNE, sans savoir que l'un des deux est en réalité du cash. Sans
        // ce marquage, `CryptoValuationService.resolve` le valoriserait comme
        // un actif ordinaire et `finalizeCryptoExchanges` fabriquerait une
        // position crypto `USD` (`sell`/`buy`) — silencieuse.
        codePaidIsFiat: _isFiat(paid, crypto),
        codeReceivedIsFiat: _isFiat(received, crypto),
      ));
      return;
    }

    final fiatLeg = fiatLegs.single;
    final nonFiatLegs = legs.where((l) => !identical(l, fiatLeg)).toList();

    if (nonFiatLegs.length == 1) {
      // Trade / spend+receive classique à jambe fiat — buy/sell (§C).
      final cryptoLeg = nonFiatLegs.single;
      final cashNet = fiatLeg.net;
      final quantity = cryptoLeg.net.abs();
      final kind = cashNet.sign > 0 ? TransactionKind.sell : TransactionKind.buy;
      final unitPrice =
          (cashNet.abs() / quantity).toDecimal(scaleOnInfinitePrecision: 12);
      final role =
          '${kind == TransactionKind.sell ? 'sell' : 'buy'}:${cryptoLeg.baseAsset}';
      final importKey = 'ref:$accountId:$refid#$role';
      final tx = AssetTransaction(
        id: AssetTransaction.generateId(),
        accountId: accountId,
        symbol: null,
        kind: kind,
        quantity: quantity.toString(),
        unitPrice: unitPrice.toString(),
        amount: cashNet.toString(),
        currency: fiatLeg.rawAsset,
        settlementCurrency: accountCurrency,
        date: date,
        meta: {'seq': seq, 'importKey': importKey},
      );
      movements.add(ImportedMovement.candidate(
        sourceRow: cryptoLeg.source,
        sourceRowIndex: cryptoLeg.sourceIndex,
        transaction: tx,
        ledgerCode: cryptoLeg.baseAsset,
        needsAssetResolution: true,
        importKey: importKey,
      ));
      return;
    }

    // DUSTSWEEPING N→1 : plusieurs jambes payées (non-fiat, net<0), UNE
    // jambe fiat REÇUE (net>0). Produit réparti au PRORATA des `amountusd`.
    if (fiatLeg.net.sign <= 0 || nonFiatLegs.any((l) => l.net.sign >= 0)) {
      for (final leg in legs) {
        reject(leg, 'ambiguousExchangeGroup');
      }
      return;
    }

    final weights = <Decimal>[];
    var weightsReadable = true;
    for (final leg in nonFiatLegs) {
      final w = leg.valuationUsd?.abs();
      if (w == null) {
        weightsReadable = false;
        break;
      }
      weights.add(w);
    }
    final totalWeight = weightsReadable
        ? weights.fold<Decimal>(Decimal.zero, (a, b) => a + b)
        : Decimal.zero;

    if (!weightsReadable || totalWeight == Decimal.zero) {
      // `amountusd` illisible quelque part dans le groupe (N2) : tout le
      // groupe part en attente de valorisation manuelle (lot 2). Repli
      // dégénéré (pas de pair unique payé/reçu net à N legs) : une entrée par
      // jambe payée, référencée par la MÊME clé de groupe — à reconstituer au
      // lot 2 (limite assumée, doc de fichier).
      for (final leg in nonFiatLegs) {
        unvaluedExchanges.add(UnvaluedExchange(
          kind: 'exchange',
          date: date,
          codePaid: leg.baseAsset,
          quantityPaid: leg.net.abs().toString(),
          codeReceived: fiatLeg.baseAsset,
          quantityReceived: fiatLeg.net.toString(),
          usdPaid: leg.valuationUsd?.toString(),
          usdReceived: fiatLeg.valuationUsd?.toString(),
          sourceLines: sourceLines,
          importKey: 'ref:$accountId:$refid',
          seq: leg.seq,
          // `leg` vient de `nonFiatLegs` (jamais fiat par construction) ;
          // `fiatLeg` est TOUJOURS de la devise du COMPTE ici (`fiatLegs`
          // filtré par `_isAccountFiat`, jamais étranger) — déjà bloqué par
          // B-2 (`finalizeCryptoExchanges`, codeReceived == accountCurrency)
          // ET par B-1 (clé `importKey` partagée par ≥ 2 entrées dans CETTE
          // branche, toujours ≥ 2 legs ici) ; marqué fiat quand même par
          // exhaustivité (B-A, tous les points de construction).
          codePaidIsFiat: false,
          codeReceivedIsFiat: true,
        ));
      }
      return;
    }

    // Prorata Decimal, résidu d'arrondi sur la plus grosse jambe (poids max).
    const shareScale = 10;
    final shares = <Decimal>[];
    var sumShares = Decimal.zero;
    for (final w in weights) {
      final share =
          ((fiatLeg.net * w) / totalWeight).toDecimal(scaleOnInfinitePrecision: shareScale);
      shares.add(share);
      sumShares += share;
    }
    final residual = fiatLeg.net - sumShares;
    var largestIdx = 0;
    for (var i = 1; i < weights.length; i++) {
      if (weights[i] > weights[largestIdx]) largestIdx = i;
    }
    shares[largestIdx] += residual;

    final roleOccurrences = <String, int>{};
    for (var i = 0; i < nonFiatLegs.length; i++) {
      final leg = nonFiatLegs[i];
      final quantity = leg.net.abs();
      final amount = shares[i];
      final unitPrice = (amount / quantity).toDecimal(scaleOnInfinitePrecision: 12);
      final role = 'sell:${leg.baseAsset}';
      final importKey =
          'ref:$accountId:$refid#${_disambiguate(roleOccurrences, role)}';
      final tx = AssetTransaction(
        id: AssetTransaction.generateId(),
        accountId: accountId,
        symbol: null,
        kind: TransactionKind.sell,
        quantity: quantity.toString(),
        unitPrice: unitPrice.toString(),
        amount: amount.toString(),
        currency: fiatLeg.rawAsset,
        settlementCurrency: accountCurrency,
        date: date,
        meta: {'seq': seq, 'importKey': importKey},
      );
      movements.add(ImportedMovement.candidate(
        sourceRow: leg.source,
        sourceRowIndex: leg.sourceIndex,
        transaction: tx,
        ledgerCode: leg.baseAsset,
        needsAssetResolution: true,
        importKey: importKey,
      ));
    }
  }

  static ImportedMovement _emitRewardIndividual(
    _Leg leg, {
    required String accountId,
    required String accountCurrency,
  }) {
    final importKey = 'ref:$accountId:${leg.operationReference ?? 'solo:${leg.sourceIndex}'}#reward';
    final tx = AssetTransaction(
      id: AssetTransaction.generateId(),
      accountId: accountId,
      symbol: null,
      kind: TransactionKind.adjustment,
      quantity: leg.net.toString(),
      currency: accountCurrency,
      date: leg.date,
      meta: {
        'corporateAction': 'stakingReward',
        'seq': leg.seq,
        'importKey': importKey,
      },
    );
    return ImportedMovement.candidate(
      sourceRow: leg.source,
      sourceRowIndex: leg.sourceIndex,
      transaction: tx,
      ledgerCode: leg.baseAsset,
      needsAssetResolution: true,
      importKey: importKey,
    );
  }

  // ---------------------------------------------------------------------
  // Garde de projection (§5.1.10, deuxième carte)
  // ---------------------------------------------------------------------

  static List<QuantityGap> _computeQuantityGaps(
    List<ImportedMovement> movements,
    List<UnvaluedExchange> unvaluedExchanges,
    Map<String, Decimal> finalBalanceByRawKey,
    CryptoLedgerSpec crypto,
    Set<String> fiatRawAssets,
  ) {
    final reportedByBase = <String, Decimal>{};
    finalBalanceByRawKey.forEach((key, value) {
      final rawAsset = key.split('|').first;
      if (fiatRawAssets.contains(rawAsset)) return;
      final base = _applyAlias(rawAsset, crypto);
      reportedByBase[base] = (reportedByBase[base] ?? Decimal.zero) + value;
    });

    final projectedByBase = <String, Decimal>{};
    for (final m in movements) {
      final tx = m.transaction;
      if (tx == null || m.ledgerCode == null) continue;
      final code = m.ledgerCode!;
      final q = tx.quantity != null ? Decimal.tryParse(tx.quantity!) : null;
      if (q == null) continue;
      Decimal signed;
      switch (tx.kind) {
        case TransactionKind.buy:
          signed = q;
          break;
        case TransactionKind.sell:
        case TransactionKind.transferOut:
          signed = -q;
          break;
        case TransactionKind.adjustment:
          signed = q; // delta déjà signé (agrégat de récompenses)
          break;
        case TransactionKind.openingBalance:
        case TransactionKind.dividend:
        case TransactionKind.deposit:
        case TransactionKind.withdrawal:
        case TransactionKind.interest:
        case TransactionKind.charge:
          continue;
      }
      projectedByBase[code] = (projectedByBase[code] ?? Decimal.zero) + signed;
    }

    // I-1 (revue adversariale) : un échange SANS jambe fiat exploitable ne
    // journalise rien (`UnvaluedExchange`, valorisation = lot 2), mais la
    // QUANTITÉ, elle, est connue dès ce lot — sans ce crédit, la carte
    // d'écart re-signalerait à tort CHAQUE actif échangé sans jambe fiat
    // (soit la quasi-totalité d'un relevé réel), alors que seule la
    // valorisation manque. Les codes FIAT sont exclus symétriquement à
    // `reportedByBase` ci-dessus (ex. le dustsweeping dégénéré pose
    // `codeReceived` = code fiat) — sans quoi un crédit non compensé
    // réintroduirait l'écart fantôme sur la devise de règlement.
    for (final u in unvaluedExchanges) {
      final paid = u.codePaid;
      final qtyPaid = u.quantityPaid;
      if (paid != null && qtyPaid != null && !fiatRawAssets.contains(paid)) {
        final q = Decimal.tryParse(qtyPaid);
        if (q != null) {
          projectedByBase[paid] = (projectedByBase[paid] ?? Decimal.zero) - q;
        }
      }
      if (!fiatRawAssets.contains(u.codeReceived)) {
        final q = Decimal.tryParse(u.quantityReceived);
        if (q != null) {
          projectedByBase[u.codeReceived] =
              (projectedByBase[u.codeReceived] ?? Decimal.zero) + q;
        }
      }
    }

    final allBases = {...reportedByBase.keys, ...projectedByBase.keys};
    final gaps = <QuantityGap>[];
    for (final base in allBases) {
      final reported = reportedByBase[base] ?? Decimal.zero;
      final projected = projectedByBase[base] ?? Decimal.zero;
      if (reported != projected) {
        gaps.add(QuantityGap(
          asset: base,
          reportedTotal: reported.toString(),
          projectedTotal: projected.toString(),
        ));
      }
    }
    return gaps;
  }

  // ---------------------------------------------------------------------
  // Alias / classification
  // ---------------------------------------------------------------------

  static String _applyAlias(String rawAsset, CryptoLedgerSpec crypto) {
    var code = rawAsset;
    for (final suffix in crypto.stakedSuffixes) {
      if (code.endsWith(suffix)) {
        code = code.substring(0, code.length - suffix.length);
        break;
      }
    }
    return crypto.identityAliases[code] ?? code;
  }

  /// Résolution de l'action pour [leg] — lookup composite `type/subtype`
  /// SEUL quand un sous-type est PRÉSENT, repli sur le type nu SEULEMENT
  /// quand le sous-type est ABSENT (B-1, revue adversariale).
  ///
  /// AVANT ce correctif, un sous-type présent mais INCONNU (ex. une graphie
  /// réelle différente de `spottostaking`) retombait quand même sur
  /// `actions[type]` — un `transfer/<sous-type inconnu>` héritait alors du
  /// sens PAR CONVENTION posé sur `transfer` seul (`depositIn`, redirigé par
  /// signe), alors qu'il s'agit en réalité d'un mouvement interne
  /// spot↔staking : la ligne partait en `transferOut` RÉEL au lieu d'un
  /// rejet motivé — position détruite, zéro alerte. Un sous-type inconnu est
  /// maintenant TOUJOURS un rejet motivé `unknownCryptoAction` (B4 : jamais
  /// de coercition), jamais un repli.
  static CryptoLedgerAction? _resolveAction(_Leg leg, CryptoLedgerSpec crypto) {
    final base = leg.subKind != null && leg.subKind!.isNotEmpty
        ? crypto.actions['${leg.kindLabel}/${leg.subKind}']
        // Sous-type ABSENT (ex. `spend`/`receive`/`deposit`/`withdrawal`
        // bruts Kraken, qui n'ont jamais de `subtype` renseigné hors
        // dustsweeping) : repli légitime sur le type nu.
        : crypto.actions[leg.kindLabel];

    // Redirection déclarative par colonne annexe (chantier B16 lot 3, conception
    // interne — Coinbase `Receive` / `Sender Address`) : REMPLACE [base] pour
    // cette ligne UNIQUEMENT quand le type ET la valeur de la colonne coïncident —
    // cf. la doc de [ConditionalActionRedirect]. Sans effet (retombe sur [base])
    // si aucune redirection ne matche, ou si la colonne visée est absente du
    // fichier (`conditionalColumns[...]` alors `null`, jamais un plantage).
    for (final redirect in crypto.conditionalActionRedirects) {
      if (redirect.kindLabel != leg.kindLabel) continue;
      final value = leg.conditionalColumns[redirect.matchColumn];
      if (value != null && value.trim() == redirect.matchValue) {
        return redirect.action;
      }
    }
    return base;
  }

  /// `true` si [leg] est classifiée FIAT — colonne dédiée
  /// ([CryptoLedgerSpec.assetClassColumn]) prioritaire, repli sur
  /// [CryptoLedgerSpec.fiatAssets]. Classification PURE de la NATURE de
  /// l'actif (fiat vs crypto), INDÉPENDANTE de la devise du compte — c'est
  /// [_isAccountFiat] qui restreint aux seules jambes empruntables SANS
  /// conversion (B-2, revue adversariale : une jambe fiat ÉTRANGÈRE à la
  /// devise du compte ne peut PAS être écrite au pair).
  static bool _isFiat(_Leg leg, CryptoLedgerSpec crypto) {
    if (crypto.assetClassColumn != null && leg.assetClass != null) {
      return leg.assetClass == 'fiat';
    }
    return crypto.fiatAssets.contains(leg.rawAsset);
  }

  /// `true` si [leg] est fiat ET dans la DEVISE DU COMPTE — seule cette
  /// combinaison peut emprunter le chemin cash direct (B-2, revue
  /// adversariale) : un fiat étranger (ex. USD sur un compte EUR) écrit au
  /// pair serait une falsification silencieuse du cash, jamais une
  /// approximation acceptable au lot 1 (conversion FX = lot 2,
  /// `ExchangeRateService.getDailyRatesToEur`).
  static bool _isAccountFiat(
    _Leg leg,
    CryptoLedgerSpec crypto,
    String accountCurrency,
  ) {
    return _isFiat(leg, crypto) &&
        leg.rawAsset.toUpperCase() == accountCurrency.toUpperCase();
  }

  /// Désambiguïsation d'un RÔLE de clé de dédup au sein d'un même groupe : la
  /// première occurrence garde le rôle nu (`sell:BTC`), les suivantes portent un
  /// suffixe d'ordinal (`sell:BTC~2`) — sans quoi deux jambes de même actif sous le
  /// même refid (dustsweeping, retraits groupés) se dédupliqueraient l'une l'autre
  /// (conception interne).
  static String _disambiguate(Map<String, int> occurrences, String role) {
    final n = occurrences.update(role, (v) => v + 1, ifAbsent: () => 1);
    return n == 1 ? role : '$role~$n';
  }

  // ---------------------------------------------------------------------
  // Colonnes / cellules
  // ---------------------------------------------------------------------

  static int? _fieldIndex(
    List<String>? header,
    BrokerProfile profile,
    MovementField field,
  ) {
    final byIndex = profile.columns.byIndex[field];
    if (byIndex != null) return byIndex;
    final name = profile.columns.byName[field];
    return _byNameIndex(header, name);
  }

  static int? _byNameIndex(List<String>? header, String? name) {
    if (name == null || header == null) return null;
    final needle = name.trim().toLowerCase();
    final idx = header.indexWhere((h) => h.trim().toLowerCase() == needle);
    return idx == -1 ? null : idx;
  }

  static String? _cell(List<String> row, int? idx) {
    if (idx == null || idx < 0 || idx >= row.length) return null;
    final v = row[idx].trim();
    return v.isEmpty ? null : v;
  }

  static _Leg _withSeq(_Leg leg, int seq) => _Leg(
        sourceIndex: leg.sourceIndex,
        source: leg.source,
        date: leg.date,
        preciseDate: leg.preciseDate,
        kindLabel: leg.kindLabel,
        subKind: leg.subKind,
        rawAsset: leg.rawAsset,
        quantity: leg.quantity,
        fee: leg.fee,
        wallet: leg.wallet,
        balance: leg.balance,
        assetClass: leg.assetClass,
        valuationUsd: leg.valuationUsd,
        operationReference: leg.operationReference,
        amount: leg.amount,
        amountCurrency: leg.amountCurrency,
        notes: leg.notes,
        conditionalColumns: leg.conditionalColumns,
        seq: seq,
      );

  static String _isoDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---------------------------------------------------------------------
  // Date / décimal — sous-ensemble crypto (voir doc de fichier)
  // ---------------------------------------------------------------------

  static final RegExp _timeSuffix = RegExp(
    r'[\sT]+\d{1,2}[:hH]\d{2}(?::\d{2})?(?:[.,]\d+)?\s*'
    r'(?:[AaPp]\.?[Mm]\.?)?\s*(?:[Zz]|[Uu][Tt][Cc]|[Gg][Mm][Tt]|[+-]\d{2}:?\d{2})?$',
  );

  static DateTime? _parseCryptoDate(String? raw, DateFormatSpec spec) {
    if (raw == null) return null;
    final value = raw.trim().replaceFirst(_timeSuffix, '').trim();

    final parts = value.split(spec.separator);
    if (parts.length != 3) return null;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    final c = int.tryParse(parts[2]);
    if (a == null || b == null || c == null) return null;

    int year, month, day;
    if (spec.yearFirst) {
      if (a < 1000) return null; // pas une année plausible → rejet explicite
      year = a;
      month = b;
      day = c;
    } else {
      year = spec.fourDigitYear || c >= 100 ? c : c + 2000;
      day = spec.dayFirst ? a : b;
      month = spec.dayFirst ? b : a;
    }
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }

  /// Heure/minute/seconde éventuelles de [raw] — à l'USAGE EXCLUSIF de
  /// `_Leg.preciseDate` (fenêtre de tolérance `CryptoLedgerSpec. groupingWindow`,
  /// chantier B16 lot 3, conception interne). [_parseCrypto Date] ci-dessus JETTE
  /// délibérément cette information (granularité JOUR assumée PARTOUT ailleurs dans
  /// ce pipeline) — cette méthode la récupère SÉPARÉMENT, sans toucher au
  /// comportement de [_parseCryptoDate]. `null` si [raw] ne porte aucune heure
  /// reconnaissable (repli sur [dateOnly] à l'appelant).
  static final RegExp _timeOfDayPattern =
      RegExp(r'(\d{1,2})[:hH](\d{2})(?::(\d{2}))?');

  static DateTime? _parseCryptoTimeOfDay(String? raw, DateTime dateOnly) {
    if (raw == null) return null;
    final m = _timeOfDayPattern.firstMatch(raw);
    if (m == null) return null;
    final hour = int.tryParse(m.group(1)!);
    final minute = int.tryParse(m.group(2)!);
    final second = m.group(3) == null ? 0 : int.tryParse(m.group(3)!);
    if (hour == null || minute == null || second == null) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;
    // `DateTime.utc` (M-2, revue adversariale, CORRECTIF), JAMAIS le
    // constructeur LOCAL : les relevés crypto (Coinbase, suffixe ` UTC`
    // dépouillé en amont par `_timeSuffix`) donnent une heure-mur qui EST
    // déjà l'heure UTC — l'interpréter comme une heure LOCALE ferait
    // dépendre le calcul de `groupingWindow` (`preciseDate.difference`) du
    // fuseau d'exécution de l'application. Sous `Europe/Paris`, le repli
    // d'heure d'hiver (heure-mur RÉPÉTÉE deux fois) rendrait deux jambes
    // RÉELLEMENT distantes de quelques secondes tantôt indiscernables
    // (fausse fenêtre), tantôt distantes d'une heure fantôme (`convertNo
    // Match` erroné) — alors qu'aucune ambiguïté n'existe côté fichier
    // (heure-mur UTC, jamais répétée). `DateTime.utc` fixe la même valeur
    // NUMÉRIQUE sans jamais consulter le fuseau local, quel qu'il soit.
    return DateTime.utc(
        dateOnly.year, dateOnly.month, dateOnly.day, hour, minute, second);
  }

  /// Symbole monétaire éventuel (`$`/`€`/`£`), toléré en tête (signe optionnel
  /// + symbole) OU en queue (symbole seul), jamais au MILIEU — même motif, même
  /// garde ANCRÉE que `StatementImportService. _currencySymbol` (conception
  /// interne, export Coinbase : préfixe `$` INCONSTANT au sein du même fichier,
  /// ex. `Fees and/or Spread`/ `Subtotal`). DUPLIQUÉ ici (pas de symbole
  /// monétaire chez Kraken/ Binance — cf. l'en-tête de fichier) plutôt
  /// qu'exposé depuis `StatementImportService`, sans effet sur ces deux
  /// profils.
  static final RegExp _currencySymbol = RegExp(r'^([+-]?)[\$€£]|[\$€£]$');

  static Decimal? _parseCryptoDecimal(String? raw, DecimalSeparator sep) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    s = s.replaceAllMapped(_currencySymbol, (m) => m.group(1) ?? '');
    if (s.isEmpty) return null;
    if (sep == DecimalSeparator.comma) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    }
    return Decimal.tryParse(s);
  }
}

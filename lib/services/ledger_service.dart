// lib/services/ledger_service.dart
//
// Projecteur atomique du modèle B* : coordonne le JOURNAL (source de vérité,
// table transactions) et la POSITION (projection dérivée, table positions).
//
// INVARIANT D'ATOMICITÉ : toute mutation du journal (insertion / suppression)
// et les reprojections DÉRIVÉES qu'elle induit se font DANS UNE SEULE
// transaction SQL (`db.transaction`). Soit tout réussit, soit rien — jamais un
// journal modifié avec une projection périmée. Deux projections dérivées sont
// reprojetées ENSEMBLE et atomiquement à chaque mutation :
//   - la POSITION du symbole concerné ([reprojectSymbolWithin]), si symbol
//     != null ;
//   - le SOLDE ESPÈCES du compte ([reprojectCashWithin]), TOUJOURS — car un
//     buy/sell déplace le cash autant qu'un deposit, et un mouvement cash pur
//     (symbol null : deposit / withdrawal / interest / charge,
//     opening/adjustment espèces) ne touche QUE le cash. C'est la correction
//     du bug B5 (jadis la reprojection ne se déclenchait que si symbol !=
//     null).
//
// La reprojection titre ([reprojectSymbolWithin]) est un UPDATE CIBLÉ (jamais
// un INSERT OR REPLACE) : il ne touche QUE quantity / average_buy_price /
// derived_at, préservant asset_json et custom_name (métadonnées d'affichage).
// Si la position n'existe pas encore (aucune ligne affectée), on SKIP
// défensivement (on ne fabrique pas de ligne sans asset_json). La reprojection
// cash ([reprojectCashWithin]) est un UPDATE CIBLÉ de derived_cash /
// derived_cash_at sur la ligne accounts (jamais cash_balance, réservée aux
// comptes kind=cash).
//
// RESTAURATION DE SAUVEGARDE : `AccountStorage.importRawData` emprunte ces
// DEUX mêmes reprojections via leurs variantes `*Within` (cf. son étape 8) —
// LedgerService reste ainsi l'unique écrivain des colonnes dérivées, y
// compris à l'import.

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;

import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/import_result.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';
import 'package:portfolio_tracker/utils/logger.dart';

/// Coordinateur journal ↔ projection de position (modèle B*).
class LedgerService {
  final AppDatabase? _database;
  final TransactionStorage _txStorage;

  /// Construit le service. En production, omettre les paramètres : la connexion
  /// partagée ([AppDatabase.shared]) et un [TransactionStorage] par défaut sont
  /// utilisés. En test, injecter un [AppDatabase] in-memory (le
  /// [TransactionStorage] sera alors adossé à la même base).
  LedgerService({AppDatabase? database, TransactionStorage? transactionStorage})
      : _database = database,
        _txStorage =
            transactionStorage ?? TransactionStorage(database: database);

  /// Instance [AppDatabase] effective (singleton partagé en production).
  AppDatabase get _db => _database ?? AppDatabase.shared();

  // ---------------------------------------------------------------------------
  // Reprojection (interne — toujours appelée DANS une transaction SQL)
  // ---------------------------------------------------------------------------

  /// Recalcule la projection (quantité + PRU) du couple (accountId, symbol)
  /// depuis son journal et l'écrit dans `positions` via un UPDATE CIBLÉ.
  ///
  /// [txn] DOIT être la transaction SQL en cours (atomicité mouvement +
  /// reprojection). Ne crée jamais de ligne : si la position est absente
  /// (0 ligne affectée), on log et on skip (pas de ligne sans asset_json).
  ///
  /// PUBLIQUE pour UN SEUL appelant externe : la restauration de sauvegarde
  /// (`AccountStorage.importRawData`, étape 8) — LedgerService reste ainsi
  /// l'UNIQUE écrivain des colonnes dérivées (derived_at / derived_cash*), ce
  /// qui doit rester vrai (invariant grep-able : aucun autre UPDATE de ces
  /// colonnes dans le code). ⚠️ [txn] DOIT être l'exécuteur de la transaction
  /// SQL EN COURS : passer la connexion globale casserait l'atomicité
  /// silencieusement. Ne porte AUCUNE politique (elle projette, point) — le
  /// choix d'adopter ou non une position appartient à l'appelant
  /// (`declaredMatchesProjection` côté import ; action utilisateur côté D3).
  Future<void> reprojectSymbolWithin(
    DatabaseExecutor txn,
    String accountId,
    String symbol,
  ) async {
    final txs = await _txStorage.getBySymbol(accountId, symbol, executor: txn);
    final proj = projectPosition(txs);

    final affected = await txn.update(
      'positions',
      {
        // quantity : String canonique EXACTE (Decimal.toString, sans zéros de
        // fin superflus). average_buy_price : PRU double, ou NULL si quantité
        // ≤ 0. derived_at : horodatage de cette projection (epoch ms).
        'quantity': proj.quantity.toString(),
        'average_buy_price': proj.averagePrice,
        'derived_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'account_id = ? AND symbol = ?',
      whereArgs: [accountId, symbol],
    );

    if (affected == 0) {
      // Position absente : le journal a été muté mais aucune ligne positions ne
      // porte asset_json pour ce symbole. On ne fabrique pas de ligne
      // incomplète (asset_json NOT NULL) — la création de la position (avec son
      // Asset) reste la responsabilité de la couche appelante (UI/contrôleur).
      AppLogger.warning(
        'LedgerService.reprojectSymbolWithin : aucune position ($accountId, $symbol) '
        'à reprojeter (ligne absente) — reprojection ignorée.',
      );
    }
  }

  /// Recalcule le SOLDE ESPÈCES DÉRIVÉ du compte [accountId] (`Σ amount` de TOUT
  /// son journal, dans la devise du compte) et l'écrit dans `accounts` via un
  /// UPDATE CIBLÉ de `derived_cash` / `derived_cash_at`.
  ///
  /// [txn] DOIT être la transaction SQL en cours (atomicité mouvement +
  /// reprojections titre ET cash). Rejoue TOUT le journal du compte (pas le
  /// filtre par symbole) : un buy/sell déplace le cash au même titre qu'un
  /// deposit. Lit UNIQUEMENT [AssetTransaction.amount] (partition stricte —
  /// jamais fee/quantity/unitPrice) : double comptage impossible par
  /// construction. PAS de clamp à 0 (un solde négatif reste vrai).
  ///
  /// MULTI-DEVISES (contrainte V1, cf. design §6) : on ne persiste que le total
  /// de la DEVISE DU COMPTE. Un éventuel mouvement en devise étrangère (rejeté à
  /// l'import B4, hors périmètre de ce lot) n'entre PAS dans le cache — les
  /// devises hétérogènes ne sont JAMAIS sommées. Compte absent (FK garantit le
  /// contraire) → skip défensif.
  ///
  /// PUBLIQUE pour le même unique appelant externe que
  /// [reprojectSymbolWithin] (restauration de sauvegarde) et pour la même
  /// raison — cf. son doc-commentaire pour l'avertissement complet sur [txn].
  Future<void> reprojectCashWithin(DatabaseExecutor txn, String accountId) async {
    final accRows = await txn.query(
      'accounts',
      columns: ['currency'],
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (accRows.isEmpty) {
      AppLogger.warning(
        'LedgerService.reprojectCashWithin : compte $accountId absent — '
        'reprojection cash ignorée.',
      );
      return;
    }
    final currency = accRows.first['currency'] as String;

    final txs = await _txStorage.getByAccount(accountId, executor: txn);
    final cashByCurrency = replayLedger(txs).cashByCurrency;
    // Bucket de la devise du compte (0 exact si aucun mouvement dans cette
    // devise). String décimal canonique via Decimal.toString().
    final derived = cashByCurrency[currency] ?? Decimal.zero;

    await txn.update(
      'accounts',
      {
        'derived_cash': derived.toString(),
        'derived_cash_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [accountId],
    );
  }

  // ---------------------------------------------------------------------------
  // Mutations atomiques du journal
  // ---------------------------------------------------------------------------

  /// Enregistre (insère ou remplace) un mouvement puis reprojette, ATOMIQUEMENT,
  /// la position du symbole concerné (si symbol non null) ET le solde espèces du
  /// compte (TOUJOURS).
  ///
  /// Le solde espèces est reprojeté même pour un mouvement cash pur (symbol
  /// null) et même pour l'édition d'un buy/sell (qui déplace le cash) : c'est la
  /// correction du bug B5 (jadis la reprojection ne se déclenchait que si symbol
  /// != null, laissant deposit/withdrawal sans effet).
  Future<void> recordTransaction(AssetTransaction tx) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await _txStorage.upsert(tx, executor: txn);
      final symbol = tx.symbol;
      if (symbol != null && symbol.isNotEmpty) {
        await reprojectSymbolWithin(txn, tx.accountId, symbol);
      }
      await reprojectCashWithin(txn, tx.accountId);
    });
  }

  /// Supprime un mouvement du journal puis reprojette, ATOMIQUEMENT, la position
  /// concernée (si symbol non null) ET le solde espèces du compte (TOUJOURS —
  /// supprimer un buy/sell ou un deposit change le cash).
  ///
  /// Capture (accountId, symbol) AVANT la suppression (l'identité du mouvement
  /// n'est plus lisible une fois la ligne effacée). No-op si l'id est absent.
  Future<void> deleteTransaction(String id) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      final existing = await _txStorage.getById(id, executor: txn);
      if (existing == null) return; // rien à supprimer, rien à reprojeter
      await _txStorage.deleteById(id, executor: txn);
      final symbol = existing.symbol;
      if (symbol != null && symbol.isNotEmpty) {
        await reprojectSymbolWithin(txn, existing.accountId, symbol);
      }
      await reprojectCashWithin(txn, existing.accountId);
    });
  }

  // ---------------------------------------------------------------------------
  // Émission de mouvements système (openingBalance / adjustment)
  // ---------------------------------------------------------------------------

  /// Émet une POSITION INITIALE déclarative (kind openingBalance) et reprojette.
  ///
  /// [declarative] pose `meta.declarative = true` (marqueur d'un lot déclaratif,
  /// exposé tel quel dans l'export ; Sparneo n'en tire aucune conséquence).
  ///
  /// NB : [currency] est requise car le modèle [AssetTransaction] l'impose ;
  /// l'appelant (UI) fournit la devise de cotation de l'actif — aucune valeur
  /// par défaut n'est supposée ici.
  Future<void> emitOpeningBalance({
    required String accountId,
    required String symbol,
    required String quantity,
    String? unitPrice,
    required String currency,
    required DateTime date,
    bool declarative = true,
    String? note,
  }) async {
    final tx = AssetTransaction(
      id: AssetTransaction.generateId(),
      accountId: accountId,
      symbol: symbol,
      kind: TransactionKind.openingBalance,
      quantity: quantity,
      unitPrice: unitPrice,
      currency: currency,
      date: date,
      note: note,
      meta: declarative ? {'declarative': true} : null,
    );
    await recordTransaction(tx);
  }

  /// Émet un AJUSTEMENT (kind adjustment) — delta SIGNÉ de quantité — et
  /// reprojette. Convention de coût : Δcoût = deltaQuantity_signé × unitPrice.
  ///
  /// NB : [currency] requise (cf. [emitOpeningBalance]).
  Future<void> emitAdjustment({
    required String accountId,
    required String symbol,
    required String deltaQuantity,
    String? unitPrice,
    required String currency,
    required DateTime date,
    String? note,
  }) async {
    final tx = AssetTransaction(
      id: AssetTransaction.generateId(),
      accountId: accountId,
      symbol: symbol,
      kind: TransactionKind.adjustment,
      quantity: deltaQuantity,
      unitPrice: unitPrice,
      currency: currency,
      date: date,
      note: note,
    );
    await recordTransaction(tx);
  }

  // ---------------------------------------------------------------------------
  // Émission de mouvements ESPÈCES (openingBalance / adjustment, symbol=null)
  // ---------------------------------------------------------------------------

  /// Émet un SOLDE ESPÈCES INITIAL (openingBalance ESPÈCES, `symbol=null`) et
  /// reprojette le cash du compte. C'est l'analogue espèces de
  /// [emitOpeningBalance] : déclarer une trésorerie préexistante SANS la
  /// falsifier en apport (`deposit`) — un `deposit` fausserait le suivi des
  /// versements (plafond PEA, MWR…).
  ///
  /// [amount] est SIGNÉ (le solde initial ; négatif si découvert déclaré).
  /// `quantity`/`unitPrice` restent null (aucune position titre). La devise
  /// fournie DOIT être celle du compte (contrainte multi-devises V1) pour que le
  /// mouvement entre dans le bucket persisté.
  ///
  /// ACCROCHE UI (lot suivant) : action « Définir le solde espèces initial… »,
  /// réservée aux comptes titres (le cash dérivé y est en lecture seule ;
  /// `cash_balance` manuel reste le modèle des comptes kind=cash).
  Future<void> emitCashOpeningBalance({
    required String accountId,
    required String amount,
    required String currency,
    required DateTime date,
    String? note,
  }) async {
    final tx = AssetTransaction(
      id: AssetTransaction.generateId(),
      accountId: accountId,
      symbol: null,
      kind: TransactionKind.openingBalance,
      amount: amount,
      currency: currency,
      date: date,
      note: note,
      meta: const {'declarative': true},
    );
    await recordTransaction(tx);
  }

  /// Émet un AJUSTEMENT DE SOLDE ESPÈCES (adjustment ESPÈCES, `symbol=null`) —
  /// delta SIGNÉ de trésorerie — et reprojette le cash. Analogue espèces de
  /// [emitAdjustment] : corriger un solde dérivé (lecture seule) par un acte de
  /// journal nommé plutôt que par une édition directe (corollaire D1/PRU).
  ///
  /// [amount] = delta signé (positif = crédit, négatif = débit).
  /// `quantity`/`unitPrice` null (aucun effet position titre).
  ///
  /// ACCROCHE UI (lot suivant) : action « Ajuster le solde espèces… ».
  Future<void> emitCashAdjustment({
    required String accountId,
    required String amount,
    required String currency,
    required DateTime date,
    String? note,
  }) async {
    final tx = AssetTransaction(
      id: AssetTransaction.generateId(),
      accountId: accountId,
      symbol: null,
      kind: TransactionKind.adjustment,
      amount: amount,
      currency: currency,
      date: date,
      note: note,
    );
    await recordTransaction(tx);
  }

  // ---------------------------------------------------------------------------
  // Réconciliation d'une position legacy depuis son journal (D3)
  // ---------------------------------------------------------------------------

  /// Adopte le journal existant d'une position (accountId, symbol) : reprojette
  /// quantité/PRU depuis les mouvements déjà présents et horodate `derived_at`,
  /// ATOMIQUEMENT — SANS émettre aucun nouveau mouvement.
  ///
  /// Point d'entrée public d'ADOPTION utilisé par le flux de réconciliation
  /// (D3, cas « journal NON vide ») : la position legacy (derived_at NULL) a
  /// déjà des mouvements ; on la bascule en projetée sans double comptage
  /// (aucun openingBalance ajouté). La ligne `positions` doit exister (UPDATE
  /// ciblé — cf. [reprojectSymbolWithin] qui skip défensivement si absente).
  ///
  /// Reprojette AUSSI le cash du compte : l'adoption ne mute pas le journal
  /// (le Σ amount ne change donc pas), mais sur un compte JAMAIS projeté
  /// (derived_cash_at NULL — base migrée pré-v6, ou position restaurée avant
  /// le correctif d'import), l'adoption est souvent le premier acte B* du
  /// compte et doit initialiser le cache cash. Idempotent si le cache est
  /// déjà frais. Contrat uniforme : TOUTE reprojection passe par les DEUX
  /// projections.
  Future<void> reconcileFromJournal(String accountId, String symbol) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await reprojectSymbolWithin(txn, accountId, symbol);
      await reprojectCashWithin(txn, accountId);
    });
  }

  // ---------------------------------------------------------------------------
  // Suppression conjointe position + journal
  // ---------------------------------------------------------------------------

  /// Supprime ATOMIQUEMENT une position ET tout son journal (tous les mouvements
  /// du même symbole sur le compte). Les mouvements d'un AUTRE symbole du compte
  /// ne sont pas touchés.
  ///
  /// Supprimer les mouvements d'un symbole (buys/sells) change le solde espèces
  /// du compte : la reprojection cash est donc REJOUÉE dans la même transaction
  /// (sinon `derived_cash` resterait périmé, incluant le cash de titres effacés).
  Future<void> deletePositionWithJournal(String accountId, String symbol) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.delete(
        'transactions',
        where: 'account_id = ? AND symbol = ?',
        whereArgs: [accountId, symbol],
      );
      await txn.delete(
        'positions',
        where: 'account_id = ? AND symbol = ?',
        whereArgs: [accountId, symbol],
      );
      await reprojectCashWithin(txn, accountId);
    });
  }

  // ---------------------------------------------------------------------------
  // Import ADDITIF d'un relevé (append au journal, jamais destructif)
  // ---------------------------------------------------------------------------

  /// Ajoute [movements] au journal du compte [accountId] SANS rien effacer, en
  /// UNE SEULE transaction SQL. ATOMICITÉ GLOBALE : une exception à n'importe
  /// quelle étape ROLLBACK tout — aucun import partiel ne subsiste.
  ///
  /// [newAssets] : les [Asset] à matérialiser en lignes `positions` pour les
  /// symboles encore ABSENTS du compte (ils portent l'ISIN résolu par la couche
  /// appelante). La clé effective d'un actif est son `symbol` ; un [Asset] dont
  /// le symbole existe déjà est ignoré (jamais de recréation).
  ///
  /// ORDRE IMPOSÉ (I3) : la ligne `positions` d'un symbole nouveau est créée
  /// AVANT toute journalisation, car [reprojectSymbolWithin] est un UPDATE ciblé
  /// qui SKIP si la position n'existe pas — journaliser d'abord laisserait sa
  /// projection ignorée en silence.
  ///
  /// POLITIQUE DE REPROJECTION TITRE (anti-écrasement d'une déclaration legacy —
  /// invariant central de cette méthode) : un symbole titre touché n'est
  /// reprojeté que lorsque c'est SÛR —
  ///   - symbole NOUVEAU (créé ici) ou DÉJÀ PROJETÉ (`derived_at` non NULL) :
  ///     reprojection sûre (le journal complet du symbole fait foi, elle englobe
  ///     l'ancien et le nouveau) ;
  ///   - symbole LEGACY DÉCLARÉ (`derived_at` NULL : quantité / PRU saisis à la
  ///     main, aucun journal adopté) : reprojeter écraserait la déclaration par
  ///     une projection PARTIELLE fausse (un relevé ne couvre qu'une période,
  ///     pas tout l'historique). On ne le fait donc PAS — SAUF si les mouvements
  ///     entrants portent une ancre `openingBalance` dont la projection REPRODUIT
  ///     la déclaration ([declaredMatchesProjection]) : l'antériorité est alors
  ///     prouvée capturée, l'adoption est non-destructive. Sans cette preuve, la
  ///     position reste legacy INTACTE (le contrôleur a averti l'utilisateur en
  ///     amont) et seul le cash bouge.
  ///
  /// Le SOLDE ESPÈCES est TOUJOURS reprojeté (Σ amount de tout le journal, tous
  /// kinds) : le cash n'est jamais « legacy », c'est une pure projection.
  ///
  /// PERFORMANCE : chaque symbole est reprojeté UNE seule fois et le cash UNE
  /// seule fois, à la fin — jamais en bouclant [recordTransaction] (qui
  /// rouvrirait une transaction et reprojetterait tout le cash à chaque
  /// mouvement : O(N²)).
  ///
  /// Les colonnes dérivées ne sont écrites QUE via [reprojectSymbolWithin] /
  /// [reprojectCashWithin] — LedgerService reste l'unique écrivain (invariant).
  ///
  /// [importBatchId] (OPTIONNEL, défaut null → comportement historique INCHANGÉ)
  /// estampille chaque mouvement écrit avec `meta['importBatch'] =
  /// importBatchId`, EN FUSION avec le meta existant (jamais d'écrasement de
  /// `meta['importKey']` ni de `meta['seq']`). Cette estampille identifie le LOT
  /// d'import et rend l'annulation ciblée possible ([removeImportBatch]) : elle
  /// n'a AUCUN autre effet (ni sur la projection titre, ni sur le cash).
  Future<ImportResult> importMovements({
    required String accountId,
    required List<AssetTransaction> movements,
    required List<Asset> newAssets,
    String? importBatchId,
  }) async {
    final db = await _db.database;

    var written = 0;
    final created = <String>[];
    final reprojected = <String>[];
    final leftLegacy = <String>[];

    await db.transaction((txn) async {
      // Instantané PRÉ-IMPORT des positions du compte (symbol → état), lu UNE
      // fois et AVANT toute création/reprojection : c'est ce qui distingue sans
      // ambiguïté un symbole nouveau, un symbole déjà projeté (derived_at non
      // NULL) et un symbole legacy déclaré (derived_at NULL). Capturé ici car
      // l'étape 1 va poser de nouvelles lignes (à derived_at NULL elles aussi) —
      // seul cet instantané permet de ne pas les confondre avec du legacy.
      final pre = <String, ({int? derivedAt, String? qty, double? pru})>{};
      final preRows = await txn.query(
        'positions',
        columns: ['symbol', 'quantity', 'average_buy_price', 'derived_at'],
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      for (final r in preRows) {
        pre[r['symbol'] as String] = (
          derivedAt: (r['derived_at'] as num?)?.toInt(),
          qty: r['quantity'] as String?,
          pru: (r['average_buy_price'] as num?)?.toDouble(),
        );
      }

      // 1. Créer les positions MANQUANTES (ordre I3). Même SQL que
      // `AccountStorage.savePosition` (asset_json = définition complète). Le
      // garde `pre.containsKey` / `createdSet` assure qu'AUCUNE ligne existante
      // n'est jamais atteinte par ce INSERT OR REPLACE — donc aucun effacement
      // de métadonnées ni de cascade. quantity/PRU sont des valeurs d'amorçage
      // (« 0 » / null) : l'étape 3 les remplacera par la projection du journal.
      final createdSet = <String>{};
      for (final asset in newAssets) {
        final sym = asset.symbol;
        if (sym.isEmpty || pre.containsKey(sym) || createdSet.contains(sym)) {
          continue;
        }
        await txn.rawInsert(
          '''
          INSERT OR REPLACE INTO positions
            (account_id, symbol, quantity, average_buy_price, custom_name, asset_json)
          VALUES (?, ?, ?, ?, ?, ?)
          ''',
          [accountId, sym, '0', null, null, jsonEncode(asset.toJson())],
        );
        createdSet.add(sym);
        created.add(sym);
      }

      // 2. Upsert de chaque mouvement, en regroupant les mouvements titres par
      // symbole (pour la vérification d'ancre à l'étape 3). L'accountId est
      // FORCÉ à celui de l'import — comme `importRawData` impose la clé de la map
      // plutôt que le champ interne : un candidat malformé pointant un autre
      // compte serait sinon journalisé hors de portée de la reprojection
      // ci-dessous (corruption silencieuse d'un solde).
      final incomingBySymbol = <String, List<AssetTransaction>>{};
      for (final m in movements) {
        var tx =
            m.accountId == accountId ? m : m.copyWith(accountId: accountId);
        // Estampille de LOT (support de l'annulation d'import) : fusion de
        // meta['importBatch'] SANS écraser meta['importKey']/['seq'] ni aucune
        // autre clé existante. Null → meta laissé tel quel (legacy).
        if (importBatchId != null) {
          tx = tx.copyWith(meta: {...?tx.meta, 'importBatch': importBatchId});
        }
        await _txStorage.upsert(tx, executor: txn);
        written++;
        final s = tx.symbol;
        if (s != null && s.isNotEmpty) {
          (incomingBySymbol[s] ??= <AssetTransaction>[]).add(tx);
        }
      }

      // 3. Reprojection titre — chaque symbole touché exactement une fois.
      for (final entry in incomingBySymbol.entries) {
        final sym = entry.key;
        final isNew = createdSet.contains(sym);
        final ex = pre[sym];

        if (isNew || (ex != null && ex.derivedAt != null)) {
          // Nouveau, ou position déjà projetée → reprojection sûre.
          await reprojectSymbolWithin(txn, accountId, sym);
          reprojected.add(sym);
        } else if (ex != null) {
          // Legacy déclaré (derived_at NULL) : adopter UNIQUEMENT si une ancre
          // openingBalance entrante REPRODUIT la déclaration — preuve que
          // l'antériorité est capturée et que la reprojection ne détruira rien.
          final anchors = entry.value
              .where((t) =>
                  t.kind == TransactionKind.openingBalance &&
                  t.symbol != null &&
                  t.symbol!.isNotEmpty)
              .toList();
          final coherent = anchors.isNotEmpty &&
              declaredMatchesProjection(
                projectPosition(anchors),
                declaredQuantity: ex.qty,
                declaredAveragePrice: ex.pru,
              );
          if (coherent) {
            await reprojectSymbolWithin(txn, accountId, sym);
            reprojected.add(sym);
          } else {
            leftLegacy.add(sym);
          }
        }
        // ex == null && !isNew : le mouvement porte un symbole sans position ni
        // Asset fourni par l'appelant. Il est journalisé, mais aucune ligne
        // `positions` n'existe à projeter (le UPDATE ciblé skiperait de toute
        // façon). On ne fabrique pas de position incomplète — cohérent avec
        // recordTransaction sur un symbole absent ; à l'appelant de fournir le
        // newAssets correspondant.
      }

      // 4. Cash : TOUJOURS reprojeté (pure projection du journal, tous kinds).
      await reprojectCashWithin(txn, accountId);
    });

    // Ordres déterministes (feedback UI reproductible).
    created.sort();
    reprojected.sort();
    leftLegacy.sort();
    return ImportResult(
      movementsWritten: written,
      createdSymbols: created,
      reprojectedSymbols: reprojected,
      legacySymbols: leftLegacy,
    );
  }

  // ---------------------------------------------------------------------------
  // Annulation ciblée d'un LOT d'import (inverse de importMovements)
  // ---------------------------------------------------------------------------

  /// Supprime ATOMIQUEMENT du journal du compte [accountId] TOUS les mouvements
  /// estampillés `meta['importBatch'] == batchId` (posés par [importMovements]),
  /// puis reprojette — dans la MÊME transaction SQL — les symboles titres touchés
  /// et le solde espèces. Retourne le NOMBRE de mouvements supprimés (0 si le lot
  /// est vide / inconnu — no-op sans effet de bord).
  ///
  /// ATOMICITÉ : suppression + reprojections dans un unique `db.transaction` —
  /// toute exception ROLLBACK l'ensemble (aucune suppression partielle, aucune
  /// projection périmée). C'est l'inverse strict de [importMovements] : seuls les
  /// mouvements DU LOT sont effacés ; ceux d'un AUTRE lot ou saisis à la main
  /// (sans `importBatch`, ou avec un autre `importBatch`) ne sont JAMAIS touchés.
  ///
  /// POLITIQUE DE REPROJECTION TITRE (miroir EXACT de la garde anti-écrasement de
  /// [importMovements], appliquée sur l'état PRÉ-suppression) : un symbole touché
  /// n'est reprojeté que si sa position était DÉJÀ PROJETÉE avant l'annulation
  /// (`derived_at` non NULL) — la reprojection englobe alors le journal RESTANT
  /// (l'import n'y figure plus). Un symbole dont la position est restée LEGACY
  /// (`derived_at` NULL : jamais adoptée par l'import — cf. sa garde) n'est PAS
  /// reprojeté : la déclaration manuelle demeure INTACTE (elle n'a jamais été
  /// modifiée par l'import, l'annulation n'a donc rien à y défaire).
  ///
  /// POSITION VIDÉE (symbole créé par le lot, ou legacy adopté par le lot) : si
  /// l'annulation vide entièrement le journal d'un symbole DÉJÀ PROJETÉ, la
  /// reprojection le ramène à quantité 0 / PRU null (la ligne `positions`
  /// SUBSISTE). CHOIX ASSUMÉ : on ne supprime PAS la ligne devenue orpheline.
  /// Raisons : (1) au moment de l'annulation on ne peut PAS distinguer de façon
  /// sûre un symbole CRÉÉ par ce lot d'une position legacy ADOPTÉE par ce lot
  /// (les deux ont `derived_at` non NULL) — supprimer détruirait alors
  /// `asset_json`/`custom_name` d'une position PRÉEXISTANTE à l'import (bien pire
  /// qu'un résidu à 0) ; (2) laisser à 0 est non destructif et récupérable (la
  /// suppression d'une position à 0 reste une action utilisateur explicite via
  /// [deletePositionWithJournal]). Le léger résidu (position neuve importée puis
  /// annulée, laissée à 0) est accepté au profit de la sûreté des données.
  ///
  /// LIMITE V1 (legacy ADOPTÉ) : si l'import avait adopté une position legacy
  /// (ancre openingBalance cohérente → `derived_at` posé, déclaration remplacée
  /// par la projection), l'annulation ne peut PAS restaurer la déclaration
  /// manuelle d'origine (quantité/PRU + `derived_at` NULL) : l'adoption a écrasé
  /// ces valeurs à l'import et aucun instantané pré-import n'est conservé. La
  /// position reste alors PROJETÉE sur le journal restant (0 si vidé). Inverse
  /// imparfait assumé pour la V1.
  Future<int> removeImportBatch(String accountId, String batchId) async {
    final db = await _db.database;
    var removed = 0;

    await db.transaction((txn) async {
      // 1. Journal complet du compte, lu DANS la transaction (atomicité).
      final all = await _txStorage.getByAccount(accountId, executor: txn);
      // 2. Mouvements du LOT — filtre STRICT sur meta['importBatch'].
      final batch =
          all.where((t) => t.meta?['importBatch'] == batchId).toList();
      if (batch.isEmpty) return; // lot inconnu/vide → no-op, rien à reprojeter.

      // 3. Symboles titres touchés par le lot (les mouvements cash purs ne
      //    portent pas de symbole : seul le cash, reprojeté en 5, les concerne).
      final touchedSymbols = <String>{
        for (final t in batch)
          if (t.symbol != null && t.symbol!.isNotEmpty) t.symbol!,
      };

      // 4. Instantané PRÉ-suppression des `derived_at` des symboles touchés :
      //    c'est lui qui pilote la garde anti-écrasement (une position legacy,
      //    derived_at NULL, ne doit PAS être reprojetée). Lu AVANT toute
      //    suppression (identique en esprit à l'instantané pré-import).
      final preDerivedAt = <String, int?>{};
      if (touchedSymbols.isNotEmpty) {
        final rows = await txn.query(
          'positions',
          columns: ['symbol', 'derived_at'],
          where: 'account_id = ?',
          whereArgs: [accountId],
        );
        for (final r in rows) {
          final sym = r['symbol'] as String;
          if (touchedSymbols.contains(sym)) {
            preDerivedAt[sym] = (r['derived_at'] as num?)?.toInt();
          }
        }
      }

      // 5. Suppression des mouvements du lot (par id — ciblage exact).
      for (final t in batch) {
        await _txStorage.deleteById(t.id, executor: txn);
        removed++;
      }

      // 6. Reprojection titre : chaque symbole touché exactement une fois, mais
      //    UNIQUEMENT si sa position était déjà projetée (derived_at non NULL).
      //    - null (legacy jamais adopté, OU aucune ligne positions) : on SKIP —
      //      la déclaration legacy reste intacte, et reprojectSymbolWithin
      //      skiperait de toute façon une position absente.
      //    - non null : reprojection sûre sur le journal RESTANT (0 si vidé ;
      //      la ligne positions subsiste, cf. doc « POSITION VIDÉE »).
      for (final sym in touchedSymbols) {
        if (preDerivedAt[sym] == null) continue;
        await reprojectSymbolWithin(txn, accountId, sym);
      }

      // 7. Cash : TOUJOURS reprojeté (pure projection du journal restant).
      await reprojectCashWithin(txn, accountId);
    });

    return removed;
  }
}

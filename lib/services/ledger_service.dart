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

import 'package:decimal/decimal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;

import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
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
}

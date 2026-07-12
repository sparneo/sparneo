// lib/services/account_storage.dart
import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseExecutor;
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/model/valuation_snapshot.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/app_database.dart';
import 'package:portfolio_tracker/services/ledger_service.dart';

/// Persistance de la hiérarchie wallet → account → position via SQLite.
///
/// Les snapshots et les allocation_targets sont gérés par leurs propres
/// services (SnapshotStorage, AllocationTargetStorage). [AccountStorage]
/// les inclut dans [exportRawData] / [importRawData] pour garantir la
/// fidélité du backup (invariant I2) et maintenir l'API publique inchangée.
///
/// Toutes les contraintes FK (PRAGMA foreign_keys = ON, ON DELETE CASCADE)
/// sont assurées par AppDatabase._onConfigure. Les opérations en cascade
/// (deleteWallet, deleteAccount) sont donc déléguées au moteur SQLite.
class AccountStorage {
  final AppDatabase? _database;

  /// Constructeur de production : utilise l'instance [AppDatabase] injectée
  /// ou crée un [AppDatabase()] par défaut (singleton runtime effectif).
  AccountStorage({AppDatabase? database}) : _database = database;

  /// Retourne l'instance [AppDatabase] effective.
  /// En production (aucune injection) : le singleton partagé (R6).
  AppDatabase get _db => _database ?? AppDatabase.shared();

  // ---------------------------------------------------------------------------
  // Helpers internes : mapping colonnes ↔ modèles
  // ---------------------------------------------------------------------------

  /// Reconstruit un [Wallet] à partir d'une row SQLite.
  ///
  /// Le JSON attendu par [Wallet.fromJson] utilise la clé 'createdAt' (camelCase)
  /// alors que la colonne SQL est 'created_at' (snake_case).
  static Wallet _rowToWallet(Map<String, dynamic> row) {
    return Wallet.fromJson({
      'id': row['id'],
      'name': row['name'],
      'createdAt': row['created_at'],
    });
  }

  /// Reconstruit un [Account] à partir d'une row SQLite.
  static Account _rowToAccount(Map<String, dynamic> row) {
    return Account.fromJson({
      'id': row['id'],
      'walletId': row['wallet_id'],
      'name': row['name'],
      'type': row['type'],
      'currency': row['currency'] ?? 'EUR',
      'description': row['description'],
      'createdAt': row['created_at'],
      'cashBalance': row['cash_balance'],
      // `kind` = source unique. Le `type` transmis plus haut sert de repli pour
      // les lignes héritées où `kind` serait absent (fromJson préfère `kind`).
      'kind': row['kind'],
    });
  }

  /// Reconstruit un [Position] à partir d'une row SQLite.
  ///
  /// La colonne [asset_json] contient le [Asset.toJson()] complet ;
  /// les colonnes dénormalisées (symbol, quantity, average_buy_price,
  /// custom_name) servent à la PK et aux requêtes mais sont redondantes
  /// avec asset_json pour le round-trip. On reconstruit via [Position.fromJson]
  /// en injectant le compte depuis la colonne account_id.
  static Position _rowToPosition(Map<String, dynamic> row) {
    final assetMap = jsonDecode(row['asset_json'] as String) as Map<String, dynamic>;
    final posJson = {
      'accountId': row['account_id'],
      'asset': assetMap,
      'quantity': row['quantity'],
      'averageBuyPrice': row['average_buy_price'],
      'customName': row['custom_name'],
    };
    return Position.fromJson(posJson, fallbackAccountId: row['account_id'] as String);
  }

  /// Reconstruit un [ValuationSnapshot] depuis une row SQLite `snapshots`.
  /// Reprend le même mapping que [SnapshotStorage._rowToSnapshot].
  static ValuationSnapshot _rowToSnapshot(Map<String, dynamic> row) {
    return ValuationSnapshot(
      date: row['date'] as String,
      totalValue: (row['total_value'] as num).toDouble(),
      currency: row['currency'] as String,
      capturedAt: (row['captured_at'] as num).toInt(),
      accountCount: (row['account_count'] as num?)?.toInt() ?? 0,
      schemaVersion: (row['schema_version'] as num?)?.toInt() ?? 1,
    );
  }

  /// Reconstruit un [AssetTransaction] depuis une row SQLite `transactions`.
  ///
  /// Réplique EXACTEMENT le mapping colonnes→modèle de
  /// [TransactionStorage._rowToTx] (source non importable car privée) afin de
  /// garantir une projection bit-cohérente pour le backup (invariant I2).
  /// meta_json corrompu (JSON invalide ou non-Map) → meta null, sans crash
  /// (tolérance ascendante identique à TransactionStorage).
  static AssetTransaction _rowToTransaction(Map<String, dynamic> row) {
    Map<String, dynamic>? meta;
    final metaRaw = row['meta_json'] as String?;
    if (metaRaw != null) {
      try {
        final decoded = jsonDecode(metaRaw);
        if (decoded is Map) {
          meta = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // JSON invalide : meta reste null (pas de crash).
      }
    }

    return AssetTransaction(
      id: row['id'] as String,
      accountId: row['account_id'] as String,
      symbol: row['symbol'] as String?,
      // Lecture DB TOLÉRANTE (projection pour l'export) : voir la note
      // détaillée dans TransactionStorage._rowToTx. Ces lignes proviennent de
      // notre propre base, déjà validée à l'écriture ; un wire inconnu ici
      // signifierait une corruption locale — repli `buy` pour ne pas casser
      // l'export, jamais de `fromWire` levant sur nos propres données.
      kind: TransactionKind.tryFromWire(row['kind'] as String) ??
          TransactionKind.buy,
      quantity: row['quantity'] as String?,
      unitPrice: row['unit_price'] as String?,
      amount: row['amount'] as String?,
      currency: row['currency'] as String,
      date: DateTime.parse(row['date'] as String),
      fee: row['fee'] as String?,
      note: row['note'] as String?,
      meta: meta,
      settlementCurrency: row['settlement_currency'] as String?,
    );
  }

  // ---------------------------------------------------------------------------
  // GESTION DES WALLETS
  // ---------------------------------------------------------------------------

  /// Retourne tous les wallets, triés de façon déterministe (created_at, id).
  Future<List<Wallet>> getAllWallets() async {
    final db = await _db.database;
    final rows = await db.query(
      'wallets',
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(_rowToWallet).toList();
  }

  /// Insère un wallet, ou met à jour ses champs mutables s'il existe déjà.
  ///
  /// CRITIQUE — NE PAS remplacer par `INSERT OR REPLACE` : SQLite implémente
  /// REPLACE en DELETE-puis-INSERT, ce qui déclenche les `ON DELETE CASCADE`
  /// des enfants (accounts → positions → transactions → snapshots → cibles).
  /// Éditer un wallet existant effacerait donc tout son arbre. On fait un
  /// UPDATE ciblé, et un INSERT seulement si la ligne n'existe pas — aucun
  /// DELETE, donc aucune cascade. Robuste sur toutes les versions de SQLite
  /// (contrairement à `ON CONFLICT DO UPDATE`, indisponible avant SQLite 3.24).
  Future<void> saveWallet(Wallet wallet) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      final updated = await txn.update(
        'wallets',
        {'name': wallet.name},
        where: 'id = ?',
        whereArgs: [wallet.id],
      );
      if (updated == 0) {
        await txn.insert('wallets', {
          'id': wallet.id,
          'name': wallet.name,
          'created_at': wallet.createdAt.toIso8601String(),
        });
      }
    });
  }

  /// Supprime le wallet et tout son arbre en cascade (accounts → positions →
  /// snapshots → allocation_targets) grâce aux FK ON DELETE CASCADE.
  Future<void> deleteWallet(String walletId) async {
    final db = await _db.database;
    await db.delete(
      'wallets',
      where: 'id = ?',
      whereArgs: [walletId],
    );
  }

  // ---------------------------------------------------------------------------
  // GESTION DES COMPTES
  // ---------------------------------------------------------------------------

  /// Retourne le compte d'identifiant [id], ou `null` s'il n'existe pas.
  ///
  /// Lecture ciblée (une ligne) — utile pour récupérer la DEVISE DU COMPTE
  /// (devise de règlement) au moment de saisir un mouvement sur une position
  /// (cf. `TransactionEditDialog`, design cash-ledger §8).
  Future<Account?> getAccount(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      'accounts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToAccount(rows.first);
  }

  /// Retourne tous les comptes, triés de façon déterministe (created_at, id).
  Future<List<Account>> getAllAccounts() async {
    final db = await _db.database;
    final rows = await db.query(
      'accounts',
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(_rowToAccount).toList();
  }

  /// Retourne les comptes d'un wallet, triés de façon déterministe.
  Future<List<Account>> getAccountsByWallet(String walletId) async {
    final db = await _db.database;
    final rows = await db.query(
      'accounts',
      where: 'wallet_id = ?',
      whereArgs: [walletId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(_rowToAccount).toList();
  }

  /// Insère un compte, ou met à jour ses champs mutables s'il existe déjà.
  ///
  /// ATTENTION FK : le wallet référencé doit exister dans `wallets`.
  ///
  /// CRITIQUE — NE PAS remplacer par `INSERT OR REPLACE` : SQLite implémente
  /// REPLACE en DELETE-puis-INSERT, ce qui déclenche les `ON DELETE CASCADE`
  /// de `positions` ET `transactions`. Éditer un compte existant (renommage
  /// OU changement de nature) effacerait donc toutes ses positions et tous ses
  /// mouvements. On fait un UPDATE ciblé, et un INSERT seulement si la ligne
  /// n'existe pas — aucun DELETE, donc aucune cascade. On ne touche pas à
  /// `created_at` sur mise à jour (immuable). Robuste sur toutes les versions
  /// de SQLite (contrairement à `ON CONFLICT DO UPDATE`, absent avant 3.24).
  Future<void> saveAccount(Account account) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      final updated = await txn.update(
        'accounts',
        {
          'wallet_id': account.walletId,
          'name': account.name,
          'type': account.type.name, // miroir dérivé de kind (legacy NOT NULL)
          'currency': account.currency,
          'description': account.description,
          'cash_balance': account.cashBalance,
          'kind': account.kind.name, // source unique
        },
        where: 'id = ?',
        whereArgs: [account.id],
      );
      if (updated == 0) {
        await txn.insert('accounts', {
          'id': account.id,
          'wallet_id': account.walletId,
          'name': account.name,
          'type': account.type.name,
          'currency': account.currency,
          'description': account.description,
          'created_at': account.createdAt?.toIso8601String(),
          'cash_balance': account.cashBalance,
          'kind': account.kind.name,
        });
      }
    });
  }

  /// Retourne le SOLDE ESPÈCES DÉRIVÉ d'un compte titres : `(cash, at)` où
  /// `cash` est le montant décimal (String exact, dans la devise du compte) et
  /// `at` l'epoch ms du dernier recalcul (`accounts.derived_cash_at`).
  ///
  /// `cash == null` ET `at == null` : compte jamais projeté (aucun journal
  /// rejoué, ou compte legacy d'avant v6) — le cash dérivé est INCONNU (à
  /// distinguer d'un solde nul « 0 »). Cache reconstructible, EXCLU du backup
  /// (comme `positions.derived_at`) : le modèle [Account] n'expose pas ces
  /// champs ; on les lit ici de façon ciblée.
  ///
  /// NB : « espèces suivies vs non suivies » (opt-in) est une décision
  /// d'affichage distincte, à trancher sur le journal via `journalHasCashAnchor`
  /// (cf. position_projection.dart) — pas sur la nullité de ce cache.
  ///
  /// [executor] : lecture dans une transaction SQL en cours (par défaut, la
  /// connexion partagée).
  Future<({String? cash, int? at})> getAccountDerivedCash(
    String accountId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await _db.database;
    final rows = await db.query(
      'accounts',
      columns: ['derived_cash', 'derived_cash_at'],
      where: 'id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (rows.isEmpty) return (cash: null, at: null);
    return (
      cash: rows.first['derived_cash'] as String?,
      at: (rows.first['derived_cash_at'] as num?)?.toInt(),
    );
  }

  /// Supprime le compte et ses positions en cascade (FK ON DELETE CASCADE).
  Future<void> deleteAccount(String accountId) async {
    final db = await _db.database;
    await db.delete(
      'accounts',
      where: 'id = ?',
      whereArgs: [accountId],
    );
    // Les positions sont supprimées automatiquement par la FK ON DELETE CASCADE.
  }

  // ---------------------------------------------------------------------------
  // POSITIONS
  // ---------------------------------------------------------------------------

  /// Retourne les positions d'un compte, triées par symbole (déterministe).
  Future<List<Position>> getPositions(String accountId) async {
    final db = await _db.database;
    final rows = await db.query(
      'positions',
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'symbol ASC',
    );
    return rows.map(_rowToPosition).toList();
  }

  /// Insère ou remplace une position (upsert par PK composite account_id, symbol).
  ///
  /// [quantity] reste TEXT (String dans le modèle — risque R8 : ne jamais
  /// convertir en REAL pour préserver la précision et le round-trip).
  /// ATTENTION FK : le compte référencé doit exister dans `accounts`.
  ///
  /// [executor] : écriture dans une transaction SQL en cours. Par défaut, la
  /// connexion partagée (comportement inchangé pour les appelants existants).
  ///
  /// NB projection B* : ce chemin legacy (INSERT OR REPLACE) NE renseigne PAS
  /// `derived_at` — la ligne écrite ici a donc `derived_at` NULL (quantité/PRU
  /// saisis, non dérivés du journal). Le projecteur ([LedgerService]) utilise un
  /// UPDATE ciblé qui, lui, horodate `derived_at`.
  Future<void> savePosition(
    String accountId,
    Position position, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await _db.database;
    await db.rawInsert(
      '''
      INSERT OR REPLACE INTO positions
        (account_id, symbol, quantity, average_buy_price, custom_name, asset_json)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        accountId,
        position.symbol,
        position.quantity,
        position.averageBuyPrice,
        position.customName,
        jsonEncode(position.asset.toJson()),
      ],
    );
  }

  /// Alias de [savePosition] (upsert idempotent).
  Future<void> updatePosition(String accountId, Position position) async {
    await savePosition(accountId, position);
  }

  /// Retourne la position (accountId, symbol), ou null si absente.
  ///
  /// [executor] : lecture dans une transaction SQL en cours (par défaut, la
  /// connexion partagée).
  Future<Position?> getPosition(
    String accountId,
    String symbol, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await _db.database;
    final rows = await db.query(
      'positions',
      where: 'account_id = ? AND symbol = ?',
      whereArgs: [accountId, symbol],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _rowToPosition(rows.first);
  }

  /// Retourne l'horodatage de dernière projection (`positions.derived_at`, epoch
  /// ms) de la position (accountId, symbol), ou null si la position est absente
  /// OU si elle n'a jamais été projetée (legacy : quantité/PRU saisis à la main).
  ///
  /// Lecture ciblée de la seule colonne `derived_at` — le modèle [Position]
  /// n'expose délibérément pas ce champ (cache reconstructible, hors backup).
  Future<int?> getPositionDerivedAt(
    String accountId,
    String symbol, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await _db.database;
    final rows = await db.query(
      'positions',
      columns: ['derived_at'],
      where: 'account_id = ? AND symbol = ?',
      whereArgs: [accountId, symbol],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['derived_at'] as num?)?.toInt();
  }

  /// Sentinelle interne : distingue « non fourni » de « mettre à null » pour
  /// [updatePositionMetadata] (permet d'effacer un customName).
  static const Object _undefined = Object();

  /// Met à jour UNIQUEMENT les métadonnées d'affichage d'une position
  /// (`asset_json` et/ou `custom_name`) SANS jamais toucher aux champs dérivés
  /// du journal (`quantity`, `average_buy_price`, `derived_at`).
  ///
  /// Séparation stricte B* : la quantité et le PRU sont des projections du
  /// journal (écrites par le projecteur) ; le renommage / l'édition de la
  /// définition d'actif est une métadonnée indépendante, éditable directement.
  ///
  /// [asset] omis (null) → `asset_json` inchangé ; [customName] omis → colonne
  /// inchangée ; `customName: null` explicite → efface le nom personnalisé.
  /// No-op si aucun champ n'est fourni. Idempotent si la position est absente.
  Future<void> updatePositionMetadata(
    String accountId,
    String symbol, {
    Asset? asset,
    Object? customName = _undefined,
    DatabaseExecutor? executor,
  }) async {
    final updates = <String, Object?>{};
    if (asset != null) {
      updates['asset_json'] = jsonEncode(asset.toJson());
    }
    if (!identical(customName, _undefined)) {
      updates['custom_name'] = customName as String?;
    }
    if (updates.isEmpty) return;

    final db = executor ?? await _db.database;
    await db.update(
      'positions',
      updates,
      where: 'account_id = ? AND symbol = ?',
      whereArgs: [accountId, symbol],
    );
  }

  /// Supprime la position identifiée par (accountId, symbol).
  /// Idempotent : aucune exception si la ligne est absente.
  Future<void> removePosition(
    String accountId,
    String symbol, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await _db.database;
    await db.delete(
      'positions',
      where: 'account_id = ? AND symbol = ?',
      whereArgs: [accountId, symbol],
    );
  }

  // ---------------------------------------------------------------------------
  // EXPORT / IMPORT (invariant I2 : fidélité parfaite du backup)
  // ---------------------------------------------------------------------------

  /// Lit toutes les tables et projette vers la map de backup :
  /// ```
  /// {
  ///   'wallets': [Wallet.toJson(), ...],
  ///   'accounts': [Account.toJson(), ...],
  ///   'positions': {accountId: [Position.toJson(), ...], ...},
  ///   'transactions': {accountId: [AssetTransaction.toJson(), ...], ...},
  ///   'snapshots': {walletId: [ValuationSnapshot.toJson(), ...], ...},
  ///   'allocationTargets': {walletId: <target_json décodé>, ...},
  /// }
  /// ```
  ///
  /// Tous les ordres sont déterministes pour garantir la stabilité du
  /// round-trip export→import→export.
  ///
  /// Les caches dérivés (derived_at, derived_cash*) sont exclus : reconstruits
  /// ET vérifiés à l'import (étape 8 de [importRawData]).
  Future<Map<String, dynamic>> exportRawData() async {
    final db = await _db.database;

    // --- wallets ---
    final walletRows = await db.query('wallets', orderBy: 'created_at ASC, id ASC');
    final wallets = walletRows.map((r) => _rowToWallet(r).toJson()).toList();

    // --- accounts ---
    final accountRows = await db.query('accounts', orderBy: 'created_at ASC, id ASC');
    final accounts = accountRows.map((r) => _rowToAccount(r).toJson()).toList();

    // --- positions groupées par account_id (triées par symbol) ---
    final positionRows = await db.query('positions', orderBy: 'account_id ASC, symbol ASC');
    final positions = <String, dynamic>{};
    for (final row in positionRows) {
      final accountId = row['account_id'] as String;
      positions.putIfAbsent(accountId, () => <dynamic>[]);
      (positions[accountId] as List).add(_rowToPosition(row).toJson());
    }

    // --- transactions groupées par account_id ---
    // ORDER BY déterministe (account_id, date, id) pour garantir la stabilité
    // du round-trip export→import→export. NB : cet ordre diffère volontairement
    // de l'ordre d'AFFICHAGE de TransactionStorage (date DESC, id DESC) ; ici
    // seule la reproductibilité importe.
    final transactionRows = await db.query(
      'transactions',
      orderBy: 'account_id ASC, date ASC, id ASC',
    );
    final transactions = <String, dynamic>{};
    for (final row in transactionRows) {
      final accountId = row['account_id'] as String;
      transactions.putIfAbsent(accountId, () => <dynamic>[]);
      (transactions[accountId] as List).add(_rowToTransaction(row).toJson());
    }

    // --- snapshots groupés par wallet_id (triés par date) ---
    final snapshotRows = await db.query('snapshots', orderBy: 'wallet_id ASC, date ASC');
    final snapshots = <String, dynamic>{};
    for (final row in snapshotRows) {
      final walletId = row['wallet_id'] as String;
      snapshots.putIfAbsent(walletId, () => <dynamic>[]);
      (snapshots[walletId] as List).add(_rowToSnapshot(row).toJson());
    }

    // --- allocationTargets par wallet_id ---
    // On décode directement le TEXT stocké pour fidélité parfaite (pas de
    // reconstruction via AllocationTarget.fromJson/toJson qui pourrait perdre
    // des clés inconnues d'une future version du schéma).
    final targetRows = await db.query('allocation_targets', orderBy: 'wallet_id ASC');
    final allocationTargets = <String, dynamic>{};
    for (final row in targetRows) {
      final walletId = row['wallet_id'] as String;
      allocationTargets[walletId] = jsonDecode(row['target_json'] as String);
    }

    return {
      'wallets': wallets,
      'accounts': accounts,
      'positions': positions,
      'transactions': transactions,
      'snapshots': snapshots,
      'allocationTargets': allocationTargets,
    };
  }

  /// Remplace l'intégralité des données par celles fournies, dans une seule
  /// transaction (tout-ou-rien).
  ///
  /// Ordre FK strict : DELETE all → INSERT wallets → accounts → positions →
  /// transactions → snapshots → allocation_targets.
  ///
  /// Tolérance ascendante : les clés 'positions', 'transactions', 'snapshots'
  /// et 'allocationTargets' peuvent être absentes (vieille sauvegarde) — elles
  /// sont traitées comme des maps vides (les préexistants sont purgés).
  /// Les clés 'wallets' et 'accounts' absentes sont traitées comme des listes
  /// vides.
  Future<void> importRawData(Map<String, dynamic> data) async {
    final db = await _db.database;

    // Collectées pendant les étapes 3/4/5 pour alimenter la reprojection
    // post-restauration (étape 8), sans relire la base : on a déjà en main les
    // objets parsés issus du fichier.
    final accountIds = <String>[];
    final positionsByAccount = <String, List<Position>>{};
    final journalByAccount = <String, List<AssetTransaction>>{};

    await db.transaction((txn) async {
      // 1. Purge dans l'ordre inverse des FK (enfants avant parents) afin
      //    d'éviter toute violation de contrainte pendant la purge elle-même.
      //    En pratique, avec ON DELETE CASCADE, supprimer les wallets suffit ;
      //    mais on purge explicitement toutes les tables pour robustesse.
      await txn.delete('allocation_targets');
      await txn.delete('snapshots');
      await txn.delete('transactions');
      await txn.delete('positions');
      await txn.delete('accounts');
      await txn.delete('wallets');

      // 2. Wallets
      final walletList = (data['wallets'] as List?) ?? [];
      for (final wJson in walletList) {
        final w = Wallet.fromJson(Map<String, dynamic>.from(wJson as Map));
        await txn.rawInsert(
          'INSERT OR REPLACE INTO wallets(id, name, created_at) VALUES(?, ?, ?)',
          [w.id, w.name, w.createdAt.toIso8601String()],
        );
      }

      // 3. Accounts
      final accountList = (data['accounts'] as List?) ?? [];
      for (final aJson in accountList) {
        final a = Account.fromJson(Map<String, dynamic>.from(aJson as Map));
        accountIds.add(a.id);
        await txn.rawInsert(
          '''
          INSERT OR REPLACE INTO accounts
            (id, wallet_id, name, type, currency, description, created_at, cash_balance,
             kind)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            a.id,
            a.walletId,
            a.name,
            a.type.name, // miroir dérivé de kind (colonne legacy NOT NULL)
            a.currency,
            a.description,
            a.createdAt?.toIso8601String(),
            a.cashBalance,
            a.kind.name, // source unique
          ],
        );
      }

      // 4. Positions
      final positionsMap = (data['positions'] as Map?) ?? {};
      for (final entry in positionsMap.entries) {
        final accountId = entry.key as String;
        final posList = (entry.value as List?) ?? [];
        for (final pJson in posList) {
          final p = Position.fromJson(
            Map<String, dynamic>.from(pJson as Map),
            fallbackAccountId: accountId,
          );
          positionsByAccount.putIfAbsent(accountId, () => <Position>[]).add(p);
          await txn.rawInsert(
            '''
            INSERT OR REPLACE INTO positions
              (account_id, symbol, quantity, average_buy_price, custom_name, asset_json)
            VALUES (?, ?, ?, ?, ?, ?)
            ''',
            [
              accountId,
              p.symbol,
              p.quantity,
              p.averageBuyPrice,
              p.customName,
              jsonEncode(p.asset.toJson()),
            ],
          );
        }
      }

      // 5. Transactions (absent des vieilles sauvegardes → toléré).
      //    Enfant d'accounts (FK account_id CASCADE) : réinséré APRÈS accounts.
      //    Une transaction référençant un accountId absent viole la FK et fait
      //    échouer TOUTE la transaction db (rollback atomique) — comportement
      //    voulu, cohérent avec les positions orphelines.
      final transactionsMap = (data['transactions'] as Map?) ?? {};
      for (final entry in transactionsMap.entries) {
        final accountId = entry.key as String;
        final txList = (entry.value as List?) ?? [];
        for (final tJson in txList) {
          final tMap = Map<String, dynamic>.from(tJson as Map);
          // POLITIQUE STRICTE d'import (données EXTERNES) : un `kind` présent
          // mais inconnu (sauvegarde produite par une version plus récente, ou
          // fichier altéré) est REJETÉ — jamais coercé en `buy`. On lève ici :
          // le throw remonte hors de `db.transaction`, ce qui ROLLBACK toute
          // la restauration (atomicité — mêmes garanties que la FK orpheline).
          // Un `kind` absent reste toléré (repli `buy` côté fromJson : lignes
          // héritées d'avant le champ). tryFromWire couvre AUSSI les 2 nouveaux
          // kinds (openingBalance/adjustment) → eux passent normalement.
          final rawKind = tMap['kind'];
          if (rawKind != null &&
              TransactionKind.tryFromWire(rawKind.toString()) == null) {
            throw FormatException(
              'Transaction "${tMap['id']}" : type de mouvement inconnu '
              '"$rawKind". Sauvegarde probablement créée par une version plus '
              'récente de l\'application — restauration annulée.',
            );
          }
          final t = AssetTransaction.fromJson(
            tMap,
            fallbackAccountId: accountId,
          );
          // settlement_currency (v7) : devise de règlement de amount — donnée
          // du JOURNAL (source de vérité), sa perte fausserait irrémédiablement
          // la projection cash (bucket de cotation au lieu du compte).
          //
          // account_id = CLÉ de la map (comme les positions, étape 4) — JAMAIS
          // t.accountId : un champ interne divergent (fichier malformé)
          // désalignerait la décision d'adoption (étape 8, groupée par clé) de
          // la reprojection (relue par account_id) et pourrait écraser une
          // déclaration par une projection vide.
          await txn.rawInsert(
            '''
            INSERT OR REPLACE INTO transactions
              (id, account_id, symbol, kind, quantity, unit_price, amount,
               currency, date, fee, note, meta_json, settlement_currency)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              t.id,
              accountId,
              t.symbol,
              t.kind.wire,
              t.quantity,
              t.unitPrice,
              t.amount,
              t.currency,
              t.date.toIso8601String(),
              t.fee,
              t.note,
              t.meta != null ? jsonEncode(t.meta) : null,
              t.settlementCurrency,
            ],
          );
          journalByAccount.putIfAbsent(accountId, () => <AssetTransaction>[]).add(t);
        }
      }

      // 6. Snapshots (absent des vieilles sauvegardes → toléré)
      final snapshotsMap = (data['snapshots'] as Map?) ?? {};
      for (final entry in snapshotsMap.entries) {
        final walletId = entry.key as String;
        final snapList = (entry.value as List?) ?? [];
        for (final sJson in snapList) {
          final s = ValuationSnapshot.fromJson(Map<String, dynamic>.from(sJson as Map));
          await txn.rawInsert(
            '''
            INSERT OR REPLACE INTO snapshots
              (wallet_id, date, total_value, currency, captured_at,
               account_count, schema_version)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              walletId,
              s.date,
              s.totalValue,
              s.currency,
              s.capturedAt,
              s.accountCount,
              s.schemaVersion,
            ],
          );
        }
      }

      // 7. AllocationTargets (absent des vieilles sauvegardes → toléré)
      final targetsMap = (data['allocationTargets'] as Map?) ?? {};
      for (final entry in targetsMap.entries) {
        final walletId = entry.key as String;
        // Réencode la valeur pour la stocker en target_json (fidélité parfaite).
        await txn.rawInsert(
          'INSERT OR REPLACE INTO allocation_targets(wallet_id, target_json) VALUES(?, ?)',
          [walletId, jsonEncode(entry.value)],
        );
      }

      // 8. REPROJECTION POST-RESTAURATION (même transaction — atomique avec
      // l'import : un échec ici ROLLBACK toute la restauration).
      //
      // Les caches dérivés (positions.derived_at, accounts.derived_cash*) sont
      // volontairement EXCLUS du format de sauvegarde (reconstructibles) :
      // sans cette étape, TOUTE restauration — même d'un export fait la veille
      // par l'app à jour — redégraderait chaque position en « Non réconcilié »
      // et chaque solde espèces en « inconnu », alors que le journal complet
      // est là.
      //
      // Politique (aucun état transporté, aucune confiance dans le fichier) :
      // — CASH : reprojeté pour TOUS les comptes. Pur cache, aucune donnée
      //   déclarée à écraser (cash_balance des comptes kind=cash est réinséré
      //   tel quel à l'étape 3 et jamais touché) ; l'opt-in d'affichage
      //   (journalHasCashAnchor) neutralise les soldes non significatifs.
      //   Invariant post-import : tout compte a un cash projeté à jour.
      // — TITRE : ADOPTION CONDITIONNELLE. On ne pose derived_at que si la
      //   (quantité, PRU) déclarée dans le fichier est PROUVÉE égale à la
      //   projection de son journal (declaredMatchesProjection) — l'adoption
      //   est alors le no-op qu'aurait produit l'action « Réconcilier » (D3).
      //   Sinon la position reste legacy (derived_at NULL, valeur d'INSERT),
      //   déclarations INTACTES : un journal partiel (100 déclarés, 40 au
      //   journal), un fichier édité à la main ou un vieux backup ne peuvent
      //   JAMAIS écraser une déclaration. Auto-guérison rétroactive : le
      //   critère répare aussi les sauvegardes v1/v2/v3 antérieures à ce
      //   correctif, sans branche par version.
      //
      // Les écritures passent par LedgerService (reproject*Within) : il reste
      // l'unique écrivain des colonnes dérivées.
      final ledger = LedgerService(database: _database);
      for (final entry in positionsByAccount.entries) {
        final accountId = entry.key;
        final bySymbol = <String, List<AssetTransaction>>{};
        for (final t in journalByAccount[accountId] ?? const <AssetTransaction>[]) {
          final s = t.symbol;
          if (s != null && s.isNotEmpty) (bySymbol[s] ??= []).add(t);
        }
        // Déduplique par symbole en gardant la DERNIÈRE entrée : miroir exact
        // de l'INSERT OR REPLACE de l'étape 4, qui ne conserve que la dernière
        // ligne en base pour un symbole dupliqué (fichier fabriqué). Sans ce
        // miroir, une entrée PERDANTE (jamais écrite en base) pourrait matcher
        // la projection et faire adopter une ligne alors que la déclaration
        // réellement en base (la dernière) diverge.
        final lastBySymbol = <String, Position>{
          for (final p in entry.value)
            if (p.symbol.isNotEmpty) p.symbol: p,
        };
        for (final p in lastBySymbol.values) {
          final proj = projectPosition(bySymbol[p.symbol] ?? const []);
          if (declaredMatchesProjection(
            proj,
            declaredQuantity: p.quantity,
            declaredAveragePrice: p.averageBuyPrice,
          )) {
            await ledger.reprojectSymbolWithin(txn, accountId, p.symbol);
          }
        }
      }
      for (final id in accountIds) {
        await ledger.reprojectCashWithin(txn, id);
      }
    });
  }
}

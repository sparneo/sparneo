// lib/services/app_database.dart
//
// Couche d'accès SQLite centrale.
// Responsabilités :
//   - Ouverture lazy mémoïsée (singleton runtime effectif — risque R6).
//   - DDL v1 (5 tables) avec PRAGMA foreign_keys = ON (risque R4).
//   - Sélection de la factory selon la plateforme :
//       • mobile (Android/iOS)  → databaseFactory sqflite natif
//       • desktop (Linux/macOS/Windows) → databaseFactoryFfi après sqfliteFfiInit()
//       • test → injection via constructeur (factory + inMemoryDatabasePath)
//   - Résolution du chemin de la base selon la plateforme (cf. _resolveDefaultPath) :
//       • mobile → nom de fichier RELATIF (sqflite le résout dans son
//         répertoire databases standard — comportement historique inchangé)
//       • desktop → chemin ABSOLU dans le répertoire de support applicatif
//         (databaseFactoryFfi ne connaît pas ce répertoire standard et
//         résout un relatif ailleurs, hors XDG — cf. _resolveDefaultPath)

import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// sqflite_common_ffi ré-exporte les symboles sqflite (Database, DatabaseFactory,
// databaseFactory, inMemoryDatabasePath…) — pas d'import sqflite direct requis.

class AppDatabase {
  /// Version courante du schéma. Incrémentée à chaque migration.
  ///
  /// v1 : 5 tables initiales (wallets, accounts, positions, snapshots,
  ///      allocation_targets).
  /// v2 : ajout de la table `transactions` (journal d'opérations — vague 4).
  ///      Migration purement additive (nouvelle table, aucune table v1 touchée).
  /// v3 : ajout de la colonne `accounts.kind` (nature du compte — axe unique
  ///      valorisation + fiscalité, cf. [AccountKind]). Additive : ADD COLUMN
  ///      avec DEFAULT puis backfill depuis l'ancien `type`. La colonne `type`
  ///      (v1) est CONSERVÉE comme miroir dérivé (NOT NULL, écrit par le
  ///      storage = `kind.valuationType`) — SQLite < 3.35 ne sait pas DROP une
  ///      colonne, et la garder assure un rollback sûr sans jamais diverger
  ///      (le storage la recalcule toujours depuis `kind`).
  /// v4 : ajout de la table `last_known_quotes` (cache « dernier cours connu »,
  ///      LOT 2 — dégradation douce quand la source de cotation tombe).
  ///      Purement additive, aucune table existante touchée. Table
  ///      volontairement EXCLUE du pont backup (cache reconstructible, cf.
  ///      [CachingMarketDataProvider]).
  /// v5 : ajout de la colonne `positions.derived_at` (marqueur de projection
  ///      B* — la position devient une projection dérivée du journal). Additive,
  ///      NULLABLE, SANS backfill : les positions existantes restent NULL =
  ///      legacy (quantité/PRU saisis à la main, à réconcilier). Zéro perte de
  ///      données. Colonne EXCLUE du pont backup (cache reconstructible depuis
  ///      le journal, cf. décision D « derived_at hors backup »).
  /// v6 : ajout des colonnes `accounts.derived_cash` (String décimal exact) et
  ///      `accounts.derived_cash_at` (epoch ms) — SOLDE ESPÈCES DÉRIVÉ des
  ///      comptes titres (`Σ amount` du journal, par devise du compte). Calqué
  ///      EXACTEMENT sur le pattern v5 (positions.derived_at) : additif,
  ///      NULLABLE, SANS backfill (comptes existants restent NULL = jamais
  ///      projetés), cache reconstructible EXCLU du pont backup. Colonne
  ///      DÉDIÉE — `cash_balance` (v1) reste réservée aux comptes `kind=cash`
  ///      (solde déclaratif manuel), jamais réutilisée pour le cash dérivé.
  /// v7 : ajout de la colonne `transactions.settlement_currency` (TEXT, devise
  ///      de RÈGLEMENT de `amount`, distincte de `currency` = cotation).
  ///      Additive, NULLABLE, SANS backfill : les lignes existantes restent NULL
  ///      = règlement identique à la cotation (comportement legacy). Corrige le
  ///      découplage cotation/règlement (design cash-ledger §8, option A) sans
  ///      aucune conversion de change (le taux est un fait figé dans `amount`).
  ///      Zéro perte de données.
  static const int _schemaVersion = 7;

  /// Définition de la colonne `accounts.kind`, partagée mot pour mot entre le
  /// CREATE TABLE (base fraîche, [_onCreate]) et l'ALTER TABLE ADD COLUMN
  /// (migration v2→v3, [_onUpgrade]) afin que les deux chemins convergent vers
  /// un schéma identique (risque R9). Le DEFAULT 'autre' initialise la colonne ;
  /// le backfill depuis `type` (métaux/cash) est fait juste après à l'upgrade.
  static const String _accountsKindColumn =
      "kind TEXT NOT NULL DEFAULT 'autre'";

  /// Définition de la colonne `positions.derived_at` (v5), partagée mot pour mot
  /// entre le CREATE TABLE (base fraîche, [_onCreate]) et l'ALTER TABLE ADD
  /// COLUMN (migration v4→v5, [_onUpgrade]) afin que les deux chemins convergent
  /// vers un schéma identique (contrat onCreate XOR onUpgrade, source DDL
  /// unique). derived_at = epoch ms du dernier recalcul de projection ; NULL =
  /// position legacy jamais projetée (quantité/PRU saisis à la main, à
  /// réconcilier). NULLABLE et SANS DEFAULT : distingue explicitement le legacy
  /// (NULL) d'une projection (horodatée).
  static const String _positionsDerivedAtColumn = "derived_at INTEGER";

  /// Définitions des colonnes `accounts.derived_cash` / `accounts.derived_cash_at`
  /// (v6), partagées mot pour mot entre le CREATE TABLE (base fraîche,
  /// [_onCreate]) et les ALTER TABLE ADD COLUMN (migration v5→v6, [_onUpgrade]) —
  /// source DDL unique, schémas convergents (contrat onCreate XOR onUpgrade).
  ///
  /// `derived_cash` = solde espèces DÉRIVÉ (`Σ amount` du journal, dans la devise
  /// du compte), stocké en TEXT décimal EXACT (comme `positions.quantity` /
  /// `transactions.amount` — jamais REAL, pour préserver la précision et éviter
  /// toute dérive binaire du cash). `derived_cash_at` = epoch ms du dernier
  /// recalcul ; NULL = compte jamais projeté (cash dérivé non calculé). Toutes
  /// deux NULLABLES et SANS DEFAULT (miroir de `positions.derived_at`).
  static const String _accountsDerivedCashColumn = "derived_cash TEXT";
  static const String _accountsDerivedCashAtColumn =
      "derived_cash_at INTEGER";

  /// Définition de la colonne `transactions.settlement_currency` (v7), partagée
  /// mot pour mot entre le CREATE TABLE (base fraîche, [_createTransactionsTable])
  /// et l'ALTER TABLE ADD COLUMN (migration v6→v7, [_onUpgrade]) — source DDL
  /// unique, schémas convergents (contrat onCreate XOR onUpgrade). Devise de
  /// RÈGLEMENT de `amount` (celle du COMPTE), distincte de `currency` (cotation).
  /// TEXT NULLABLE et SANS DEFAULT : NULL = règlement identique à la cotation
  /// (comportement legacy, rétro-compatible). Ne PAS confondre avec `currency`
  /// (NOT NULL, devise de cotation portant quantity/unit_price/fee).
  static const String _transactionsSettlementCurrencyColumn =
      "settlement_currency TEXT";

  final DatabaseFactory _factory;

  /// Chemin explicite (test) ; `null` = résolu à l'ouverture selon la
  /// plateforme par [_resolveDefaultPath] (production). Nullable et non plus
  /// figé au constructeur car la résolution desktop est asynchrone
  /// (`getApplicationSupportDirectory`) — un constructeur Dart ne peut pas
  /// awaiter.
  final String? _explicitPath;

  Database? _db;

  /// Construit une instance [AppDatabase].
  ///
  /// En production, omettre les deux paramètres : la factory et le chemin
  /// sont déterminés automatiquement selon la plateforme.
  ///
  /// En test, passer :
  ///   ```dart
  ///   AppDatabase(
  ///     factory: databaseFactoryFfi,
  ///     path: inMemoryDatabasePath,
  ///   )
  ///   ```
  AppDatabase({DatabaseFactory? factory, String? path})
      : _factory = factory ?? _defaultFactory(),
        _explicitPath = path;

  // ---------------------------------------------------------------------------
  // Singleton partagé de production (résolution du risque R6)
  // ---------------------------------------------------------------------------

  /// Unique instance partagée pour le chemin de production.
  ///
  /// R6 : les storages construits sans injection (`AppDatabase()` à chaque
  /// appel) créaient une nouvelle instance à chaque accès. Bien que sqflite
  /// partage la connexion native par chemin (`singleInstance: true`), un
  /// `close()` sur l'une invalidait la connexion des autres. On garantit ici
  /// qu'il n'existe qu'UNE instance/connexion en production.
  static AppDatabase? _shared;

  /// Retourne l'unique [AppDatabase] de production (mémoïsée statiquement).
  ///
  /// À utiliser comme fallback par défaut des storages en production. Les tests
  /// injectent leur propre [AppDatabase] in-memory et ne touchent JAMAIS ce
  /// singleton.
  factory AppDatabase.shared() => _shared ??= AppDatabase();

  /// Réinitialise le singleton partagé (réservé aux tests d'infrastructure qui
  /// auraient besoin de repartir d'un état propre). Ne ferme PAS la connexion.
  @visibleForTesting
  static void resetShared() {
    _shared = null;
  }

  // ---------------------------------------------------------------------------
  // Sélection de la factory selon la plateforme
  // ---------------------------------------------------------------------------

  static DatabaseFactory _defaultFactory() {
    if (kIsWeb) {
      throw UnsupportedError('AppDatabase : la plateforme web n\'est pas prise en charge.');
    }
    if (Platform.isAndroid || Platform.isIOS) {
      // Factory native sqflite — pas besoin d'initialisation ffi.
      return databaseFactory;
    }
    // Desktop : Linux, macOS, Windows.
    sqfliteFfiInit();
    return databaseFactoryFfi;
  }

  // ---------------------------------------------------------------------------
  // Résolution du chemin de la base selon la plateforme
  // ---------------------------------------------------------------------------

  /// Résout le chemin de base par défaut (production, aucun chemin injecté).
  ///
  /// Mobile (Android/iOS) : nom de fichier RELATIF, comportement HISTORIQUE
  /// inchangé — `databaseFactory` (sqflite natif) le résout lui-même dans le
  /// répertoire databases standard de l'app. Des utilisateurs Android réels
  /// existent déjà : ne PAS toucher ce chemin.
  ///
  /// Desktop (Linux/macOS/Windows) : chemin ABSOLU dans le répertoire de
  /// support applicatif (`getApplicationSupportDirectory`, ex. XDG_DATA_HOME
  /// sous Linux). `databaseFactoryFfi` n'a pas la même résolution que sqflite
  /// natif : un chemin relatif y est résolu sous
  /// `~/.dart_tool/sqflite_common_ffi/databases/` — hors des standards XDG,
  /// PARTAGÉ entre toutes les apps FFI de la machine (collision possible), et
  /// cassé sous sandbox Flatpak (répertoire non accessible). Le dossier est
  /// créé si absent (garantie explicite, `getApplicationSupportDirectory` le
  /// fait déjà en général mais `openDatabase` exige qu'il existe).
  static Future<String> _resolveDefaultPath() async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      return 'portfolio_tracker.db';
    }
    final supportDir = await getApplicationSupportDirectory();
    await Directory(supportDir.path).create(recursive: true);
    return p.join(supportDir.path, 'portfolio_tracker.db');
  }

  // ---------------------------------------------------------------------------
  // Accès à la base (ouverture lazy mémoïsée)
  // ---------------------------------------------------------------------------

  /// Ouvre la base au premier appel, puis retourne l'instance mise en cache.
  /// Aucune concurrence n'est gérée ici : le singleton applicatif garantit
  /// qu'un seul AppDatabase est instancié en production (risque R6).
  Future<Database> get database async {
    _db ??= await _openDatabase();
    return _db!;
  }

  Future<Database> _openDatabase() async {
    final path = _explicitPath ?? await _resolveDefaultPath();
    // singleInstance: false est indispensable pour les bases in-memory :
    // avec singleInstance: true (défaut), la factory FFI retourne la même
    // instance pour tout appel sur inMemoryDatabasePath, rendant deux
    // AppDatabase(path: inMemoryDatabasePath) non-isolés en test.
    // En production (chemin fichier), on garde singleInstance: true.
    final singleInstance = path != inMemoryDatabasePath;
    return _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        singleInstance: singleInstance,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Callbacks SQLite
  // ---------------------------------------------------------------------------

  /// Active les clés étrangères dès l'ouverture de la connexion.
  /// CRITIQUE : sans ce PRAGMA, les ON DELETE CASCADE sont silencieusement
  /// ignorés par SQLite (risque R4).
  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Crée le schéma v1 (5 tables).
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE wallets (
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    // La colonne kind (v3) est incluse ici pour les bases FRAÎCHES (ouvertes
    // directement en v3 → onCreate, jamais onUpgrade). Sa définition est
    // partagée avec l'ALTER de _onUpgrade via _accountsKindColumn (source
    // unique → schémas convergents, risque R9). `type` reste présente comme
    // miroir dérivé (écrite par le storage = kind.valuationType).
    await db.execute('''
      CREATE TABLE accounts (
        id           TEXT PRIMARY KEY,
        wallet_id    TEXT NOT NULL,
        name         TEXT NOT NULL,
        type         TEXT NOT NULL,
        currency     TEXT NOT NULL DEFAULT 'EUR',
        description  TEXT,
        created_at   TEXT,
        cash_balance REAL,
        $_accountsKindColumn,
        $_accountsDerivedCashColumn,
        $_accountsDerivedCashAtColumn,
        FOREIGN KEY (wallet_id) REFERENCES wallets(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_accounts_wallet_id ON accounts(wallet_id)',
    );

    // positions : PK composite (account_id, symbol).
    // quantity reste TEXT (String dans le modèle — risque R8 : ne pas convertir
    // en REAL pour préserver la précision et le round-trip).
    // asset_json contient le Asset.toJson() complet pour fidélité backup (I2).
    // lastUpdated n'est PAS persisté : absent de Position.toJson().
    await db.execute('''
      CREATE TABLE positions (
        account_id        TEXT NOT NULL,
        symbol            TEXT NOT NULL,
        quantity          TEXT NOT NULL,
        average_buy_price REAL,
        custom_name       TEXT,
        asset_json        TEXT NOT NULL,
        $_positionsDerivedAtColumn,
        PRIMARY KEY (account_id, symbol),
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
      )
    ''');

    // snapshots : PK composite (wallet_id, date).
    // date est 'YYYY-MM-DD' (String) ; captured_at est epoch ms (INTEGER).
    await db.execute('''
      CREATE TABLE snapshots (
        wallet_id      TEXT NOT NULL,
        date           TEXT NOT NULL,
        total_value    REAL NOT NULL,
        currency       TEXT NOT NULL,
        captured_at    INTEGER NOT NULL,
        account_count  INTEGER NOT NULL DEFAULT 0,
        schema_version INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (wallet_id, date),
        FOREIGN KEY (wallet_id) REFERENCES wallets(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_snapshots_wallet_date ON snapshots(wallet_id, date)',
    );

    // allocation_targets : UNE ligne par wallet.
    // target_json contient AllocationTarget.toJson() complet (risque R5 :
    // moving target absorbé par target_json — pas de colonnes par type).
    await db.execute('''
      CREATE TABLE allocation_targets (
        wallet_id   TEXT PRIMARY KEY,
        target_json TEXT NOT NULL,
        FOREIGN KEY (wallet_id) REFERENCES wallets(id) ON DELETE CASCADE
      )
    ''');

    // Table v2 (transactions) : sur une base FRAÎCHE ouverte en v2, sqflite
    // appelle onCreate (jamais onUpgrade). On crée donc ici aussi la table v2
    // via la MÊME méthode que onUpgrade — source de DDL unique, onCreate et
    // onUpgrade produisent un schéma final identique (risque R9).
    await _createTransactionsTable(db);
    // Colonne v7 (settlement_currency) : la DDL de _createTransactionsTable est
    // FIGÉE au schéma v2 (elle est rejouée telle quelle au palier v1→v2 de
    // _onUpgrade — un ADD COLUMN y suit) ; on ne peut donc PAS l'y intégrer sans
    // provoquer un « duplicate column » à l'upgrade. Le delta v7 est appliqué
    // ici, sur base fraîche, par le MÊME ALTER que _onUpgrade (même constante DDL
    // → schémas convergents, R9).
    await _addTransactionsSettlementCurrencyColumn(db);

    // Table v4 (last_known_quotes) : sur une base FRAÎCHE ouverte en v4,
    // sqflite appelle onCreate (jamais onUpgrade). Même source de DDL que
    // onUpgrade (risque R9).
    await _createLastPriceTable(db);
  }

  /// Migration de schéma incrémentale (paliers cumulatifs).
  ///
  /// sqflite garantit onCreate XOR onUpgrade : ce callback n'est JAMAIS invoqué
  /// pour une base fraîche (celle-ci passe par onCreate). Il est déclenché À
  /// L'OUVERTURE, avant tout accès applicatif à la connexion.
  ///
  /// Structure par paliers `if (oldVersion < N)` pour accueillir les futures
  /// migrations sans réécriture.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 → v2 : ajout de la table `transactions` (purement additif, aucune
      // table existante touchée → zéro risque de perte de données).
      await _createTransactionsTable(db);
    }
    if (oldVersion < 3) {
      // v2 → v3 : ajout de la colonne `accounts.kind` (nature du compte).
      // 1) ADD COLUMN avec DEFAULT NOT NULL → toutes les lignes existantes à
      //    'autre' sans réécrire la table (additif, zéro perte).
      await db.execute(
        'ALTER TABLE accounts ADD COLUMN $_accountsKindColumn',
      );
      // 2) Backfill depuis l'ancien `type` : les comptes non-titres reçoivent
      //    leur nature exacte ; les comptes d'investissement restent 'autre'
      //    (aucune enveloppe n'existait avant v3 → nature titres non précisée).
      await db.execute(
        "UPDATE accounts SET kind = CASE type "
        "WHEN 'cash' THEN 'cash' "
        "WHEN 'preciousMetal' THEN 'preciousMetal' "
        "ELSE 'autre' END",
      );
    }
    if (oldVersion < 4) {
      // v3 → v4 : ajout de la table `last_known_quotes` (cache dernier cours
      // connu). Purement additive, aucune table existante touchée.
      await _createLastPriceTable(db);
    }
    if (oldVersion < 5) {
      // v4 → v5 : colonne positions.derived_at (marqueur de projection B*).
      // Additive, NULLABLE, SANS backfill → positions existantes restent NULL =
      // legacy (q/PRU stockés préservés). Zéro perte de données.
      await db.execute('ALTER TABLE positions ADD COLUMN $_positionsDerivedAtColumn');
    }
    if (oldVersion < 6) {
      // v5 → v6 : colonnes accounts.derived_cash / derived_cash_at (solde
      // espèces dérivé du journal). Additives, NULLABLES, SANS backfill →
      // comptes existants restent NULL = jamais projetés (le solde dérivé sera
      // calculé à la prochaine mutation du journal ou reprojection explicite).
      // Zéro perte de données ; `cash_balance` (comptes kind=cash) intacte.
      await db.execute(
        'ALTER TABLE accounts ADD COLUMN $_accountsDerivedCashColumn',
      );
      await db.execute(
        'ALTER TABLE accounts ADD COLUMN $_accountsDerivedCashAtColumn',
      );
    }
    if (oldVersion < 7) {
      // v6 → v7 : colonne transactions.settlement_currency (devise de règlement
      // de `amount`, distincte de la cotation). Additive, NULLABLE, SANS
      // backfill → mouvements existants restent NULL = règlement identique à la
      // cotation (comportement legacy). Zéro perte de données ; corrige
      // l'étiquetage cotation/règlement (design cash-ledger §8) sans conversion.
      await _addTransactionsSettlementCurrencyColumn(db);
    }
    // Futurs paliers : if (oldVersion < 8) { ... }
  }

  /// DDL de la table `transactions` (v2) + ses deux index.
  ///
  /// SOURCE DE DDL UNIQUE partagée par onCreate (base fraîche v2) et onUpgrade
  /// (v1 → v2). Toute divergence de schéma entre les deux chemins est ainsi
  /// structurellement impossible (risque R9).
  ///
  /// `IF NOT EXISTS` (défensif, idempotent) : coût nul, protège contre un
  /// ré-entrant accidentel (ex. onUpgrade rejoué après un crash de migration
  /// partielle sur un futur palier).
  ///
  /// Montants (quantity, unit_price, amount, fee) en TEXT et NON en REAL :
  /// décision de précision assumée (cf. design §1.2). Cohérent avec
  /// positions.quantity ; préserve la sommation exacte du ledger et le
  /// round-trip. Ne PAS « harmoniser » ces colonnes en REAL.
  Future<void> _createTransactionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS transactions (
        id           TEXT PRIMARY KEY,
        account_id   TEXT NOT NULL,
        symbol       TEXT,
        kind         TEXT NOT NULL,
        quantity     TEXT,
        unit_price   TEXT,
        amount       TEXT,
        currency     TEXT NOT NULL,
        date         TEXT NOT NULL,
        fee          TEXT,
        note         TEXT,
        meta_json    TEXT,
        FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transactions_account_date '
      'ON transactions(account_id, date)',
    );

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_transactions_symbol_date '
      'ON transactions(symbol, date)',
    );
  }

  /// Ajoute la colonne `transactions.settlement_currency` (v7).
  ///
  /// SOURCE DE DDL UNIQUE partagée par onCreate (base fraîche, après la création
  /// v2 de la table) et onUpgrade (palier v6→v7) — même constante
  /// [_transactionsSettlementCurrencyColumn], schémas convergents (R9). N'est
  /// PAS intégrée à la DDL de [_createTransactionsTable] (figée au schéma v2,
  /// rejouée au palier v1→v2) : l'y mettre provoquerait un « duplicate column »
  /// lorsque ce même ALTER s'exécute ensuite au palier v6→v7.
  Future<void> _addTransactionsSettlementCurrencyColumn(Database db) async {
    await db.execute(
      'ALTER TABLE transactions ADD COLUMN '
      '$_transactionsSettlementCurrencyColumn',
    );
  }

  /// DDL de la table `last_known_quotes` (v4).
  ///
  /// SOURCE DE DDL UNIQUE partagée par onCreate (base fraîche v4) et onUpgrade
  /// (v3 → v4). `IF NOT EXISTS` : défensif, idempotent (risque R9).
  ///
  /// `symbol` est la clé du cache (le `quoteSymbol` brut transmis au
  /// [MarketDataProvider], ex. `GC=F` pour un métal). Montants (price, change,
  /// previous_close, change_percent) en TEXT — pas REAL (règle repo, cf.
  /// _createTransactionsTable). Pas de FK : ce cache est indépendant du cycle
  /// de vie des comptes/positions (un symbole peut rester en cache après
  /// suppression de la dernière position qui l'utilisait). `cached_at` est
  /// l'horodatage epoch-ms du dernier succès de cotation.
  Future<void> _createLastPriceTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS last_known_quotes (
        symbol          TEXT PRIMARY KEY,
        name            TEXT,
        price           TEXT,
        change          TEXT,
        change_percent  TEXT,
        previous_close  TEXT,
        currency        TEXT,
        exchange        TEXT,
        cached_at       INTEGER NOT NULL
      )
    ''');
  }

  // ---------------------------------------------------------------------------
  // Fermeture
  // ---------------------------------------------------------------------------

  /// Ferme la connexion et réinitialise le cache.
  /// Appeler en fin de test ou lors du dispose de l'application.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

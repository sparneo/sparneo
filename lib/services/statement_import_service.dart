// lib/services/statement_import_service.dart
//
// Service PUR de parsing + normalisation d'un relevé courtier : décodage
// bytes (CSV ou `.xlsx`, selon `BrokerProfile.format`) → lignes texte →
// mouvements normalisés. ZÉRO accès disque/base — ni lecture ni écriture. Le
// fichier (bytes) et le compte cible (devise) sont fournis par l'appelant ;
// toute résolution d'actif, déduplication contre le journal existant,
// projection et écriture appartiennent aux couches supérieures (contrôleur,
// LedgerService).
//
// PIÈGES DÉFENDUS EXPLICITEMENT (voir commentaires inline) :
//  - dates en LOCAL, jamais converties en UTC (un décalage de fuseau peut
//    faire basculer minuit sur le jour précédent et fausser l'ordre WAC) ;
//  - ordre de génération des id MONOTONE dans l'ordre chronologique du
//    relevé (détection du sens chrono/anti-chrono du fichier), pour que l'id
//    départage correctement les ex-æquo de date au rejeu du journal ;
//  - encodage/délimiteur/décimale paramétrables (Latin-1 + `;` + virgule
//    étant le triplet le plus fréquent des exports bancaires français) ;
//  - un libellé de nature d'opération non reconnu REJETTE la ligne — jamais
//    de coercition en `buy` ;
//  - lecture `.xlsx` : cellules numériques canonisées en décimale à point
//    SANS séparateur de milliers (une date stockée comme nombre, ex.
//    `20150127`, ressort telle quelle) — voir [_parseXlsx].

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:decimal/decimal.dart';
import 'package:xml/xml.dart';

import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';

/// Nature de mouvement selon la présence (ou non) d'une identité d'actif :
/// distingue les deux variantes possibles des kinds `openingBalance` et
/// `adjustment` (titre vs espèces — cf. `AssetTransaction`), et détermine
/// quels champs sont requis/attendus sur la ligne source.
enum _MovementShape {
  /// Champs titre : quantity/unitPrice(/fee), en devise de cotation.
  security,

  /// Champ cash : amount seul, en devise de règlement.
  cash,
}

/// Représentation intermédiaire d'une ligne de relevé après extraction des
/// colonnes mappées, AVANT résolution du kind / calcul du signe / génération
/// de l'id. Ne sort jamais de ce fichier.
class _RawRow {
  final int sourceIndex;
  final List<String> source;
  final String? dateRaw;
  final String? kindLabel;
  final String? isin;
  final String? symbol;
  final String? label;
  final String? quantityRaw;
  final String? unitPriceRaw;
  final String? feeRaw;
  final String? amountRaw;
  final String? currencyRaw;
  final String? taxRaw;
  final String? operationReference;
  final String? cashDirectionRaw; // sens ESPÈCES fiable (ex. SensEsp : D/C)
  final DateTime? date; // null si non parsable

  _RawRow({
    required this.sourceIndex,
    required this.source,
    required this.dateRaw,
    required this.kindLabel,
    required this.isin,
    required this.symbol,
    required this.label,
    required this.quantityRaw,
    required this.unitPriceRaw,
    required this.feeRaw,
    required this.amountRaw,
    required this.currencyRaw,
    required this.taxRaw,
    required this.operationReference,
    required this.cashDirectionRaw,
    required this.date,
  });
}

/// Résultat brut du parsing d'un relevé : lignes texte + numéro de ligne
/// PHYSIQUE (1-based) de chacune dans le fichier source, en liste PARALLÈLE à
/// [rows] (même longueur, même ordre).
///
/// - `.xlsx` : le numéro vient de l'attribut `r` de chaque `<row r="N">` —
///   EXACT, car les lignes vides absentes du XML créent naturellement les
///   trous correspondants (on obtient exactement le n° de ligne que voit
///   l'utilisateur dans le tableur).
/// - CSV : le numéro est l'index (1-based) de la ligne dans les lignes
///   décodées par le lecteur CSV — donc APPROCHÉ : si le décodeur élimine des
///   lignes vides, le repère peut être décalé (contrairement à l'xlsx, exact).
class ParsedStatement {
  /// Lignes de champs texte (déjà trimées), une entrée par ligne parsée.
  final List<List<String>> rows;

  /// Numéro de ligne PHYSIQUE 1-based de chaque entrée de [rows] dans le
  /// fichier source (liste parallèle, `sourceLines[i]` ↔ `rows[i]`).
  final List<int> sourceLines;

  const ParsedStatement(this.rows, this.sourceLines);

  static const ParsedStatement empty = ParsedStatement([], []);
}

/// Parsing + normalisation d'un relevé courtier en mouvements candidats.
///
/// Service PUR : aucune méthode ne touche au disque, à SQLite ni au réseau.
class StatementImportService {
  /// Décode les [bytes] d'un relevé (CSV ou `.xlsx`, selon
  /// [BrokerProfile.format]) et renvoie les lignes sous forme de
  /// `List<List<String>>` (une ligne = une liste de champs texte, déjà
  /// trimés) — même forme de sortie quel que soit le format d'entrée, pour
  /// que [normalize] reste identique dans les deux cas.
  ///
  /// Ne fait AUCUNE hypothèse sur la présence d'une ligne d'en-tête EN
  /// PREMIÈRE LIGNE — c'est [normalize] qui utilise [BrokerProfile.
  /// hasHeaderRow] pour la distinguer des lignes de données. Si le profil
  /// fournit [BrokerProfile.headerDetectionColumn] (cas d'un fichier précédé
  /// d'une ligne de titre, ex. Bourse Direct), les lignes qui précèdent la
  /// ligne d'en-tête détectée sont éliminées ici pour que la ligne 0 du
  /// résultat soit bien la ligne d'en-tête.
  ///
  /// Variante conservant le numéro de ligne physique du fichier source :
  /// [parseWithLineNumbers] (utilisée par le chemin réel d'import pour que
  /// l'aperçu affiche le n° de ligne exact du relevé). [parse] n'en renvoie
  /// que les [ParsedStatement.rows], pour les appelants qui n'ont besoin que
  /// des cellules.
  static List<List<String>> parse(Uint8List bytes, BrokerProfile profile) =>
      parseWithLineNumbers(bytes, profile).rows;

  /// Comme [parse], mais renvoie aussi le numéro de ligne PHYSIQUE 1-based de
  /// chaque ligne dans le fichier source (voir [ParsedStatement]). À passer à
  /// [normalize] via `sourceLines` pour que `ImportedMovement.sourceRowIndex`
  /// porte le vrai n° de ligne (et non un index de ligne de données).
  static ParsedStatement parseWithLineNumbers(
    Uint8List bytes,
    BrokerProfile profile,
  ) {
    final parsed = profile.format == StatementFileFormat.xlsx
        ? _parseXlsx(bytes)
        : _parseCsv(bytes, profile);
    return _applyHeaderDetection(parsed, profile);
  }

  static ParsedStatement _parseCsv(Uint8List bytes, BrokerProfile profile) {
    final String text;
    try {
      text = profile.encoding.decode(bytes);
    } on FormatException {
      // Mauvais encodage choisi (ex. UTF-8 sur un fichier Latin-1) : on
      // remonte une liste vide plutôt qu'une exception non gérée — c'est à
      // l'appelant (écran d'import) de proposer un autre encodage.
      return ParsedStatement.empty;
    }

    if (text.trim().isEmpty) return ParsedStatement.empty;

    final csv = Csv(
      fieldDelimiter: profile.delimiter,
      autoDetect: false,
      dynamicTyping: false,
    );

    final decoded = csv.decode(text);
    final rows = <List<String>>[];
    final sourceLines = <int>[];
    for (var i = 0; i < decoded.length; i++) {
      rows.add(
        decoded[i].map((field) => field?.toString().trim() ?? '').toList(),
      );
      // Repère PHYSIQUE approché : index (1-based) dans les lignes décodées.
      // Si le décodeur CSV a fusionné/éliminé des lignes vides, ce n° peut
      // différer du n° réel du fichier — contrairement au chemin xlsx, exact.
      sourceLines.add(i + 1);
    }
    return ParsedStatement(rows, sourceLines);
  }

  /// Élimine les lignes précédant la ligne d'en-tête réelle, quand
  /// [BrokerProfile.headerDetectionColumn] est renseigné (sinon no-op) — voir
  /// doc de [parse]. Tronque la liste parallèle [ParsedStatement.sourceLines]
  /// À L'IDENTIQUE pour préserver l'appariement ligne ↔ n° physique.
  static ParsedStatement _applyHeaderDetection(
    ParsedStatement parsed,
    BrokerProfile profile,
  ) {
    final rows = parsed.rows;
    final marker = profile.headerDetectionColumn;
    if (marker == null || rows.isEmpty) return parsed;

    final needle = marker.trim().toLowerCase();
    final headerIndex = rows.indexWhere(
      (row) => row.any((cell) => cell.trim().toLowerCase() == needle),
    );
    if (headerIndex <= 0) return parsed;
    return ParsedStatement(
      rows.sublist(headerIndex),
      parsed.sourceLines.sublist(headerIndex),
    );
  }

  // ---------------------------------------------------------------------
  // Lecture .xlsx — extraction ZIP + XML minimale (PAS de dépendance à un
  // package de haut niveau : `excel`/`spreadsheet_decoder` ciblent encore des
  // versions d'`archive`/`xml` antérieures à celles déjà résolues dans ce
  // projet — cf. rapport de livraison). Ne lit QUE la première feuille
  // (`xl/worksheets/sheet1.xml`) : un relevé de courtier n'en a jamais qu'une.
  // ---------------------------------------------------------------------

  /// Lit les [bytes] d'un classeur `.xlsx` et renvoie ses lignes sous forme
  /// canonique `List<List<String>>` : les cellules numériques sont
  /// restituées en notation DÉCIMALE À POINT sans séparateur de milliers, et
  /// sans décimales superflues (une cellule entière `20150127` ressort
  /// `"20150127"`, pas `"20150127.0"`) — les cellules texte/date-texte sont
  /// restituées telles quelles. Renvoie une liste vide si le fichier est
  /// illisible (mauvais format, archive corrompue).
  static ParsedStatement _parseXlsx(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return ParsedStatement.empty;
    }

    final sharedStrings = _readSharedStrings(archive);
    final sheetEntry = _firstWorksheetEntry(archive);
    if (sheetEntry == null) return ParsedStatement.empty;

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(sheetEntry.content));
    } catch (_) {
      return ParsedStatement.empty;
    }

    final rows = <List<String>>[];
    final sourceLines = <int>[];
    for (final rowEl in doc.findAllElements('row')) {
      final cells = <int, String>{};
      var maxCol = -1;
      for (final cellEl in rowEl.findElements('c')) {
        final ref = cellEl.getAttribute('r') ?? '';
        final colIndex = _columnLetterToIndex(ref);
        if (colIndex < 0) continue;
        cells[colIndex] = _cellValue(cellEl, sharedStrings);
        if (colIndex > maxCol) maxCol = colIndex;
      }
      rows.add(List<String>.generate(maxCol + 1, (i) => cells[i] ?? ''));
      // Numéro de ligne PHYSIQUE du tableur : attribut `r` de `<row>` — les
      // lignes vides (absentes du XML) créent les trous correspondants, donc
      // ce n° est EXACTEMENT celui affiché par le tableur. Repli sur la
      // position 1-based si `r` manque (fichier non conforme).
      final rAttr = rowEl.getAttribute('r');
      sourceLines.add((rAttr != null ? int.tryParse(rAttr) : null) ?? rows.length);
    }
    return ParsedStatement(rows, sourceLines);
  }

  /// Trouve la première feuille de calcul (`xl/worksheets/sheetN.xml`, la
  /// plus petite valeur de N — c'est `sheet1.xml` pour un classeur mono-
  /// feuille, cas de tout relevé de courtier).
  static ArchiveFile? _firstWorksheetEntry(Archive archive) {
    final sheetPattern = RegExp(r'xl/worksheets/sheet(\d+)\.xml$');
    ArchiveFile? best;
    var bestN = 1 << 30;
    for (final file in archive.files) {
      final match = sheetPattern.firstMatch(file.name);
      if (match == null) continue;
      final n = int.parse(match.group(1)!);
      if (n < bestN) {
        bestN = n;
        best = file;
      }
    }
    return best;
  }

  /// Table des chaînes partagées (`xl/sharedStrings.xml`), référencées par
  /// index depuis les cellules de type `t="s"`. Liste vide si le classeur
  /// n'en a pas (aucune cellule texte, ou toutes en `inlineStr`).
  static List<String> _readSharedStrings(Archive archive) {
    final entry = archive.findFile('xl/sharedStrings.xml');
    if (entry == null) return const [];
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(entry.content));
    } catch (_) {
      return const [];
    }
    return doc
        .findAllElements('si')
        .map((si) => si.findElements('t').map((t) => t.innerText).join())
        .toList();
  }

  /// Valeur texte canonique d'une cellule `<c>` (voir doc de [_parseXlsx]).
  static String _cellValue(XmlElement cellEl, List<String> sharedStrings) {
    final type = cellEl.getAttribute('t');
    if (type == 's') {
      final idxText = _firstChild(cellEl.findElements('v'))?.innerText;
      final idx = idxText != null ? int.tryParse(idxText) : null;
      if (idx == null || idx < 0 || idx >= sharedStrings.length) return '';
      return sharedStrings[idx];
    }
    if (type == 'inlineStr') {
      final isEl = _firstChild(cellEl.findElements('is'));
      if (isEl == null) return '';
      return isEl.findElements('t').map((t) => t.innerText).join();
    }
    final raw = _firstChild(cellEl.findElements('v'))?.innerText;
    if (raw == null || raw.isEmpty) return '';
    if (type == 'str' || type == 'b' || type == 'e') return raw;
    // Numérique (type == 'n' ou absent, cas par défaut du format xlsx).
    final d = double.tryParse(raw);
    return d == null ? raw : _formatCanonicalNumber(d);
  }

  /// Premier élément d'un itérable, ou `null` s'il est vide (évite une
  /// dépendance à `package:collection` pour ce seul besoin).
  static XmlElement? _firstChild(Iterable<XmlElement> elements) {
    final it = elements.iterator;
    return it.moveNext() ? it.current : null;
  }

  /// Formate un `double` en notation décimale à point, sans séparateur de
  /// milliers ni décimales superflues (`20150127.0` → `"20150127"`,
  /// `100.500000` → `"100.5"`), jusqu'à 6 décimales.
  static String _formatCanonicalNumber(double d) {
    if (d.isNaN || d.isInfinite) return '';
    if (d == d.truncateToDouble() && d.abs() < 1e15) {
      return d.truncate().toString();
    }
    var s = d.toStringAsFixed(6);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Index de colonne 0-based (A=0, Z=25, AA=26…) déduit d'une référence de
  /// cellule Excel (ex. `"C5"` → 2). `-1` si la référence est illisible.
  static int _columnLetterToIndex(String cellRef) {
    var index = 0;
    var found = false;
    for (final code in cellRef.codeUnits) {
      if (code >= 65 && code <= 90) {
        // A-Z
        index = index * 26 + (code - 64);
        found = true;
      } else if (code >= 97 && code <= 122) {
        // a-z (tolérance, non standard mais inoffensif)
        index = index * 26 + (code - 96);
        found = true;
      } else {
        break;
      }
    }
    return found ? index - 1 : -1;
  }

  /// Normalise les [rows] parsées (voir [parse]) en une liste de
  /// [ImportedMovement], candidats ou rejets.
  ///
  /// [accountCurrency] est la devise de RÈGLEMENT (celle du compte cible) —
  /// MVP mono-devise : `settlementCurrency` vaut toujours [accountCurrency].
  /// [accountId] est optionnel (`''` par défaut) : cette couche pure ne
  /// connaît pas encore le compte cible (choix laissé au contrôleur qui
  /// pilote l'import) ; l'appelant peut néanmoins le
  /// fournir dès qu'il est connu, ce qui alimente `AssetTransaction.accountId`
  /// ET la clé de dédup. Si omis, le contrôleur doit `copyWith(accountId:
  /// ...)` chaque transaction avant écriture — la clé de dédup reste valable
  /// car la comparaison aux doublons se fait de toute façon PAR COMPTE
  /// (journal déjà filtré par `accountId`), donc l'absence d'`accountId` dans
  /// le hash ne crée pas de collision exploitable.
  static List<ImportedMovement> normalize(
    List<List<String>> rows,
    BrokerProfile profile, {
    required String accountCurrency,
    String accountId = '',
    List<int>? sourceLines,
  }) {
    if (rows.isEmpty) return const [];

    final header = profile.hasHeaderRow && rows.isNotEmpty ? rows.first : null;
    final headerOffset = profile.hasHeaderRow ? 1 : 0;
    final dataRows = profile.hasHeaderRow ? rows.skip(1).toList() : rows;
    final columnIndex = _resolveColumnIndices(profile, header);

    // Numéro de ligne source à porter par chaque ligne de DONNÉES :
    //  - [sourceLines] fourni (chemin réel `parseWithLineNumbers`→`normalize`) :
    //    n° de ligne PHYSIQUE 1-based du fichier, décalé du saut d'en-tête ;
    //  - absent (appels directs de test avec `List<List<String>>`) : on
    //    conserve l'ancien comportement `sourceIndex = i` (index de ligne de
    //    données 0-based), aucune régression pour ces appelants.
    int sourceLineFor(int dataRowIdx) {
      if (sourceLines == null) return dataRowIdx;
      final absIdx = dataRowIdx + headerOffset;
      return absIdx >= 0 && absIdx < sourceLines.length
          ? sourceLines[absIdx]
          : dataRowIdx;
    }

    // ---- Étape 1 : extraction brute des colonnes mappées + parsing date ----
    final raw = <_RawRow>[];
    for (var i = 0; i < dataRows.length; i++) {
      final row = dataRows[i];
      // Ligne INTÉGRALEMENT VIDE (aucune cellule non blanche) : ignorée
      // SILENCIEUSEMENT, jamais rejetée. Une ligne vide présente dans le fichier
      // (séparateur xlsx, ligne blanche du relevé) ne doit pas polluer la liste
      // des rejets avec un faux « type d'opération manquant ». La numérotation
      // de ligne source n'est pas affectée (indexée par la position d'origine).
      if (row.every((c) => c.trim().isEmpty)) continue;
      final dateRaw = _field(row, columnIndex, MovementField.date);
      raw.add(_RawRow(
        sourceIndex: sourceLineFor(i),
        source: row,
        dateRaw: dateRaw,
        kindLabel: _field(row, columnIndex, MovementField.kindLabel),
        isin: _field(row, columnIndex, MovementField.isin),
        symbol: _field(row, columnIndex, MovementField.symbol),
        label: _field(row, columnIndex, MovementField.label),
        quantityRaw: _field(row, columnIndex, MovementField.quantity),
        unitPriceRaw: _field(row, columnIndex, MovementField.unitPrice),
        feeRaw: _field(row, columnIndex, MovementField.fee),
        amountRaw: _field(row, columnIndex, MovementField.amount),
        currencyRaw: _field(row, columnIndex, MovementField.currency),
        taxRaw: _field(row, columnIndex, MovementField.tax),
        operationReference:
            _field(row, columnIndex, MovementField.operationReference),
        cashDirectionRaw: _field(row, columnIndex, MovementField.cashDirection),
        date: _parseDate(dateRaw, profile.dateFormat),
      ));
    }

    // ---- Étape 1bis : ISIN porteurs d'un DROIT DE SOUSCRIPTION ----
    // Un ISIN portant AU MOINS une ligne dont le CODE est mappé sur
    // CorporateActionKind.manualReview (détachement de droit `DS`) EST un droit
    // de souscription. Marqueur FIABLE, indépendant de tout tri, pour reclasser
    // plus bas la (les) ligne(s) d'exercice de ce MÊME ISIN (`SOUSC` → buy) en
    // SORTIE de titres — cf. _normalizeRow.
    final rightsIsins = <String>{};
    for (final r in raw) {
      if (r.isin != null &&
          r.kindLabel != null &&
          profile.corporateActions[r.kindLabel] ==
              CorporateActionKind.manualReview) {
        rightsIsins.add(r.isin!);
      }
    }

    // ---- Étape 2 : détection du sens chronologique du relevé ----
    // Compare la première et la dernière date PARSABLE dans l'ordre du
    // fichier. Un relevé anti-chronologique (le plus récent en premier, cas
    // fréquent des exports d'opérations) doit être rejoué à l'envers pour que
    // les id générés croissent avec le temps (départage des ex-æquo de date
    // par `replayLedger`, qui trie sur `(date, id)`).
    final processingOrder = _chronologicalOrder(raw);

    // ---- Étape 3 : normalisation ligne par ligne dans l'ordre chronologique ----
    // Compte les occurrences d'une même « signature de contenu » pour
    // attribuer un ordinal stable aux doublons intra-fichier : deux lignes
    // réellement identiques le même jour ne doivent PAS s'écraser mutuellement.
    final contentOccurrences = <String, int>{};
    final result = <ImportedMovement>[];

    // [seq] : séquence MONOTONE dans l'ordre CHRONOLOGIQUE de traitement (=
    // ordre du fichier, le relevé étant ascendant strict). Posée dans
    // `meta['seq']` de chaque candidat, elle départage les mouvements de MÊME
    // DATE au rejeu du journal — à la place de l'id (aléatoire à l'import), dont
    // l'ordre intraday arbitraire faisait disparaître des titres sur les
    // allers-retours d'un même jour (clamp anti-survente). Incrémentée pour
    // TOUTE ligne traitée (rejets inclus) : seule la monotonie compte, les
    // trous sont sans effet.
    var seq = 0;
    for (final r in processingOrder) {
      result.add(_normalizeRow(
        r,
        profile,
        accountCurrency: accountCurrency,
        accountId: accountId,
        contentOccurrences: contentOccurrences,
        seq: seq,
        rightsIsins: rightsIsins,
      ));
      seq++;
    }

    // ---- Étape 4 : fusion des JAMBES DE RÈGLEMENT scindées ----
    // Passe INTER-LIGNES, donc APRÈS la normalisation ligne à ligne (le
    // traitement par ligne n'a aucune visibilité sur ses voisines). Ne touche
    // QUE les paires reconnues sans ambiguïté — cf. [_mergeSplitSettlementLegs].
    return _mergeSplitSettlementLegs(result);
  }

  // ---------------------------------------------------------------------
  // Fusion des JAMBES DE RÈGLEMENT scindées (passe INTER-LIGNES)
  // ---------------------------------------------------------------------

  /// Replie sur son opération de titre la jambe ESPÈCES d'une opération que le
  /// relevé a scindée en DEUX lignes, puis supprime cette jambe.
  ///
  /// CAS RÉEL (exercice de droits, Bourse Direct) : `SOUSC` 356 × `<ISIN>` à
  /// 0,22 € avec `Net = 0` (aucune contrepartie espèces sur la ligne), suivi le
  /// MÊME JOUR d'un `ODOST` (→ `adjustment` ESPÈCES) de −78,32 € portant le
  /// MÊME ISIN. Économiquement : UNE opération, 78,32 € payés pour 356 titres.
  ///
  /// POURQUOI FUSIONNER — les deux lignes tombent de part et d'autre de la
  /// partition stricte des champs (cf. en-tête de `position_projection.dart`) :
  /// le moteur TITRE inscrit 78,32 € de base de coût depuis la ligne d'achat,
  /// pendant que le moteur ESPÈCES lit un `adjustment` à `symbol == null`,
  /// c'est-à-dire un FLUX EXTERNE de capital (cf. `buildExternalFlowsCurve`,
  /// brique (a)) alors qu'il ne s'agit que du TRANSFERT INTERNE trésorerie →
  /// titre d'un achat (dont la jambe cash est justement neutralisée, brique
  /// (b)). Le même euro est donc compté deux fois et l'invariant « Valeur −
  /// Capital investi == gain total » dérive du montant réglé. Recollées, les
  /// deux lignes redeviennent l'opération unique qu'elles décrivent.
  ///
  /// CONDITIONS (TOUTES requises ; au moindre doute on ne fusionne PAS et les
  /// deux lignes ressortent STRICTEMENT inchangées) :
  ///  - la jambe est un `adjustment` ESPÈCES (`symbol == null`) portant un ISIN
  ///    de RÉFÉRENCE, un `amount` non nul, et AUCUNE quantité exploitable —
  ///    seule forme produite par [CorporateActionKind.cashRegularization] ;
  ///    un `adjustment` espèces PUR (sans ISIN) n'est JAMAIS candidat, et un
  ///    `adjustment` TITRE porte une quantité et `amount == null` ;
  ///  - l'accueil est un `buy`/`sell` du MÊME compte, du MÊME jour, sur le MÊME
  ///    ISIN, dont la contrepartie espèces est ABSENTE ou NUMÉRIQUEMENT NULLE —
  ///    c'est ce qui signe la jambe manquante. Une opération déjà réglée (Net
  ///    fourni, ou montant dérivé de quantité×cours faute de colonne Net) n'est
  ///    JAMAIS touchée ;
  ///  - appariement 1-1 STRICT : la jambe ne doit voir qu'UN accueil possible,
  ///    et cet accueil qu'UNE jambe. Toute pluralité (deux achats du même titre
  ///    le même jour, deux régularisations pour un achat) = ambiguïté = abandon.
  ///    L'unicité est évaluée AVANT le contrôle de signe, pour qu'une jambe de
  ///    signe contraire compte quand même comme une ambiguïté (elle bloque, au
  ///    lieu de laisser fusionner l'autre) ;
  ///  - cohérence de SIGNE : montant négatif pour un `buy`, positif pour un
  ///    `sell`. Un signe contraire décrit autre chose qu'un règlement (crédit
  ///    d'OST, remboursement) : on s'abstient.
  ///
  /// CLÉ DE DÉDUP (décision explicite) : l'`importKey` de l'accueil est
  /// CONSERVÉE TELLE QUELLE, c'est-à-dire calculée AVANT le repli (donc sur un
  /// `amount` de 0). Le hash de contenu n'est qu'un jeton OPAQUE de
  /// déduplication : personne ne le recalcule à partir d'un mouvement du
  /// journal (il n'est que comparé à `meta['importKey']` des mouvements déjà
  /// journalisés, cf. `AccountController.previewStatementImport`). Le figer
  /// donne l'idempotence LA PLUS LARGE : ré-importer le même relevé retrouve la
  /// même clé, y compris sur un journal alimenté AVANT ce correctif (où
  /// l'accueil avait été journalisé avec `amount = 0`) — cas dans lequel une
  /// clé recalculée aurait présenté l'achat comme un mouvement NEUF et aurait
  /// donc laissé l'utilisateur créer un TROISIÈME mouvement par-dessus la paire
  /// déjà fausse. La jambe supprimée emporte sa propre clé : si elle avait été
  /// journalisée avant le correctif, elle reste en base (le ré-import ne la
  /// propose plus, il ne la supprime pas non plus — la réparation d'un journal
  /// antérieur reste MANUELLE).
  ///
  /// ORDRE / `seq` : aucune renumérotation. La liste conserve son ordre
  /// chronologique de traitement, les `meta['seq']` déjà posés restent
  /// STRICTEMENT CROISSANTS (la suppression ne fait qu'un trou, explicitement
  /// sans effet — cf. étape 3) et les id générés ne sont pas régénérés.
  static List<ImportedMovement> _mergeSplitSettlementLegs(
    List<ImportedMovement> movements,
  ) {
    // Indices des deux rôles. Rôles DISJOINTS par construction (une jambe est
    // un `adjustment`, un accueil un `buy`/`sell`).
    final legs = <int>[];
    final hosts = <int>[];
    for (var i = 0; i < movements.length; i++) {
      if (movements[i].transaction == null) continue; // rejet : jamais touché
      if (_isSplitCashLeg(movements[i])) legs.add(i);
      if (_isUnsettledTrade(movements[i])) hosts.add(i);
    }
    if (legs.isEmpty || hosts.isEmpty) return movements;

    // Appariement structurel (compte + ISIN + jour), SANS contrôle de signe :
    // celui-ci est un VETO appliqué après, pour qu'une jambe inattendue reste
    // une ambiguïté bloquante plutôt qu'un candidat silencieusement écarté.
    final hostsOfLeg = <int, List<int>>{};
    final legsOfHost = <int, List<int>>{};
    for (final l in legs) {
      for (final h in hosts) {
        if (!_pairsWith(movements[l], movements[h])) continue;
        (hostsOfLeg[l] ??= <int>[]).add(h);
        (legsOfHost[h] ??= <int>[]).add(l);
      }
    }

    final foldedAmountByHost = <int, String>{};
    // Ligne SOURCE (1-based) de la jambe absorbée, par accueil : trace remontée
    // dans meta puis affichée à l'aperçu, pour que le repli ne fasse pas
    // disparaître une ligne du relevé sans laisser d'accroche (cf. §14.8).
    final foldedLegRowByHost = <int, int>{};
    final droppedLegs = <int>{};
    for (final entry in hostsOfLeg.entries) {
      if (entry.value.length != 1) continue; // plusieurs accueils possibles
      final h = entry.value.single;
      if (legsOfHost[h]!.length != 1) continue; // plusieurs jambes possibles
      final amount = Decimal.parse(movements[entry.key].transaction!.amount!);
      final expectsDebit =
          movements[h].transaction!.kind == TransactionKind.buy;
      if ((amount.sign < 0) != expectsDebit) continue; // signe incohérent
      foldedAmountByHost[h] = amount.toString();
      foldedLegRowByHost[h] = movements[entry.key].sourceRowIndex;
      droppedLegs.add(entry.key);
    }
    if (droppedLegs.isEmpty) return movements;

    final merged = <ImportedMovement>[];
    for (var i = 0; i < movements.length; i++) {
      if (droppedLegs.contains(i)) continue;
      final folded = foldedAmountByHost[i];
      final m = movements[i];
      if (folded == null) {
        merged.add(m);
        continue;
      }
      // Le montant est REPLIÉ TEL QUEL (aucune arithmétique : la contrepartie
      // de l'accueil était nulle, et `amount` inclut déjà frais et taxes par
      // convention du modèle). meta (dont `seq` et `importKey`) est conservé
      // par `copyWith`, et l'id n'est pas régénéré.
      //
      // TRAÇABILITÉ (§14.8) : on marque la transaction d'accueil pour que le
      // repli soit VISIBLE — à l'aperçu (le mouvement absorbé disparaît de la
      // liste) et, persisté dans `meta_json`, comme accroche à une éventuelle
      // migration réparatrice sur les imports déjà passés. `mergedSettlementLeg`
      // = le fait, `mergedLegSourceRow` = la ligne du relevé absorbée.
      final mergedMeta = <String, dynamic>{
        ...?m.transaction!.meta,
        'mergedSettlementLeg': true,
        'mergedLegSourceRow': foldedLegRowByHost[i],
      };
      merged.add(ImportedMovement.candidate(
        sourceRow: m.sourceRow,
        sourceRowIndex: m.sourceRowIndex,
        transaction: m.transaction!.copyWith(amount: folded, meta: mergedMeta),
        isin: m.isin,
        label: m.label,
        needsAssetResolution: m.needsAssetResolution,
        resolvedSymbol: m.resolvedSymbol,
        importKey: m.importKey!,
      ));
    }
    return merged;
  }

  /// `true` si [m] est une JAMBE ESPÈCES candidate au repli : `adjustment`
  /// ESPÈCES (`symbol == null` — la position n'est jamais touchée) portant un
  /// ISIN de RÉFÉRENCE, un `amount` NON NUL, et aucune quantité exploitable.
  /// C'est exactement la forme produite par
  /// [CorporateActionKind.cashRegularization] ; un `adjustment` TITRE (qui
  /// porte une quantité et `amount == null`) et un `adjustment` espèces PUR
  /// (sans ISIN) sont tous deux exclus.
  static bool _isSplitCashLeg(ImportedMovement m) {
    final tx = m.transaction!;
    if (tx.kind != TransactionKind.adjustment) return false;
    if (tx.symbol != null) return false;
    if (m.isin == null) return false;
    final amount = tx.amount != null ? Decimal.tryParse(tx.amount!) : null;
    if (amount == null || amount.sign == 0) return false;
    final quantity =
        tx.quantity != null ? Decimal.tryParse(tx.quantity!) : null;
    if (quantity != null && quantity.sign != 0) return false;
    return true;
  }

  /// `true` si [m] est une opération de marché dont la CONTREPARTIE ESPÈCES
  /// est absente ou numériquement nulle — la signature d'une jambe de règlement
  /// portée par une autre ligne. Un `buy`/`sell` dont le relevé ne mappe aucun
  /// Net porte un montant DÉRIVÉ (quantité×cours±frais), donc non nul : il
  /// n'est jamais candidat (cf. [_normalizeRow]).
  static bool _isUnsettledTrade(ImportedMovement m) {
    final tx = m.transaction!;
    if (tx.kind != TransactionKind.buy && tx.kind != TransactionKind.sell) {
      return false;
    }
    if (m.isin == null) return false;
    if (tx.amount == null) return true;
    final amount = Decimal.tryParse(tx.amount!);
    return amount != null && amount.sign == 0;
  }

  /// `true` si la jambe [leg] et l'accueil [host] décrivent la même opération :
  /// MÊME compte, MÊME ISIN, MÊME JOUR. Le libellé est délibérément EXCLU du
  /// rapprochement (texte libre : « Espèces sur OST » ne ressemble pas au nom
  /// de la valeur, et un libellé générique apparierait n'importe quoi) — seul
  /// l'ISIN identifie l'actif de façon fiable.
  static bool _pairsWith(ImportedMovement leg, ImportedMovement host) {
    final a = leg.transaction!;
    final b = host.transaction!;
    return a.accountId == b.accountId &&
        leg.isin == host.isin &&
        a.date.year == b.date.year &&
        a.date.month == b.date.month &&
        a.date.day == b.date.day;
  }

  // ---------------------------------------------------------------------
  // Résolution des colonnes
  // ---------------------------------------------------------------------

  static Map<MovementField, int> _resolveColumnIndices(
    BrokerProfile profile,
    List<String>? header,
  ) {
    final resolved = <MovementField, int>{};

    // Mapping par NOM résolu en premier (si un en-tête est disponible) ...
    if (header != null) {
      for (final entry in profile.columns.byName.entries) {
        final idx = header.indexWhere(
          (h) => h.trim().toLowerCase() == entry.value.trim().toLowerCase(),
        );
        if (idx != -1) resolved[entry.key] = idx;
      }
    }
    // ... puis le mapping par INDEX, prioritaire (choix explicite de
    // l'utilisateur dans le profil générique manuel).
    resolved.addAll(profile.columns.byIndex);

    return resolved;
  }

  static String? _field(
    List<String> row,
    Map<MovementField, int> columnIndex,
    MovementField field,
  ) {
    final idx = columnIndex[field];
    if (idx == null || idx < 0 || idx >= row.length) return null;
    final value = row[idx].trim();
    return value.isEmpty ? null : value;
  }

  // ---------------------------------------------------------------------
  // Dates — parsing STRICTEMENT local
  // ---------------------------------------------------------------------

  /// Parse une date selon [spec], en LOCAL (jamais de conversion UTC — un
  /// décalage de fuseau ferait basculer minuit sur le jour précédent et
  /// fausserait l'ordre WAC des mouvements intra-journée). `null` si la
  /// chaîne est absente ou mal formée.
  static DateTime? _parseDate(String? raw, DateFormatSpec spec) {
    if (raw == null) return null;

    // Certains relevés accolent une HEURE à la date (« 29/06/2026 00:00 »,
    // export Fortuneo). Seul le JOUR nous intéresse (le modèle date les
    // mouvements à la journée, l'ordre intraday venant de `meta.seq`), donc la
    // partie horaire est retirée AVANT tout découpage — sinon le dernier champ
    // (« 2026 00:00 ») n'est plus un entier et la ligne partait en rejet
    // `invalidDate`.
    final value = _stripTimeComponent(raw);

    int day, month, year;
    if (spec.compactYmd) {
      // Format compact `AAAAMMJJ` (ex. `20150127`), sans séparateur — export
      // Bourse Direct. Peut arriver stocké comme nombre (donc déjà
      // canonisé sans point ni zéro superflu par `_parseXlsx`) ou en texte.
      final digits = value;
      if (digits.length != 8) return null;
      final y = int.tryParse(digits.substring(0, 4));
      final m = int.tryParse(digits.substring(4, 6));
      final d = int.tryParse(digits.substring(6, 8));
      if (y == null || m == null || d == null) return null;
      year = y;
      month = m;
      day = d;
    } else {
      final parts = value.split(spec.separator);
      if (parts.length != 3) return null;

      final a = int.tryParse(parts[0]);
      final b = int.tryParse(parts[1]);
      var y = int.tryParse(parts[2]);
      if (a == null || b == null || y == null) return null;

      day = spec.dayFirst ? a : b;
      month = spec.dayFirst ? b : a;
      if (!spec.fourDigitYear && y < 100) y += 2000;
      year = y;
    }

    if (month < 1 || month > 12 || day < 1 || day > 31) return null;

    final date = DateTime(year, month, day);
    // Rejette une date « corrigée » silencieusement par DateTime (ex. 31/02
    // devenant le 3 mars) : mieux vaut un rejet explicite qu'une date fausse.
    if (date.year != year || date.month != month || date.day != day) {
      return null;
    }
    return date;
  }

  /// Heure accolée à une date : espace (ou `T` ISO) suivi de `HH:MM`(`:SS`)
  /// éventuellement décimal, d'un `AM`/`PM`, et/ou d'un fuseau (`Z`, `+02:00`).
  /// Ancrée en FIN de chaîne pour ne jamais amputer une date : sans heure
  /// reconnaissable derrière, rien n'est retiré (une chaîne douteuse continue
  /// d'être rejetée par le parsing au lieu d'être tronquée en silence).
  static final RegExp _timeSuffix = RegExp(
    r'[\sT]+\d{1,2}[:hH]\d{2}(?::\d{2})?(?:[.,]\d+)?\s*'
    r'(?:[AaPp]\.?[Mm]\.?)?\s*(?:Z|[+-]\d{2}:?\d{2})?$',
  );

  /// Retire l'éventuelle partie horaire d'une date de relevé (cf. [_parseDate])
  /// et trime le résultat. Le séparateur de date ne pouvant jamais être un
  /// espace ni un `T` (cf. `DateFormatSpec`), la découpe est sans ambiguïté.
  static String _stripTimeComponent(String raw) =>
      raw.trim().replaceFirst(_timeSuffix, '').trim();

  /// Détermine l'ordre de traitement (chronologique croissant) des lignes.
  ///
  /// Compare la première et la dernière date parsable dans l'ordre du
  /// fichier : si la dernière est strictement antérieure à la première, le
  /// relevé est considéré anti-chronologique (le plus récent en tête) et
  /// l'ordre de traitement est inversé. Sans au moins deux dates parsables,
  /// on conserve l'ordre du fichier (rien à détecter).
  static List<_RawRow> _chronologicalOrder(List<_RawRow> raw) {
    final dated = raw.where((r) => r.date != null).toList();
    if (dated.length < 2) return raw;

    final first = dated.first.date!;
    final last = dated.last.date!;
    final isAntiChronological = last.isBefore(first);

    return isAntiChronological ? raw.reversed.toList() : raw;
  }

  // ---------------------------------------------------------------------
  // Normalisation d'une ligne
  // ---------------------------------------------------------------------

  static ImportedMovement _normalizeRow(
    _RawRow r,
    BrokerProfile profile, {
    required String accountCurrency,
    required String accountId,
    required Map<String, int> contentOccurrences,
    required int seq,
    required Set<String> rightsIsins,
  }) {
    ImportedMovement reject(String reason) => ImportedMovement.rejected(
          sourceRow: r.source,
          sourceRowIndex: r.sourceIndex,
          rejectReason: reason,
          isin: r.isin,
          label: r.label,
        );

    if (r.kindLabel == null) return reject('missingKind');

    // OPÉRATIONS SUR TITRES (corporate actions) : traitées selon leur EFFET
    // (cf. CorporateActionKind), PRIORITAIREMENT au lexique simple. Le sens
    // (entrée/sortie de titres) est déduit du CODE, jamais des colonnes de sens.
    final ca = profile.corporateActions[r.kindLabel];
    if (ca != null) {
      if (r.date == null) return reject('invalidDate');
      return _normalizeCorporateAction(
        r,
        profile,
        ca,
        accountCurrency: accountCurrency,
        accountId: accountId,
        contentOccurrences: contentOccurrences,
        seq: seq,
      );
    }

    final kind = profile.kindLexicon[r.kindLabel];
    // Libellé non reconnu : REJET, jamais de coercition en `buy` (cohérent
    // avec `TransactionKind.tryFromWire`, politique stricte du modèle).
    if (kind == null) return reject('unknownKind');

    if (r.date == null) return reject('invalidDate');

    // DROIT DE SOUSCRIPTION — reclassement de la ligne d'EXERCICE.
    // Sur un ISIN porteur d'un détachement de droit (`DS` → manualReview,
    // collecté dans [rightsIsins]), une ligne d'ACHAT (`SOUSC` → buy) matérialise
    // l'EXERCICE des droits : les droits SORTENT du portefeuille (ils sont
    // consommés), ce n'est PAS un achat. On la traite donc comme une SORTIE de
    // titres (transferOut : quantité sortante au PRU courant, AUCUNE plus-value)
    // pour que le droit se solde à ≤ 0 → créé non coté et masqué par le
    // contrôleur, sans prompt ni delta (mécanisme « soldée » déjà en place).
    //
    // DÉCISION CASH : transferOut n'a AUCUN effet cash (amount null). C'est
    // correct sur un droit : ses jambes de QUANTITÉ (DS/SOUSC/RTFIS) ne règlent
    // aucune espèce — le PAIEMENT de la souscription est une ligne DISTINCTE
    // (`ODOST`, cashRegularization, déjà traitée). Le montant que le chemin `buy`
    // fabriquait sur cette jambe (dérivé de quantité×cours, ou `Net` force-signé)
    // était un PHANTOM : le supprimer corrige aussi le cash (cf. test dédié).
    //
    // Gaté STRICTEMENT sur la présence d'un `DS` pour le MÊME ISIN : une
    // souscription réelle (`SOUSC` sur un ISIN SANS `DS`) reste un achat normal.
    if (r.isin != null &&
        kind == TransactionKind.buy &&
        rightsIsins.contains(r.isin)) {
      return _normalizeCorporateAction(
        r,
        profile,
        CorporateActionKind.transferOut,
        accountCurrency: accountCurrency,
        accountId: accountId,
        contentOccurrences: contentOccurrences,
        seq: seq,
      );
    }

    final hasAssetIdentity = (r.isin != null) || (r.label != null) || (r.symbol != null);

    final shape = _shapeOf(kind, hasAssetIdentity);

    final quantity = _parseAmount(r.quantityRaw, profile.decimalSeparator);
    final unitPrice = _parseAmount(r.unitPriceRaw, profile.decimalSeparator);
    final fee = _parseAmount(r.feeRaw, profile.decimalSeparator);
    final mappedAmount = _parseAmount(r.amountRaw, profile.decimalSeparator);

    // Un champ mappé mais illisible (texte non numérique) est une erreur de
    // mapping/format, pas une absence — on la distingue explicitement.
    if (r.quantityRaw != null && quantity == null) {
      return reject('invalidQuantity');
    }
    if (r.unitPriceRaw != null && unitPrice == null) {
      return reject('invalidUnitPrice');
    }
    if (r.feeRaw != null && fee == null) return reject('invalidFee');
    if (r.amountRaw != null && mappedAmount == null) {
      return reject('invalidAmount');
    }

    String? txQuantity;
    String? txUnitPrice;
    String? txFee = fee?.toString();
    String? txAmount;
    String? txSymbol;
    bool needsResolution = false;

    if (shape == _MovementShape.security) {
      if (!hasAssetIdentity) return reject('missingAssetIdentity');
      if (quantity == null) return reject('invalidQuantity');

      // unitPrice optionnel pour openingBalance/adjustment (position/
      // correction déclarée sans prix connu) ; requis pour buy/sell.
      final requiresUnitPrice =
          kind == TransactionKind.buy || kind == TransactionKind.sell;
      if (requiresUnitPrice && unitPrice == null) {
        return reject('invalidUnitPrice');
      }

      txQuantity = quantity.toString();
      txUnitPrice = unitPrice?.toString();
      txSymbol = r.symbol;
      needsResolution = txSymbol == null;

      // Effet cash de la transaction titre. openingBalance/adjustment
      // (variante TITRE) n'affectent JAMAIS le cash — `amount` DOIT rester
      // `null` (invariant du modèle, cf. AssetTransaction).
      if (kind == TransactionKind.buy || kind == TransactionKind.sell) {
        final p = unitPrice ?? Decimal.zero;
        final f = fee ?? Decimal.zero;
        // Montant mappé explicitement s'il existe (net réglé fourni par le
        // relevé), sinon dérivé de quantity×unitPrice±fee — nécessaire pour
        // que la projection cash (qui lit `amount` pour TOUS les kinds, y
        // compris buy/sell) reflète l'effet réel sur les espèces.
        final derived = kind == TransactionKind.buy
            ? -(quantity * p + f)
            : (quantity * p - f);
        final signed = mappedAmount != null
            ? _forceSign(mappedAmount, negative: kind == TransactionKind.buy)
            : derived;
        txAmount = signed.toString();
      }
    } else {
      // Variante/kind CASH : le champ pivot est `amount`.
      final isDeclarativeCashVariant = kind == TransactionKind.openingBalance ||
          kind == TransactionKind.adjustment;

      if (mappedAmount == null) return reject('missingAmount');

      if (isDeclarativeCashVariant) {
        // Delta/solde déclaré : pris TEL QUEL, aucun signe forcé (ce n'est
        // pas une opération de marché, cf. doc de classe TransactionKind).
        txAmount = mappedAmount.toString();
      } else {
        final negative = kind == TransactionKind.withdrawal ||
            kind == TransactionKind.charge;
        txAmount = _forceSign(mappedAmount, negative: negative).toString();
      }

      // dividend peut porter quantity/unitPrice optionnels (ajustement
      // manuel ultérieur) ; les autres kinds cash n'en portent pas.
      if (kind == TransactionKind.dividend) {
        txQuantity = quantity?.toString();
        txUnitPrice = unitPrice?.toString();
      }
      // symbol optionnel pour un mouvement cash (ex. dividende rattaché à un
      // titre) ; jamais requis.
      txSymbol = r.symbol;
      needsResolution = hasAssetIdentity && txSymbol == null;
    }

    return _finishCandidate(
      r,
      profile,
      accountCurrency: accountCurrency,
      accountId: accountId,
      contentOccurrences: contentOccurrences,
      seq: seq,
      kind: kind,
      quantity: txQuantity,
      unitPrice: txUnitPrice,
      fee: txFee,
      amount: txAmount,
      symbol: txSymbol,
      needsResolution: needsResolution,
    );
  }

  // ---------------------------------------------------------------------
  // Normalisation d'une OPÉRATION SUR TITRES (corporate action)
  // ---------------------------------------------------------------------

  /// Normalise une ligne dont le code est une opération sur titres (cf.
  /// [CorporateActionKind]). Isolé du chemin standard pour rendre chaque effet
  /// EXPLICITE et auditable (donnée fiscale en aval) : chaque branche décrit
  /// précisément son impact sur quantité / PRU / plus-value / cash.
  static ImportedMovement _normalizeCorporateAction(
    _RawRow r,
    BrokerProfile profile,
    CorporateActionKind ca, {
    required String accountCurrency,
    required String accountId,
    required Map<String, int> contentOccurrences,
    required int seq,
  }) {
    ImportedMovement reject(String reason) => ImportedMovement.rejected(
          sourceRow: r.source,
          sourceRowIndex: r.sourceIndex,
          rejectReason: reason,
          isin: r.isin,
          label: r.label,
        );

    final hasAssetIdentity =
        (r.isin != null) || (r.label != null) || (r.symbol != null);
    final quantity = _parseAmount(r.quantityRaw, profile.decimalSeparator);
    final unitPrice = _parseAmount(r.unitPriceRaw, profile.decimalSeparator);
    final fee = _parseAmount(r.feeRaw, profile.decimalSeparator);
    final mappedAmount = _parseAmount(r.amountRaw, profile.decimalSeparator);

    // Un champ mappé mais illisible est une erreur de format (comme le chemin
    // standard) — on ne l'assimile pas à une absence.
    if (r.quantityRaw != null && quantity == null) return reject('invalidQuantity');
    if (r.unitPriceRaw != null && unitPrice == null) return reject('invalidUnitPrice');
    if (r.feeRaw != null && fee == null) return reject('invalidFee');
    if (r.amountRaw != null && mappedAmount == null) return reject('invalidAmount');

    ImportedMovement finishSecurity({
      required TransactionKind kind,
      required String quantity,
      String? unitPrice,
      String? fee,
      String? amount,
    }) =>
        _finishCandidate(
          r,
          profile,
          accountCurrency: accountCurrency,
          accountId: accountId,
          contentOccurrences: contentOccurrences,
          seq: seq,
          kind: kind,
          quantity: quantity,
          unitPrice: unitPrice,
          fee: fee,
          amount: amount,
          symbol: r.symbol,
          needsResolution: r.symbol == null,
        );

    switch (ca) {
      case CorporateActionKind.transferOut:
        // Sortie de titres SANS cession : réduit la quantité au PRU courant
        // (base de coût emportée AU PRORATA par la projection), AUCUNE PV,
        // AUCUN cash (amount null). quantity = magnitude (le moteur soustrait) ;
        // unitPrice délibérément null (aucun coût unitaire pertinent — la base
        // de coût retirée est proportionnelle, pas q×p).
        if (!hasAssetIdentity) return reject('missingAssetIdentity');
        if (quantity == null) return reject('invalidQuantity');
        return finishSecurity(
          kind: TransactionKind.transferOut,
          quantity: quantity.abs().toString(),
        );

      case CorporateActionKind.freeAttribution:
        // Attribution gratuite : +quantité à COÛT 0 (baisse le PRU), aucun cash.
        // unitPrice FORCÉ null même si le relevé porte un `cours` informatif —
        // sinon la base de coût grossirait et le PRU ne baisserait pas.
        if (!hasAssetIdentity) return reject('missingAssetIdentity');
        if (quantity == null) return reject('invalidQuantity');
        return finishSecurity(
          kind: TransactionKind.adjustment,
          quantity: quantity.abs().toString(),
        );

      case CorporateActionKind.fractionalRedemption:
        // Rompus rachetés en cash : petite vente (réduit la fraction, crédite le
        // Net, petite PV réalisée). unitPrice requis (le relevé porte le cours) ;
        // amount = Net forcé POSITIF (entrée de cash), comme un `sell`.
        if (!hasAssetIdentity) return reject('missingAssetIdentity');
        if (quantity == null) return reject('invalidQuantity');
        if (unitPrice == null) return reject('invalidUnitPrice');
        if (mappedAmount == null) return reject('missingAmount');
        return finishSecurity(
          kind: TransactionKind.sell,
          quantity: quantity.abs().toString(),
          unitPrice: unitPrice.toString(),
          fee: fee?.toString(),
          amount: mappedAmount.abs().toString(),
        );

      case CorporateActionKind.placeChange:
        // Changement de place : QUANTITÉ-NEUTRE. adjustment TITRE à quantité 0
        // (aucune PV, aucun cash) : trace au journal sans jamais altérer la
        // position — l'identité de l'actif est l'ISIN→symbole, indépendante de
        // la place, donc la (les) jambe(s) out/in ne doivent rien changer.
        if (!hasAssetIdentity) return reject('missingAssetIdentity');
        return finishSecurity(
          kind: TransactionKind.adjustment,
          quantity: '0',
        );

      case CorporateActionKind.manualReview:
        // Opération ambiguë (ex. détachement de droit de souscription) : rejet
        // motivé, jamais journalisée automatiquement (ne casse pas le PRU du
        // sous-jacent).
        return reject('corporateActionReview');

      case CorporateActionKind.cashRegularization:
        // Mouvement de CASH PUR : un éventuel ISIN n'est qu'une RÉFÉRENCE (le
        // titre concerné — comme la TTF `ODTTF` porte l'ISIN du titre taxé), la
        // position n'est JAMAIS touchée (`symbol` reste null). On ne rejette
        // donc JAMAIS sur l'ISIN — le rejeter perdait un crédit/débit d'espèces
        // bien réel.
        //
        // SIGNE : le `Net` Bourse Direct est NON SIGNÉ (magnitude). La direction
        // vient du SENS ESPÈCES fiable ([MovementField.cashDirection] / SensEsp :
        // `D` = débit/sortie → négatif ; `C` = crédit/entrée, ou colonne absente
        // → positif). Ne dépend JAMAIS d'un signe supposé du Net.
        if (mappedAmount == null) return reject('missingAmount');
        final debit = r.cashDirectionRaw?.trim().toUpperCase() == 'D';
        final signedAmount =
            debit ? -mappedAmount.abs() : mappedAmount.abs();
        return _finishCandidate(
          r,
          profile,
          accountCurrency: accountCurrency,
          accountId: accountId,
          contentOccurrences: contentOccurrences,
          seq: seq,
          kind: TransactionKind.adjustment,
          amount: signedAmount.toString(),
          symbol: null,
          needsResolution: false,
        );
    }
  }

  /// Assemble la queue commune de normalisation (devise, meta/tax, clé de dédup,
  /// [AssetTransaction], [ImportedMovement]) partagée par le chemin standard et
  /// le chemin corporate action. Ne décide d'aucune sémantique — les champs
  /// [kind]/[quantity]/[unitPrice]/[amount]/[symbol] sont fournis déjà résolus.
  static ImportedMovement _finishCandidate(
    _RawRow r,
    BrokerProfile profile, {
    required String accountCurrency,
    required String accountId,
    required Map<String, int> contentOccurrences,
    required int seq,
    required TransactionKind kind,
    String? quantity,
    String? unitPrice,
    String? fee,
    String? amount,
    String? symbol,
    required bool needsResolution,
  }) {
    final currency = r.currencyRaw ?? accountCurrency;

    final meta = <String, dynamic>{};
    if (r.taxRaw != null) meta['tax'] = r.taxRaw;
    // Séquence de fichier (ordre chronologique/intraday réel) : départage les
    // mouvements de même date au rejeu (cf. AssetTransaction.compareChronological).
    meta['seq'] = seq;

    // ---- Clé de dédup ----
    final contentKey = _contentKey(
      accountId: accountId,
      date: r.date!,
      kind: kind,
      identity: r.isin ?? symbol ?? r.label ?? '',
      quantity: quantity,
      amount: amount,
    );
    final ordinal = contentOccurrences.update(
      contentKey,
      (v) => v + 1,
      ifAbsent: () => 0,
    );
    final importKey = r.operationReference != null
        ? 'ref:$accountId:${r.operationReference}'
        : 'hash:${_stableHash('$contentKey|$ordinal')}';
    meta['importKey'] = importKey;

    final tx = AssetTransaction(
      id: AssetTransaction.generateId(),
      accountId: accountId,
      symbol: symbol,
      kind: kind,
      quantity: quantity,
      unitPrice: unitPrice,
      amount: amount,
      currency: currency,
      settlementCurrency: accountCurrency,
      date: r.date!,
      fee: fee,
      meta: meta,
    );

    return ImportedMovement.candidate(
      sourceRow: r.source,
      sourceRowIndex: r.sourceIndex,
      transaction: tx,
      isin: r.isin,
      label: r.label,
      needsAssetResolution: needsResolution,
      resolvedSymbol: symbol,
      importKey: importKey,
    );
  }

  static _MovementShape _shapeOf(TransactionKind kind, bool hasAssetIdentity) {
    switch (kind) {
      case TransactionKind.buy:
      case TransactionKind.sell:
      case TransactionKind.transferOut:
        return _MovementShape.security;
      case TransactionKind.openingBalance:
      case TransactionKind.adjustment:
        // Variante titre si une identité d'actif est fournie, sinon variante
        // espèces (cf. doc de classe `TransactionKind`).
        return hasAssetIdentity ? _MovementShape.security : _MovementShape.cash;
      case TransactionKind.dividend:
      case TransactionKind.deposit:
      case TransactionKind.withdrawal:
      case TransactionKind.interest:
      case TransactionKind.charge:
        return _MovementShape.cash;
    }
  }

  static Decimal _forceSign(Decimal value, {required bool negative}) {
    final magnitude = value.abs();
    return negative ? -magnitude : magnitude;
  }

  // ---------------------------------------------------------------------
  // Parsing décimal — tolère virgule/point et séparateurs de milliers FR
  // (espace normal ou insécable, ex. « 1 234,56 »).
  // ---------------------------------------------------------------------

  static Decimal? _parseAmount(String? raw, DecimalSeparator sep) {
    if (raw == null) return null;
    var s = raw.trim().replaceAll(RegExp(r'[\s ]'), '');
    if (s.isEmpty) return null;

    if (sep == DecimalSeparator.comma) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '');
    }
    return Decimal.tryParse(s);
  }

  // ---------------------------------------------------------------------
  // Déduplication (voir doc de classe [normalize])
  // ---------------------------------------------------------------------

  static String _contentKey({
    required String accountId,
    required DateTime date,
    required TransactionKind kind,
    required String identity,
    required String? quantity,
    required String? amount,
  }) {
    final day = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return '$accountId|$day|${kind.wire}|$identity|${quantity ?? ''}|${amount ?? ''}';
  }

  /// Hash déterministe maison (FNV-1a 64 bits) — pas de dépendance
  /// cryptographique ajoutée pour ce seul besoin (une clé de dédup n'a besoin
  /// que d'être STABLE et à faible collision, pas résistante aux attaques).
  static String _stableHash(String input) {
    const fnvOffsetBasis = 0xcbf29ce484222325;
    const fnvPrime = 0x100000001b3;
    var hash = fnvOffsetBasis;
    const mask = 0xFFFFFFFFFFFFFFF; // limite l'arithmétique à 60 bits pour
    // rester dans les entiers natifs (Dart web/JS n'a pas d'int 64 bits non
    // signé) tout en gardant un espace de hachage large.
    for (final byte in utf8.encode(input)) {
      hash = (hash ^ byte) & mask;
      hash = (hash * fnvPrime) & mask;
    }
    return hash.toRadixString(16).padLeft(15, '0');
  }
}

// lib/widgets/import/statement_import_page.dart
//
// Assistant d'import de relevé courtier (lot B4, dernière couche : l'UI).
// Câble les couches déjà livrées et testées (StatementImportService pour le
// parsing brut/aperçu, AccountController.previewStatementImport/
// confirmStatementImport pour la résolution/dédup/delta/écriture) à un
// parcours multi-étapes :
//   1. Sélection du fichier (bytes — jamais un chemin, cf. backup_service.dart
//      pour la justification du split desktop/mobile).
//   2. Configuration du profil générique (délimiteur/encodage/dates/décimales,
//      mapping des colonnes, vocabulaire des natures d'opération) — aperçu des
//      premières lignes pour guider le mapping.
//   3. Prévisualisation (previewStatementImport) : à créer / doublons /
//      rejets / nouveaux actifs / delta projeté / avertissement legacy.
//   4. Résolution des nouveaux actifs SANS proposedSymbol (saisie manuelle du
//      symbole Yahoo Finance) — bouton de confirmation désactivé tant qu'il en
//      reste un non résolu (confirmer avec un actif non résolu journaliserait
//      un mouvement orphelin cash-only, cf. AccountController.
//      confirmStatementImport).
//   5. Confirmation (confirmStatementImport) → résumé + retour au compte (le
//      contrôleur passé en paramètre est celui d'AccountView : sa propre
//      recharge via _initService() dans confirmStatementImport suffit à
//      rafraîchir positions/cash affichés sans étape supplémentaire ici).
//
// FRICTION DE MODÈLE (documentée, pas contournée en douce) : ImportPreview et
// NewAssetCandidate sont IMMUTABLES et previewStatementImport ne peut pas
// connaître par avance le symbole qu'un utilisateur choisira pour un actif non
// résolu. Cette page reconstruit donc un ImportPreview patché juste avant la
// confirmation (cf. [_applyResolvedSymbols]) : chaque ImportedMovement de
// [ImportPreview.toCreate] dont la transaction n'a pas encore de symbole est
// réémis avec le symbole saisi (AssetTransaction.copyWith), et les
// NewAssetCandidate correspondants reçoivent leur proposedSymbol. Les deltas
// projetés ([ImportPreview.projectedDeltas]) ne sont PAS recalculés pour ces
// actifs tout juste résolus (ils n'existaient pas encore comme symbole connu
// au moment du calcul de delta) : limite assumée, cf. rapport de livraison.

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/logic/position_projection.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/broker_profile.dart';
import 'package:portfolio_tracker/model/import_preview.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';
import 'package:portfolio_tracker/services/isin_resolver.dart';
import 'package:portfolio_tracker/services/market_data_service.dart'
    show IsinSearchException;
import 'package:portfolio_tracker/services/statement_import_service.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';
import 'package:portfolio_tracker/utils/error_text.dart';
import 'package:portfolio_tracker/utils/formatters.dart';
import 'package:portfolio_tracker/widgets/common/responsive_body.dart';

enum _ImportStep { pickFile, configureProfile, preview, resolveAssets, done }

/// Choix de profil courtier proposé à l'étape 1 (segment, pas une étape à
/// part entière) : « Bourse Direct » saute l'étape 2 (mapping manuel — le
/// profil est déjà entièrement pré-rempli, cf. [BrokerProfile.bourseDirect])
/// et va directement à la prévisualisation ; « Générique / manuel » conserve
/// le parcours historique.
enum _ImportProfileChoice { genericManual, bourseDirect }

class StatementImportPage extends StatefulWidget {
  /// Contrôleur DÉJÀ initialisé du compte ouvrant l'assistant (celui
  /// d'AccountView) : réutilisé tel quel (jamais disposé ici, la page ne le
  /// possède pas) pour que la confirmation d'import rafraîchisse directement
  /// l'écran d'où l'assistant a été ouvert.
  final AccountController controller;
  final String accountId;
  final String accountName;

  /// Point d'entrée réservé aux TESTS WIDGET : démarre directement à l'étape
  /// de résolution des nouveaux actifs avec cette prévisualisation, sans
  /// passer par la sélection de fichier (file_picker/file_selector n'ont pas
  /// d'implémentation dans l'environnement de test widget). Toujours `null`
  /// en production.
  @visibleForTesting
  final ImportPreview? debugInitialPreview;

  /// Réservé aux TESTS WIDGET : amorce l'étape de résolution avec ces clés
  /// (isin ?? label) déjà en état « recherche échouée », SANS déclencher de
  /// réseau (le vrai peuplement passe par [_resolveOneNewAsset] sur
  /// [IsinSearchException], non joignable en test). Toujours `null` en
  /// production. N'a d'effet qu'avec [debugInitialPreview].
  @visibleForTesting
  final Set<String>? debugInitialSearchFailedKeys;

  /// Réservé aux TESTS WIDGET : place de cotation (par clé isin ?? label) déjà
  /// résolue, comme si [_resolveOneNewAsset] l'avait obtenue d'un hit réel —
  /// SANS déclencher de réseau. Vérifie l'affichage du correctif « place à
  /// côté du symbole proposé ». Toujours `null` en production. N'a d'effet
  /// qu'avec [debugInitialPreview].
  @visibleForTesting
  final Map<String, String>? debugInitialResolvedVenues;

  /// Réservé aux TESTS WIDGET : clés (isin ?? label) déjà marquées « rang 3 »
  /// (résolution peu sûre, cf. [IsinResolver.venueRank]), SANS déclencher de
  /// réseau. Vérifie l'affichage de l'avertissement correspondant. Toujours
  /// `null` en production. N'a d'effet qu'avec [debugInitialPreview].
  @visibleForTesting
  final Set<String>? debugInitialLowConfidenceVenueKeys;

  const StatementImportPage({
    super.key,
    required this.controller,
    required this.accountId,
    required this.accountName,
    this.debugInitialPreview,
    this.debugInitialSearchFailedKeys,
    this.debugInitialResolvedVenues,
    this.debugInitialLowConfidenceVenueKeys,
  });

  @override
  State<StatementImportPage> createState() => _StatementImportPageState();
}

class _StatementImportPageState extends State<StatementImportPage> {
  _ImportStep _step = _ImportStep.pickFile;

  /// Plafond d'affichage par groupe à l'étape d'aperçu : un relevé de plusieurs
  /// centaines de lignes ne construit pas tout d'un coup (le reste est annoncé
  /// par une ligne « … et N autre(s) », jamais masqué en silence).
  static const int _groupDisplayCap = 50;

  // ---- Étape 1 : fichier + choix du profil courtier ----
  Uint8List? _fileBytes;
  String _fileLabel = '';
  _ImportProfileChoice _profileChoice = _ImportProfileChoice.genericManual;

  // ---- Étape 2 : profil générique (valeurs par défaut = BrokerProfile.
  // genericManual, le triplet le plus fréquent des exports bancaires FR) ----
  String _delimiter = ';';
  Encoding _encoding = latin1;
  bool _hasHeaderRow = true;
  String _dateSeparator = '/';
  bool _dayFirst = true;
  bool _fourDigitYear = true;
  DecimalSeparator _decimalSeparator = DecimalSeparator.comma;

  List<List<String>> _parsedRows = const [];
  final Map<MovementField, int?> _columnSelection = {
    for (final f in MovementField.values) f: null,
  };
  final Map<String, TransactionKind?> _kindMapping = {};
  String? _configureError;

  // ---- Étape 3 : prévisualisation ----
  bool _loadingPreview = false;
  String? _previewError;
  ImportPreview? _preview;

  // ---- Étape 4 : résolution des nouveaux actifs (clé = isin ?? label) ----
  final Map<String, TextEditingController> _newAssetSymbolControllers = {};

  /// Clés (isin ?? label) des actifs pour lesquels l'utilisateur a choisi le
  /// repli « non coté » (symbole == ISIN, jamais interrogé). Réservé aux
  /// candidats porteurs d'un ISIN.
  final Set<String> _fallbackIsinKeys = {};

  /// Clés (isin ?? label) dont la recherche ISIN → symbole est EN COURS.
  /// Une ligne présente ici affiche un indicateur de recherche ; elle n'est
  /// donc ni « trouvée » ni « introuvable » tant qu'elle y figure. Vidée clé
  /// par clé à mesure que les recherches (parallèles bornées) aboutissent.
  final Set<String> _resolvingKeys = {};

  /// Clés (isin ?? label) dont la recherche ISIN → symbole a ÉCHOUÉ pour cause
  /// de panne réseau/transport ([IsinSearchException]) — À DISTINGUER d'un ISIN
  /// simplement introuvable (liste vide → repli « non coté » légitime). Une clé
  /// ici affiche un bandeau « Réessayer » qui relance ces recherches. Depuis
  /// P2.3, cela n'EMPRISONNE plus l'utilisateur : le repli « non coté » reste
  /// proposé sur un candidat porteur d'un ISIN (échappatoire hors-ligne), la
  /// panne restant signalée par le bandeau.
  final Set<String> _searchFailedKeys = {};

  /// Place de cotation (libellé lisible, ex. « Londres ») du hit retenu par
  /// [IsinResolver.pickBest] pour chaque clé auto-résolue — vidée/rétablie en
  /// même temps que le pré-remplissage du champ (cf. [_resolveOneNewAsset]),
  /// jamais pour une saisie manuelle. Rend visible l'anomalie qui a motivé ce
  /// correctif (cf. doc de fichier) : sans elle, `0E2B.IL` s'affichait sans
  /// aucun indice que la place retenue est Londres, pas Paris.
  final Map<String, String> _resolvedVenueByKey = {};

  /// Clés dont le hit retenu est au rang 3 de [IsinResolver.venueRank] (« le
  /// reste » — aucune place Euronext/Xetra connue) : signal fort de
  /// résolution DOUTEUSE pour un patrimoine local en euros. N'empêche PAS la
  /// confirmation (le champ reste pré-rempli et éditable), affiche seulement
  /// un avertissement à côté du champ concerné.
  final Set<String> _lowConfidenceVenueKeys = {};

  /// `true` pendant la vérification (à la validation de l'étape) des symboles
  /// SAISIS À LA MAIN auprès de la source de marché — cf. [_onConfirmResolveAssets].
  bool _verifyingSymbols = false;

  /// Clés dont le symbole saisi à la main a été vérifié INTROUVABLE auprès de
  /// la source de marché (recherche aboutie, aucun hit exact) — bloque la
  /// confirmation tant que la saisie n'est pas corrigée. Jamais peuplée pour
  /// le repli « non coté » (cf. [_onConfirmResolveAssets], qui l'exclut de la
  /// vérification).
  final Set<String> _invalidSymbolKeys = {};

  /// Clés dont la vérification du symbole saisi a échoué pour cause de PANNE
  /// RÉSEAU/transport ([IsinSearchException]) : à DISTINGUER d'un symbole
  /// réellement introuvable — aucune info sur son existence, donc PAS de
  /// blocage (même raisonnement que [_searchFailedKeys], cf. doc de fichier).
  /// Purement informatif.
  final Set<String> _unverifiableSymbolKeys = {};

  // ---- Étape 5 : confirmation ----
  bool _confirming = false;
  _ImportSummaryData? _summary;

  /// Identifiant du lot du dernier import confirmé (lu sur le contrôleur après
  /// succès), support du bouton « Annuler cet import » de l'étape finale. Null
  /// tant qu'aucun import n'a abouti dans cette page.
  String? _lastBatchId;

  /// `true` pendant l'annulation d'un import (désactive les boutons de l'étape
  /// finale et affiche un indicateur d'attente).
  bool _undoing = false;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  @override
  void initState() {
    super.initState();
    final debugPreview = widget.debugInitialPreview;
    if (debugPreview != null) {
      _preview = debugPreview;
      _step = _ImportStep.resolveAssets;
      for (final asset in debugPreview.newAssets) {
        if (asset.proposedSymbol == null) {
          final key = asset.isin ?? asset.label;
          _newAssetSymbolControllers.putIfAbsent(
            key,
            () => TextEditingController(),
          );
        }
      }
      final failed = widget.debugInitialSearchFailedKeys;
      if (failed != null) _searchFailedKeys.addAll(failed);
      final venues = widget.debugInitialResolvedVenues;
      if (venues != null) _resolvedVenueByKey.addAll(venues);
      final lowConfidence = widget.debugInitialLowConfidenceVenueKeys;
      if (lowConfidence != null) _lowConfidenceVenueKeys.addAll(lowConfidence);
    }
  }

  @override
  void dispose() {
    for (final c in _newAssetSymbolControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Navigation entre étapes
  // ---------------------------------------------------------------------------

  void _goBack() {
    switch (_step) {
      case _ImportStep.pickFile:
        Navigator.pop(context);
        return;
      case _ImportStep.configureProfile:
        setState(() => _step = _ImportStep.pickFile);
        return;
      case _ImportStep.preview:
        setState(() {
          // Bourse Direct saute l'étape de mapping manuel (profil pré-rempli,
          // cf. _pickFile) : retour direct à la sélection de fichier.
          _step = _profileChoice == _ImportProfileChoice.bourseDirect
              ? _ImportStep.pickFile
              : _ImportStep.configureProfile;
          _preview = null;
        });
        return;
      case _ImportStep.resolveAssets:
        setState(() => _step = _ImportStep.preview);
        return;
      case _ImportStep.done:
        Navigator.pop(context, true);
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // Étape 1 — sélection du fichier
  // ---------------------------------------------------------------------------

  Future<void> _pickFile() async {
    final l10n = AppLocalizations.of(context)!;
    Uint8List? bytes;
    String? name;
    try {
      if (_isDesktop) {
        // Le premier groupe est le filtre PRÉSÉLECTIONNÉ par le sélecteur
        // desktop : on met en tête le format attendu par le profil choisi
        // (Bourse Direct = xlsx), sinon CSV pour le générique.
        const csvGroup = XTypeGroup(label: 'CSV', extensions: ['csv', 'txt']);
        const excelGroup = XTypeGroup(label: 'Excel', extensions: ['xlsx']);
        final file = await openFile(
          acceptedTypeGroups:
              _profileChoice == _ImportProfileChoice.bourseDirect
                  ? const [excelGroup, csvGroup]
                  : const [csvGroup, excelGroup],
        );
        if (file == null) return;
        bytes = await file.readAsBytes();
        name = file.name;
      } else {
        // Le service ne sait lire que CSV/texte/xlsx : on filtre à la source
        // (aligné sur les groupes desktop) plutôt que d'échouer avec un message
        // générique après qu'un PDF a été choisi. `withData` requis : on
        // travaille sur les octets, jamais un chemin (cf. doc de fichier).
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['csv', 'txt', 'xlsx'],
          withData: true,
        );
        if (result == null || result.files.isEmpty) return;
        final picked = result.files.single;
        bytes = picked.bytes;
        name = picked.name;
      }
    } catch (_) {
      bytes = null;
    }

    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      showAppSnackBar(context, l10n.importFileUnreadable, type: SnackType.error);
      return;
    }

    setState(() {
      _fileBytes = bytes;
      _fileLabel = name ?? '';
    });

    if (_profileChoice == _ImportProfileChoice.bourseDirect) {
      // Profil pré-rempli : pas de mapping manuel, prévisualisation directe
      // (reste à l'étape 1 le temps du calcul — cf. _buildPickFileStep pour
      // l'indicateur de chargement/erreur).
      await _runPreviewWithProfile(BrokerProfile.bourseDirect());
      return;
    }

    setState(() => _step = _ImportStep.configureProfile);
    _reparse();
  }

  // ---------------------------------------------------------------------------
  // Étape 2 — configuration du profil générique
  // ---------------------------------------------------------------------------

  /// Redécode les lignes brutes selon délimiteur/encodage/en-tête courants.
  /// Utilise [StatementImportService.parse] (PUR, ignore mapping/lexique) —
  /// c'est la même fonction que celle utilisée par la prévisualisation réelle,
  /// donc l'aperçu affiché ici est fidèle à ce que produira l'étape 3.
  void _reparse() {
    final bytes = _fileBytes;
    if (bytes == null) return;
    final draft = BrokerProfile.genericManual(
      delimiter: _delimiter,
      encoding: _encoding,
      hasHeaderRow: _hasHeaderRow,
      columns: const ColumnMapping(),
      kindLexicon: const {},
    );
    final rows = StatementImportService.parse(bytes, draft);
    setState(() {
      _parsedRows = rows;
      _configureError = rows.isEmpty ? 'empty' : null;
    });
    _autoDetectColumns();
  }

  /// Synonymes (déjà NORMALISÉS : minuscules, sans accents, séparateurs réduits
  /// à une espace) par champ cible, pour la pré-détection du mapping. Un
  /// synonyme MONO-mot n'est reconnu qu'en tant que JETON entier de l'en-tête
  /// (« code » ne rafle pas « codeoperation ») ; un synonyme MULTI-mots
  /// (« montant net ») est reconnu comme sous-chaîne.
  static const Map<MovementField, List<String>> _headerSynonyms = {
    MovementField.date: ['date', 'date operation', 'date execution'],
    MovementField.kindLabel: [
      'operation',
      'nature',
      'libelle operation',
      'type',
      'transaction',
    ],
    MovementField.isin: ['isin', 'code isin', 'code'],
    MovementField.symbol: ['symbole', 'ticker', 'mnemo', 'code valeur'],
    MovementField.label: [
      'libelle',
      'valeur',
      'designation',
      'description',
      'name',
    ],
    MovementField.quantity: ['quantite', 'qte', 'quantity', 'nombre'],
    MovementField.unitPrice: ['cours', 'prix', 'prix unitaire', 'price'],
    MovementField.amount: ['montant', 'montant net', 'net', 'amount'],
    MovementField.fee: ['frais', 'commission', 'courtage', 'fee'],
    MovementField.currency: ['devise', 'monnaie', 'currency'],
    MovementField.tax: ['taxe', 'ttf', 'impot', 'tax'],
    MovementField.operationReference: [
      'reference',
      'ref',
      'n operation',
      'numero operation',
    ],
  };

  /// Ordre de priorité de la pré-détection : les champs aux en-têtes les plus
  /// spécifiques d'abord ; [MovementField.kindLabel]/[MovementField.label]
  /// (dont les synonymes génériques risquent une collision) en dernier. Ne
  /// figurent PAS ici les champs sans détection auto (ex. cashDirection).
  static const List<MovementField> _autoDetectOrder = [
    MovementField.date,
    MovementField.isin,
    MovementField.symbol,
    MovementField.operationReference,
    MovementField.quantity,
    MovementField.unitPrice,
    MovementField.fee,
    MovementField.tax,
    MovementField.amount,
    MovementField.currency,
    MovementField.kindLabel,
    MovementField.label,
  ];

  /// Normalise un texte d'en-tête pour la comparaison tolérante : minuscules,
  /// accents retirés, tout séparateur (espace, ponctuation, « ° », « n° »…)
  /// réduit à une espace simple.
  static String _normalizeHeader(String raw) {
    const accents = 'àâäáãçéèêëíìîïñóòôöõúùûüýÿ';
    const plain = 'aaaaaceeeeiiiinooooouuuuyy';
    final buffer = StringBuffer();
    for (final ch in raw.toLowerCase().split('')) {
      final idx = accents.indexOf(ch);
      buffer.write(idx >= 0 ? plain[idx] : ch);
    }
    return buffer
        .toString()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  static bool _headerMatches(
    String header,
    List<String> synonyms, {
    required bool exact,
  }) {
    if (exact) return synonyms.contains(header);
    final tokens = header.split(' ');
    return synonyms.any(
      (s) => s.contains(' ') ? header.contains(s) : tokens.contains(s),
    );
  }

  /// Pré-remplit [_columnSelection] par correspondance tolérante entre les
  /// en-têtes du relevé et [_headerSynonyms]. AIDE best-effort : ne s'applique
  /// qu'aux champs encore à `null` (ne piétine JAMAIS un choix utilisateur), ne
  /// réattribue jamais une colonne déjà prise, et seulement s'il y a une ligne
  /// d'en-tête. Deux passes : correspondance EXACTE d'abord (un synonyme
  /// générique comme « code » ne rafle pas une colonne « ISIN »), puis par
  /// inclusion. Rejouée à chaque [_reparse] : sans effet sur les champs déjà
  /// mappés.
  void _autoDetectColumns() {
    if (!_hasHeaderRow || _parsedRows.isEmpty) return;
    final header = _parsedRows.first;
    final normalized = [for (final h in header) _normalizeHeader(h)];
    final taken = <int>{
      for (final v in _columnSelection.values) ?v,
    };
    final detected = <MovementField, int>{};
    for (final exact in [true, false]) {
      for (final field in _autoDetectOrder) {
        if (_columnSelection[field] != null || detected.containsKey(field)) {
          continue;
        }
        final synonyms = _headerSynonyms[field]!;
        for (var i = 0; i < normalized.length; i++) {
          if (taken.contains(i) || normalized[i].isEmpty) continue;
          if (_headerMatches(normalized[i], synonyms, exact: exact)) {
            detected[field] = i;
            taken.add(i);
            break;
          }
        }
      }
    }
    if (detected.isEmpty) return;
    setState(() {
      detected.forEach((field, idx) => _columnSelection[field] = idx);
    });
  }

  List<List<String>> get _dataRows => _hasHeaderRow && _parsedRows.isNotEmpty
      ? _parsedRows.skip(1).toList()
      : _parsedRows;

  /// Noms de colonnes affichés dans les menus de mapping ET l'aperçu : texte
  /// d'en-tête si disponible, sinon un nom générique « Colonne N ».
  List<String> _columnLabels(AppLocalizations l10n) {
    if (_parsedRows.isEmpty) return const [];
    final colCount = _parsedRows.fold<int>(
      0,
      (m, r) => r.length > m ? r.length : m,
    );
    final header = _hasHeaderRow ? _parsedRows.first : null;
    return [
      for (var i = 0; i < colCount; i++)
        (header != null && i < header.length && header[i].trim().isNotEmpty)
            ? header[i].trim()
            : l10n.importColumnGeneric(i + 1),
    ];
  }

  /// Valeurs distinctes rencontrées dans la colonne mappée à [MovementField.
  /// kindLabel], pour construire le vocabulaire (kindLexicon) du profil.
  List<String> get _distinctKindLabels {
    final idx = _columnSelection[MovementField.kindLabel];
    if (idx == null) return const [];
    final seen = <String>{};
    for (final row in _dataRows) {
      if (idx < row.length) {
        final v = row[idx].trim();
        if (v.isNotEmpty) seen.add(v);
      }
    }
    final list = seen.toList()..sort();
    return list;
  }

  bool get _canContinueToPreview =>
      _parsedRows.isNotEmpty &&
      _columnSelection[MovementField.date] != null &&
      _columnSelection[MovementField.kindLabel] != null;

  BrokerProfile _buildProfile() {
    final byIndex = <MovementField, int>{
      for (final entry in _columnSelection.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    final lexicon = <String, TransactionKind>{
      for (final entry in _kindMapping.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    return BrokerProfile.genericManual(
      delimiter: _delimiter,
      encoding: _encoding,
      hasHeaderRow: _hasHeaderRow,
      dateFormat: DateFormatSpec(
        separator: _dateSeparator,
        dayFirst: _dayFirst,
        fourDigitYear: _fourDigitYear,
      ),
      decimalSeparator: _decimalSeparator,
      columns: ColumnMapping(byIndex: byIndex),
      kindLexicon: lexicon,
    );
  }

  Future<void> _runPreview() async {
    final l10n = AppLocalizations.of(context)!;
    if (_fileBytes == null || _dataRows.isEmpty) {
      setState(() => _previewError = l10n.importParseEmptyError);
      return;
    }
    await _runPreviewWithProfile(_buildProfile());
  }

  /// Calcule la prévisualisation pour [profile] et avance à l'étape 3 en cas
  /// de succès — factorisé entre le parcours générique ([_runPreview], profil
  /// construit depuis le mapping manuel de l'étape 2) et Bourse Direct
  /// ([_pickFile], profil déjà entièrement pré-rempli donc SANS passer par
  /// l'étape 2).
  Future<void> _runPreviewWithProfile(BrokerProfile profile) async {
    final bytes = _fileBytes;
    if (bytes == null) return;

    setState(() {
      _loadingPreview = true;
      _previewError = null;
    });

    try {
      final preview = await widget.controller.previewStatementImport(
        bytes,
        profile,
        accountId: widget.accountId,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loadingPreview = false;
        _step = _ImportStep.preview;
        for (final asset in preview.newAssets) {
          if (asset.proposedSymbol == null) {
            final key = asset.isin ?? asset.label;
            _newAssetSymbolControllers.putIfAbsent(
              key,
              () => TextEditingController(),
            );
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingPreview = false;
        _previewError = ErrorText.of(context, e);
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Étape 4 — résolution des nouveaux actifs
  // ---------------------------------------------------------------------------

  /// Passe à l'étape de résolution ET déclenche l'auto-résolution ISIN →
  /// symbole. Point d'entrée UNIQUE de production (le parcours de test entre
  /// via `debugInitialPreview`/initState, qui NE déclenche PAS le réseau).
  void _enterResolveAssets() {
    // Amorce SYNCHRONE de l'état « recherche en cours » (dans le même frame que
    // le changement d'étape) : sans cela, les lignes non encore résolues
    // s'afficheraient une fraction de seconde comme « introuvables ».
    final preview = _preview;
    final resolvingKeys = <String>{
      if (preview != null)
        for (final a in preview.newAssets)
          if (a.proposedSymbol == null && a.isin != null)
            if ((_newAssetSymbolControllers[a.isin ?? a.label]?.text.trim() ??
                    '')
                .isEmpty)
              (a.isin ?? a.label),
    };
    setState(() {
      _step = _ImportStep.resolveAssets;
      _resolvingKeys
        ..clear()
        ..addAll(resolvingKeys);
    });
    _maybeAutoResolveNewAssets();
  }

  /// Pour chaque nouvel actif non résolu PORTEUR d'un ISIN, interroge la source
  /// de marché (recherche par ISIN) et pré-remplit le symbole retenu par la
  /// désambiguïsation ([IsinResolver.pickBest]). Best-effort : un échec / ISIN
  /// introuvable laisse le champ vide (l'utilisateur pourra saisir un symbole
  /// ou cocher « non coté »). Ne PIÉTINE jamais une saisie déjà présente.
  ///
  /// Concurrence BORNÉE (pas de rafale de N requêtes simultanées vers
  /// l'endpoint de recherche, qui filtre les scripts) : les recherches partent
  /// par lots, et chaque ligne quitte l'état « en cours » dès SA réponse — pas
  /// à la fin du lot — pour un remplissage progressif sans latence perçue.
  Future<void> _maybeAutoResolveNewAssets() async {
    final preview = _preview;
    if (preview == null) return;
    final toResolve = preview.newAssets
        .where((a) => a.proposedSymbol == null && a.isin != null)
        .where((a) =>
            _resolvingKeys.contains(a.isin ?? a.label)) // champs encore vides
        .toList();
    if (toResolve.isEmpty) return;

    const maxConcurrent = 5;
    for (var i = 0; i < toResolve.length; i += maxConcurrent) {
      final batch = toResolve.skip(i).take(maxConcurrent);
      await Future.wait(batch.map(_resolveOneNewAsset));
      if (!mounted) return;
    }
  }

  /// Résout UN actif et le sort de l'état « en cours » à réception, sans
  /// écraser une saisie manuelle survenue entre-temps.
  Future<void> _resolveOneNewAsset(NewAssetCandidate asset) async {
    final key = asset.isin ?? asset.label;
    final ctrl = _newAssetSymbolControllers[key];
    if (ctrl == null) {
      _resolvingKeys.remove(key);
      return;
    }
    List<IsinSearchHit> hits;
    try {
      hits = await widget.controller.searchIsin(asset.isin!);
    } on IsinSearchException {
      // Panne réseau/transport : ne PAS conclure « introuvable » (aucune info
      // sur l'existence du titre). On marque la clé « recherche échouée » — le
      // bandeau « Réessayer » de l'étape 4 relancera ces recherches — sans rien
      // pré-remplir ni cocher.
      if (!mounted) return;
      setState(() {
        _searchFailedKeys.add(key);
        _resolvingKeys.remove(key);
      });
      return;
    } catch (_) {
      // Exception inattendue (non réseau) : repli best-effort, champ laissé
      // vide (l'utilisateur saisit un symbole ou coche « non coté »).
      hits = const [];
    }
    if (!mounted) return;
    final best = IsinResolver.pickBest(hits);
    setState(() {
      if (best != null && ctrl.text.trim().isEmpty) {
        ctrl.text = best.symbol;
        // Place du hit retenu (correctif 1) : affichée à côté du champ pour
        // que l'anomalie saute aux yeux (cf. cas réel `0E2B.IL`/Londres en
        // doc de fichier), au lieu de rester un simple symbole opaque.
        final venue = best.exchangeDisplay ?? best.exchange;
        if (venue != null && venue.trim().isNotEmpty) {
          _resolvedVenueByKey[key] = venue.trim();
        }
        // Rang 3 (correctif 2) : aucune place Euronext/Xetra connue — signal
        // fort de résolution douteuse pour un patrimoine local en euros. On
        // avertit sans bloquer (le champ reste pré-rempli et éditable).
        if (IsinResolver.venueRank(best) == 3) {
          _lowConfidenceVenueKeys.add(key);
        }
      }
      _resolvingKeys.remove(key);
    });
  }

  /// Relance les recherches ISIN restées en échec réseau : les clés concernées
  /// (encore sans symbole saisi entre-temps) repassent « en cours » et
  /// [_maybeAutoResolveNewAssets] les reconsidère (il filtre sur
  /// [_resolvingKeys]). Une clé dont l'utilisateur a saisi un symbole depuis
  /// l'échec est simplement retirée de [_searchFailedKeys], sans relance.
  void _retryFailedSearches() {
    final retryKeys = _searchFailedKeys.where((key) {
      final text = _newAssetSymbolControllers[key]?.text.trim() ?? '';
      return text.isEmpty;
    }).toSet();
    setState(() {
      _searchFailedKeys.clear();
      _resolvingKeys.addAll(retryKeys);
    });
    _maybeAutoResolveNewAssets();
  }

  bool get _allNewAssetsResolved {
    final preview = _preview;
    if (preview == null) return false;
    for (final asset in preview.newAssets) {
      if (asset.proposedSymbol != null) continue;
      final key = asset.isin ?? asset.label;
      // Repli « non coté » : résout le candidat sans symbole saisi.
      if (_fallbackIsinKeys.contains(key)) continue;
      final text = _newAssetSymbolControllers[key]?.text.trim() ?? '';
      if (text.isEmpty) return false;
    }
    return true;
  }

  /// Reconstruit un [ImportPreview] où chaque mouvement/actif neuf encore sans
  /// symbole reçoit celui saisi par l'utilisateur (cf. doc de fichier —
  /// [ImportPreview]/[NewAssetCandidate] sont immutables, previewStatementImport
  /// ne peut pas connaître ce choix par avance).
  ImportPreview _applyResolvedSymbols(ImportPreview preview) {
    // Par clé (isin ?? label) : le symbole retenu ET s'il est coté. Le repli
    // « non coté » impose symbole == ISIN et quotable == false.
    final resolvedByKey = <String, ({String symbol, bool quotable})>{};
    for (final asset in preview.newAssets) {
      if (asset.proposedSymbol != null) continue;
      final key = asset.isin ?? asset.label;
      if (_fallbackIsinKeys.contains(key) && asset.isin != null) {
        resolvedByKey[key] = (symbol: asset.isin!, quotable: false);
      } else {
        final text = _newAssetSymbolControllers[key]?.text.trim() ?? '';
        if (text.isNotEmpty) {
          resolvedByKey[key] = (symbol: text.toUpperCase(), quotable: true);
        }
      }
    }
    if (resolvedByKey.isEmpty) return preview;

    final patchedToCreate = preview.toCreate.map((m) {
      final tx = m.transaction;
      if (tx == null || tx.symbol != null) return m;
      final key = m.isin ?? m.label;
      final resolved = key != null ? resolvedByKey[key] : null;
      if (resolved == null) return m;
      return ImportedMovement.candidate(
        sourceRow: m.sourceRow,
        sourceRowIndex: m.sourceRowIndex,
        transaction: tx.copyWith(symbol: resolved.symbol),
        isin: m.isin,
        label: m.label,
        resolvedSymbol: resolved.symbol,
        importKey: m.importKey!,
      );
    }).toList();

    final patchedNewAssets = preview.newAssets.map((asset) {
      if (asset.proposedSymbol != null) return asset;
      final key = asset.isin ?? asset.label;
      final resolved = resolvedByKey[key];
      if (resolved == null) return asset;
      return NewAssetCandidate(
        isin: asset.isin,
        label: asset.label,
        proposedSymbol: resolved.symbol,
        quotable: resolved.quotable,
      );
    }).toList();

    return ImportPreview(
      toCreate: patchedToCreate,
      duplicates: preview.duplicates,
      rejects: preview.rejects,
      newAssets: patchedNewAssets,
      projectedDeltas: preview.projectedDeltas,
      legacySymbols: preview.legacySymbols,
    );
  }

  /// Vérifie qu'un symbole SAISI À LA MAIN (ou laissé tel quel après
  /// l'auto-résolution) existe bien auprès de la source de marché — bug
  /// rapporté : `CSH2.PAR` (plausible mais invalide, Yahoo attend `.PA`)
  /// était accepté sans contrôle, créant une position dont le cours ne serait
  /// jamais récupéré.
  ///
  /// Réutilise [AccountController.searchIsin] (donc [MarketDataService.
  /// searchByIsin]) plutôt que [MarketDataService.getQuoteWithMetadata] : ce
  /// dernier AVALE toute erreur de transport et renvoie `null` aussi bien
  /// pour un symbole invalide que pour une panne réseau (cf. [YahooFinanceProvider
  /// .getQuoteWithMetadata]) — impossible d'y distinguer les deux cas.
  /// `searchIsin` accepte n'importe quelle requête textuelle (pas seulement
  /// un ISIN, cf. son implémentation) et lève [IsinSearchException] sur un
  /// échec de TRANSPORT, exactement la distinction qu'il faut ici.
  ///
  /// Retourne :
  ///  - `true`  : un hit porte EXACTEMENT ce symbole → accepté.
  ///  - `false` : recherche aboutie mais aucun hit exact → REJETÉ.
  ///  - `null`  : échec de transport OU erreur inattendue — AUCUNE info sur
  ///    l'existence du titre, donc PAS de rejet (même raisonnement que pour
  ///    la recherche ISIN, cf. doc de fichier / [_resolveOneNewAsset]).
  Future<bool?> _verifySymbolExists(String symbol) async {
    List<IsinSearchHit> hits;
    try {
      hits = await widget.controller.searchIsin(symbol);
    } on IsinSearchException {
      return null;
    } catch (_) {
      // Erreur inattendue non réseau : même prudence best-effort que
      // _resolveOneNewAsset — on ne bloque pas l'utilisateur sur un signal
      // qu'on ne maîtrise pas.
      return null;
    }
    return hits.any((h) => h.symbol.toUpperCase() == symbol);
  }

  /// Point d'entrée RÉEL du bouton de confirmation de l'étape 4 : vérifie
  /// D'ABORD chaque symbole SAISI À LA MAIN avant d'enchaîner sur
  /// [_confirmImport]. Déclenchée à la VALIDATION DE L'ÉTAPE (pas à la sortie
  /// de chaque champ) : ce bouton est déjà le point de passage obligé
  /// ([_allNewAssetsResolved] le garde), donc UN SEUL passage borné suffit,
  /// sans FocusNode par ligne à câbler ni risque de laisser passer un champ
  /// jamais quitté (auto-rempli puis édité sans perdre le focus, par ex.).
  ///
  /// Le repli « non coté » ([_fallbackIsinKeys]) n'est JAMAIS soumis à cette
  /// vérification : par construction ces titres n'existent pas chez la
  /// source (symbole = ISIN, quotable = false).
  ///
  /// Asynchrone et NON bloquant : [_verifyingSymbols] pilote un indicateur
  /// d'attente (même mécanique que [_resolvingKeys] pour l'auto-résolution),
  /// concurrence bornée par lots comme [_maybeAutoResolveNewAssets].
  Future<void> _onConfirmResolveAssets() async {
    if (!_allNewAssetsResolved) return;
    final preview = _preview;
    if (preview == null) return;

    // Symboles à vérifier : SAISIS (auto-remplis ou manuels), à l'exclusion
    // du repli « non coté ».
    final toVerify = <String, String>{};
    for (final asset in preview.newAssets) {
      if (asset.proposedSymbol != null) continue;
      final key = asset.isin ?? asset.label;
      if (_fallbackIsinKeys.contains(key)) continue;
      final text = _newAssetSymbolControllers[key]?.text.trim() ?? '';
      if (text.isNotEmpty) toVerify[key] = text.toUpperCase();
    }

    if (toVerify.isEmpty) {
      await _confirmImport();
      return;
    }

    setState(() {
      _verifyingSymbols = true;
      _invalidSymbolKeys.clear();
      _unverifiableSymbolKeys.clear();
    });

    final invalid = <String>{};
    final unverifiable = <String>{};
    const maxConcurrent = 5;
    final entries = toVerify.entries.toList();
    for (var i = 0; i < entries.length; i += maxConcurrent) {
      final batch = entries.skip(i).take(maxConcurrent);
      await Future.wait(batch.map((entry) async {
        final result = await _verifySymbolExists(entry.value);
        if (result == false) invalid.add(entry.key);
        if (result == null) unverifiable.add(entry.key);
      }));
    }
    if (!mounted) return;

    setState(() {
      _verifyingSymbols = false;
      _invalidSymbolKeys
        ..clear()
        ..addAll(invalid);
      _unverifiableSymbolKeys
        ..clear()
        ..addAll(unverifiable);
    });

    // Au moins un symbole introuvable : on bloque, message affiché sous
    // chaque champ concerné ([_buildResolveAssetRow]) — l'utilisateur corrige
    // et retente (un nouveau clic relance la vérification).
    if (invalid.isNotEmpty) return;

    await _confirmImport();
  }

  // ---------------------------------------------------------------------------
  // Étape 5 — confirmation
  // ---------------------------------------------------------------------------

  Future<void> _confirmImport() async {
    final preview = _preview;
    if (preview == null) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() => _confirming = true);

    final resolvedPreview = _applyResolvedSymbols(preview);
    final erreur = await widget.controller.confirmStatementImport(
      resolvedPreview,
      accountId: widget.accountId,
    );

    if (!mounted) return;
    setState(() => _confirming = false);

    if (erreur != null) {
      showAppSnackBar(
        context,
        erreur == 'noActiveAccount' ? l10n.noActiveAccount : l10n.importConfirmError,
        type: SnackType.error,
      );
      return;
    }

    setState(() {
      _summary = _buildSummary(resolvedPreview);
      // Support de « Annuler cet import » : le contrôleur expose l'ID de lot
      // seulement APRÈS une écriture réussie (cf. AccountController).
      _lastBatchId = widget.controller.lastImportBatchId;
      _step = _ImportStep.done;
    });
  }

  /// Annule l'import tout juste confirmé : confirmation, appel du backend, puis
  /// retour au compte (rafraîchi). Sur échec, reste sur l'étape finale avec un
  /// message d'erreur (l'import n'est pas perdu).
  Future<void> _undoImport() async {
    final batchId = _lastBatchId;
    if (batchId == null) return;
    final l10n = AppLocalizations.of(context)!;
    final movementsAdded = _summary?.movementsAdded ?? 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.importUndoDialogTitle),
        content: Text(l10n.importUndoDialogMessage(movementsAdded)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.importUndoConfirmButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _undoing = true);
    try {
      final removed = await widget.controller.undoStatementImport(
        accountId: widget.accountId,
        batchId: batchId,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        l10n.importUndoSuccess(removed),
        type: SnackType.success,
      );
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _undoing = false);
      showAppSnackBar(context, l10n.importUndoError, type: SnackType.error);
    }
  }

  _ImportSummaryData _buildSummary(ImportPreview resolvedPreview) {
    // Positions RÉELLEMENT ouvertes créées : on exclut les lignes soldées
    // (closedLine — clôturées à 0, masquées) pour ne pas gonfler le compte.
    final createdSymbols = resolvedPreview.newAssets
        .where((a) => a.proposedSymbol != null && !a.closedLine)
        .map((a) => a.proposedSymbol!)
        .toSet();
    final legacy = resolvedPreview.legacySymbols.toSet();
    final reprojected = resolvedPreview.projectedDeltas
        .where(
          (d) =>
              d.symbol != null &&
              !legacy.contains(d.symbol) &&
              !createdSymbols.contains(d.symbol),
        )
        .map((d) => d.symbol!)
        .toList();

    return _ImportSummaryData(
      movementsAdded: resolvedPreview.toCreate.length,
      positionsCreated: createdSymbols.length,
      reprojectedSymbols: reprojected,
      legacySymbols: resolvedPreview.legacySymbols,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.importPageTitle(widget.accountName),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: l10n.backTooltip,
          onPressed: _goBack,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ResponsiveBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStepIndicator(l10n),
              _buildStep(l10n),
            ],
          ),
        ),
      ),
    );
  }

  /// Séquence réelle des étapes du parcours courant, pour un indicateur de
  /// progression qui ne MENT pas selon le chemin : Bourse Direct saute la
  /// configuration du format (profil pré-rempli) et l'étape de résolution
  /// n'existe que si le relevé apporte des actifs neufs non résolus.
  List<_ImportStep> _pathSteps() {
    final preview = _preview;
    final needsResolve =
        preview != null && preview.newAssets.any((a) => a.proposedSymbol == null);
    return [
      _ImportStep.pickFile,
      if (_profileChoice == _ImportProfileChoice.genericManual)
        _ImportStep.configureProfile,
      _ImportStep.preview,
      if (needsResolve) _ImportStep.resolveAssets,
      _ImportStep.done,
    ];
  }

  /// « Étape X sur Y » + barre de progression, cohérents avec [_pathSteps].
  Widget _buildStepIndicator(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final steps = _pathSteps();
    var index = steps.indexOf(_step);
    if (index < 0) index = 0;
    final current = index + 1;
    final total = steps.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.importStepIndicator(current, total),
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : current / total,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(AppLocalizations l10n) {
    switch (_step) {
      case _ImportStep.pickFile:
        return _buildPickFileStep(l10n);
      case _ImportStep.configureProfile:
        return _buildConfigureProfileStep(l10n);
      case _ImportStep.preview:
        return _buildPreviewStep(l10n);
      case _ImportStep.resolveAssets:
        return _buildResolveAssetsStep(l10n);
      case _ImportStep.done:
        return _buildDoneStep(l10n);
    }
  }

  // ---- Étape 1 ----

  Widget _buildPickFileStep(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.importStep1Heading, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),

        Text(l10n.importProfileSectionTitle, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<_ImportProfileChoice>(
          segments: [
            ButtonSegment(
              value: _ImportProfileChoice.genericManual,
              label: Text(l10n.importProfileGenericLabel),
            ),
            ButtonSegment(
              value: _ImportProfileChoice.bourseDirect,
              label: Text(l10n.importProfileBourseDirectLabel),
            ),
          ],
          selected: {_profileChoice},
          onSelectionChanged: _loadingPreview
              ? null
              : (selection) => setState(() => _profileChoice = selection.first),
        ),
        const SizedBox(height: 16),

        Text(
          _profileChoice == _ImportProfileChoice.bourseDirect
              ? l10n.importPickFileHintBourseDirect
              : l10n.importPickFileHint,
        ),
        const SizedBox(height: 24),
        if (_previewError != null) ...[
          Text(
            _previewError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
        ],
        _loadingPreview
            ? const Center(child: CircularProgressIndicator())
            : FilledButton.icon(
                onPressed: _pickFile,
                icon: const Icon(Icons.upload_file),
                label: Text(l10n.importPickFileButton),
              ),
      ],
    );
  }

  // ---- Étape 2 ----

  Widget _buildConfigureProfileStep(AppLocalizations l10n) {
    final labels = _columnLabels(l10n);
    final kindLabels = _distinctKindLabels;
    for (final label in kindLabels) {
      _kindMapping.putIfAbsent(label, () => null);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.importStep2Heading, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(_fileLabel, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),

        Text(l10n.importFileFormatSectionTitle, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _delimiter,
          decoration: InputDecoration(labelText: l10n.importDelimiterLabel, isDense: true),
          items: [
            DropdownMenuItem(value: ';', child: Text(l10n.importDelimiterSemicolon)),
            DropdownMenuItem(value: ',', child: Text(l10n.importDelimiterComma)),
            DropdownMenuItem(value: '\t', child: Text(l10n.importDelimiterTab)),
            DropdownMenuItem(value: '|', child: Text(l10n.importDelimiterPipe)),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _delimiter = v);
            _reparse();
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<Encoding>(
          initialValue: _encoding,
          decoration: InputDecoration(labelText: l10n.importEncodingLabel, isDense: true),
          items: [
            DropdownMenuItem(value: latin1, child: Text(l10n.importEncodingLatin1)),
            DropdownMenuItem(value: utf8, child: Text(l10n.importEncodingUtf8)),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _encoding = v);
            _reparse();
          },
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _hasHeaderRow,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(l10n.importHasHeaderLabel),
          onChanged: (v) {
            setState(() => _hasHeaderRow = v ?? true);
            _reparse();
          },
        ),

        const SizedBox(height: 16),
        Text(l10n.importDateFormatSectionTitle, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _dateSeparator,
          decoration: InputDecoration(labelText: l10n.importDateSeparatorLabel, isDense: true),
          items: const [
            DropdownMenuItem(value: '/', child: Text('/')),
            DropdownMenuItem(value: '-', child: Text('-')),
            DropdownMenuItem(value: '.', child: Text('.')),
          ],
          onChanged: (v) => setState(() => _dateSeparator = v ?? '/'),
        ),
        SwitchListTile(
          value: _dayFirst,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.importDayFirstLabel),
          onChanged: (v) => setState(() => _dayFirst = v),
        ),
        SwitchListTile(
          value: _fourDigitYear,
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.importFourDigitYearLabel),
          onChanged: (v) => setState(() => _fourDigitYear = v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<DecimalSeparator>(
          initialValue: _decimalSeparator,
          decoration: InputDecoration(labelText: l10n.importDecimalSeparatorLabel, isDense: true),
          items: [
            DropdownMenuItem(
              value: DecimalSeparator.comma,
              child: Text(l10n.importDecimalSeparatorComma),
            ),
            DropdownMenuItem(
              value: DecimalSeparator.dot,
              child: Text(l10n.importDecimalSeparatorDot),
            ),
          ],
          onChanged: (v) => setState(() => _decimalSeparator = v ?? DecimalSeparator.comma),
        ),

        const SizedBox(height: 16),
        if (_configureError != null) ...[
          Text(
            l10n.importParseEmptyError,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 16),
        ] else ...[
          Text(l10n.importPreviewRowsTitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _buildRawPreviewTable(labels),
          const SizedBox(height: 16),

          Text(
            l10n.importColumnMappingSectionTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          _columnDropdown(l10n, MovementField.date, l10n.importFieldDate),
          _columnDropdown(l10n, MovementField.kindLabel, l10n.importFieldKind),
          _columnDropdown(l10n, MovementField.isin, l10n.importFieldIsin),
          _columnDropdown(l10n, MovementField.symbol, l10n.importFieldSymbol),
          _columnDropdown(l10n, MovementField.label, l10n.importFieldLabel),
          _columnDropdown(l10n, MovementField.quantity, l10n.importFieldQuantity),
          _columnDropdown(l10n, MovementField.unitPrice, l10n.importFieldUnitPrice),
          _columnDropdown(l10n, MovementField.amount, l10n.importFieldAmount),
          _columnDropdown(l10n, MovementField.fee, l10n.importFieldFee),
          _columnDropdown(l10n, MovementField.currency, l10n.importFieldCurrency),
          _columnDropdown(l10n, MovementField.tax, l10n.importFieldTax),
          _columnDropdown(
            l10n,
            MovementField.operationReference,
            l10n.importFieldOperationReference,
          ),

          if (kindLabels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              l10n.importKindLexiconSectionTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.importKindLexiconHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final label in kindLabels) _kindLexiconRow(l10n, label),
          ],
        ],

        const SizedBox(height: 24),
        if (_previewError != null) ...[
          Text(
            _previewError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          const SizedBox(height: 8),
        ],
        _loadingPreview
            ? const Center(child: CircularProgressIndicator())
            : FilledButton(
                onPressed: _canContinueToPreview ? _runPreview : null,
                child: Text(l10n.importContinueToPreviewButton),
              ),
      ],
    );
  }

  Widget _buildRawPreviewTable(List<String> labels) {
    if (labels.isEmpty) return const SizedBox.shrink();
    final rows = _dataRows.take(5).toList();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 32,
        dataRowMinHeight: 28,
        dataRowMaxHeight: 36,
        columns: [
          for (final l in labels)
            DataColumn(
              label: Text(
                l,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
        ],
        rows: [
          for (final row in rows)
            DataRow(
              cells: [
                for (var i = 0; i < labels.length; i++)
                  DataCell(
                    Text(
                      i < row.length ? row[i] : '',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _columnDropdown(AppLocalizations l10n, MovementField field, String labelText) {
    final labels = _columnLabels(l10n);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<int?>(
        initialValue: _columnSelection[field],
        isExpanded: true,
        // Cibles tactiles : sur mobile, on renonce à `isDense` pour garantir
        // une hauteur confortable (~48 dp) sur les 13 menus de mapping ; la
        // densité desktop est préservée.
        decoration: InputDecoration(labelText: labelText, isDense: _isDesktop),
        items: [
          DropdownMenuItem<int?>(value: null, child: Text(l10n.importColumnNotMapped)),
          for (var i = 0; i < labels.length; i++)
            DropdownMenuItem<int?>(
              value: i,
              child: Text(labels[i], overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => _columnSelection[field] = v),
      ),
    );
  }

  Widget _kindLexiconRow(AppLocalizations l10n, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(label, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<TransactionKind?>(
              initialValue: _kindMapping[label],
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                DropdownMenuItem<TransactionKind?>(
                  value: null,
                  child: Text(l10n.importKindNotMapped),
                ),
                for (final k in TransactionKind.values.where((k) => !k.isSystemGenerated))
                  DropdownMenuItem<TransactionKind?>(value: k, child: Text(_kindLabel(l10n, k))),
              ],
              onChanged: (v) => setState(() => _kindMapping[label] = v),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Étape 3 ----

  Widget _buildPreviewStep(AppLocalizations l10n) {
    final preview = _preview;
    if (preview == null) return const SizedBox.shrink();

    if (preview.toCreate.isEmpty) {
      // Rien à créer, MAIS on ne masque pas les rejets/OST (P1) : un relevé
      // 100 % rejeté (natures d'opération non mappées → unknownKind/missingKind)
      // ou ne portant qu'une OST doit toujours montrer POURQUOI. Groupes rendus
      // à l'identique de la branche principale via [_rejectGroups].
      final rejectGroups = _rejectGroups(l10n, preview);
      final String emptyMessage;
      if (preview.rejects.isNotEmpty) {
        emptyMessage = l10n.importNoMovementsButRejected(preview.rejects.length);
      } else if (preview.duplicates.isNotEmpty) {
        emptyMessage = l10n.importNoNewMovements;
      } else {
        emptyMessage = l10n.importNothingToImport;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.importStep3Heading, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          Text(emptyMessage),
          if (rejectGroups.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...rejectGroups,
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.importCloseButton),
          ),
        ],
      );
    }

    final theme = Theme.of(context);
    final needsResolve =
        preview.newAssets.any((a) => a.proposedSymbol == null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.importStep3Heading, style: theme.textTheme.titleMedium),
        const SizedBox(height: 16),

        // Delta projeté « avant → après » : l'info la plus importante avant
        // d'écrire dans le journal, donc placée en tête.
        _buildDeltaSection(l10n, preview),

        ExpansionTile(
          initiallyExpanded: true,
          tilePadding: EdgeInsets.zero,
          title: Text(l10n.importGroupToCreate(preview.toCreate.length)),
          children: _cappedMovementTiles(l10n, preview.toCreate),
        ),

        // OST à revoir (dépliées, en avertissement) juste après « à créer » :
        // proches du delta qu'elles nuancent silencieusement.
        ..._ostRejectGroup(l10n, preview),

        _buildNewAssetsGroup(l10n, preview),

        if (preview.duplicates.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(l10n.importGroupDuplicates(preview.duplicates.length)),
            children: _cappedMovementTiles(l10n, preview.duplicates),
          ),

        // Rejets techniques (repliés) tout en bas : bruit de diagnostic.
        ..._techRejectGroup(l10n, preview),

        const SizedBox(height: 24),
        // Écrit directement dans le journal si aucun actif neuf ne reste à
        // résoudre (P2.1) : le libellé le dit alors (« Confirmer l'import »),
        // sinon « Continuer » mène à l'étape de résolution.
        FilledButton(
          onPressed: needsResolve ? _enterResolveAssets : _confirmImport,
          child: Text(
            needsResolve ? l10n.importContinueButton : l10n.importConfirmButton,
          ),
        ),
      ],
    );
  }

  /// Groupes de rejets de l'aperçu, PARTAGÉS entre la branche principale et la
  /// branche « rien à créer » (P1) : les OST à revoir (dépliées, en
  /// avertissement — elles faussent SILENCIEUSEMENT le delta) puis les rejets
  /// purement techniques (repliés). Factorise la logique de split
  /// OST/technique et [_cappedMovementTiles] pour ne la dupliquer nulle part.
  /// Carte des OST à revoir (dépliée, en avertissement — elles faussent
  /// SILENCIEUSEMENT le delta) : rendue juste après « à créer », proche du
  /// delta qu'elle nuance. Liste vide si aucune OST. Partagée avec la branche
  /// « rien à créer » (P1) via [_rejectGroups].
  List<Widget> _ostRejectGroup(AppLocalizations l10n, ImportPreview preview) {
    final theme = Theme.of(context);
    final ostRejects = preview.rejects
        .where((m) => m.rejectReason == 'corporateActionReview')
        .toList();
    if (ostRejects.isEmpty) return const [];
    return [
      Card(
        margin: const EdgeInsets.symmetric(vertical: 8),
        color: theme.colorScheme.errorContainer,
        child: ExpansionTile(
          initiallyExpanded: true,
          shape: const Border(),
          collapsedShape: const Border(),
          leading: Icon(
            Icons.warning_amber_rounded,
            color: theme.colorScheme.error,
          ),
          title: Text(
            l10n.importCorporateActionGroupTitle(ostRejects.length),
            style: TextStyle(
              color: theme.colorScheme.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.importCorporateActionWarning,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            ..._cappedMovementTiles(l10n, ostRejects),
          ],
        ),
      ),
    ];
  }

  /// Groupe des rejets purement TECHNIQUES (replié) : simple bruit de
  /// diagnostic, rendu tout en BAS de l'aperçu (sous les doublons). Liste vide
  /// si aucun rejet technique. Partagé avec la branche « rien à créer » (P1).
  List<Widget> _techRejectGroup(AppLocalizations l10n, ImportPreview preview) {
    final techRejects = preview.rejects
        .where((m) => m.rejectReason != 'corporateActionReview')
        .toList();
    if (techRejects.isEmpty) return const [];
    return [
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(l10n.importGroupRejects(techRejects.length)),
        children: _cappedMovementTiles(l10n, techRejects),
      ),
    ];
  }

  /// OST + rejets techniques à la suite : utilisé UNIQUEMENT par la branche
  /// « rien à créer » (P1), où tous les rejets sont regroupés sous le message.
  /// La branche principale place l'OST près du delta et les rejets techniques
  /// en bas — cf. [_ostRejectGroup] / [_techRejectGroup].
  List<Widget> _rejectGroups(AppLocalizations l10n, ImportPreview preview) =>
      [..._ostRejectGroup(l10n, preview), ..._techRejectGroup(l10n, preview)];

  Widget _buildDeltaSection(AppLocalizations l10n, ImportPreview preview) {
    final theme = Theme.of(context);
    final legacy = preview.legacySymbols.toSet();
    final securityDeltas =
        preview.projectedDeltas.where((d) => d.symbol != null).toList();
    final cashDeltas =
        preview.projectedDeltas.where((d) => d.symbol == null).toList();
    final hasOstRejects =
        preview.rejects.any((m) => m.rejectReason == 'corporateActionReview');

    // Actifs NEUFS (symbole pas encore résolu) : le contrôleur ne produit aucun
    // ProjectedDelta titre pour eux (leur symbole est null au calcul du delta),
    // la moitié « positions » resterait donc vide alors que le titre la promet.
    // On projette ici leurs mouvements entrants (position de départ = 0) — sans
    // double comptage : on ne lit QUE les mouvements à symbole null (les
    // symboles déjà connus sont déjà dans [securityDeltas]).
    final newAssetDeltas = _projectedNewAssetDeltas(preview);

    if (securityDeltas.isEmpty && cashDeltas.isEmpty && newAssetDeltas.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.trending_up,
                  size: 18,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.importDeltaSectionTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final d in securityDeltas)
              if (legacy.contains(d.symbol))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    l10n.importLegacyWarning(d.symbol!),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    l10n.importDeltaQuantity(
                      d.symbol!,
                      d.quantityBefore ?? '0',
                      d.quantityAfter ?? '0',
                    ),
                    style: TextStyle(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                if (d.averageBuyPriceAfter != null &&
                    d.averageBuyPriceAfter != 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 2),
                    child: Text(
                      l10n.importDeltaPru(
                        Formatters.formatMoney(
                          d.averageBuyPriceBefore ?? 0,
                          _accountCurrency,
                        ),
                        Formatters.formatMoney(
                          d.averageBuyPriceAfter!,
                          _accountCurrency,
                        ),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
              ],
            // Lignes des actifs NEUFS (position de départ = 0) — cf.
            // [_projectedNewAssetDeltas].
            for (final d in newAssetDeltas) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  l10n.importDeltaQuantity(d.label, '0', d.quantityAfter),
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              if (d.pru != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 2),
                  child: Text(
                    l10n.importDeltaNewAssetPru(
                      Formatters.formatMoney(d.pru!, _accountCurrency),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
            ],
            for (final d in cashDeltas)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  l10n.importDeltaCash(
                    Formatters.formatMoney(d.cashBefore ?? 0, _accountCurrency),
                    Formatters.formatMoney(d.cashAfter ?? 0, _accountCurrency),
                  ),
                  style: TextStyle(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            if (hasOstRejects) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.importDeltaCorporateActionCaveat,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Projette une ligne de delta « 0 → N titres » par ACTIF NEUF (symbole pas
  /// encore résolu à l'aperçu), à partir de ses mouvements entrants.
  ///
  /// Pour chaque [NewAssetCandidate], on rassemble les mouvements de
  /// [ImportPreview.toCreate] qui le concernent — UNIQUEMENT ceux dont la
  /// transaction n'a pas de symbole (`tx.symbol == null`), pour ne PAS
  /// double-compter avec [ImportPreview.projectedDeltas] (déjà rendus par
  /// [securityDeltas]) — appariés par ISIN si présent, sinon par libellé. La
  /// projection ([projectPosition], même moteur que le contrôleur) donne la
  /// quantité exacte et le PRU. Position de départ = 0 (l'actif est neuf).
  /// Les actifs sans quantité entrante (> 0) sont omis (rien à montrer).
  List<({String label, String quantityAfter, double? pru})>
      _projectedNewAssetDeltas(ImportPreview preview) {
    final result = <({String label, String quantityAfter, double? pru})>[];
    for (final asset in preview.newAssets) {
      final txs = <AssetTransaction>[
        for (final m in preview.toCreate)
          if (m.transaction != null && m.transaction!.symbol == null)
            if (asset.isin != null
                ? m.isin == asset.isin
                : m.label == asset.label)
              m.transaction!,
      ];
      if (txs.isEmpty) continue;
      final proj = projectPosition(txs);
      if (proj.quantity <= Decimal.zero) continue;
      result.add((
        label: asset.label,
        quantityAfter: proj.quantity.toString(),
        pru: proj.averagePrice,
      ));
    }
    return result;
  }

  /// Tuiles de mouvement d'un groupe, plafonnées à [_groupDisplayCap] avec une
  /// ligne « … et N autre(s) » (le reste n'est jamais masqué en silence).
  List<Widget> _cappedMovementTiles(
    AppLocalizations l10n,
    List<ImportedMovement> movements,
  ) {
    final tiles = <Widget>[
      for (final m in movements.take(_groupDisplayCap)) _movementTile(l10n, m),
    ];
    if (movements.length > _groupDisplayCap) {
      tiles.add(_moreRow(l10n, movements.length - _groupDisplayCap));
    }
    return tiles;
  }

  Widget _moreRow(AppLocalizations l10n, int remaining) => ListTile(
        dense: true,
        title: Text(
          l10n.importGroupMore(remaining),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );

  /// Groupe « Nouveaux actifs » de l'aperçu : ne présente QUE les positions
  /// OUVERTES (net > 0). Les lignes soldées ([NewAssetCandidate.closedLine] :
  /// titre clôturé, droit consommé) sont bien matérialisées pour l'intégrité du
  /// journal mais n'apparaissent PAS ici — ce ne sont pas de nouvelles positions
  /// détenues (cohérent avec le modèle de valorisation : seul le détenu est
  /// valorisé). Groupe masqué s'il ne reste aucun actif ouvert.
  Widget _buildNewAssetsGroup(AppLocalizations l10n, ImportPreview preview) {
    final open = preview.newAssets.where((a) => !a.closedLine).toList();
    if (open.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: EdgeInsets.zero,
      title: Text(l10n.importGroupNewAssets(open.length)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(l10n.importNewAssetsHint, style: theme.textTheme.bodySmall),
        ),
        for (final a in open.take(_groupDisplayCap))
          ListTile(
            dense: true,
            title: Text(a.label),
            subtitle: Text(a.isin ?? ''),
            trailing: Text(a.proposedSymbol ?? l10n.importNewAssetPending),
          ),
        if (open.length > _groupDisplayCap)
          _moreRow(l10n, open.length - _groupDisplayCap),
      ],
    );
  }

  Widget _movementTile(AppLocalizations l10n, ImportedMovement m) {
    if (m.isRejected) {
      return ListTile(
        dense: true,
        title: Text(m.label ?? m.isin ?? l10n.notAvailable),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_rejectReasonLabel(l10n, m.rejectReason!)),
            _sourceRowRef(l10n, m),
          ],
        ),
      );
    }
    final tx = m.transaction!;
    // Libellé du mouvement d'ABORD (nom lisible du titre), plus parlant que le
    // symbole/ISIN (retour auteur). Le symbole marché n'est ajouté entre
    // parenthèses que s'il apporte une info : vrai ticker distinct du libellé
    // ET de l'ISIN — on masque le repli « non coté » (symbole == ISIN).
    final name = m.label ?? tx.symbol ?? m.isin ?? l10n.cashLabel;
    final sym = tx.symbol;
    final showSym = sym != null && sym != name && sym != m.isin;
    final symbolLabel = showSym ? '$name ($sym)' : name;
    final currency = tx.currency;
    final unitPrice = _money(tx.unitPrice, currency);
    final total = _money(tx.amount, currency);
    final detail = tx.quantity != null
        ? '${tx.quantity} × ${unitPrice ?? '?'}${total != null ? ' · $total' : ''}'
        : (total ?? '');
    return ListTile(
      dense: true,
      title: Text('$symbolLabel — ${_kindLabel(l10n, tx.kind)}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_formatDate(tx.date)} · $detail'),
          _sourceRowRef(l10n, m),
        ],
      ),
    );
  }

  /// Rappel COMPACT de la ligne source d'un mouvement (candidat, doublon ou
  /// rejet) : « Ligne N » (numéro 1-based, lisible) SEUL — sans écho des
  /// cellules brutes du relevé, retiré (retour auteur, passe visuelle : cet
  /// écho surchargeait l'interface). En [bodySmall] atténué.
  Widget _sourceRowRef(AppLocalizations l10n, ImportedMovement m) {
    final theme = Theme.of(context);
    return Text(
      l10n.importSourceRowRef(m.sourceRowIndex),
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  // ---- Étape 4 ----

  Widget _buildResolveAssetsStep(AppLocalizations l10n) {
    final preview = _preview;
    if (preview == null) return const SizedBox.shrink();
    final unresolved = preview.newAssets.where((a) => a.proposedSymbol == null).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.importStep4Heading, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(l10n.importResolveHint),
        const SizedBox(height: 16),
        if (_searchFailedKeys.isNotEmpty) _buildSearchFailedBanner(l10n),
        for (final asset in unresolved) _buildResolveAssetRow(l10n, asset),
        const SizedBox(height: 16),
        _confirming || _verifyingSymbols
            ? const Center(child: CircularProgressIndicator())
            : FilledButton(
                onPressed:
                    _allNewAssetsResolved ? _onConfirmResolveAssets : null,
                child: Text(l10n.importConfirmButton),
              ),
      ],
    );
  }

  /// Ligne de résolution d'UN nouvel actif, à trois états :
  ///  - EN COURS (clé dans [_resolvingKeys]) : champ désactivé + indicateur de
  ///    recherche, aucune case « non coté » (on ne sait pas encore).
  ///  - TROUVÉ (champ non vide) : symbole pré-rempli et modifiable, PAS de
  ///    message « introuvable ».
  ///  - SANS SYMBOLE (recherche finie OU échouée, champ vide) : la case
  ///    « non coté » (repli ISIN) est proposée pour tout candidat porteur d'un
  ///    ISIN — y compris en échec réseau (P2.3), où le bandeau « Réessayer »
  ///    reste affiché mais n'interdit plus de débloquer. Vider un champ trouvé
  ///    la fait réapparaître.
  /// En repli, le champ symbole est désactivé (symbole == ISIN, cf.
  /// [_applyResolvedSymbols]).
  Widget _buildResolveAssetRow(AppLocalizations l10n, NewAssetCandidate asset) {
    final theme = Theme.of(context);
    final key = asset.isin ?? asset.label;
    final isFallback = _fallbackIsinKeys.contains(key);
    final isResolving = _resolvingKeys.contains(key);
    final hasSymbol =
        (_newAssetSymbolControllers[key]?.text.trim().isNotEmpty ?? false);
    // La case « non coté » est proposée dès que la recherche n'est plus EN COURS
    // et qu'aucun symbole n'a été trouvé/saisi (ou si le repli est déjà actif).
    // COEXISTENCE avec l'échec réseau (P2.3) : on la propose MÊME quand la
    // recherche a échoué (searchFailed) pour un candidat porteur d'un ISIN — la
    // panne reste signalée par le bandeau « Réessayer », mais on ne l'utilise
    // plus pour EMPRISONNER l'utilisateur : il peut réessayer, saisir un
    // symbole, OU cocher « non coté » pour débloquer l'import hors-ligne.
    final showFallback = asset.isin != null &&
        !isResolving &&
        (!hasSymbol || isFallback);
    // Place + avertissement rang 3 (correctifs 1/2) : uniquement pour un hit
    // auto-résolu encore en place (une saisie manuelle les efface, cf.
    // onChanged) et jamais en repli (le champ ne porte alors plus ce symbole).
    final venue = !isFallback ? _resolvedVenueByKey[key] : null;
    final isLowConfidence = !isFallback && _lowConfidenceVenueKeys.contains(key);
    final isInvalid = _invalidSymbolKeys.contains(key);
    final isUnverifiable = _unverifiableSymbolKeys.contains(key);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _newAssetSymbolControllers[key],
            enabled: !isFallback && !isResolving,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: '${asset.label} — ${l10n.importNewAssetSymbolLabel}',
              border: const OutlineInputBorder(),
              isDense: true,
              helperText: isResolving ? l10n.importResolvingLabel : asset.isin,
              errorText: isInvalid ? l10n.importSymbolNotFoundError : null,
              suffixIcon: isResolving
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            onChanged: (_) => setState(() {
              // La saisie change : la place/l'avertissement du hit auto-résolu
              // et un précédent résultat de vérification ne sont plus valables
              // pour ce nouveau texte.
              _resolvedVenueByKey.remove(key);
              _lowConfidenceVenueKeys.remove(key);
              _invalidSymbolKeys.remove(key);
              _unverifiableSymbolKeys.remove(key);
            }),
          ),
          if (venue != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                l10n.importResolvedVenueLabel(venue),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (isLowConfidence)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      l10n.importLowConfidenceVenueWarning,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          if (isUnverifiable)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                l10n.importSymbolVerificationUnavailable,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (showFallback)
            CheckboxListTile(
              value: isFallback,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              title: Text(l10n.importFallbackIsinLabel),
              subtitle: Text(
                l10n.importFallbackIsinHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _fallbackIsinKeys.add(key);
                  // Le repli « non coté » n'est jamais vérifié (par
                  // construction, ces titres n'existent pas chez la source) :
                  // un résultat de vérification antérieur n'a plus de sens.
                  _invalidSymbolKeys.remove(key);
                  _unverifiableSymbolKeys.remove(key);
                } else {
                  _fallbackIsinKeys.remove(key);
                }
              }),
            ),
        ],
      ),
    );
  }

  /// Bandeau discret signalant une recherche ISIN indisponible (panne réseau),
  /// avec un bouton « Réessayer » qui relance les recherches échouées. Distinct
  /// du repli « non coté » : ici, l'existence du titre reste inconnue.
  Widget _buildSearchFailedBanner(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 20,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.importSearchUnavailable,
                style: TextStyle(color: theme.colorScheme.onTertiaryContainer),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _retryFailedSearches,
              child: Text(l10n.importSearchRetryButton),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Étape 5 ----

  Widget _buildDoneStep(AppLocalizations l10n) {
    final summary = _summary;
    if (summary == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.importDoneHeading, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        Text(l10n.importSummaryMovementsAdded(summary.movementsAdded)),
        if (summary.positionsCreated > 0) ...[
          const SizedBox(height: 4),
          Text(l10n.importSummaryPositionsCreated(summary.positionsCreated)),
        ],
        if (summary.reprojectedSymbols.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(l10n.importSummaryReprojected(summary.reprojectedSymbols.join(', '))),
        ],
        if (summary.legacySymbols.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(l10n.importSummaryLegacyKept(summary.legacySymbols.join(', '))),
        ],
        if (_lastBatchId != null) ...[
          const SizedBox(height: 16),
          Text(
            l10n.importUndoExplanation,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 24),
        if (_undoing)
          const Center(child: CircularProgressIndicator())
        else
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.importDoneCloseButton),
              ),
              if (_lastBatchId != null)
                OutlinedButton.icon(
                  onPressed: _undoImport,
                  icon: const Icon(Icons.undo, size: 18),
                  label: Text(l10n.importUndoButton),
                ),
            ],
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers d'affichage
  // ---------------------------------------------------------------------------

  String get _accountCurrency {
    for (final a in widget.controller.accounts) {
      if (a.id == widget.accountId) return a.currency;
    }
    return widget.controller.activeAccount?.currency ?? 'EUR';
  }

  /// Formate une valeur monétaire brute (String de précision, décimale « . »)
  /// dans sa devise ; `null`/non parsable → `null` (l'appelant décide du repli).
  String? _money(String? raw, String currency) {
    if (raw == null || raw.trim().isEmpty) return null;
    final v = double.tryParse(raw.trim());
    if (v == null) return raw.trim();
    return Formatters.formatMoney(v, currency);
  }

  String _formatDate(DateTime dt) => DateFormat.yMd(
        Localizations.localeOf(context).languageCode,
      ).format(dt);

  String _kindLabel(AppLocalizations l10n, TransactionKind k) {
    switch (k) {
      case TransactionKind.buy:
        return l10n.transactionKindBuy;
      case TransactionKind.sell:
        return l10n.transactionKindSell;
      case TransactionKind.dividend:
        return l10n.transactionKindDividend;
      case TransactionKind.deposit:
        return l10n.transactionKindDeposit;
      case TransactionKind.withdrawal:
        return l10n.transactionKindWithdrawal;
      case TransactionKind.openingBalance:
        return l10n.transactionKindOpeningBalance;
      case TransactionKind.adjustment:
        return l10n.transactionKindAdjustment;
      case TransactionKind.interest:
        return l10n.transactionKindInterest;
      case TransactionKind.charge:
        return l10n.transactionKindCharge;
      case TransactionKind.transferOut:
        return l10n.transactionKindTransferOut;
    }
  }

  String _rejectReasonLabel(AppLocalizations l10n, String reason) {
    switch (reason) {
      case 'missingKind':
        return l10n.importRejectMissingKind;
      case 'unknownKind':
        return l10n.importRejectUnknownKind;
      case 'invalidDate':
        return l10n.importRejectInvalidDate;
      case 'invalidQuantity':
        return l10n.importRejectInvalidQuantity;
      case 'invalidUnitPrice':
        return l10n.importRejectInvalidUnitPrice;
      case 'invalidFee':
        return l10n.importRejectInvalidFee;
      case 'invalidAmount':
        return l10n.importRejectInvalidAmount;
      case 'missingAssetIdentity':
        return l10n.importRejectMissingAssetIdentity;
      case 'missingAmount':
        return l10n.importRejectMissingAmount;
      case 'corporateActionReview':
        return l10n.importRejectCorporateActionReview;
      default:
        return l10n.importRejectGeneric;
    }
  }
}

/// Résumé best-effort affiché à l'étape 5 : `positionsCreated`/
/// `reprojectedSymbols` sont dérivés de la prévisualisation PATCHÉE côté UI,
/// pas d'un retour détaillé de LedgerService.importMovements (qui ne renvoie
/// qu'un compte agrégé) — un candidat orphelin théorique (aucun mouvement
/// rattaché) resterait compté ici sans être réellement créé, cf. commentaire
/// de AccountController.confirmStatementImport.
class _ImportSummaryData {
  final int movementsAdded;
  final int positionsCreated;
  final List<String> reprojectedSymbols;
  final List<String> legacySymbols;

  const _ImportSummaryData({
    required this.movementsAdded,
    required this.positionsCreated,
    required this.reprojectedSymbols,
    required this.legacySymbols,
  });
}

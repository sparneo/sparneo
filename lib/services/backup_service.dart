// lib/services/backup_service.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:portfolio_tracker/services/account_storage.dart';

/// Exception levée quand un fichier de sauvegarde est invalide ou
/// incompatible.
class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

/// Gère la sauvegarde (export) et la restauration (import) de l'ensemble
/// des données de l'application sous forme d'un fichier JSON partageable.
class BackupService {
  /// Signature écrite dans tout NOUVEL export.
  static const String _magic = 'sparneo_backup';

  /// Ancienne signature (nom de code historique de l'app). Conservée en
  /// LECTURE SEULE pour que les sauvegardes réelles déjà produites restent
  /// importables ; jamais réémise à l'export.
  static const String _legacyMagic = 'portfolio_tracker_backup';

  /// Signatures acceptées à l'IMPORT (nouvelle + héritage).
  static const Set<String> _acceptedMagics = {_magic, _legacyMagic};

  /// Version du format de BACKUP.
  ///
  /// v2 (additif) : le journal peut désormais contenir les kinds
  /// `openingBalance` et `adjustment`. Le bump est la protection CENTRALE de
  /// la sûreté ascendante : une version ANCIENNE de l'app (dont `_version` == 1)
  /// relisant un backup v2 le REJETTE au contrôle `version > _version`
  /// ci-dessous (« Sauvegarde créée par une version plus récente ») AU LIEU de
  /// coercer un `adjustment` inconnu en `buy` (donnée fausse). En sens inverse,
  /// cette version relit sans erreur un backup v1 (rétro-compat lecture).
  ///
  /// v3 (additif, lot cash) : le journal peut désormais contenir les kinds
  /// `interest` et `charge`, et les variantes ESPÈCES (`symbol=null`)
  /// d'`openingBalance`/`adjustment`. MÊME logique de sûreté ascendante : un
  /// backup v3 (susceptible de contenir ces kinds) est rejeté DÈS LE CONTRÔLE
  /// `version > _version` par une app v2, au lieu de dépendre de la seule
  /// rejection par kind inconnu (défense en profondeur + étiquetage honnête du
  /// format). Bump en lockstep avec l'export fiscal v3.
  ///
  /// v3 (précision, 2026-07-09) : le format v3 inclut AUSSI la clé OPTIONNELLE
  /// settlementCurrency des mouvements (devise de règlement de amount, schéma
  /// v7) — présente dès l'origine du format (jeu de démo, modèle
  /// AssetTransaction), mais que le pont SQLite perdait à l'export ET à
  /// l'import (bug corrigé, sans changement de format). PAS de bump : aucune
  /// build lisant v3 n'a jamais été distribuée (v3 est né non publié), la
  /// population qu'un v4 protégerait est vide, et les apps v1/v2 rejettent
  /// déjà tout v3 au contrôle de version. RÈGLE pour la suite : si une build
  /// écrivant la version N a été DISTRIBUÉE, toute extension du contenu
  /// possible du fichier exige le bump N+1 — on ne redéfinit un format en
  /// place qu'avant sa première diffusion.
  /// Les caches dérivés (derived_at, derived_cash*) ne sont PAS transportés,
  /// quelle que soit la version : l'import les reconstruit par VÉRIFICATION
  /// (cf. AccountStorage.importRawData, étape 8) — transporter un statut
  /// « réconcilié » reviendrait à croire le fichier là où on peut prouver.
  static const int _version = 3;

  final AccountStorage _storage;

  BackupService({AccountStorage? storage})
      : _storage = storage ?? AccountStorage();

  /// `file_picker` s'appuie sur un sous-processus externe (zenity/kdialog/
  /// qarma) pour ses dialogues desktop — absent (ou cassé en sandbox
  /// Flatpak) sur certaines machines Linux. Sur desktop on route donc les
  /// dialogues de fichiers vers `file_selector` (sélecteur GTK natif en
  /// process, via les portails XDG). Sur mobile, `file_selector` ne supporte
  /// pas `getSaveLocation` : on garde `file_picker` (Android SAF, inchangé).
  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  /// Construit le contenu JSON complet de la sauvegarde (avec métadonnées).
  Future<String> buildBackupJson() async {
    final data = await _storage.exportRawData();
    final payload = {
      'format': _magic,
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': data,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// Exporte les données dans un fichier puis ouvre la feuille de partage
  /// du système (enregistrer dans Drive, envoyer par mail, etc.).
  Future<void> exportAndShare() async {
    final json = await buildBackupJson();

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fileName = 'portfolio-backup-$stamp.json';

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(json);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json', name: fileName)],
      subject: 'Sauvegarde Sparneo',
    );
  }

  /// Ouvre le sélecteur du système pour enregistrer la sauvegarde à
  /// l'emplacement choisi par l'utilisateur (Téléchargements, Drive…).
  /// Le fichier est réellement écrit sur place. Retourne le chemin choisi,
  /// ou `null` si l'utilisateur annule.
  Future<String?> exportToFile() async {
    final json = await buildBackupJson();
    final bytes = Uint8List.fromList(utf8.encode(json));

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fileName = 'portfolio-backup-$stamp.json';

    if (_isDesktop) {
      // `file_selector` ne fait qu'obtenir l'emplacement choisi ; contrairement
      // à `FilePicker.saveFile(bytes:)`, l'écriture du fichier reste à notre
      // charge.
      final loc = await getSaveLocation(suggestedName: fileName);
      if (loc == null) return null;
      await File(loc.path).writeAsBytes(bytes);
      return loc.path;
    }

    return FilePicker.platform.saveFile(
      dialogTitle: 'Enregistrer la sauvegarde',
      fileName: fileName,
      bytes: bytes,
    );
  }

  /// Laisse l'utilisateur choisir un fichier de sauvegarde et restaure les
  /// données. Retourne `false` si l'utilisateur annule la sélection.
  ///
  /// ⚠️ Remplace l'intégralité des données existantes.
  Future<bool> pickAndImport() async {
    if (_isDesktop) {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'Sauvegarde Sparneo', extensions: ['json']),
        ],
      );
      if (file == null) return false;
      final content = await file.readAsString();
      await importFromJson(content);
      return true;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return false;

    final picked = result.files.single;
    final String content;
    if (picked.bytes != null) {
      content = utf8.decode(picked.bytes!);
    } else if (picked.path != null) {
      content = await File(picked.path!).readAsString();
    } else {
      throw BackupException('Impossible de lire le fichier sélectionné.');
    }

    await importFromJson(content);
    return true;
  }

  /// Valide et restaure les données depuis le contenu JSON d'une sauvegarde.
  Future<void> importFromJson(String content) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw BackupException('Le fichier n\'est pas un JSON valide.');
    }

    if (decoded is! Map ||
        !_acceptedMagics.contains(decoded['format']) ||
        decoded['data'] is! Map) {
      throw BackupException(
          'Ce fichier n\'est pas une sauvegarde Sparneo.');
    }

    final version = decoded['version'];
    if (version is int && version > _version) {
      throw BackupException(
          'Sauvegarde créée par une version plus récente de l\'application.');
    }

    // L'import est atomique (une seule transaction SQLite) : si le contenu est
    // référentiellement incohérent (ex. position orpheline dont le compte est
    // absent), la contrainte FK fait échouer et rollback l'intégralité — les
    // données existantes restent intactes. On habille l'exception SQLite brute
    // en BackupException pour remonter un message clair à l'utilisateur.
    try {
      await _storage.importRawData(
        Map<String, dynamic>.from(decoded['data'] as Map),
      );
    } on BackupException {
      rethrow;
    } catch (e) {
      throw BackupException(
          'Sauvegarde incohérente : restauration annulée, vos données existantes sont préservées.');
    }
  }
}

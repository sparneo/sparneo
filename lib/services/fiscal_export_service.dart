// lib/services/fiscal_export_service.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:portfolio_tracker/logic/fiscal_export.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/services/transaction_storage.dart';

/// Orchestration de l'export fiscal `sparneo-fiscal-export v1` (voir
/// `docs/sparneo-fiscal-export.md`) : lit les comptes/transactions/positions du
/// wallet courant, délègue la construction du contenu à [buildFiscalExport]
/// (fonction pure), puis soit partage un fichier temporaire via la feuille de
/// partage du système ([exportAndShare], même schéma que
/// [BackupService.exportAndShare]), soit laisse l'utilisateur choisir
/// l'emplacement d'enregistrement ([exportToFile], même schéma que
/// [BackupService.exportToFile] — nécessaire sur desktop où `Share.shareXFiles`
/// n'est pas supporté pour les fichiers, cf. Linux).
class FiscalExportService {
  /// Version applicative reportée dans `source.appVersion` de l'export
  /// (pubspec 0.1.0 ; pas de dépendance à package_info).
  static const String _appVersion = '0.1.0';

  final AccountStorage _accountStorage;
  final TransactionStorage _transactionStorage;

  FiscalExportService({
    AccountStorage? accountStorage,
    TransactionStorage? transactionStorage,
  })  : _accountStorage = accountStorage ?? AccountStorage(),
        _transactionStorage = transactionStorage ?? TransactionStorage();

  /// `file_picker` s'appuie sur un sous-processus externe (zenity/kdialog/
  /// qarma) pour ses dialogues desktop — absent (ou cassé en sandbox
  /// Flatpak) sur certaines machines Linux. Sur desktop on route donc les
  /// dialogues de fichiers vers `file_selector` (sélecteur GTK natif en
  /// process, via les portails XDG). Sur mobile, `file_selector` ne supporte
  /// pas `getSaveLocation` : on garde `file_picker` (Android SAF, inchangé).
  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  /// Construit le JSON de l'export fiscal du wallet [walletId] pour [taxYear].
  ///
  /// Le périmètre est l'intégralité des comptes du wallet courant, avec leur
  /// historique complet de transactions (`taxYear` n'est qu'une métadonnée,
  /// pas un filtre — voir la doc du format). Factorisé entre [exportAndShare]
  /// et [exportToFile] : même contenu, seule la destination diffère.
  Future<String> _buildJson({
    required String walletId,
    required int taxYear,
  }) async {
    final accounts = await _accountStorage.getAccountsByWallet(walletId);

    final transactionsByAccount = <String, List<AssetTransaction>>{};
    final assetsBySymbol = <String, Asset>{};
    for (final account in accounts) {
      transactionsByAccount[account.id] =
          await _transactionStorage.getByAccount(account.id);
      final positions = await _accountStorage.getPositions(account.id);
      for (final position in positions) {
        assetsBySymbol[position.asset.symbol] = position.asset;
      }
    }

    final content = buildFiscalExport(
      accounts: accounts,
      transactionsByAccount: transactionsByAccount,
      assetsBySymbol: assetsBySymbol,
      taxYear: taxYear,
      appVersion: _appVersion,
      exportedAt: DateTime.now().toUtc(),
    );
    return const JsonEncoder.withIndent('  ').convert(content);
  }

  /// Nom de fichier par défaut de l'export fiscal (partagé entre
  /// [exportAndShare] et [exportToFile]).
  String _fileName(int taxYear) {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return 'sparneo-fiscal-export-$taxYear-$stamp.json';
  }

  /// Construit l'export fiscal du wallet [walletId] pour [taxYear] et ouvre
  /// la feuille de partage du système sur le fichier JSON généré.
  ///
  /// [subject] est le libellé affiché par la feuille de partage du système ;
  /// le service (Dart pur, sans accès aux localisations) laisse l'appelant
  /// fournir un libellé traduit (`l10n.fiscalExportSubject`). À défaut, un
  /// libellé neutre est utilisé.
  Future<void> exportAndShare({
    required String walletId,
    required int taxYear,
    String? subject,
  }) async {
    final json = await _buildJson(walletId: walletId, taxYear: taxYear);
    final fileName = _fileName(taxYear);

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(json);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json', name: fileName)],
      subject: subject ?? 'Export fiscal Sparneo',
    );
  }

  /// Ouvre le sélecteur du système pour enregistrer l'export fiscal à
  /// l'emplacement choisi par l'utilisateur (Téléchargements, Drive…).
  /// Le fichier est réellement écrit sur place. Retourne le chemin choisi,
  /// ou `null` si l'utilisateur annule. Calqué sur
  /// [BackupService.exportToFile] — alternative à [exportAndShare] là où le
  /// partage de fichiers n'est pas disponible (ex. Linux, cf. `share_plus`).
  Future<String?> exportToFile({
    required String walletId,
    required int taxYear,
  }) async {
    final json = await _buildJson(walletId: walletId, taxYear: taxYear);
    final bytes = Uint8List.fromList(utf8.encode(json));
    final fileName = _fileName(taxYear);

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
      dialogTitle: 'Enregistrer l\'export fiscal',
      fileName: fileName,
      bytes: bytes,
    );
  }
}

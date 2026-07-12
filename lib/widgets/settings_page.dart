// lib/widgets/settings_page.dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:portfolio_tracker/app_info.dart';
import 'package:portfolio_tracker/controllers/theme_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/services/backup_service.dart';
import 'package:portfolio_tracker/services/fiscal_export_service.dart';
import 'package:portfolio_tracker/utils/app_snackbar.dart';
import 'package:portfolio_tracker/utils/error_text.dart';

/// `true` sur desktop (Linux/macOS/Windows) : le partage de fichiers
/// (`Share.shareXFiles`, share_plus) n'y est pas supporté — seule
/// l'alternative « Enregistrer sous » (FilePicker.saveFile) fonctionne. Même
/// détection que [AppDatabase] (kIsWeb en garde avant tout accès à
/// `Platform`, qui n'existe pas sur web).
bool get _isDesktop =>
    !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

/// Page « Réglages » : Apparence, Sauvegarde & export, Confidentialité,
/// À propos / Licence.
///
/// [activeWalletId] : id du wallet actif au moment de l'ouverture de la page,
/// fourni par WalletView (passage par constructeur — la notion de « wallet
/// actif » vit dans WalletController, pas dans un service partagé). Utilisé
/// uniquement par l'export fiscal, qui est scopé à un wallet ; la sauvegarde/
/// restauration porte sur l'intégralité des données et n'en a pas besoin.
class SettingsPage extends StatefulWidget {
  final String? activeWalletId;

  const SettingsPage({super.key, this.activeWalletId});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final BackupService _backupService = BackupService();
  final FiscalExportService _fiscalExportService = FiscalExportService();

  // ==================== SAUVEGARDE / RESTAURATION ====================
  // Logique portée à l'identique depuis _WalletViewState (comportement
  // inchangé, seulement relocalisé).

  Future<void> _saveDataToFile() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await _backupService.exportToFile();
      if (!mounted || path == null) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.backupSaved)));
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, ErrorText.of(context, e), type: SnackType.error);
    }
  }

  Future<void> _shareData() async {
    try {
      await _backupService.exportAndShare();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, ErrorText.of(context, e), type: SnackType.error);
    }
  }

  /// Demande l'année fiscale ciblée (métadonnée de l'export, l'historique
  /// complet est toujours inclus). Retourne `null` si l'utilisateur annule ou
  /// si le wallet actif est inconnu. Factorisé entre [_exportFiscal] (partage)
  /// et [_saveFiscalExportToFile] (enregistrer sous) : même sélection, seule
  /// la destination diffère.
  Future<int?> _pickTaxYear() async {
    final l10n = AppLocalizations.of(context)!;
    if (widget.activeWalletId == null) return null;

    final currentYear = DateTime.now().year;
    // 5 dernières années fiscales révolues, la plus récente d'abord.
    final years = List<int>.generate(5, (i) => currentYear - 1 - i);

    return showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.fiscalExportYearTitle),
        children: [
          for (final year in years)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, year),
              child: Text('$year'),
            ),
        ],
      ),
    );
  }

  /// Demande l'année fiscale ciblée puis génère et partage l'export fiscal du
  /// wallet courant. Calqué sur [_shareData]. Masqué sur desktop (bouton
  /// absent, cf. [_isDesktop] dans [build]) : `Share.shareXFiles` n'y est pas
  /// supporté.
  Future<void> _exportFiscal() async {
    final l10n = AppLocalizations.of(context)!;
    final walletId = widget.activeWalletId;
    if (walletId == null) return;

    final selectedYear = await _pickTaxYear();
    if (selectedYear == null) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await _fiscalExportService.exportAndShare(
        walletId: walletId,
        taxYear: selectedYear,
        subject: l10n.fiscalExportSubject,
      );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.fiscalExportDone)));
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, ErrorText.of(context, e), type: SnackType.error);
    }
  }

  /// Demande l'année fiscale ciblée puis enregistre l'export fiscal du wallet
  /// courant à l'emplacement choisi par l'utilisateur. Calqué sur
  /// [_saveDataToFile] — alternative à [_exportFiscal] là où le partage de
  /// fichiers n'est pas disponible (desktop, cf. [_isDesktop]).
  Future<void> _saveFiscalExportToFile() async {
    final l10n = AppLocalizations.of(context)!;
    final walletId = widget.activeWalletId;
    if (walletId == null) return;

    final selectedYear = await _pickTaxYear();
    if (selectedYear == null) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await _fiscalExportService.exportToFile(
        walletId: walletId,
        taxYear: selectedYear,
      );
      if (!mounted || path == null) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.fiscalExportSaved)));
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, ErrorText.of(context, e), type: SnackType.error);
    }
  }

  Future<void> _importData() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.backupImportTitle),
        content: Text(l10n.backupImportWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.backupReplace),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final imported = await _backupService.pickAndImport();
      if (!mounted || !imported) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.backupRestoreSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, ErrorText.of(context, e), type: SnackType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsPageTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(title: l10n.settingsAppearanceSectionTitle),
            const SizedBox(height: 8),
            _ThemeModeSelector(),
            const SizedBox(height: 32),

            _SectionTitle(title: l10n.settingsDataSectionTitle),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _saveDataToFile,
                icon: const Icon(Icons.save_alt),
                label: Text(l10n.backupSaveFile),
              ),
            ),
            // Partage de fichiers (share_plus) non supporté sur desktop
            // (Linux notamment lève à l'exécution) : bouton masqué, seul
            // « Enregistrer le fichier » reste disponible. Cf. [_isDesktop].
            if (!_isDesktop) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _shareData,
                  icon: const Icon(Icons.share),
                  label: Text(l10n.backupShare),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _importData,
                icon: const Icon(Icons.download),
                label: Text(l10n.backupImportRestore),
              ),
            ),
            // Export fiscal — « Enregistrer sous » TOUJOURS proposé (toutes
            // plateformes) : la feuille de partage Android n'offre PAS
            // systématiquement de cible « Enregistrer dans Fichiers » selon le
            // device et les apps installées (constaté en réel : certains
            // n'affichent que Quick Share / Gmail). FilePicker.saveFile ouvre le
            // sélecteur SAF système, chemin d'enregistrement fiable. Symétrique
            // de la section Sauvegarde (save toujours + partage mobile).
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _saveFiscalExportToFile,
                icon: const Icon(Icons.receipt_long),
                label: Text(l10n.fiscalExportSaveFile),
              ),
            ),
            // Partage : mobile uniquement (Share.shareXFiles cassé sur desktop).
            if (!_isDesktop) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: _exportFiscal,
                  icon: const Icon(Icons.share),
                  label: Text(l10n.fiscalExport),
                ),
              ),
            ],
            const SizedBox(height: 32),

            _SectionTitle(title: l10n.settingsPrivacySectionTitle),
            const SizedBox(height: 8),
            Text(l10n.settingsPrivacyBody, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 32),

            _SectionTitle(title: l10n.settingsAboutSectionTitle),
            const SizedBox(height: 8),
            Text(
              'Sparneo',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(l10n.settingsAppTagline, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              l10n.settingsAppVersion(kAppVersion),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text(l10n.settingsLicenseNotice, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                showLicensePage(
                  context: context,
                  applicationName: 'Sparneo',
                  applicationVersion: kAppVersion,
                  applicationLegalese: kAgplLegalese,
                );
              },
              icon: const Icon(Icons.description_outlined),
              label: Text(l10n.settingsThirdPartyLicenses),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.settingsRepositoryLabel,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            const SelectableText('https://github.com/sparneo/sparneo'),
          ],
        ),
      ),
    );
  }
}

/// Titre de section, cohérent avec le style utilisé ailleurs dans l'app.
class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}

/// Sélecteur de thème (système / clair / sombre), relié à
/// [ThemeController.shared]. Écoute le contrôleur pour refléter le choix
/// courant (y compris s'il a été changé ailleurs) et persiste immédiatement
/// tout changement.
class _ThemeModeSelector extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = ThemeController.shared();

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SegmentedButton<ThemeMode>(
        segments: [
          ButtonSegment(
            value: ThemeMode.system,
            label: Text(l10n.settingsThemeSystem),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            label: Text(l10n.settingsThemeLight),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            label: Text(l10n.settingsThemeDark),
          ),
        ],
        selected: {controller.themeMode},
        onSelectionChanged: (selection) {
          controller.setThemeMode(selection.first);
        },
      ),
    );
  }
}

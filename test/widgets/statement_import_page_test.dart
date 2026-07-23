// test/widgets/statement_import_page_test.dart
//
// Tests WIDGET de l'assistant d'import de relevé (lot B4, UI).
//
// Le premier pas (sélection de fichier) s'appuie sur file_picker/
// file_selector, sans implémentation dans l'environnement de test widget — on
// ne l'exerce donc pas ici. Le point d'entrée `debugInitialPreview` (réservé
// aux tests, cf. doc de StatementImportPage) permet de démarrer directement à
// l'étape de résolution des nouveaux actifs avec une prévisualisation
// synthétique, sans fichier ni base de données.
//
// AUCUN accès SQLite dans ces tests : ni la construction de la page (étape
// « sélection du fichier ») ni l'étape « résoudre les nouveaux actifs » ne
// lisent le contrôleur — celui-ci n'est requis que pour appeler
// previewStatementImport/confirmStatementImport (non exercés ici). Constater
// (cf. friction rencontrée) que sqflite_common_ffi bloque indéfiniment
// (`dart:isolate _RawReceivePort._handleMessage`) quand une base réelle est
// ouverte à l'intérieur d'un `testWidgets` (aucun test widget existant du
// dépôt ne combine les deux) : on l'évite donc plutôt que de la contourner —
// un AccountController par défaut (jamais interrogé) suffit à ces tests.
// Zéro appel réseau (aucune méthode réseau n'est appelée non plus).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/controllers/account_controller.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/model/import_preview.dart';
import 'package:portfolio_tracker/model/imported_movement.dart';
import 'package:portfolio_tracker/widgets/import/statement_import_page.dart';

const _accountId = 'account-1';

Widget _host(
  ImportPreview? debugInitialPreview, {
  Set<String>? debugInitialSearchFailedKeys,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('fr'),
    home: StatementImportPage(
      controller: AccountController(initialAccountId: _accountId),
      accountId: _accountId,
      accountName: 'Compte test',
      debugInitialPreview: debugInitialPreview,
      debugInitialSearchFailedKeys: debugInitialSearchFailedKeys,
    ),
  );
}

/// Un mouvement candidat « New Co » dont le symbole n'a pas encore été résolu
/// (identité par libellé, aucun ISIN) — reflète le cas REF-NEW3 de
/// account_controller_import_test.dart (ISIN/symbole inconnus).
ImportedMovement _unresolvedMovement() => ImportedMovement.candidate(
      sourceRow: const ['12/01/2024', 'Achat', '', '', 'New Co', '2', '10'],
      // Numéro de ligne PHYSIQUE 1-based (nouvelle sémantique) affiché tel quel.
      sourceRowIndex: 3,
      transaction: AssetTransaction(
        id: 'tx-newco',
        accountId: _accountId,
        symbol: null,
        kind: TransactionKind.buy,
        quantity: '2',
        unitPrice: '10',
        amount: '-20',
        currency: 'EUR',
        date: DateTime(2024, 1, 12),
        meta: const {'importKey': 'hash:test-newco'},
      ),
      isin: null,
      label: 'New Co',
      needsAssetResolution: true,
      importKey: 'hash:test-newco',
    );

/// Un mouvement candidat identifié par ISIN, non résolu — reflète le cas d'un
/// titre délisté / purgé de la source (le blocage que le repli « non coté »
/// débloque).
ImportedMovement _unresolvedMovementWithIsin() => ImportedMovement.candidate(
      sourceRow: const ['13/01/2024', 'Achat', 'FR000UNKNOWN', '', 'Old Corp', '1', '5'],
      sourceRowIndex: 4,
      transaction: AssetTransaction(
        id: 'tx-old',
        accountId: _accountId,
        symbol: null,
        kind: TransactionKind.buy,
        quantity: '1',
        unitPrice: '5',
        amount: '-5',
        currency: 'EUR',
        date: DateTime(2024, 1, 13),
        meta: const {'importKey': 'ref:account-1:REF-NEW3'},
      ),
      isin: 'FR000UNKNOWN',
      label: 'Old Corp',
      needsAssetResolution: true,
      importKey: 'ref:account-1:REF-NEW3',
    );

/// Une ligne d'OST rejetée « à revoir » (groupe déplié à l'aperçu), avec une
/// ligne source brute non vide (non affichée : seul le numéro de ligne
/// l'est, cf. _sourceRowRef).
ImportedMovement _rejectedOstMovement() => ImportedMovement.rejected(
      sourceRow: const ['15/01/2024', 'DS', 'FR00TEST', '', 'Mystère SA'],
      // Ligne physique 6 dans le relevé : affichée directement « Ligne 6 »
      // (plus de « + 1 » à l'écran — la valeur est déjà 1-based absolue).
      sourceRowIndex: 6,
      rejectReason: 'corporateActionReview',
      isin: 'FR00TEST',
      label: 'Mystère SA',
    );

/// Une ligne rejetée pour un motif PUREMENT TECHNIQUE (type d'opération non
/// reconnu) — le cas fréquent en profil générique quand le vocabulaire des
/// natures d'opération n'a pas été renseigné. Groupe replié à l'aperçu.
ImportedMovement _rejectedTechMovement() => ImportedMovement.rejected(
      sourceRow: const ['16/01/2024', 'VIREMENT INTERNE', '', '', 'Écriture'],
      sourceRowIndex: 7,
      rejectReason: 'unknownKind',
      isin: null,
      label: 'Écriture',
    );

void main() {
  group('StatementImportPage — rendu', () {
    testWidgets('s\'affiche sans exception (étape sélection du fichier)',
        (tester) async {
      await tester.pumpWidget(_host(null));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Choisir un fichier'), findsOneWidget);
      // Indicateur de progression cohérent avec le parcours générique
      // (fichier → config → aperçu → fait), sans résolution connue à ce stade.
      expect(find.text('Étape 1 sur 4'), findsOneWidget);
    });

    testWidgets(
        'sélectionner le profil Bourse Direct change l\'indication affichée '
        '(sans passer par le sélecteur de fichier, non disponible en test '
        'widget)', (tester) async {
      await tester.pumpWidget(_host(null));
      await tester.pumpAndSettle();

      // Profil générique par défaut.
      expect(
        find.text("Sélectionnez l'export CSV de votre courtier (profil générique / manuel)."),
        findsOneWidget,
      );

      await tester.tap(find.text('Bourse Direct'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Sélectionnez l'export .xlsx « Extraction de compte » de votre compte Bourse Direct.",
        ),
        findsOneWidget,
      );
      // Le bouton de sélection de fichier reste présent (parcours inchangé,
      // seul le profil appliqué après sélection diffère).
      expect(find.text('Choisir un fichier'), findsOneWidget);
    });
  });

  group('StatementImportPage — résolution des nouveaux actifs', () {
    testWidgets(
        'le bouton Confirmer reste désactivé tant qu\'un nouvel actif '
        'n\'est pas résolu, puis s\'active une fois le symbole saisi',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      // Étape « résoudre les nouveaux actifs » atteinte directement.
      expect(find.text('Résoudre les nouveaux actifs'), findsOneWidget);
      // Le parcours générique inclut l'étape de résolution (actif neuf non
      // résolu) : « Étape 4 sur 5 ».
      expect(find.text('Étape 4 sur 5'), findsOneWidget);

      // Le bouton de confirmation est désactivé : aucun symbole saisi.
      var confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNull);

      // L'utilisateur saisit le symbole résolu.
      await tester.enterText(find.byType(TextField).first, 'NEWCO');
      await tester.pump();

      confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNotNull);
    });

    testWidgets(
        'repli « non coté » : cocher la case active la confirmation sans '
        'symbole saisi (aucun réseau — parcours debugInitialPreview)',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      expect(find.text('Résoudre les nouveaux actifs'), findsOneWidget);

      // Désactivé au départ : ni symbole saisi ni repli coché.
      var confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNull);

      // La case de repli « non coté » est proposée (ISIN présent).
      final fallbackTile = find.byType(CheckboxListTile);
      expect(fallbackTile, findsOneWidget);

      await tester.tap(fallbackTile);
      await tester.pumpAndSettle();

      // Cocher le repli résout le candidat : la confirmation s'active.
      confirmButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer l\'import'),
      );
      expect(confirmButton.onPressed, isNotNull);
    });

    testWidgets('un symbole saisi puis effacé redésactive le bouton',
        (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'NEWCO');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNotNull,
      );

      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets(
        'recherche ISIN en échec réseau : le bandeau « Réessayer » ET le repli '
        '« non coté » coexistent (échappatoire hors-ligne, sans conclure à un '
        'titre introuvable) — P2.3', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovementWithIsin()],
        newAssets: const [
          NewAssetCandidate(
            isin: 'FR000UNKNOWN',
            label: 'Old Corp',
            proposedSymbol: null,
          ),
        ],
      );

      await tester.pumpWidget(
        _host(preview, debugInitialSearchFailedKeys: const {'FR000UNKNOWN'}),
      );
      await tester.pumpAndSettle();

      // Bandeau de panne + bouton « Réessayer ».
      expect(
        find.text('Recherche indisponible — vérifiez votre connexion.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Réessayer'), findsOneWidget);

      // Le repli « non coté » est DÉSORMAIS proposé même en échec réseau (le
      // candidat porte un ISIN) : la panne est signalée, mais l'utilisateur
      // n'est plus emprisonné.
      final fallbackTile = find.byType(CheckboxListTile);
      expect(fallbackTile, findsOneWidget);

      // Tant que rien n'est résolu, la confirmation reste bloquée : le bandeau
      // à lui seul ne débloque pas.
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNull,
      );

      // Cocher « non coté » débloque l'import, le bandeau de panne restant
      // affiché (coexistence).
      await tester.tap(fallbackTile);
      await tester.pumpAndSettle();
      expect(
        find.text('Recherche indisponible — vérifiez votre connexion.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Confirmer l\'import'),
            )
            .onPressed,
        isNotNull,
      );
    });
  });

  group('StatementImportPage — aperçu (retour depuis la résolution)', () {
    testWidgets(
        'le delta projette l\'actif NEUF (0 → N titres) et les tuiles rappellent '
        'la ligne source du relevé', (tester) async {
      final preview = ImportPreview(
        toCreate: [_unresolvedMovement()],
        rejects: [_rejectedOstMovement()],
        newAssets: const [
          NewAssetCandidate(isin: null, label: 'New Co', proposedSymbol: null),
        ],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      // Le point d'entrée de test démarre à la résolution : on revient à
      // l'aperçu (bouton retour de l'AppBar) pour l'exercer.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Aperçu de l\'import'), findsWidgets);

      // Défaut 1 : la moitié « positions » n'est plus vide — l'actif neuf est
      // projeté depuis 0 (2 titres achetés).
      expect(find.text('New Co : 0 → 2 titres'), findsOneWidget);

      // Défaut 3 : la phrase d'explication du groupe des nouveaux actifs et le
      // libellé reformulé « Symbole à associer ».
      expect(
        find.text(
          'Titres détectés dans le relevé, à associer à une valeur cotée '
          'avant l\'import.',
        ),
        findsOneWidget,
      );
      expect(find.text('Symbole à associer'), findsOneWidget);

      // Défaut 2 : l'OST rejetée (groupe déplié) rappelle sa ligne source par
      // le SEUL numéro (1-based) — l'écho des cellules brutes a été retiré
      // (retour auteur : surchargeait l'interface).
      expect(find.text('Ligne 6'), findsOneWidget);
    });

    testWidgets(
        'aperçu « rien à créer » MAIS des rejets : les groupes de rejets/OST '
        'sont rendus et le message annonce le nombre de lignes rejetées — P1',
        (tester) async {
      // Cas très plausible en profil générique : toutes les lignes rejetées
      // (natures d'opération non mappées) + une OST. Rien à créer, mais on ne
      // doit PAS masquer les motifs.
      final preview = ImportPreview(
        toCreate: const [],
        rejects: [_rejectedOstMovement(), _rejectedTechMovement()],
        newAssets: const [],
      );

      await tester.pumpWidget(_host(preview));
      await tester.pumpAndSettle();

      // Le point d'entrée de test démarre à la résolution : retour à l'aperçu.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Aperçu de l\'import'), findsWidgets);

      // Message adapté : N lignes rejetées ci-dessous (au lieu du laconique
      // « Aucune ligne exploitable… » qui masquait les motifs).
      expect(
        find.text('Aucun mouvement à importer — 2 ligne(s) rejetée(s) ci-dessous.'),
        findsOneWidget,
      );

      // Le groupe OST (déplié, avertissement) est rendu avec son titre et son
      // rappel de ligne source.
      expect(find.text('Opérations sur titres à revoir (1)'), findsOneWidget);
      expect(find.text('Ligne 6'), findsOneWidget);

      // Le groupe des rejets techniques (replié) est rendu avec son titre.
      expect(find.text('Lignes rejetées (1)'), findsOneWidget);

      // Le bouton « Fermer » reste présent (aucune écriture possible).
      expect(find.widgetWithText(FilledButton, 'Fermer'), findsOneWidget);
    });
  });
}

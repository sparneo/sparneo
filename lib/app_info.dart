// lib/app_info.dart

/// Version affichée dans l'UI (page Réglages, licences…).
///
/// GARDER SYNCHRO avec `pubspec.yaml` (champ `version`) — pas de lecture
/// automatique (pas de dépendance `package_info_plus` dans ce projet), donc
/// mise à jour manuelle à chaque bump de version.
const String kAppVersion = '0.1.0';

/// Notice AGPL-3.0 courte, source unique partagée par le registre de licences
/// ([main]) et les « mentions légales » de `showLicensePage` (page Réglages).
/// Volontairement concise : le texte intégral reste dans le fichier LICENSE à
/// la racine du dépôt.
const String kAgplLegalese =
    'Sparneo — Copyright (C) les contributeurs Sparneo.\n'
    'Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).\n'
    'See the LICENSE file at the root of the repository for the full text.';

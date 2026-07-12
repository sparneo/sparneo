// lib/utils/app_snackbar.dart
import 'package:flutter/material.dart';

/// Nature d'un message éphémère (snackbar), qui détermine ses couleurs.
enum SnackType { info, success, error, warning }

/// Affiche un snackbar M3 cohérent et lisible dans les deux thèmes.
///
/// Remplace les `SnackBar(backgroundColor: Colors.red/green)` dispersés :
/// les couleurs dérivent du [ColorScheme] (erreur) ou de teintes sémantiques
/// contrastées, jamais de `Colors.*` en dur. Masque le snackbar courant avant
/// d'en afficher un nouveau pour éviter les empilements.
/// Retourne le contrôleur du snackbar affiché : permet d'observer sa fermeture
/// (`.closed`) — utile pour les motifs « supprimé + Annuler » où la suppression
/// réelle n'est validée qu'à l'expiration sans annulation.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAppSnackBar(
  BuildContext context,
  String message, {
  SnackType type = SnackType.info,
  SnackBarAction? action,
  Duration? duration,
}) {
  final scheme = Theme.of(context).colorScheme;

  final (Color background, Color foreground) = switch (type) {
    SnackType.error => (scheme.errorContainer, scheme.onErrorContainer),
    SnackType.success => (const Color(0xFF1B7A3E), Colors.white),
    SnackType.warning => (const Color(0xFF8A5A00), Colors.white),
    SnackType.info => (scheme.inverseSurface, scheme.onInverseSurface),
  };

  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      content: Text(message, style: TextStyle(color: foreground)),
      backgroundColor: background,
      behavior: SnackBarBehavior.floating,
      action: action,
      duration: duration ?? const Duration(seconds: 4),
      // Flutter ≥ 3.38 : un SnackBar AVEC action persiste indéfiniment par
      // défaut (persist = action != null, cf. flutter/flutter#173000). Nos
      // motifs « supprimé + Annuler » reposent au contraire sur l'EXPIRATION du
      // snackbar (commit différé à la fermeture par timeout, via `.closed`) :
      // on restaure explicitement l'auto-fermeture. Sans ça, le snackbar de
      // suppression reste collé indéfiniment et le commit ne part jamais.
      persist: false,
    ),
  );
}

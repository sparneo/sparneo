// lib/utils/app_snackbar.dart
import 'package:flutter/material.dart';

/// Nature d'un message éphémère (snackbar), qui détermine ses couleurs.
enum SnackType { info, success, error, warning }

/// Snackbar actuellement affiché qui porte une fenêtre d'annulation encore
/// ouverte, s'il y en a un. Tant qu'il est là, [showAppSnackBar] n'évince plus
/// le snackbar courant : il empile. Remis à `null` à sa fermeture.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _openUndoWindow;

/// Oublie la fenêtre d'annulation protégée (tests uniquement) : l'état est
/// global au processus et un test qui se termine snackbar ouvert le laisserait
/// fuir sur le suivant.
@visibleForTesting
void resetUndoWindowForTesting() => _openUndoWindow = null;

/// Affiche un snackbar M3 cohérent et lisible dans les deux thèmes.
///
/// Remplace les `SnackBar(backgroundColor: Colors.red/green)` dispersés :
/// les couleurs dérivent du [ColorScheme] (erreur) ou de teintes sémantiques
/// contrastées, jamais de `Colors.*` en dur. Masque le snackbar courant avant
/// d'en afficher un nouveau pour éviter les empilements.
/// Retourne le contrôleur du snackbar affiché : permet d'observer sa fermeture
/// (`.closed`) — utile pour les motifs « supprimé + Annuler » où la suppression
/// réelle n'est validée qu'à l'expiration sans annulation.
///
/// Passer [undoWindow] à `true` pour un snackbar qui PORTE une telle fenêtre
/// d'annulation : il devient inévinçable tant qu'il est affiché (cf. MIN-3).
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAppSnackBar(
  BuildContext context,
  String message, {
  SnackType type = SnackType.info,
  SnackBarAction? action,
  Duration? duration,
  bool undoWindow = false,
}) {
  final scheme = Theme.of(context).colorScheme;

  final (Color background, Color foreground) = switch (type) {
    SnackType.error => (scheme.errorContainer, scheme.onErrorContainer),
    SnackType.success => (const Color(0xFF1B7A3E), Colors.white),
    SnackType.warning => (const Color(0xFF8A5A00), Colors.white),
    SnackType.info => (scheme.inverseSurface, scheme.onInverseSurface),
  };

  final messenger = ScaffoldMessenger.of(context);
  // On masque le snackbar courant pour éviter les empilements — SAUF s'il porte
  // une fenêtre d'annulation encore ouverte. `hideCurrentSnackBar()` le
  // fermerait avec `reason = hide`, que les motifs « supprimé + Annuler »
  // interprètent (à raison) comme « pas d'annulation » : le commit différé
  // partirait aussitôt et la fenêtre serait quasi nulle. Dans ce cas on laisse
  // le messenger EMPILER : le nouveau message attend son tour, l'utilisateur
  // garde ses secondes pour appuyer sur « Annuler ».
  if (_openUndoWindow == null) {
    messenger.hideCurrentSnackBar();
  }
  final controller = messenger.showSnackBar(
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

  if (undoWindow) {
    _openUndoWindow = controller;
    // Ne libère la protection que si c'est bien CE snackbar qui la détient :
    // deux suppressions rapprochées empilent deux fenêtres, et la fermeture de
    // la première ne doit pas exposer la seconde.
    controller.closed.whenComplete(() {
      if (identical(_openUndoWindow, controller)) _openUndoWindow = null;
    });
  }
  return controller;
}

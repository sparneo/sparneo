// lib/theme/app_colors.dart
import 'package:flutter/material.dart';

/// Couleurs sémantiques de l'application, séparées de l'accent (« bleu
/// confiance »). Le vert/rouge de plus-value ou de moins-value doit passer
/// EXCLUSIVEMENT par ces helpers : les teintes sont choisies pour rester
/// lisibles (contraste ≥ 4,5:1) aussi bien en thème clair qu'en thème sombre,
/// là où `Colors.green/red.shade700` s'écrasait sur fond sombre (~3,4:1).
class AppColors {
  const AppColors._();

  // Thème clair : teintes profondes, lisibles sur surface claire.
  static const Color _gainLight = Color(0xFF1B7A3E);
  static const Color _lossLight = Color(0xFFC0362C);

  // Thème sombre : teintes désaturées et éclaircies, lisibles sur surface sombre.
  static const Color _gainDark = Color(0xFF57D08A);
  static const Color _lossDark = Color(0xFFFF7A6B);

  /// Couleur de gain/perte adaptée au thème courant.
  static Color gainLoss(BuildContext context, bool positive) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (positive) return isDark ? _gainDark : _gainLight;
    return isDark ? _lossDark : _lossLight;
  }

  /// Couleur « gain » (positive) adaptée au thème courant.
  static Color gain(BuildContext context) => gainLoss(context, true);

  /// Couleur « perte » (négative) adaptée au thème courant.
  static Color loss(BuildContext context) => gainLoss(context, false);

  /// Palette d'identité pour les avatars (pastille + lettre). Volontairement
  /// distincte du vert gain / rouge perte pour ne pas laisser croire que la
  /// couleur d'un avatar encode une performance.
  static const List<Color> _avatarPalette = [
    Color(0xFF3A5BD0), // indigo (proche marque)
    Color(0xFF00897B), // teal
    Color(0xFF8E24AA), // violet
    Color(0xFFD81B60), // rose
    Color(0xFFF4511E), // orange profond
    Color(0xFF6D4C41), // brun
    Color(0xFF00838F), // cyan
    Color(0xFF5E35B1), // violet profond
  ];

  /// Couleur d'avatar STABLE, dérivée du symbole (et non de la performance) :
  /// l'identité visuelle d'un actif ne doit pas changer quand son cours varie.
  static Color avatarColor(String seed) {
    if (seed.isEmpty) return _avatarPalette.first;
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return _avatarPalette[hash % _avatarPalette.length];
  }
}

// lib/widgets/common/responsive_body.dart
import 'package:flutter/material.dart';

/// Centre le contenu et le contraint à [maxWidth] sur les grands écrans
/// (desktop/web) sans effet perceptible sur mobile. Empêche le contenu d'une
/// page de s'étirer sur toute la largeur d'une fenêtre de bureau.
///
/// À insérer entre le scroll-view d'une page et sa Column de contenu :
/// `SingleChildScrollView(child: ResponsiveBody(child: Column(...)))`.
class ResponsiveBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ResponsiveBody({super.key, required this.child, this.maxWidth = 640});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

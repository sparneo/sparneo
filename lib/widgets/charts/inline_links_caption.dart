// lib/widgets/charts/inline_links_caption.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Une entrée CLIQUABLE d'une [InlineLinksCaption] : ce qu'on lit, ce que le
/// tap déclenche.
@immutable
class InlineLinkSpec {
  final String label;
  final VoidCallback onTap;

  const InlineLinkSpec({required this.label, required this.onTap});
}

/// Caption d'UNE SEULE PHRASE dont certains mots sont cliquables — « 3
/// positions sans historique ne figurent pas dans cette courbe : PEA (2),
/// CTO (1) ».
///
/// POURQUOI DU TEXTE EN LIGNE ET PAS UNE RANGÉE DE BOUTONS : ce bloc vit SOUS
/// le graphe, au milieu d'autres captions (`bodySmall`, gris). Une `Wrap` de
/// `TextButton`/chips y ferait un ÎLOT visuel — un composant de plus, à la
/// hauteur et à la densité étrangères aux lignes voisines — là où l'auteur
/// demande explicitement de rester en caption. Un `Text.rich` garde la ligne
/// de base, l'interligne et la couleur des autres notes, et se replie
/// naturellement sur plusieurs lignes à 400 dp comme à police système
/// agrandie (le repli d'un `RichText` suit la taille réelle du texte ; une
/// `Wrap` de boutons, elle, a déjà valu à ce projet des débordements — cf. les
/// gardes `Flexible`/`SingleChildScrollView` de wallet_view sur le sélecteur
/// de mode).
///
/// CONTREPARTIE ASSUMÉE : la cible tactile d'un lien est sa boîte de glyphes,
/// donc plus petite que les 48 dp recommandés (elle croît toutefois avec la
/// police système). C'est acceptable ICI parce qu'aucune de ces actions n'est
/// unique : le compte reste atteignable par sa tuile dans la liste, le titre
/// par sa carte de position. Le lien est un RACCOURCI vers l'endroit où agir,
/// jamais le seul chemin.
///
/// CYCLE DE VIE : chaque lien porte un [TapGestureRecognizer], qui est une
/// ressource à libérer. Ce widget les possède et les détruit dans [dispose] ET
/// à chaque [didUpdateWidget] qui change la liste — d'où un `StatefulWidget`,
/// alors que tout le reste de `ChartNotes` est sans état. C'est précisément
/// pour ne pas contaminer `ChartNotes` avec cet état que la mécanique vit dans
/// son propre fichier.
class InlineLinksCaption extends StatefulWidget {
  /// Texte d'ouverture, affiché tel quel avant les liens (typiquement la
  /// phrase chiffrée, terminée par « : »). Une espace est insérée entre lui et
  /// le premier lien.
  final String prefix;

  /// Entrées cliquables, dans l'ordre d'affichage. Vide ⇒ seul [prefix] (et
  /// [suffix]) est rendu, sans séparateur orphelin.
  final List<InlineLinkSpec> links;

  /// Séparateur entre deux liens.
  final String separator;

  /// Texte de fermeture, après le dernier lien (« et 2 autres. », un conseil
  /// d'usage…). `null` = rien.
  final String? suffix;

  /// Style du texte non cliquable. `null` ⇒ `bodySmall` sur
  /// `onSurfaceVariant`, comme les autres captions sous le graphe.
  final TextStyle? style;

  const InlineLinksCaption({
    super.key,
    required this.prefix,
    required this.links,
    this.separator = ', ',
    this.suffix,
    this.style,
  });

  @override
  State<InlineLinksCaption> createState() => _InlineLinksCaptionState();
}

class _InlineLinksCaptionState extends State<InlineLinksCaption> {
  List<TapGestureRecognizer> _recognizers = const [];

  @override
  void initState() {
    super.initState();
    _buildRecognizers();
  }

  @override
  void didUpdateWidget(covariant InlineLinksCaption oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Les callbacks sont recréés à chaque build de l'appelant (closures) : on
    // ne peut pas comparer les `onTap`. On reconstruit dès que le NOMBRE ou
    // les LIBELLÉS changent, et sinon on se contente de réaffecter le callback
    // courant sur les recognizers existants — sans quoi un tap déclencherait
    // la closure d'un build périmé (capturant un ancien accountId).
    var sameShape = oldWidget.links.length == widget.links.length;
    for (var i = 0; sameShape && i < widget.links.length; i++) {
      sameShape = oldWidget.links[i].label == widget.links[i].label;
    }
    if (!sameShape) {
      _disposeRecognizers();
      _buildRecognizers();
      return;
    }
    for (var i = 0; i < _recognizers.length; i++) {
      _recognizers[i].onTap = widget.links[i].onTap;
    }
  }

  void _buildRecognizers() {
    _recognizers = [
      for (final link in widget.links) TapGestureRecognizer()..onTap = link.onTap,
    ];
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers = const [];
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle = widget.style ??
        theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
    // Souligné ET coloré : la couleur seule ne suffit pas (daltonisme, thème
    // sombre où le primaire s'approche du texte courant).
    final linkStyle = (baseStyle ?? const TextStyle()).copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );

    final spans = <InlineSpan>[TextSpan(text: widget.prefix)];
    for (var i = 0; i < widget.links.length; i++) {
      spans.add(TextSpan(text: i == 0 ? ' ' : widget.separator));
      spans.add(
        TextSpan(
          text: widget.links[i].label,
          style: linkStyle,
          recognizer: i < _recognizers.length ? _recognizers[i] : null,
        ),
      );
    }
    final suffix = widget.suffix;
    if (suffix != null && suffix.isNotEmpty) {
      spans.add(TextSpan(text: ' $suffix'));
    }

    return Text.rich(TextSpan(children: spans), style: baseStyle);
  }
}

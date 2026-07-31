# Journal des versions

Toutes les modifications notables de Sparneo. Le format s'inspire de
[Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) et le projet suit le
[versionnage sémantique](https://semver.org/lang/fr/).

## [0.2.0] — 2026-07-31

Cette version fait du **journal des mouvements** le cœur de l'application : on
l'alimente par import de relevé plutôt qu'à la main, et il produit en retour une
courbe de patrimoine qui dit ce que vous déteniez vraiment à chaque date.

### ⚠️ À lire avant de mettre à jour

- **Les instantanés de valorisation sont supprimés, et cette suppression est
  irréversible.** Jusqu'ici l'app enregistrait un total une fois par jour, à son
  ouverture : la densité de cet historique mesurait votre assiduité, pas celle du
  marché, et il ne disait rien de ce qui précédait l'installation. Il est remplacé
  par la courbe reconstruite depuis votre journal et les cours historiques, qui
  remonte aussi loin que vos mouvements. Aucune saisie n'est perdue — ces
  instantanés étaient entièrement dérivés de vos positions et des cotations — mais
  la table est bien détruite à la première ouverture. **Si vous tenez à conserver
  l'ancienne série, exportez une sauvegarde avant de mettre à jour.**
- **Le format d'export fiscal passe de la v3 à la v4** (nouveau type de mouvement
  `transferOut`, ajout de l'ISIN et du pays). Un outil qui lit la v3 rejettera un
  fichier v4 : mettez-le à jour avant de produire de nouveaux exports. Le format
  reste [documenté et versionné](docs/sparneo-fiscal-export.md).
- Le format de **sauvegarde** reste en v3 : la v0.1.0 relit sans problème une
  sauvegarde produite par cette version, et l'inverse est vrai aussi.

### Ajouté

- **Import de relevés courtier.** Un assistant à étapes charge un relevé
  **Bourse Direct** (`.xlsx`) ou un **CSV générique** dont les colonnes se
  mappent à la main, et le parse entièrement sur l'appareil. Un aperçu complet
  précède toute écriture : effet sur les positions et sur les espèces, doublons
  ignorés, lignes à revoir avec leur numéro dans le fichier. La résolution
  **ISIN → symbole** est assistée, avec repli « non coté » hors ligne pour les
  titres délistés. L'import est additif et idempotent — ré-importer le même
  relevé n'ajoute que les nouveautés — et **annulable en un geste**.
- **Opérations sur titres** reconnues à l'import : sorties de titres,
  attributions gratuites, rachats de rompus, changements de place de cotation et
  régularisations d'espèces. Les droits de souscription sont signalés pour revue
  plutôt que devinés.
- **Évolution réelle du patrimoine**, reconstruite depuis le journal et les cours
  historiques, sur les trois écrans (patrimoine, compte, position). Un sélecteur
  la met en regard de l'ancienne lecture — vos positions actuelles reprojetées
  sur les cours passés — car les deux répondent à des questions différentes.
- **Ligne du capital investi** superposée à la courbe de valeur : l'écart entre
  les deux, c'est le gain. Elle s'escamote d'elle-même quand elle écraserait la
  courbe de valeur, et se rappelle d'un tap.
- **Performance exacte du portefeuille**, neutre aux apports et aux retraits,
  affichée en cumulé et en annualisé au-delà de dix-huit mois.
- **Comptes espèces de plein exercice** : ils ont désormais leur propre écran et
  leur propre journal, au même titre que les comptes titres. Le solde d'un compte
  se dérive uniformément du journal dès lors qu'un mouvement l'ancre.
- **Édition et suppression des mouvements d'espèces** saisis à la main.
- **ISIN et pays** dans l'export fiscal, le pays étant dérivé du préfixe de
  l'ISIN.
- **Impact des frais** isolé dans le détail du gain total.
- **Performance de la période** affichée à côté de la plus-value.

### Modifié

- L'historique de valorisation ne repose plus sur des instantanés capturés mais
  sur la courbe reconstruite (voir l'avertissement de mise à jour ci-dessus).
- L'écran d'un compte a été épuré : chaque chiffre est remis près de ce qui le
  pilote.
- Le journal gagne en lisibilité — nature des opérations explicitée, taps
  prévisibles — et tous ses filtres sont désormais visibles, sur mobile comme sur
  desktop.
- Les rafales de cotations sont bornées et les séries historiques mises en cache,
  ce qui allège nettement les allers-retours réseau.

### Corrigé

- **L'application reste lisible quand la police système est agrandie.** À
  l'échelle 2,0 d'Android, les étiquettes d'axes se chevauchaient, les tuiles de
  compte émiettaient le nom du compte tout en débordant de leur carte, plusieurs
  sélecteurs tronquaient leurs libellés et les légendes de camembert recouvraient
  la section suivante. Les gouttières et la densité des graduations suivent
  maintenant la place réellement disponible, et les rangées trop serrées basculent
  en colonnes.
- Les prix unitaires des positions s'affichent sans perte de précision.
- L'écart entre les deux courbes est réconcilié avec le gain total affiché.
- La jambe espèces scindée d'une opération sur titre est recollée à son
  opération, au lieu de compter deux fois.
- Les relevés qui accolent une heure à la date ne partent plus intégralement en
  rejet.
- L'écran d'une position montre ce que vous déteniez à chaque date, et non ce que
  vous détenez aujourd'hui.
- L'écran d'un compte se rafraîchit au retour du journal.
- Le sélecteur de mode est masqué sur un compte espèces, où il n'a pas d'objet.

## [0.1.0] — 2026-07-12

Première version publique. Suivi de patrimoine multi-comptes (PEA, CTO,
assurance-vie, cash, crypto, métaux précieux) fonctionnant **entièrement sur
l'appareil** : aucun compte à créer, aucun serveur, aucune télémétrie. Positions
et espèces dérivées d'un journal de mouvements, cotations et change via API
tierces, sauvegarde et restauration en JSON, export fiscal documenté, thèmes
clair/sombre/système, français et anglais.

[0.2.0]: https://github.com/sparneo/sparneo/releases/tag/v0.2.0
[0.1.0]: https://github.com/sparneo/sparneo/releases/tag/v0.1.0

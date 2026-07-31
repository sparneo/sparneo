[English](README.en.md) · **Français**

<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/branding/wordmark_dark.png">
  <img alt="Sparneo" src="assets/branding/wordmark_light.png" height="56">
</picture>

*vos comptes, vos données, votre appareil.*

![Platform](https://img.shields.io/badge/platform-Flutter-blue)
![License](https://img.shields.io/badge/license-AGPL%20v3-blue)
![Version](https://img.shields.io/badge/version-0.2.0-orange)

**Votre patrimoine, 100 % local et privé. Aucune inscription, aucun serveur, aucune clé API.**

*Un tracker de patrimoine privé et local-first pour les investisseurs français (PEA / CTO / Assurance-vie) et les métaux précieux physiques.*

[![Fork](https://img.shields.io/github/forks/sparneo/sparneo)](https://github.com/sparneo/sparneo/network)
[![Stars](https://img.shields.io/github/stars/sparneo/sparneo)](https://github.com/sparneo/sparneo/stargazers)
[![Issues](https://img.shields.io/github/issues/sparneo/sparneo)](https://github.com/sparneo/sparneo/issues)

</div>

---

## 📖 À propos du projet

**Sparneo** est une application Flutter de suivi de patrimoine, **100 % locale et privée**, pensée pour les investisseurs français : enveloppes **PEA**, **PEA-PME**, **CTO**, **assurance vie**, **PEE**, **PER**, comptes **crypto** et **espèces**, ainsi que le suivi de l'**or et des métaux précieux physiques** (pièces et lingots) avec prise en compte de la **prime**.

Toutes vos données restent sur votre appareil :

- 🔒 **Aucune inscription, aucun compte** requis.
- 🛰️ **Aucun serveur** : vos positions et vos montants ne quittent jamais votre téléphone.
- 🔑 **Aucune clé API à configurer** : les cours et taux de change proviennent d'APIs publiques et gratuites.

Les données sont stockées localement dans une base **SQLite** (`sqflite`). Les cours de marché ne sont récupérés que pour actualiser les valorisations, à la demande.

## 🔒 Vos données financières vous appartiennent

Les applications de finances personnelles comptent parmi les plus intrusives qui soient : pour fonctionner, elles voient vos revenus, votre épargne, vos habitudes de consommation. Avant d'en adopter une, voici quelques risques à connaître — il s'agit de catégories de pratiques répandues, sans viser quiconque :

- **Agrégation bancaire.** Certaines applications demandent vos identifiants bancaires, ou se connectent à vos comptes via des API d'open banking. Un tiers voit alors l'intégralité de vos flux financiers, en continu. Chaque intermédiaire élargit la surface d'attaque, et vous dépendez de sa sécurité, de sa pérennité et de ses choix futurs.
- **Monétisation des données.** Quand un service financier est gratuit et hébergé, demandez-vous quel est le vrai produit. Un historique de transactions permet un profilage (publicitaire, commercial) d'une précision redoutable, et ce type de données alimente un marché du courtage de données (*data brokers*).
- **Partage avec des tiers.** Les politiques de confidentialité autorisent souvent le partage avec des « partenaires » et sous-traitants. Ces données peuvent aussi être communiquées à des autorités sur demande légale, changer de mains lors d'un rachat de l'entreprise, ou être exposées lors d'une fuite.
- **Centralisation.** Un serveur qui agrège le patrimoine de milliers d'utilisateurs est une cible de choix pour les attaquants — les fuites de données financières sont régulières, et une donnée qui n'est pas collectée est la seule qui ne fuit jamais.

Sparneo réduit ces risques **par conception**, pas par promesse :

- **Aucune donnée ne quitte votre appareil.** Pas de compte, pas de serveur Sparneo, pas de télémétrie ni de traceur. Vos comptes, positions, montants et mouvements vivent dans une base SQLite locale.
- **Aucune connexion à votre banque.** Sparneo ne demande jamais d'identifiants bancaires : vous saisissez (ou importez) vous-même vos positions.
- **Réseau minimal et anonyme.** Les seuls appels réseau sont la récupération de cotations publiques (par symbole : `AAPL`, `BTC-USD`…) et de taux de change (par paire de devises, ex. `USD→EUR`). Jamais vos quantités, montants ou soldes. Le code fait foi : [`lib/services/yahoo_finance_provider.dart`](lib/services/yahoo_finance_provider.dart) et [`lib/services/exchange_rate_service.dart`](lib/services/exchange_rate_service.dart).
- **Code ouvert (AGPL-3.0).** Tout ce qui précède est vérifiable, ligne par ligne.

Honnêteté oblige, ce que cela ne garantit **pas** : les cotations transitent par des API tierces (Yahoo Finance, Frankfurter), qui voient donc votre adresse IP et les symboles demandés — comme n'importe quel site que vous consultez. Et vos données restent à protéger comme le reste du contenu de votre appareil : verrouillage et chiffrement du téléphone, prudence avec les fichiers de sauvegarde que vous exportez (ils contiennent vos données en clair et sont sous votre seule responsabilité). Le local-first supprime des catégories entières de risques ; il ne dispense pas d'hygiène numérique.

## ✨ Fonctionnalités

- **Multi-patrimoines** : gérez plusieurs portefeuilles (ex. « Personnel », « Pro ») et basculez de l'un à l'autre en touchant le nom du patrimoine en haut de l'écran.
- **Comptes typés par enveloppe** : CTO, PEA, PEA-PME, assurance vie, PEE, PER, crypto, espèces, métaux précieux. La nature du compte détermine son mode de valorisation (titres, solde ou métal) ; l'application n'effectue **aucun calcul d'imposition**.
- **Journal des mouvements** par compte : dix natures — achat, vente, dividende, versement, retrait, intérêts, frais, solde initial déclaratif, ajustement et transfert de titres sortant (les trois dernières sont produites par l'application, jamais saisies à la main). Filtrable par nature et par période, modifiable a posteriori.
- **Import de relevé courtier** : chargez un relevé **Bourse Direct** (`.xlsx`) ou un **CSV générique** (délimiteur, encodage, format de date et vocabulaire du courtier détectés puis ajustables) — le fichier est parsé **sur l'appareil**, rien n'est envoyé. Un **aperçu complet** avant toute écriture montre l'effet sur vos positions et vos espèces, signale les doublons ignorés et les lignes à revoir avec leur numéro dans le fichier ; la résolution **ISIN → symbole** est assistée (recherche de cotation, ou repli « non coté » hors ligne pour les titres délistés). Les **opérations sur titres** sont reconnues : sorties de titres, attributions gratuites, rachats de rompus, changements de place de cotation, régularisations d'espèces — les droits de souscription, eux, sont signalés pour revue plutôt que devinés. L'import est **additif et idempotent** — ré-importer le même relevé n'ajoute que les nouveautés — et **annulable** en un geste. Le journal reste la source de vérité : rien n'est jamais écrasé.
- **Positions dérivées du journal** : quantité et **PRU** sont projetés depuis l'historique des mouvements (le journal est la source de vérité), avec plus-value **latente** et plus-value **réalisée** par position.
- **Espèces dérivées du journal** : le solde de liquidités est calculé à partir des mouvements (un achat débite, un dividende crédite…) dès qu'un premier mouvement l'ancre — sur un compte titres comme sur un compte espèces pur, qui dispose de son propre écran et de son propre journal. Les soldes restent **multi-devises**, avec conversion automatique en euros.
- **Type d'actif auto-détecté** (action, ETF, crypto, fonds…) à partir des métadonnées de cotation, avec **remplacement manuel** possible (le choix explicite n'est jamais écrasé).
- **💰 Calcul spécifique métaux précieux** *(fonctionnalité distinctive rare)* : le prix d'une pièce ou d'un lingot est déduit du cours spot selon la formule
  > **prix unitaire = cours spot × poids de métal fin × (1 + prime %)**

  Vous saisissez le poids fin (en grammes) et la prime, l'app valorise chaque unité automatiquement à partir du cours de référence.
- **Graphiques interactifs** (via `fl_chart`) :
  - Évolution de la valeur (patrimoine global, par compte et par position) sur plusieurs périodes (J, 1M, 3M, 1A, 5A, Max). Deux lectures au choix : l'**évolution réelle**, reconstruite depuis votre journal et les cours historiques — ce que vous déteniez vraiment à chaque date, avec la ligne du **capital investi** en regard, dont l'écart à la courbe de valeur *est* le gain — ou **vos positions actuelles** reprojetées sur les cours passés. La courbe des apports s'escamote d'elle-même quand elle écraserait la courbe de valeur, et se rappelle d'un tap.
  - **Performance de la période**, neutre aux apports et aux retraits, affichée à côté de la plus-value — en cumulé, et en annualisé au-delà de dix-huit mois. Le détail du gain total isole l'**impact des frais**.
  - Répartition par compte et par classe d'actifs (camemberts), liquidités incluses.
- **Cibles d'allocation** : définissez un pourcentage cible par classe d'actifs (et pour les liquidités) et suivez les **écarts** entre allocation réelle et cible.
- **Mode dégradé assumé** : en cas de panne réseau ou d'API indisponible, l'app ressert le **dernier cours connu** (persisté localement) en signalant l'ancienneté de la donnée.
- **Sauvegarde & restauration** : export et import de l'intégralité de vos données au format JSON (fichier local ou partage), pour sauvegarder ou migrer d'appareil. À l'import, les positions déclarées sont **réconciliées** avec le journal pour garantir la cohérence. Un export séparé du journal des mouvements d'un patrimoine, au format JSON [documenté et versionné](docs/sparneo-fiscal-export.md), complète cette portabilité de vos données.
- **Réglages** : thème système / clair / sombre, note de confidentialité, licences (AGPL-3.0 et dépendances).
- **Précision monétaire** : les montants du journal sont stockés et calculés en **décimal exact** (jamais en flottant).
- **Accessibilité** : l'interface reste lisible et utilisable jusqu'à l'échelle de police système 2,0 — les rangées trop serrées basculent en colonnes, la densité des graduations d'axes suit la place réellement disponible.
- **Bilingue FR / EN**, interface **Material 3**.

## 📸 Captures d'écran

<div align="center">

<table>
  <tr>
    <td align="center"><img src="screenshots/home.png" alt="Vue Patrimoine" width="200"/></td>
    <td align="center"><img src="screenshots/allocation.png" alt="Répartition &amp; écarts vs cibles" width="200"/></td>
    <td align="center"><img src="screenshots/account.png" alt="Vue Compte" width="200"/></td>
  </tr>
  <tr>
    <td align="center"><sub>Vue Patrimoine —<br/>valeur totale, évolution réelle<br/>&amp; capital investi</sub></td>
    <td align="center"><sub>Répartition —<br/>par compte, par classe d'actifs<br/>&amp; écarts vs cibles</sub></td>
    <td align="center"><sub>Vue Compte —<br/>positions &amp; espèces<br/>d'une enveloppe</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="screenshots/detail.png" alt="Détail Position" width="200"/></td>
    <td align="center"><img src="screenshots/journal.png" alt="Journal des mouvements" width="200"/></td>
    <td align="center"><img src="screenshots/import.png" alt="Import de relevé courtier" width="200"/></td>
  </tr>
  <tr>
    <td align="center"><sub>Détail Position —<br/>plus-values latente<br/>&amp; réalisée</sub></td>
    <td align="center"><sub>Journal —<br/>historique filtrable<br/>des mouvements</sub></td>
    <td align="center"><sub>Import de relevé —<br/>aperçu de l'effet<br/>avant toute écriture</sub></td>
  </tr>
  <tr>
    <td align="center" colspan="3"><img src="screenshots/settings.png" alt="Réglages" width="200"/><br/><sub>Réglages —<br/>thème, sauvegarde &amp; confidentialité</sub></td>
  </tr>
</table>

<p><em>Interface épurée et centrée sur les données. Captures réalisées à partir du jeu de démo ci-dessous.</em></p>

</div>

> 🎬 **Jeu de données de démonstration** : le fichier [`sample_data/demo-backup.json`](sample_data/demo-backup.json) contient le portefeuille fictif d'un épargnant français type (~62 000 €) — six comptes (**PEA**, **Compte-titres**, **Assurance-vie**, **Livret A**, **Crypto**, **Or physique**), quinze lignes (ETF, actions dont une en devise, obligations, foncière, crypto, or papier et pièces d'or au poids et à la prime), dont **une entièrement soldée** — elle ne pèse plus rien aujourd'hui, mais elle porte une plus-value réalisée et reste visible dans l'évolution réelle du patrimoine — et plus de trois ans de journal (**80 mouvements couvrant les dix natures** : versements, achats avec frais, ventes, dividendes, intérêts, droits de garde, retraits, soldes initiaux déclaratifs, ajustements et un transfert de titres sortant), avec cibles d'allocation. L'historique de valorisation n'est pas stocké : il est **reconstruit** depuis ce journal et les cours historiques. Chaque position correspond exactement à la projection de son journal (garanti par un test dédié). Pour l'explorer sans rien saisir, ouvrez **Réglages → Sauvegarde &amp; export → Importer / restaurer** et sélectionnez ce fichier. C'est aussi le jeu utilisé pour les captures ci-dessus.
>
> 📄 **Relevé d'exemple** : [`sample_data/demo-releve.csv`](sample_data/demo-releve.csv) est un relevé courtier fictif au format qu'exportent couramment les courtiers français (séparateur `;`, dates `jj/mm/aaaa`, virgule décimale, encodage Latin-1), dont une ligne identifiée par ISIN. Chargez-le sur le **Compte-titres** du jeu de démo via **⋮ → Importer un relevé…** pour dérouler l'assistant d'import de bout en bout.

## 🛠️ Stack technique

| Technologie | Utilisation |
|-------------|-------------|
| **Framework** | [Flutter](https://flutter.dev) (Dart SDK `^3.11`) |
| **Gestion d'état** | Contrôleurs `ChangeNotifier` + `ListenableBuilder` (pas de Provider ni Riverpod) |
| **Stockage** | SQLite (`sqflite` sur mobile, `sqflite_common_ffi` sur desktop) |
| **Précision décimale** | `decimal` / `rational` (montants exacts, jamais de flottants) |
| **Graphiques** | `fl_chart` |
| **Import de relevés** | `csv`, plus `archive` + `xml` pour lire un `.xlsx` sans dépendance lourde |
| **HTTP** | `http` |
| **Logging** | `logger` |
| **Partage / export** | `share_plus`, `file_picker`, `path_provider` |
| **i18n** | `flutter_localizations` + `gen-l10n` (locales EN / FR) |

L'application vise d'abord le **mobile** (Android / iOS) ; les cibles desktop (Linux, macOS, Windows) sont configurées et fonctionnent via SQLite FFI.

### Sources de données

- **Cours des actifs** : [Yahoo Finance](https://finance.yahoo.com) (endpoint `query1.finance.yahoo.com/v8`).
- **Taux de change** : [frankfurter.app](https://www.frankfurter.app).

Ces deux APIs sont **publiques et sans clé** : rien à configurer. Seuls des symboles et des paires de devises leur sont transmis — jamais vos données patrimoniales.

> ⚠️ **Note honnête** : les cours proviennent de l'**API publique non officielle** de Yahoo Finance. Elle n'offre aucune garantie de disponibilité et peut changer ou cesser de fonctionner sans préavis.
>
> Cette API rejette les clients qui ne s'identifient pas comme un navigateur : l'app envoie donc un User-Agent de navigateur, à l'instar des clients open source habituels de cet endpoint (yfinance, yahoo-finance2 / Ghostfolio, Portfolio Performance...). L'usage reste sobre : requêtes à la demande uniquement, jamais de polling en arrière-plan. En cas d'indisponibilité, l'app ressert le dernier cours connu en indiquant sa date. La source de cotation est isolée derrière une interface remplaçable (`MarketDataProvider`), ce qui permet d'en changer sans toucher au reste de l'app.

## 🚀 Installation

> Les nouveautés et les points d'attention de chaque version sont dans le [journal des versions](CHANGELOG.md) — à lire avant une mise à jour.

### Depuis une release publiée

Les artefacts sont sur la [page des releases](https://github.com/sparneo/sparneo/releases).

- **Android** — téléchargez le `.apk` et installez-le (il faut autoriser l'installation depuis votre navigateur ou votre gestionnaire de fichiers). L'application est signée ; l'empreinte SHA-256 du certificat est publiée dans les notes de chaque release, et reste la même d'une version à l'autre — c'est ce qui permet la mise à jour par-dessus la précédente.
- **Linux x64** — l'archive est portable, elle s'extrait où vous voulez :

    ```bash
    tar xzf sparneo-0.2.0-linux-x64.tar.gz
    cd sparneo-0.2.0
    ./portfolio_tracker          # lancement direct
    ./install.sh                 # ou : entrée de menu + icônes, pour l'utilisateur courant
    ```

    `install.sh` n'écrit que dans `~/.local/share` et pointe l'entrée de menu sur le dossier extrait — ne le déplacez pas sans le relancer. `./uninstall.sh` retire l'entrée et les icônes, sans toucher à vos données.

### Compiler depuis les sources

#### Prérequis

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (canal stable recommandé, Dart `^3.11`)
- Un éditeur de code (VS Code, Android Studio)
- Un émulateur ou un appareil physique connecté

#### Étapes

1. **Cloner le dépôt**
    ```bash
    git clone https://github.com/sparneo/sparneo.git
    cd sparneo
    ```

2. **Installer les dépendances**
    ```bash
    flutter pub get
    ```

3. **(Optionnel) Régénérer les fichiers de localisation**
    ```bash
    flutter gen-l10n
    ```

4. **Lancer l'application**
    ```bash
    flutter run
    ```

Aucune configuration de clé API n'est nécessaire : les sources de données sont publiques.

## 📝 Utilisation

1. **Patrimoines** : au premier lancement, un patrimoine par défaut est créé. Touchez le **nom du patrimoine dans la barre de titre** (nom + chevron) pour ouvrir le sélecteur : basculer entre patrimoines, en créer un nouveau, ou ouvrir « **Gérer les patrimoines** » (renommage, suppression).
2. **Ajouter un compte** : choisissez sa nature (PEA, PEA-PME, CTO, assurance vie, PEE, PER, crypto, espèces, métaux précieux) et sa devise.
3. **Ajouter des positions et des mouvements** :
   - Actions / ETF / crypto : saisissez un symbole (ex. `AAPL`, `BTC-EUR`), déclarez votre position de départ (quantité, PRU optionnel), puis enregistrez vos mouvements (achats, ventes, dividendes…) au fil de l'eau — quantité et PRU sont recalculés automatiquement.
   - Métaux précieux : renseignez le poids de métal fin et la prime ; la valorisation se calcule à partir du cours spot.
   - Espèces : indiquez le solde dans la devise voulue, ou tenez le journal (versements, retraits, intérêts, frais).
4. **Importer un relevé** (plutôt que tout saisir) : depuis le menu **⋮** d'un compte, « **Importer un relevé…** ». L'assistant détecte le format du fichier, vous laissez associer chaque libellé du courtier à une nature de mouvement, puis un aperçu montre l'effet exact sur vos positions et vos espèces avant d'écrire quoi que ce soit. Un import déjà passé peut être annulé d'un geste.
5. **Visualiser** : graphiques d'évolution et de répartition, performance de la période, écarts par rapport à vos cibles d'allocation.
6. **Sauvegarder** : depuis **Réglages → Sauvegarde &amp; export**, exportez vos données (JSON) pour les archiver ou les restaurer sur un autre appareil.

## 📂 Structure du projet

Vue d'ensemble par dossier (plutôt qu'une arborescence fichier par fichier, qui dériverait) :

    lib/
    ├── main.dart          # Point d'entrée, thème, registre de licences
    ├── app_info.dart      # Version affichée & notice de licence
    ├── model/             # Modèles : Wallet, Account, Position, Asset,
    │                      #   AssetTransaction (journal), AllocationTarget
    ├── services/          # Persistance SQLite (schéma & storages), réseau
    │                      #   (cotations Yahoo derrière MarketDataProvider,
    │                      #   taux de change, cache « dernier cours connu »),
    │                      #   sauvegarde/restauration & exports, LedgerService
    │                      #   (projection atomique journal → position & espèces),
    │                      #   import de relevés & résolution d'ISIN
    ├── logic/             # Fonctions pures, testables sans UI ni I/O :
    │                      #   projection de position, allocation & écarts,
    │                      #   agrégation d'historique, valorisation
    ├── controllers/       # État applicatif (ChangeNotifier) : patrimoine
    │                      #   actif, compte, thème
    ├── widgets/           # Écrans & composants : vue patrimoine, vue compte,
    │                      #   détail position, journal, assistant d'import,
    │                      #   réglages, graphiques, dialogues
    ├── theme/             # Palette & thèmes clair/sombre
    ├── utils/             # Formatage, périodes de graphique, logging, snackbars
    └── l10n/              # Localisation FR / EN (gen-l10n, fichiers .arb)

    test/                  # Suite de tests unitaires et de widgets
    docs/                  # Formats de fichiers documentés (export JSON)
    sample_data/           # Jeu de démonstration, relevé d'exemple & générateur
    CHANGELOG.md           # Journal des versions

## 🤝 Contribuer

Les contributions sont les bienvenues !

1. Fork le projet
2. Créez votre branche de fonctionnalité (`git checkout -b feature/AmazingFeature`)
3. Commit vos changements (`git commit -m 'Add some AmazingFeature'`)
4. Push vers la branche (`git push origin feature/AmazingFeature`)
5. Ouvrez une Pull Request

Si vous modifiez des chaînes d'interface, mettez à jour les deux fichiers `lib/l10n/app_fr.arb` et `lib/l10n/app_en.arb`, puis relancez `flutter gen-l10n`. Merci de faire passer `flutter test` avant d'ouvrir la PR.

## 📄 Licence

Distribué sous la licence **GNU Affero General Public License v3.0 (AGPL-3.0)**. Voir le fichier [LICENSE](LICENSE) pour le texte complet.

## 📧 Contact

Lien du projet : [https://github.com/sparneo/sparneo](https://github.com/sparneo/sparneo)

---
<div align="center">
  <sub>Fait avec ❤️ par l'équipe <strong>Sparneo</strong></sub>
</div>

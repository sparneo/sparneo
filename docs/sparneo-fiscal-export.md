# Format `sparneo-fiscal-export`

Sparneo peut exporter l'historique de vos transactions dans un fichier JSON documenté et stable,
destiné à être relu par des **outils fiscaux tiers** (calcul de plus-values, aide à la déclaration…).

Ce format n'est **pas** un calcul fiscal : Sparneo n'y met aucune logique d'imposition. Il se contente
d'exposer fidèlement les **faits bruts** que vous avez saisis (comptes, actifs, transactions). C'est
l'outil qui lit le fichier qui reconstitue lots, prix moyens pondérés, conversions de change et
imputations.

## Principes

- **Produit à la demande**, en local, quand vous appuyez sur « Export fiscal ». Le fichier est écrit
  sur votre appareil ; **aucune donnée n'est envoyée à qui que ce soit**.
- **Aucune information personnelle** au-delà des comptes, actifs, dates et montants que vous détenez
  déjà (pas de nom, pas d'identité).
- **Auto-porteur et versionné.** Le champ `version` identifie la révision du format. Une fois publié,
  le format n'évolue que de façon **additive** (ajout de champs optionnels) ; un changement incompatible
  incrémente `version`.
- **Transactions brutes.** L'export livre vos transactions telles quelles ; la reconstitution
  (lots, prix moyen, change) est faite par l'outil qui consomme le fichier.

## Représentation des montants

Tous les montants (`quantity`, `unitPrice`, `amount`, `fee`) sont des **chaînes de caractères
décimales exactes**, telles que stockées par Sparneo (ex. `"180.1234"`, `"-360.25"`). Elles doivent
être lues comme des **décimaux exacts, jamais comme des flottants** (`parseFloat` interdit — utilisez
une bibliothèque décimale). Sparneo n'effectue **aucun arrondi** : la précision saisie est préservée,
y compris pour les actifs à nombreuses décimales (crypto, change).

Le champ `amount` est **déjà signé** selon le sens du flux de trésorerie :

| `kind`       | Signe de `amount` |
|--------------|-------------------|
| `buy`        | négatif (sortie)  |
| `withdrawal` | négatif (sortie)  |
| `charge`     | négatif en général (sortie) ; **positif** pour un rebate |
| `sell`       | positif (entrée)  |
| `dividend`   | positif (entrée)  |
| `deposit`    | positif (entrée)  |
| `interest`   | positif (entrée)  |

`amount` est l'**effet net signé sur les espèces**, frais et taxes déjà inclus : ne jamais le
recombiner avec `fee` (double comptage). Le consommateur qui reconstitue une trésorerie **somme
`amount` tel quel** (agnostique au signe).

**Devise de cotation vs devise de règlement (v3).** `currency` est la devise de **cotation**
(`quantity`, `unitPrice`, `fee`). `amount`, lui, est exprimé dans la devise de **règlement** — celle
du compte, portée par le champ optionnel `settlementCurrency` **quand elle diffère** de `currency`
(ex. un titre coté en USD réglé en EUR sur un CTO en euros : `currency = "USD"`,
`settlementCurrency = "EUR"`, `amount` en EUR). En son absence, règlement = cotation (mono-devise).
Le taux de change est un **fait passé figé** dans `amount` (le net effectivement débité/crédité au
jour de l'opération) : Sparneo ne le recalcule jamais. C'est précisément la contre-valeur utile à la
plus-value imposable. Ne **jamais** additionner des `amount` de devises de règlement différentes.

Pour `openingBalance` et `adjustment` (voir `transactions.kind` ci-dessous), `amount` dépend de la
variante :

- **Variante titre** (`symbol` non null) : `amount` est **`null`** (déclarer/corriger un lot ne
  déplace pas d'espèces). `openingBalance` déclare une base de coût (`quantity` × `unitPrice`) ;
  `adjustment` porte un delta **signé** de quantité (`quantity` peut être négatif). L'outil
  consommateur reconstitue le coût à partir de `quantity`/`unitPrice`, **pas** de `amount`.
- **Variante espèces** (`symbol` null, **v3**) : `amount` est **signé** et porte le solde initial
  (`openingBalance`) ou le delta de trésorerie (`adjustment`) ; `quantity`/`unitPrice` sont `null`.

## Structure

```json
{
  "format": "sparneo-fiscal-export",
  "version": 3,
  "exportedAt": "2026-04-15T10:00:00.000Z",
  "taxYear": 2025,
  "source": { "app": "Sparneo", "appVersion": "0.1.0" },
  "accounts": [
    { "id": "a-cto", "name": "Compte-Titres", "envelope": "CTO", "currency": "EUR" }
  ],
  "assets": [
    { "symbol": "AAPL", "name": "Apple Inc.", "class": "stock",
      "currency": "USD", "exchange": "NMS", "country": "US" }
  ],
  "transactions": [
    { "id": "t-1", "accountId": "a-cto", "symbol": "AAPL", "kind": "buy",
      "date": "2024-04-05", "quantity": "2", "unitPrice": "180.1234",
      "amount": "-360.25", "fee": "1.20", "currency": "USD" }
  ]
}
```

### Racine

| Champ        | Type    | Description |
|--------------|---------|-------------|
| `format`     | string  | Toujours `"sparneo-fiscal-export"`. |
| `version`    | int     | Version du format (`3`). |
| `exportedAt` | string  | Horodatage ISO-8601 (UTC) de la génération. |
| `taxYear`    | int     | Année de déclaration ciblée. **Métadonnée, pas un filtre** : l'export contient l'historique complet (les acquisitions antérieures sont nécessaires à la reconstitution des lots). |
| `source`     | object  | `{ app, appVersion }`. |

### `accounts`

| Champ      | Type   | Description |
|------------|--------|-------------|
| `id`       | string | Identifiant du compte (référencé par `transactions.accountId`). |
| `name`     | string | Nom du compte. |
| `envelope` | string | Enveloppe fiscale (voir ci-dessous). |
| `currency` | string | Devise du compte (ISO 4217). |

**`envelope`** ∈ `CTO`, `PEA`, `PEA_PME`, `AV` (assurance-vie), `PEE`, `PER`, `CRYPTO`, `AUTRE`.
Sparneo se contente de **transmettre** l'enveloppe déclarée du compte ; il n'attache aucun calcul
d'imposition. C'est à l'outil consommateur de l'interpréter selon le régime applicable (un PEA et un
compte-titres ordinaire, par exemple, relèvent de régimes distincts).

### `assets`

Un actif par `symbol` distinct apparaissant dans les transactions.

| Champ      | Type    | Description |
|------------|---------|-------------|
| `symbol`   | string  | Symbole de l'actif. |
| `name`     | string? | Libellé (peut être `null`). |
| `class`    | string? | Classe d'actif (voir ci-dessous), `null` si inconnue. |
| `currency` | string  | Devise de cotation (ISO 4217). |
| `exchange` | string? | Code place de cotation, `null` si inconnu. |
| `country`  | string? | Pays (ISO 3166-1 alpha-2) dérivé de `exchange`, `null` si indéterminable. |

**`class`** ∈ `etf`, `stock`, `bond`, `crypto`, `fund`, `preciousMetal`, `other`.

> Pour un actif intégralement cédé, Sparneo peut ne plus disposer de ses métadonnées (place, classe) :
> l'entrée est alors émise avec ces champs à `null`, à compléter par l'outil consommateur.

### `transactions`

Triées par `date` croissante puis `id` croissant.

| Champ       | Type    | Description |
|-------------|---------|-------------|
| `id`        | string  | Identifiant de la transaction. |
| `accountId` | string  | Compte de rattachement. |
| `symbol`    | string? | Actif concerné ; `null` pour un mouvement d'espèces (`deposit`/`withdrawal`/`interest`/`charge`, et variante espèces d'`openingBalance`/`adjustment`). |
| `kind`      | string  | `buy`, `sell`, `dividend`, `deposit`, `withdrawal`, `interest`, `charge`, `openingBalance`, `adjustment`. |
| `date`      | string  | Date ISO-8601. |
| `quantity`  | string? | Quantité (décimal exact), `null` pour un mouvement d'espèces. Peut être **négatif** pour un `adjustment` titre (delta signé). |
| `unitPrice` | string? | Prix unitaire (décimal exact), `null` pour un mouvement d'espèces. |
| `amount`    | string? | Montant total **signé** (décimal exact), exprimé dans la **devise de règlement** (`settlementCurrency` si présent, sinon `currency`). |
| `fee`       | string? | Frais (décimal exact), en devise de **cotation** (`currency`). |
| `currency`  | string  | Devise de **cotation** (`quantity`/`unitPrice`/`fee`), ISO 4217. |
| `settlementCurrency` | string? | **v3, optionnel.** Devise de **règlement** de `amount` (celle du compte) quand elle **diffère** de `currency`. Absent = règlement identique à la cotation. |
| `note`      | string? | Note libre, présente uniquement si renseignée. |
| `meta`      | object? | Métadonnées optionnelles (v2), présentes uniquement si non vides. Voir ci-dessous. |

**`kind` — types (v2) :**

- `openingBalance` : **position initiale déclarative** datée. Amorce un lot (quantité + prix
  unitaire déclarés comme base de coût) sans historique d'achat enregistré. Typiquement accompagné de
  `meta.declarative = true` (marqueur d'un lot dont la base de coût est déclarée, cf. `meta`).
  **v3** : une variante ESPÈCES (`symbol` null) déclare le **solde espèces initial** du compte
  (`amount` signé, `quantity`/`unitPrice` null).
- `adjustment` : **correction / inventaire**. Delta **signé** de quantité (`quantity` peut être
  négatif) et de base de coût. Ce n'est **pas** une cession : il ne génère aucune plus-value réalisée.
  **v3** : une variante ESPÈCES (`symbol` null) porte un **ajustement du solde espèces** (`amount`
  = delta signé, `quantity`/`unitPrice` null).

**`kind` — nouveaux types (v3) :**

- `interest` : **intérêts sur espèces** (livret associé au broker, PEA espèces, coupons de fonds
  monétaires…). Mouvement d'espèces (`symbol` généralement null) ; `amount` **positif**. Distinct de
  `dividend` (pas de quantité, régime propre) et de `deposit` (n'est pas un apport externe).
- `charge` : **frais autonomes** non adossés à un trade (droits de garde, frais de place, tenue de
  compte, ligne de taxe isolée). Mouvement d'espèces ; `amount` **signé** (typiquement négatif,
  **positif** pour un rebate). Le montant est porté par `amount` ; `fee` reste `null` sur une ligne
  `charge`.

**`meta`** (v2, optionnel) : objet libre de métadonnées propagé tel quel depuis Sparneo, émis
uniquement s'il est non vide. Clé documentée : `declarative` (bool) — `true` marque un lot dont la
base de coût a été **déclarée** (saisie par l'utilisateur) plutôt qu'issue d'un mouvement d'achat
enregistré (cas d'un `openingBalance`). Sparneo se contente de transmettre ce marqueur ; son
interprétation appartient à l'outil qui lit le fichier. Un consommateur doit **ignorer** les clés
`meta` qu'il ne connaît pas.

### Types de mouvement inconnus

Un `kind` non listé ci-dessus est **invalide** : le consommateur doit le **rejeter** (erreur), jamais
le réinterpréter (ne pas coercer en `buy`). Symétriquement, à l'import d'une **sauvegarde** Sparneo, un
`kind` inconnu fait échouer la restauration de façon **atomique** (données existantes préservées) ; et
une sauvegarde produite par une version plus récente (numéro de `version` supérieur) est refusée plutôt
que relue partiellement.

### Correspondance place → pays

Table utilisée pour dériver `assets.country` depuis `exchange` (valeur `null` si absente de la table) :

```
PAR→FR  AMS→NL  BRU→BE  LIS→PT  XET→DE  FRA→DE  GER→DE
NMS→US  NYQ→US  NGM→US  NGS→US  NCM→US  ASE→US  PCX→US
LSE→GB  MIL→IT  MTA→IT  SWX→CH  EBS→CH  MCE→ES  VIE→AT
STO→SE  HEL→FI  CPH→DK  OSL→NO  TSE→JP  JPX→JP  HKG→HK
TOR→CA  ASX→AU
```

## Versionnement

Le format évolue de manière **additive** : de nouveaux champs optionnels peuvent apparaître sans
changer `version`. Un consommateur doit **ignorer les champs qu'il ne connaît pas**. Un changement
incompatible (renommage, sémantique modifiée) incrémente `version` et fait l'objet d'un double
support pendant une transition.

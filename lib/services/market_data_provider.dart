// services/market_data_provider.dart
import 'package:portfolio_tracker/model/asset_historical_data.dart';
import 'package:portfolio_tracker/model/asset_quote_data.dart';
import 'package:portfolio_tracker/model/isin_search_hit.dart';

/// Point d'extension pour la source de cotation brute (par symbole).
///
/// Ce contrat couvre UNIQUEMENT la récupération de données brutes auprès
/// d'un fournisseur externe (cotation instantanée + historique d'un
/// symbole). Il ne connaît rien de la logique métier de l'app (métaux
/// précieux, conversion EUR, etc.) : cette logique reste dans
/// [MarketDataService], qui orchestre un [MarketDataProvider].
///
/// Objectif : permettre de remplacer la source de cotation (ex. Yahoo
/// Finance) par une autre implémentation sans toucher au reste de l'app.
abstract class MarketDataProvider {
  /// Cotation instantanée d'un [symbol] (devise d'origine, non convertie).
  /// Retourne `null` en cas d'échec définitif (après retries éventuels).
  Future<AssetQuoteData?> getQuoteWithMetadata(String symbol);

  /// Historique des prix d'un [symbol] sur une fenêtre d'environ [days]
  /// jours (l'implémentation choisit la granularité réelle). Retourne
  /// `null` en cas d'échec définitif.
  Future<AssetHistoricalData?> getHistoricalData(String symbol, {int days = 30});

  /// Recherche les places de cotation candidates pour un [isin] auprès de la
  /// source de marché (endpoint `search`). Retourne la liste des hits (au plus
  /// [quotesCount]), VIDE UNIQUEMENT pour une recherche ABOUTIE sans hit
  /// exploitable (ISIN introuvable, titre délisté / purgé) — une liste vide
  /// déclenche alors en aval le repli « actif non coté » (symbole = ISIN). Un
  /// échec RÉSEAU / transport (timeout, statut != 200 après retries) lève au
  /// contraire une `IsinSearchException` (cf. market_data_service.dart), pour
  /// que l'UI distingue « introuvable » d'une panne. La désambiguïsation (choix
  /// du symbole retenu parmi les hits) n'appartient PAS à cette couche.
  Future<List<IsinSearchHit>> searchByIsin(String isin, {int quotesCount = 8});

  /// Vérifie l'EXISTENCE d'un [symbol] auprès de la source de marché, adossée à
  /// `v8/finance/chart/<symbol>` — même endpoint que [getQuoteWithMetadata], mais
  /// lu au niveau du CODE DE STATUT plutôt que de la charge utile (conception
  /// interne, import crypto B16).
  ///
  /// Trois issues, DISTINCTES — c'est la raison d'être de cette méthode par
  /// rapport à [getQuoteWithMetadata]/[getHistoricalData], qui APLATISSENT
  /// aujourd'hui toute erreur (404 symbole invalide inclus) en `null` :
  ///  - `false` : réponse `404` — le symbole N'EXISTE PAS chez le
  ///    fournisseur (constat fiable, jamais un repli sur panne) ;
  ///  - `true` : réponse `200` avec `chart.result` non vide — le symbole
  ///    est valide et coté ;
  ///  - `null` : TOUTE AUTRE issue (timeout, `429` même après backoff,
  ///    erreur socket, autre statut HTTP, `200` sans résultat exploitable…) —
  ///    *inconnu*, jamais assimilable à `false`. Un symbole crypto valide
  ///    (ex. `POL28321-USD`) peut ne pas être vérifiable par la voie `search`
  ///    existante (§14.9) ; cette méthode ne doit jamais le faire passer à
  ///    tort pour inexistant sur une simple panne réseau.
  ///
  /// Pas de cache à ce stade (lot 0) : passthrough pur côté décorateur
  /// [CachingMarketDataProvider].
  Future<bool?> symbolExists(String symbol);

  /// Barres JOURNALIÈRES de [symbol] sur la fenêtre PASSÉE [from]..[to] (bornes
  /// incluses, jours calendaires), via `v8/finance/chart` avec `period1`/`period2`
  /// explicites et `interval=1d` — extension recommandée par le design de l'import
  /// crypto (conception interne, chantier B16 lot 4) : contrairement à
  /// [getHistoricalData], dont l'implémentation Yahoo dégrade la granularité
  /// (hebdomadaire au-delà de ~2 ans, mensuelle au-delà de ~5 ans, cf. son mapping
  /// `days → range`) — donc INUTILISABLE pour retrouver la clôture d'UN jour
  /// précis sur un historique ancien (l'étage 2 de la cascade de valorisation
  /// crypto a justement besoin de la clôture EXACTE du jour d'une opération
  /// passée, parfois vieille de plusieurs années). Vérifié à la main (18/09/2026)
  /// : un actif crypto répond en granularité journalière dès son PREMIER jour
  /// coté, quelle que soit l'ancienneté de la fenêtre demandée.
  ///
  /// Retourne `null` en cas d'échec définitif (après retries éventuels) —
  /// même politique que [getHistoricalData]. Une fenêtre sans AUCUNE barre
  /// (ex. jour non coté, week-end sur un actif qui ne trade pas 24/7) rend
  /// un [AssetHistoricalData] aux listes VIDES plutôt que `null` — à
  /// l'appelant de traiter l'absence de barre pour le jour recherché comme
  /// un échec de CET étage (B4, jamais de coercition), pas une erreur de
  /// transport.
  ///
  /// [maxAttempts] (I-1, revue adversariale LOT 4) : nombre de tentatives
  /// transmis à `retryWithBackoff` côté implémentation — défaut `3` (même
  /// politique que les autres méthodes de ce contrat). L'étage 2 de la
  /// cascade de valorisation crypto ([AccountController.
  /// _resolveMarketHistoryValuations]), best-effort dont l'échec est de
  /// toute façon absorbé par l'étage 3, l'appelle avec `1` pour borner sa
  /// latence pire-cas (3 tentatives × 10 s de timeout, soit ~31,5 s PAR
  /// symbole, serait inadapté à un aperçu synchrone).
  Future<AssetHistoricalData?> getHistoricalRange(
    String symbol,
    DateTime from,
    DateTime to, {
    int maxAttempts = 3,
  });
}

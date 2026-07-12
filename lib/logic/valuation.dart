// lib/logic/valuation.dart

import 'package:portfolio_tracker/model/position_with_market_data.dart';

/// Calculs purs de valorisation en EUR.
///
/// INVARIANT CRITIQUE : les métaux précieux arrivent déjà convertis en EUR
/// par [MarketDataService] (currency == 'EUR'). La conversion USD→EUR s'applique
/// EXCLUSIVEMENT quand [asset.currency] == 'USD'. Ne jamais généraliser à
/// d'autres devises ; ne jamais re-convertir un métal.
class Valuation {
  Valuation._(); // classe non instanciable

  /// Valeur EUR d'une position à partir de son prix courant et de sa quantité.
  ///
  /// Règles de conversion :
  ///   - [asset.currency] == 'USD' → on multiplie par [usdToEurRate].
  ///   - Toute autre devise (dont 'EUR') → pas de conversion.
  ///
  /// Cas dégradés :
  ///   - [price] null → traité comme 0.
  ///   - [qty] non parsable → traité comme 0.
  static double positionValueEur({
    required PositionWithMarketData positionData,
    required double usdToEurRate,
  }) {
    final double price = positionData.currentPrice ?? 0;
    final double qty = double.tryParse(positionData.quantity) ?? 0;
    double value = price * qty;

    if (positionData.asset.currency.toUpperCase() == 'USD') {
      value = value * usdToEurRate;
    }

    return value;
  }

  /// Valeur EUR totale d'un compte investissement à partir de la liste de ses
  /// positions avec données de marché et le taux de change courant.
  static double accountInvestmentTotalEur({
    required List<PositionWithMarketData> positions,
    required double usdToEurRate,
  }) {
    double total = 0;
    for (final pos in positions) {
      total += positionValueEur(positionData: pos, usdToEurRate: usdToEurRate);
    }
    return total;
  }

  /// Solde EUR d'un compte cash. Le solde est supposé déjà converti en EUR
  /// par l'appelant (comme dans [_WalletViewState._loadAllData]).
  ///
  /// Ce helper existe pour documenter la convention : l'appelant doit avoir
  /// appliqué le taux de sa devise AVANT de stocker dans [cashBalanceEurAlready].
  static double cashBalanceEur(double cashBalanceEurAlready) {
    return cashBalanceEurAlready;
  }
}

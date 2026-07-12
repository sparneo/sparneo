// test/widgets/transaction_edit_dialog_test.dart
//
// Tests du TransactionEditDialog et de la fonction pure computeAmount.
//
// Stratégie :
//   - Tests UNITAIRES de computeAmount (logique de calcul d'amount + signe) :
//     les plus à risque, zéro dépendance Flutter.
//   - Tests WIDGET du dialog : construction d'une AssetTransaction valide pour
//     un achat (buy), masquage des champs quantity/unitPrice pour deposit.
//
// Les tests widget n'appellent pas le réseau (aucun MarketDataService ni
// TransactionStorage réel instancié). Le dialog est autonome.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset_transaction.dart';
import 'package:portfolio_tracker/services/exchange_rate_service.dart';
import 'package:portfolio_tracker/widgets/transaction_edit_dialog.dart';

// ---------------------------------------------------------------------------
// Helper : enveloppe Material + l10n pour les tests widget
// ---------------------------------------------------------------------------

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(body: child),
    );

/// Ouvre le dialog dans un MaterialApp avec l10n et retourne la future
/// renvoyée par [showDialog].
Future<AssetTransaction?> _showDialog(
  WidgetTester tester, {
  String accountId = 'acc1',
  String? symbol = 'AAPL',
  String currency = 'EUR',
  AssetTransaction? existing,
}) async {
  AssetTransaction? result;

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Builder(builder: (ctx) {
        return Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              result = await showDialog<AssetTransaction>(
                context: ctx,
                builder: (_) => TransactionEditDialog(
                  accountId: accountId,
                  symbol: symbol,
                  currency: currency,
                  existing: existing,
                ),
              );
            },
            child: const Text('open'),
          ),
        );
      }),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  return result; // null tant que le dialog n'est pas soumis
}

// ---------------------------------------------------------------------------
// 1. Tests unitaires de computeAmount
// ---------------------------------------------------------------------------

void main() {
  group('computeAmount – buy', () {
    test('montant négatif, fee inclus dans le coût', () {
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '150',
        fee: '2',
        rawAmount: null,
      );
      // -(10×150 + 2) = -1502
      expect(r, '-1502');
    });

    test('sans fee', () {
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '5',
        unitPrice: '100',
        fee: '',
        rawAmount: null,
      );
      expect(r, '-500');
    });

    test('retourne null si quantity manquante', () {
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '',
        unitPrice: '100',
        fee: '',
        rawAmount: null,
      );
      expect(r, isNull);
    });

    test('retourne null si unitPrice manquant', () {
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '',
        fee: '',
        rawAmount: null,
      );
      expect(r, isNull);
    });
  });

  group('computeAmount – sell', () {
    test('montant positif, fee déduit du produit', () {
      final r = computeAmount(
        kind: TransactionKind.sell,
        quantity: '10',
        unitPrice: '200',
        fee: '5',
        rawAmount: null,
      );
      // 10×200 − 5 = 1995
      expect(r, '1995');
    });
  });

  group('computeAmount – dividend', () {
    test('montant positif (entrée de cash)', () {
      final r = computeAmount(
        kind: TransactionKind.dividend,
        quantity: '100',
        unitPrice: '0.5',
        fee: '0',
        rawAmount: null,
      );
      // 100×0.5 − 0 = 50
      expect(r, '50');
    });
  });

  group('computeAmount – deposit', () {
    test('montant positif quelle que soit la saisie', () {
      final r = computeAmount(
        kind: TransactionKind.deposit,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '1000',
      );
      expect(r, '1000');
    });

    test('retourne null si rawAmount manquant', () {
      final r = computeAmount(
        kind: TransactionKind.deposit,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '',
      );
      expect(r, isNull);
    });
  });

  group('computeAmount – withdrawal', () {
    test('montant négatif (sortie de cash)', () {
      final r = computeAmount(
        kind: TransactionKind.withdrawal,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '500',
      );
      expect(r, '-500');
    });

    test('montant déjà négatif en entrée → reste négatif', () {
      final r = computeAmount(
        kind: TransactionKind.withdrawal,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '-300',
      );
      expect(r, '-300');
    });
  });

  group('computeAmount – interest', () {
    test('montant positif (entrée de cash), quelle que soit la saisie', () {
      final r = computeAmount(
        kind: TransactionKind.interest,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '3.14',
      );
      expect(r, '3.14');
    });
  });

  group('computeAmount – charge', () {
    test('signe préservé : négatif reste négatif', () {
      final r = computeAmount(
        kind: TransactionKind.charge,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '-12',
      );
      expect(r, '-12');
    });

    test('rebate : positif reste positif (pas de forçage du signe)', () {
      final r = computeAmount(
        kind: TransactionKind.charge,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '5',
      );
      expect(r, '5');
    });
  });

  group('computeAmount – devises croisées (settlementAmount, §8)', () {
    test('buy : net réglé fait autorité, signe négatif, q×p ignorés', () {
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '10',
        unitPrice: '175.50', // cotation USD — IGNORÉE en croisé
        fee: '1.99',
        settlementAmount: '1620.00', // net EUR (magnitude)
      );
      expect(r, '-1620'); // Decimal normalise (-1620.00 → -1620)
    });

    test('sell / dividend / deposit / interest : net positif', () {
      for (final k in [
        TransactionKind.sell,
        TransactionKind.dividend,
        TransactionKind.deposit,
        TransactionKind.interest,
      ]) {
        final r = computeAmount(kind: k, settlementAmount: '250.5');
        expect(r, '250.5', reason: '$k doit être une entrée positive');
      }
    });

    test('withdrawal : net négatif', () {
      final r = computeAmount(
          kind: TransactionKind.withdrawal, settlementAmount: '200');
      expect(r, '-200');
    });

    test('charge : signe PRÉSERVÉ (le signe vient de l\'UI en amont)', () {
      expect(computeAmount(kind: TransactionKind.charge, settlementAmount: '-12'),
          '-12');
      expect(computeAmount(kind: TransactionKind.charge, settlementAmount: '5'),
          '5');
    });

    test('settlementAmount vide/null → retombe sur le calcul mono-devise', () {
      // vide → ignoré, q×p utilisés (chemin legacy).
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '2',
        unitPrice: '100',
        settlementAmount: '',
      );
      expect(r, '-200');
    });

    test('openingBalance/adjustment restent null même avec settlementAmount', () {
      expect(
          computeAmount(
              kind: TransactionKind.openingBalance, settlementAmount: '100'),
          isNull);
      expect(
          computeAmount(
              kind: TransactionKind.adjustment, settlementAmount: '100'),
          isNull);
    });
  });

  group('computeAmount – précision décimale exacte (pivot du cash)', () {
    test('buy 3 × 0.1 sans dérive binaire → "-0.3" (pas -0.30000000000000004)',
        () {
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '3',
        unitPrice: '0.1',
        fee: '',
        rawAmount: null,
      );
      expect(r, '-0.3');
    });

    test('sell 0.1 + 0.2 style : 1 × 0.3 − 0 → "0.3" exact', () {
      final r = computeAmount(
        kind: TransactionKind.sell,
        quantity: '1',
        unitPrice: '0.3',
        fee: '0',
        rawAmount: null,
      );
      expect(r, '0.3');
    });
  });

  group('computeAmount – virgule locale acceptée', () {
    test('buy avec virgule comme séparateur décimal', () {
      final r = computeAmount(
        kind: TransactionKind.buy,
        quantity: '2,5',
        unitPrice: '10',
        fee: '',
        rawAmount: null,
      );
      // -(2.5×10) = -25
      expect(r, '-25');
    });
  });

  group('computeAmount – dividend en montant (q/p optionnels)', () {
    test('q/p absents, rawAmount fourni → montant positif (net encaissé)',
        () {
      final r = computeAmount(
        kind: TransactionKind.dividend,
        quantity: '',
        unitPrice: '',
        fee: '',
        rawAmount: '42.5',
      );
      expect(r, '42.5');
    });

    test('rawAmount négatif saisi par erreur → forcé positif (entrée de cash)',
        () {
      final r = computeAmount(
        kind: TransactionKind.dividend,
        quantity: null,
        unitPrice: null,
        fee: null,
        rawAmount: '-10',
      );
      expect(r, '10');
    });

    test('q×p prioritaire quand les deux chemins sont fournis', () {
      // Si q×p ET rawAmount sont renseignés, le chemin q×p fait foi (fee
      // s'applique), cohérent avec le cas d'usage principal (relevé détaillé).
      final r = computeAmount(
        kind: TransactionKind.dividend,
        quantity: '100',
        unitPrice: '0.5',
        fee: '1',
        rawAmount: '999',
      );
      // 100×0.5 − 1 = 49 (≠ 999)
      expect(r, '49');
    });

    test('rien de fourni (ni q×p, ni montant) → null', () {
      final r = computeAmount(
        kind: TransactionKind.dividend,
        quantity: '',
        unitPrice: '',
        fee: '',
        rawAmount: '',
      );
      expect(r, isNull);
    });

    test('quantité seule (sans prix ni montant) → null (chemin incomplet)',
        () {
      final r = computeAmount(
        kind: TransactionKind.dividend,
        quantity: '10',
        unitPrice: '',
        fee: '',
        rawAmount: '',
      );
      expect(r, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Tests widget du dialog
  // ---------------------------------------------------------------------------

  group('TransactionEditDialog – rendu initial', () {
    testWidgets('dialog buy affiche les champs quantity et unitPrice',
        (tester) async {
      await _showDialog(tester);
      // Les champs sont visibles
      expect(find.byType(TextFormField), findsAtLeastNWidgets(2));
    });

    testWidgets('dialog deposit masque quantity et unitPrice', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: null,
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Changer le kind en "Dépôt"
      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dépôt').last);
      await tester.pumpAndSettle();

      // Les labels quantity/unitPrice ne doivent plus être présents
      expect(find.text('Quantité'), findsNothing);
      expect(find.text('Prix unitaire'), findsNothing);
    });

    testWidgets(
        'dialog interest masque quantity/unitPrice et affiche le montant',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: null,
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Intérêts').last);
      await tester.pumpAndSettle();

      expect(find.text('Quantité'), findsNothing);
      expect(find.text('Prix unitaire'), findsNothing);
      expect(find.widgetWithText(TextFormField, 'Montant total'),
          findsOneWidget);
      // Pas de toggle frais/remboursement pour interest (uniquement charge).
      expect(find.text('Remboursement'), findsNothing);
    });

    testWidgets(
        'dialog charge masque quantity/unitPrice et affiche le toggle de signe',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: null,
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Frais').last);
      await tester.pumpAndSettle();

      expect(find.text('Quantité'), findsNothing);
      expect(find.text('Prix unitaire'), findsNothing);
      // Le champ générique "Frais (optionnel)" (fee) est masqué pour charge —
      // seul le libellé du CHOIX de signe "Frais" doit rester (le ChoiceChip).
      expect(find.text('Frais (optionnel)'), findsNothing);
      expect(find.text('Remboursement'), findsOneWidget);
    });
  });

  group('TransactionEditDialog – soumission buy', () {
    testWidgets('construit une AssetTransaction correcte pour un achat',
        (tester) async {
      AssetTransaction? captured;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: 'AAPL',
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Saisir quantity
      final quantityField = find.widgetWithText(TextFormField, 'Quantité');
      await tester.enterText(quantityField, '10');
      await tester.pumpAndSettle();

      // Saisir unitPrice
      final priceField = find.widgetWithText(TextFormField, 'Prix unitaire');
      await tester.enterText(priceField, '150');
      await tester.pumpAndSettle();

      // Valider
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.kind, TransactionKind.buy);
      expect(captured!.kind.wire, 'buy');
      expect(captured!.quantity, '10');
      expect(captured!.unitPrice, '150');
      expect(captured!.accountId, 'acc1');
      expect(captured!.symbol, 'AAPL');
      expect(captured!.currency, 'EUR');

      // amount doit être négatif (sortie de cash) = -(10×150) = -1500
      expect(captured!.amount, isNotNull);
      final amountVal = double.parse(captured!.amount!);
      expect(amountVal, lessThan(0));
      expect(amountVal, closeTo(-1500.0, 0.001));
    });

    testWidgets('annuler retourne null', (tester) async {
      AssetTransaction? captured = AssetTransaction(
        id: 'sentinel',
        accountId: 'acc1',
        kind: TransactionKind.buy,
        currency: 'EUR',
        date: DateTime(2024),
      );

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: 'AAPL',
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      expect(captured, isNull);
    });
  });

  group('TransactionEditDialog – mode édition', () {
    testWidgets('réutilise l\'id de la transaction existante', (tester) async {
      final existing = AssetTransaction(
        id: 'existing_id_001',
        accountId: 'acc1',
        symbol: 'TSLA',
        kind: TransactionKind.sell,
        quantity: '5',
        unitPrice: '200',
        amount: '1000',
        currency: 'EUR',
        date: DateTime(2025, 3, 15),
      );

      AssetTransaction? captured;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: 'TSLA',
                      currency: 'EUR',
                      existing: existing,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Les champs sont pré-remplis : quantity = 5, unitPrice = 200
      expect(find.text('5'), findsOneWidget);
      expect(find.text('200'), findsOneWidget);

      // Soumettre sans modification
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      // L'id DOIT être celui de la transaction existante
      expect(captured!.id, 'existing_id_001');
      expect(captured!.kind, TransactionKind.sell);
    });
  });

  group('TransactionEditDialog – validation', () {
    testWidgets('buy sans quantity bloque la soumission', (tester) async {
      AssetTransaction? captured;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: 'AAPL',
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Saisir uniquement le prix (pas la quantité)
      final priceField = find.widgetWithText(TextFormField, 'Prix unitaire');
      await tester.enterText(priceField, '100');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      // Le dialog ne doit pas se fermer (captured reste null)
      expect(captured, isNull);
    });
  });

  group('TransactionEditDialog – charge : signe via le toggle', () {
    Future<AssetTransaction?> openChargeDialog(
      WidgetTester tester, {
      required String amountText,
      required bool tapRebate,
    }) async {
      AssetTransaction? captured;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: null,
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Frais').last);
      await tester.pumpAndSettle();

      final amountField = find.widgetWithText(TextFormField, 'Montant total');
      await tester.enterText(amountField, amountText);
      await tester.pumpAndSettle();

      if (tapRebate) {
        await tester.tap(find.text('Remboursement'));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      return captured;
    }

    testWidgets('par défaut (Frais) : montant saisi en magnitude → négatif',
        (tester) async {
      final captured = await openChargeDialog(
        tester,
        amountText: '25',
        tapRebate: false,
      );

      expect(captured, isNotNull);
      expect(captured!.kind, TransactionKind.charge);
      expect(captured.amount, '-25');
      // Le champ `fee` reste null sur une ligne charge (design §4).
      expect(captured.fee, isNull);
    });

    testWidgets('bascule Remboursement : même magnitude → positif',
        (tester) async {
      final captured = await openChargeDialog(
        tester,
        amountText: '25',
        tapRebate: true,
      );

      expect(captured, isNotNull);
      expect(captured!.amount, '25');
    });
  });

  group('TransactionEditDialog – dividend en montant (widget)', () {
    testWidgets('saisie en montant seul (q/p vides) → transaction valide',
        (tester) async {
      AssetTransaction? captured;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: 'AAPL',
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dividende').last);
      await tester.pumpAndSettle();

      // q/p restent vides ; on ne saisit que le montant net encaissé.
      final amountField = find.widgetWithText(TextFormField, 'Montant total');
      await tester.enterText(amountField, '18.42');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.kind, TransactionKind.dividend);
      expect(captured!.quantity, isNull);
      expect(captured!.unitPrice, isNull);
      expect(captured!.amount, '18.42');
    });

    testWidgets('ni q×p ni montant → soumission bloquée (dialog reste ouvert)',
        (tester) async {
      AssetTransaction? captured;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: 'AAPL',
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dividende').last);
      await tester.pumpAndSettle();

      // Rien de saisi (ni q, ni p, ni montant).
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(captured, isNull);
    });

    testWidgets('q×p toujours fonctionnel (non-régression)', (tester) async {
      AssetTransaction? captured;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('fr'),
          home: Builder(builder: (ctx) {
            return Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await showDialog<AssetTransaction>(
                    context: ctx,
                    builder: (_) => const TransactionEditDialog(
                      accountId: 'acc1',
                      symbol: 'AAPL',
                      currency: 'EUR',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dividende').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Quantité'), '100');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Prix unitaire'), '0.5');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.quantity, '100');
      expect(captured!.unitPrice, '0.5');
      expect(captured!.amount, '50');
    });
  });

  // ---------------------------------------------------------------------------
  // 2bis. Nudge fiscal préventif (charge en contexte position)
  // ---------------------------------------------------------------------------

  group('TransactionEditDialog – nudge charge/fee (prévention PRU)', () {
    const hint =
        "Pour les frais d'un ordre, utilisez plutôt le champ frais de "
        "l'achat ou de la vente : eux seuls comptent dans le prix de revient.";

    Future<void> selectCharge(WidgetTester tester) async {
      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Frais').last);
      await tester.pumpAndSettle();
    }

    testWidgets('affiché : kind=charge avec symbol non-null (fiche position)',
        (tester) async {
      await _showDialog(tester, symbol: 'AAPL');
      await selectCharge(tester);

      expect(find.text(hint), findsOneWidget);
    });

    testWidgets('absent : kind=charge avec symbol null (journal du compte)',
        (tester) async {
      await _showDialog(tester, symbol: null);
      await selectCharge(tester);

      expect(find.text(hint), findsNothing);
    });

    testWidgets('absent : symbol non-null mais kind ≠ charge (ex. buy)',
        (tester) async {
      await _showDialog(tester, symbol: 'AAPL');
      // kind par défaut = buy, on ne bascule pas sur charge.

      expect(find.text(hint), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Test du widget _host (smoke test de rendu sans erreur)
  // ---------------------------------------------------------------------------

  group('TransactionEditDialog – rendu sans crash', () {
    testWidgets('s\'affiche sans exception', (tester) async {
      await tester.pumpWidget(
        _host(
          Builder(builder: (ctx) {
            return ElevatedButton(
              onPressed: () {
                showDialog<AssetTransaction>(
                  context: ctx,
                  builder: (_) => const TransactionEditDialog(
                    accountId: 'acc1',
                    symbol: 'ETH',
                    currency: 'USD',
                  ),
                );
              },
              child: const Text('open'),
            );
          }),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Devises croisées (design §8) : champ « net réglé » + settlementCurrency
  // ---------------------------------------------------------------------------

  group('TransactionEditDialog – devises croisées', () {
    // FX déterministe (aucun réseau) : taux figé, injecté dans le dialogue.
    final fakeFx = _FakeFx(0.90);

    // Ouvre le dialogue en devises croisées et renvoie une closure donnant la
    // transaction capturée (null tant que non soumise).
    Future<AssetTransaction? Function()> openCross(
      WidgetTester tester, {
      required String currency,
      String? settlementCurrency,
      AssetTransaction? existing,
    }) async {
      AssetTransaction? captured;
      await tester.pumpWidget(
        _host(
          Builder(builder: (ctx) {
            return ElevatedButton(
              onPressed: () async {
                captured = await showDialog<AssetTransaction>(
                  context: ctx,
                  builder: (_) => TransactionEditDialog(
                    accountId: 'acc1',
                    symbol: 'AAPL',
                    currency: currency,
                    settlementCurrency: settlementCurrency,
                    exchangeRateService: fakeFx,
                    existing: existing,
                  ),
                );
              },
              child: const Text('open'),
            );
          }),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => captured;
    }

    testWidgets('mono-devise (règlement == cotation) : PAS de champ net réglé',
        (tester) async {
      await openCross(tester, currency: 'EUR', settlementCurrency: 'EUR');
      expect(find.text('Montant net réglé (EUR)'), findsNothing);
    });

    testWidgets('settlementCurrency null : PAS de champ net réglé (legacy)',
        (tester) async {
      await openCross(tester, currency: 'USD');
      expect(find.textContaining('Montant net réglé'), findsNothing);
    });

    testWidgets(
        'titre USD / compte EUR : champ net réglé affiché, champs cotation '
        'conservés', (tester) async {
      await openCross(tester, currency: 'USD', settlementCurrency: 'EUR');
      // Champ net réglé (devise du compte).
      expect(find.text('Montant net réglé (EUR)'), findsOneWidget);
      // Les champs de COTATION restent (PRU en USD).
      expect(find.text('Quantité'), findsOneWidget);
      expect(find.text('Prix unitaire'), findsOneWidget);
    });

    testWidgets(
        'buy croisé : amount = net EUR (autorité), settlementCurrency = EUR',
        (tester) async {
      final capture = await openCross(tester,
          currency: 'USD', settlementCurrency: 'EUR');

      // Saisie cotation (USD) — déclenche l'assist FX (non bloquant).
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Quantité'), '10');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Prix unitaire'), '175.50');
      await tester.pumpAndSettle();

      // L'utilisateur confirme/écrase le net réglé (fait autorité).
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Montant net réglé (EUR)'),
          '1620.00');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      final tx = capture();
      expect(tx, isNotNull);
      // amount dans la devise de RÈGLEMENT (EUR), signe buy négatif.
      expect(tx!.amount, '-1620'); // Decimal normalise
      expect(tx.settlementCurrency, 'EUR');
      // La cotation reste USD (pour le PRU) ; quantity/unitPrice figés en USD.
      expect(tx.currency, 'USD');
      expect(tx.quantity, '10');
      expect(tx.unitPrice, '175.50');
    });

    testWidgets('assist FX : préremplit le net réglé depuis q×p × taux courant',
        (tester) async {
      await openCross(tester, currency: 'USD', settlementCurrency: 'EUR');

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Quantité'), '10');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Prix unitaire'), '100');
      await tester.pumpAndSettle();

      // |−(10×100)| × 0.90 = 900.00 prérempli (éditable).
      final netField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Montant net réglé (EUR)'),
      );
      expect(netField.controller!.text, '900.00');
    });
  });

  // ---------------------------------------------------------------------------
  // 5. allowedKinds (filtrage du dropdown) + ceinture-bretelles sur le symbole
  // ---------------------------------------------------------------------------

  group('TransactionEditDialog – allowedKinds', () {
    /// Ouvre le dialog avec [allowedKinds] / [existing] donnés, retourne une
    /// closure exposant la transaction capturée (null tant que non soumise).
    Future<AssetTransaction? Function()> openWithAllowedKinds(
      WidgetTester tester, {
      String? symbol,
      Set<TransactionKind>? allowedKinds,
      AssetTransaction? existing,
    }) async {
      AssetTransaction? captured;
      await tester.pumpWidget(
        _host(
          Builder(builder: (ctx) {
            return ElevatedButton(
              onPressed: () async {
                captured = await showDialog<AssetTransaction>(
                  context: ctx,
                  builder: (_) => TransactionEditDialog(
                    accountId: 'acc1',
                    symbol: symbol,
                    currency: 'EUR',
                    allowedKinds: allowedKinds,
                    existing: existing,
                  ),
                );
              },
              child: const Text('open'),
            );
          }),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => captured;
    }

    testWidgets('filtre le dropdown : seuls les kinds autorisés sont proposés',
        (tester) async {
      await openWithAllowedKinds(
        tester,
        allowedKinds: const {
          TransactionKind.deposit,
          TransactionKind.withdrawal,
        },
      );

      // Ouvre la liste du dropdown.
      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();

      expect(find.text('Dépôt'), findsWidgets);
      expect(find.text('Retrait'), findsWidgets);
      // 'Achat' (buy) n'est PAS dans allowedKinds et n'est pas le kind
      // courant (défaut = premier de allowedKinds, ici deposit) : absent.
      expect(find.text('Achat'), findsNothing);
      expect(find.text('Dividende'), findsNothing);
    });

    testWidgets(
        'édition : un kind hors allowedKinds reste sélectionnable/valide',
        (tester) async {
      final existing = AssetTransaction(
        id: 'legacy_deposit_with_symbol',
        accountId: 'acc1',
        symbol: 'AI.PA', // ligne legacy non-conforme (deposit tamponné d'un
        // symbol) — cf. spec : l'édition ne doit pas être bloquée pour autant.
        kind: TransactionKind.buy,
        quantity: '5',
        unitPrice: '100',
        amount: '-500',
        currency: 'EUR',
        date: DateTime(2024, 1, 10),
      );

      final capture = await openWithAllowedKinds(
        tester,
        symbol: 'AI.PA',
        allowedKinds: const {
          TransactionKind.deposit,
          TransactionKind.withdrawal,
        },
        existing: existing,
      );

      // Le kind courant (buy), hors allowedKinds, reste proposé dans la
      // liste — on l'y sélectionne explicitement pour prouver qu'il est
      // effectivement tappable (pas seulement affiché en valeur figée).
      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      expect(find.text('Achat'), findsWidgets);
      await tester.tap(find.text('Achat').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      final tx = capture();
      expect(tx, isNotNull);
      expect(tx!.kind, TransactionKind.buy);
      expect(tx.id, 'legacy_deposit_with_symbol');
    });

    testWidgets(
        'deposit soumis avec un symbol non-null en entrée émet symbol=null',
        (tester) async {
      final capture = await openWithAllowedKinds(tester, symbol: 'AAPL');

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dépôt').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Montant total'), '100');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      final tx = capture();
      expect(tx, isNotNull);
      expect(tx!.kind, TransactionKind.deposit);
      // Ceinture-bretelles : un mouvement d'espèces pur n'a JAMAIS de symbole,
      // même ouvert depuis une fiche titre (widget.symbol = 'AAPL' ici).
      expect(tx.symbol, isNull);
    });

    testWidgets('charge soumis depuis un contexte avec symbol le conserve',
        (tester) async {
      final capture = await openWithAllowedKinds(tester, symbol: 'AAPL');

      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Frais').last);
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Montant total'), '5');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      final tx = capture();
      expect(tx, isNotNull);
      expect(tx!.kind, TransactionKind.charge);
      // charge : hybride légitime — conserve widget.symbol (frais adossé à
      // une ligne titre).
      expect(tx.symbol, 'AAPL');
    });

    testWidgets('non-régression : buy et sell émettent toujours widget.symbol',
        (tester) async {
      // buy (kind par défaut à la création).
      final captureBuy = await openWithAllowedKinds(tester, symbol: 'AAPL');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Quantité'), '10');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Prix unitaire'), '100');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      final txBuy = captureBuy();
      expect(txBuy, isNotNull);
      expect(txBuy!.kind, TransactionKind.buy);
      expect(txBuy.symbol, 'AAPL');

      // sell.
      final captureSell = await openWithAllowedKinds(tester, symbol: 'TSLA');
      await tester.tap(find.byType(DropdownButtonFormField<TransactionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vente').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Quantité'), '5');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Prix unitaire'), '200');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      final txSell = captureSell();
      expect(txSell, isNotNull);
      expect(txSell!.kind, TransactionKind.sell);
      expect(txSell.symbol, 'TSLA');
    });
  });
}

/// Faux service de change : taux constant, aucun réseau.
class _FakeFx extends ExchangeRateService {
  final double rate;
  _FakeFx(this.rate) : super.forTesting();

  @override
  Future<double> getRateToEur(String currency) async => rate;
}

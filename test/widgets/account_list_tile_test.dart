// test/widgets/account_list_tile_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/widgets/wallet/account_list_tile.dart';

Account _makeAccount({
  String id = 'acc1',
  String name = 'Compte test',
  AccountKind kind = AccountKind.autre,
  String currency = 'EUR',
}) =>
    Account(
      id: id,
      walletId: 'wallet1',
      name: name,
      kind: kind,
      currency: currency,
    );

// AccountListTile utilise AppLocalizations (cashBalanceLabel, localizedLabel) :
// on configure les delegates pour éviter le null-check en test.
Widget _host({
  required Account account,
  double value = 1000.0,
  double change = 50.0,
  double changePercent = 5.0,
  VoidCallback? onTap,
  Future<bool?> Function(DismissDirection)? confirmDismiss,
  void Function(DismissDirection)? onDismissed,
}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('fr'),
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: AccountListTile(
            account: account,
            value: value,
            periodChange: change,
            periodChangePercent: changePercent,
            onTap: onTap ?? () {},
            confirmDismiss:
                confirmDismiss ?? ((_) async => false),
            onDismissed: onDismissed ?? ((_) {}),
          ),
        ),
      ),
    );

void main() {
  testWidgets('affiche le nom et la valeur du compte', (tester) async {
    await tester.pumpWidget(_host(account: _makeAccount(name: 'PEA Bourse')));
    await tester.pumpAndSettle();

    expect(find.text('PEA Bourse'), findsOneWidget);
    // Format FR : « 1 000,00 € » (espaces insécables — \s les matche).
    expect(find.textContaining(RegExp(r'1\s000,00\s€')), findsOneWidget);
  });

  testWidgets('compte investissement affiche variation avec signe +',
      (tester) async {
    await tester.pumpWidget(_host(
      account: _makeAccount(kind: AccountKind.autre),
      change: 42.5,
      changePercent: 4.25,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'\+42,50\s€')), findsOneWidget);
    expect(find.textContaining(RegExp(r'\+4,3\s%')), findsOneWidget);
    // trending_up apparaît dans l'avatar ET dans la ligne de variation (×2)
    expect(find.byIcon(Icons.trending_up), findsAtLeastNWidgets(1));
  });

  testWidgets('compte investissement affiche variation avec signe - quand négatif',
      (tester) async {
    await tester.pumpWidget(_host(
      account: _makeAccount(kind: AccountKind.autre),
      change: -30.0,
      changePercent: -2.9,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'-30,00\s€')), findsOneWidget);
    expect(find.byIcon(Icons.trending_down), findsOneWidget);
  });

  testWidgets('compte cash n\'affiche pas la variation et montre sa nature',
      (tester) async {
    await tester.pumpWidget(_host(
      account: _makeAccount(kind: AccountKind.cash),
    ));
    await tester.pumpAndSettle();

    // Pas d'icône tendance pour les comptes cash
    expect(find.byIcon(Icons.trending_up), findsNothing);
    expect(find.byIcon(Icons.trending_down), findsNothing);
    // Le sous-titre affiche la NATURE du compte (cohérent avec les autres
    // comptes), pas « Solde cash » : le montant est déjà affiché à droite.
    expect(find.text('Cash-Épargne'), findsOneWidget);
  });

  testWidgets('compte métal précieux affiche l\'icône savings_outlined',
      (tester) async {
    await tester.pumpWidget(
        _host(account: _makeAccount(kind: AccountKind.preciousMetal)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.savings_outlined), findsOneWidget);
  });

  testWidgets('compte cash affiche l\'icône account_balance_wallet',
      (tester) async {
    await tester.pumpWidget(_host(account: _makeAccount(kind: AccountKind.cash)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.account_balance_wallet), findsOneWidget);
  });

  testWidgets('compte investissement affiche l\'icône trending_up (avatar)',
      (tester) async {
    await tester.pumpWidget(
        _host(account: _makeAccount(kind: AccountKind.autre)));
    await tester.pumpAndSettle();

    // trending_up apparaît dans l'avatar CircleAvatar ET dans la variation
    expect(find.byIcon(Icons.trending_up), findsAtLeastNWidgets(1));
  });

  testWidgets('onTap déclenché au tap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(
      account: _makeAccount(),
      onTap: () => tapped = true,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ListTile));
    expect(tapped, isTrue);
  });

  testWidgets('aucun overflow sur largeur standard', (tester) async {
    await tester.pumpWidget(_host(
      account: _makeAccount(name: 'Compte avec un nom très long et détaillé'),
      value: 123456.78,
      change: -9876.54,
      changePercent: -7.4,
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

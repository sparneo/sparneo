// Verification-only integration test: drives the real precious-metal add flow
// on the desktop embedder (live network + shared_preferences plugin).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/account.dart';
import 'package:portfolio_tracker/model/wallet.dart';
import 'package:portfolio_tracker/services/account_storage.dart';
import 'package:portfolio_tracker/widgets/account_view.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('add Napoléon 20F coin and see EUR value', (tester) async {
    // Seed a wallet + an investment account through the real storage layer.
    final storage = AccountStorage();
    final wallet = Wallet(id: 'w-verify', name: 'Vérif');
    final account = Account(
      id: 'acc-verify',
      walletId: wallet.id,
      name: 'Coffre',
      kind: AccountKind.preciousMetal,
    );
    await storage.saveWallet(wallet);
    await storage.saveAccount(account);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('fr'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const AccountView(initialAccountId: 'acc-verify'),
    ));
    await tester.pumpAndSettle();

    // 1. On a precious-metal account, the add button opens the metal dialog
    // directly (no asset-type choice).
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    // 2. Dialog opened: pick the Napoléon 20F preset (auto-fills fine weight).
    expect(find.text('Ajouter un métal précieux'), findsOneWidget);
    await tester.tap(find.text('Personnalisé').last); // open preset dropdown
    await tester.pumpAndSettle();
    await tester.tap(find.text('Napoléon 20 F').last);
    await tester.pumpAndSettle();

    // 3. Submit.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Ajouter'));

    // 4. Wait for live Yahoo + FX round-trip and the list to refresh.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('Napoléon 20 F').evaluate().isNotEmpty &&
          find.textContaining('€').evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.text('Napoléon 20 F'), findsWidgets,
        reason: 'the coin position should appear in the list');

    // Capture the value(s) shown for evidence.
    final euroTexts = find
        .textContaining('€')
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .toList();
    debugPrint('VERIFY_EURO_TEXTS=$euroTexts');

    // 5. Open the position detail and edit the premium (0% -> 10%).
    await tester.tap(find.text('Napoléon 20 F').first);
    await tester.pumpAndSettle();

    final premiumRow = find.text('Prime (%)');
    await tester.ensureVisible(premiumRow);
    await tester.pumpAndSettle();
    expect(find.text('0.0 %'), findsOneWidget, reason: 'default premium is 0%');
    await tester.tap(premiumRow);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '10');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Enregistrer'));
    await tester.pumpAndSettle();

    // The premium row reflects the new value immediately (setState, no network).
    expect(find.text('10.0 %'), findsOneWidget,
        reason: 'edited premium should be persisted and shown');
    debugPrint('VERIFY_PREMIUM_EDITED=10.0%');

    // Cleanup seeded state.
    await storage.deleteWallet(wallet.id);
  });
}

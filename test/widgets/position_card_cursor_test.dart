import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portfolio_tracker/l10n/app_localizations.dart';
import 'package:portfolio_tracker/model/asset.dart';
import 'package:portfolio_tracker/model/position.dart';
import 'package:portfolio_tracker/widgets/position_card.dart';

Position _position() => Position(
      accountId: 'acc_1',
      asset: Asset(
        symbol: 'CW8',
        name: 'Amundi MSCI World',
        type: AssetType.etf,
        currency: 'EUR',
      ),
      quantity: '10',
    );

Future<void> _pump(WidgetTester tester, {required VoidCallback? onTap}) {
  return tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: PositionCard(
          position: _position(),
          currentPrice: 100,
          onTap: onTap,
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('curseur « click » au survol quand la carte est cliquable',
      (tester) async {
    await _pump(tester, onTap: () {});
    await tester.pumpAndSettle();

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await gesture.addPointer(location: tester.getCenter(find.byType(PositionCard)));
    addTearDown(gesture.removePointer);
    await tester.pumpAndSettle();

    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
  });

  testWidgets('curseur basique quand la carte n\'est pas cliquable',
      (tester) async {
    await _pump(tester, onTap: null);
    await tester.pumpAndSettle();

    final gesture =
        await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await gesture.addPointer(location: tester.getCenter(find.byType(PositionCard)));
    addTearDown(gesture.removePointer);
    await tester.pumpAndSettle();

    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
  });
}

# AGENTS.md

## Key Commands

- `flutter pub get` - Install dependencies
- `flutter run` - Run the app
- `flutter test` - Run tests
- `flutter analyze` - Lint and typecheck
- `flutter build macos --release` - Build macOS release

## Project Structure

- **Entry point**: `lib/main.dart` → `MainApp` → `WalletView`
- **Models**: `lib/model/` (account, asset, position, wallet)
- **Services**: `lib/services/` (storage, market data, exchange rates)
- **UI**: `lib/widgets/` (pages and components)

## Important Notes

- **Flutter/Dart** project - not Python/JS/other
- Uses `shared_preferences` for local storage
- `fl_chart` for charts, `http` for API calls
- Material 3 design (`useMaterial3: true`)
- Test file (`test/widget_test.dart`) is the default Flutter counter test - not actual app tests
- macOS CI workflow exists (`.github/workflows/macos_build.yml`)
- Market data via public APIs requiring no key: Yahoo Finance (prices) and frankfurter.app (exchange rates)

## Linting

Uses `flutter_lints` via `analysis_options.yaml` - run `flutter analyze` before committing.
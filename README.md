# burna_sms_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

## Testing

We use a layered strategy:

1. Unit tests (business logic) in `test/services/*` using fakes via `ISupabaseService` and injected Daisy client.
2. Widget tests in `test/widgets/*` for UI behavior without full backend init.
3. Golden tests (planned) for visual regression of key widgets (tiles, dialogs, dark theme components).
4. Integration tests in `integration_test/` (placeholder added) to exercise an end-to-end rental flow against a real or locally emulated Supabase + mocked Daisy layer.
5. (Planned) Contract tests for Edge Functions via direct HTTP invocation with test JWT.

### Commands
Run all tests:
```
flutter test
```
Run only service tests:
```
flutter test test/services
```
Collect coverage (generates `coverage/lcov.info`):
```
flutter test --coverage
```
View coverage in VS Code: install the Coverage Gutters extension and load `lcov.info`.

### Adding New Tests
Create a fake implementing `ISupabaseService` for isolation. Avoid hitting live Supabase in unit tests; reserve that for integration tests. When adding a new RPC wrapper, provide a test verifying both success and failure (exception) paths.

### Future Enhancements
- Add golden tests with `golden_toolkit`.
- Use `integration_test` + a seeded local Supabase instance (via `supabase start`) for end-to-end.
- GitHub Actions workflow for CI (test + coverage threshold).


A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

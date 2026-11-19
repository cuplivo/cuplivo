## Summary

<!-- What changed, and why. -->

## Checks

- [ ] `dart analyze --fatal-infos lib test integration_test tool`
- [ ] `flutter test` (or the affected test paths)

## Optional: Android E2E

If this PR changes UI, add one incremental acceptance scenario at
`integration_test/e2e/<name>_test.dart` (start from
`integration_test/e2e/example_acceptance_test.dart`) and comment `/e2e`. Only
the scenario files changed by this PR run; there is no fixed screenshot tour.

The run posts the scenario's screenshots, a key-operations GIF/video and an
installable debug APK back to this PR. It is opt-in and not part of the required
checks. A PR without a changed scenario is skipped without starting an emulator.

See `docs/e2e-android.md` for the incremental contract.

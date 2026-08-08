# Package size baseline (conservative optimization)

Measurement notes for install-package size work. Prefer CI job summaries
(`📏 记录产物体积` in `build-stable-44.yml`) over local numbers when comparing releases.

## Scope of the first conservative pass (no R8 / no behavior change)

| Change | Uncompressed payload (approx.) | Notes |
|--------|--------------------------------:|-------|
| Drop `cupertino_icons` | ~252 KiB font | Unused in `lib/` |
| Drop `reel_text` | Dart-only; AOT delta small | Unused in `lib/` |
| Stop bundling `assets/app_icon.png` (1024²) | −344,499 B | File kept for launcher/splash/packaging |
| Add `assets/app_icon_about.png` (256²) | +37,938 B | About UI only |
| Remove 8 unreferenced `assets/icons/*` | −9,876 B | Exact path audit |
| **Net Flutter asset delta** | **≈ −316 KiB** | Before store/zip compression |

## Commands (local)

```bash
# Android (per-ABI APK)
flutter build apk --release --split-per-abi
ls -lh build/app/outputs/flutter-apk/*.apk

# Optional size analysis JSON
flutter build apk --release --analyze-size

# iOS (unsigned app, same as CI pre-zip)
flutter build ios --release --no-codesign
du -sh build/ios/iphoneos/Runner.app

# Desktop
flutter build macos --release && du -sh build/macos/Build/Products/Release/*.app
flutter build windows --release  # then size Release/ + zip
flutter build linux --release && du -sh build/linux/x64/release/bundle
```

## Fill-in table (after CI or local release builds)

| Artifact | Before (bytes) | After (bytes) | Delta |
|----------|---------------:|--------------:|------:|
| Android arm64-v8a APK | | | |
| Android armeabi-v7a APK | | | |
| Android x86_64 APK | | | |
| iOS Runner.app / IPA | | | |
| macOS .app / DMG | | | |
| Windows zip / setup | | | |
| Linux bundle / tar.gz | | | |

Expected install-package delta from this pass is roughly **0.2–0.4 MiB per
platform** after compression (assets dominate; `reel_text` AOT is secondary).
Larger heads (Lucide fonts, mermaid.js, ML Kit, R8) are intentionally out of scope.

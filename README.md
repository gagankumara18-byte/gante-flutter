# Gante

Gante is a native Flutter alarm app for Android and iOS.

## Features

- Manual alarms with once, daily, weekday, and weekend schedules.
- Natural-language alarms powered by the bundled SmolLM2 135M Instruct model.
- Fully on-device AI with no API key, account, backend, or cloud request.
- Alarm data cached with Android SharedPreferences / iOS UserDefaults.
- Native scheduled notifications that continue when the app is closed.
- A deterministic local parser validates model output and provides a fallback.

The bundled model is `SmolLM2_135M_Instruct.litertlm` (Apache-2.0) from the LiteRT Community repository. It adds approximately 143 MB to the app bundle.

## Run on Android

Install Android Studio and the Android SDK, then run:

```powershell
flutter doctor --android-licenses
flutter doctor -v
flutter run
```

Build an installable APK:

```powershell
flutter build apk --release
```

The APK will be written to `build/app/outputs/flutter-apk/app-release.apk`.

## Notes

- Android requires notification and exact-alarm permissions. Gante requests these on first launch.
- The first use of Ask Gante copies the bundled model into the app's private model store.
- iOS builds require macOS, Xcode, and iOS 16 or later.

# NeonAmp

NeonAmp is a native, local-first music player inspired by Winamp: fast startup, a persistent queue, keyboard-friendly controls, and a dark synthwave visualizer.

## Install

- Windows: run `release/NeonAmp-Setup-0.1.0.exe`.
- Android: install `build/app/outputs/flutter-apk/app-release.apk` on an Android device. Android may require enabling installation from the source used to open the APK.

## Current slice

- Native Windows desktop build and Android APK from one Flutter codebase.
- Import one or more local audio files.
- Persistent queue between launches.
- Play, pause, seek, next, previous, shuffle, repeat state, and volume.
- Responsive layout for desktop and mobile.
- Animated spectrum visualizer.

The Android APK is a debug/distribution artifact signed with Flutter's local release key for direct installation. A Play Store release will need a real upload keystore and store configuration.

## Development

```text
flutter pub get
flutter test
flutter build windows --release
flutter build apk --release
```

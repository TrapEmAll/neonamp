# NeonAmp

NeonAmp is a native, local-first music player inspired by Winamp: fast startup, a persistent queue, keyboard-friendly controls, and a dark synthwave visualizer.

## Install

- Windows: run `release/NeonAmp-Setup-0.1.0.exe`.
- Android: install `build/app/outputs/flutter-apk/app-release.apk` on an Android device. Android may require enabling installation from the source used to open the APK.

## Current slice

- Native Windows desktop build and Android APK from one Flutter codebase.
- Android background playback with lock-screen, headset, notification, and Android Auto media controls.
- Windows global play/pause, stop, previous, and next media keys, including when the app is unfocused.
- Import one or more local audio files.
- Add HTTP audio streams and online radio URLs.
- Search the Radio Browser internet-radio directory and play stations directly.
- Subscribe to podcast RSS feeds, add playable episode enclosures, and download episodes locally.
- Persistent queue between launches.
- Media library with search, favorites, five-star ratings, play counts, and album/artist/genre fields.
- Persistent smart playlists for favorites, top-rated, most-played, genre, and artist rules.
- Embedded album-art display when cover art is available in the audio file.
- Replace embedded cover art for supported local audio containers.
- Named playlists with add-to-playlist actions and M3U export.
- Play, pause, seek, next, previous, shuffle, repeat-all, repeat-one, and volume.
- Shared 10-band equalizer UI with presets and persisted settings.
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

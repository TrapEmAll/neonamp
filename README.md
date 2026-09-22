# NeonAmp

NeonAmp is a native, local-first music player inspired by Winamp: fast startup, a persistent queue, keyboard-friendly controls, and a dark synthwave visualizer.

## Install

- Windows: run `release/NeonAmp-Setup-0.1.0.exe`.
- Android: install `build/app/outputs/flutter-apk/app-release.apk` on an Android device. Android may require enabling installation from the source used to open the APK.

## Current slice

- Native Windows desktop build and Android APK from one Flutter codebase.
- Android background playback with lock-screen, headset, notification, and Android Auto media controls.
- Windows global play/pause, stop, previous, and next media keys, including when the app is unfocused.
- Windows System Media Transport Controls metadata and transport buttons for the current track.
- Import one or more local audio files.
- Play local videos in a separate Windows/Android queue with seeking, speed and volume controls; codec support depends on the device's native decoders.
- Add HTTP audio streams and online radio URLs.
- Search the Radio Browser and SHOUTcast internet-radio directories, merge duplicate streams, compare station metadata, save favorites, and play stations directly.
- Choose from built-in Neon, Aurora, Amber, and Classic skins; the selection persists across launches.
- Import JSON skin packages on Windows or Android; imported skins persist across launches.
- Import portable JSON plugin packages on Windows or Android; enablement and plugin-provided 10-band equalizer presets persist across launches.
- Sync local library tracks to a user-selected device folder on Windows or Android with collision-safe names and an M3U8 manifest.
- Convert local tracks to M4A using native Media Foundation on Windows or MediaCodec on Android, with source metadata restored when supported.
- Import audio CD tracks to standard WAV on Windows; Android exposes the same flow and reports when no optical drive is available.
- Import CUE sheets as segment-aware virtual tracks without splitting or altering the original audio file.
- Subscribe to podcast RSS feeds, add playable episode enclosures, and download episodes locally.
- Import and export podcast subscriptions as OPML files to move feeds between players and devices.
- Manage podcast subscriptions and unsubscribe without removing episodes already added to the queue or library.
- Persistent queue between launches.
- Persistent Bookmarks view for quick access to local tracks, CUE tracks, and radio streams.
- Reorder queued tracks, remove individual tracks, or clear the queue.
- Media library with search, favorites, five-star ratings, play counts, album/artist/genre fields, and editable year, track/disc numbers, and lyrics.
- View embedded lyrics directly from library tracks.
- Metadata editing now verifies that supported embedded tags were written successfully, including core Vorbis tags in OGG and Opus files; APE, AIFF, and common container extensions are included in folder scans.
- Metadata editing also writes common ID3 fields and lyrics into AIFF/AIFC files.
- WMA/ASF tags support common fields, lyrics, and cover art while retaining unknown metadata and encoded media data.
- AAC/ADTS metadata editing writes standard leading ID3v2 tags while preserving the encoded AAC frames.
- WebM/Matroska metadata editing supports common tags and lyrics while keeping encoded clusters intact.
- OGG Vorbis and Opus metadata editing preserves Ogg audio packets and supports common tags, lyrics, track/disc totals, and embedded cover artwork.
- AIFF/AIFC cover-art replacement embeds the selected image as an ID3 picture frame and preserves it during later metadata edits.
- WAV edits store common tags, lyrics, and cover art in an embedded ID3 chunk while preserving existing audio and RIFF chunks.
- AIFF/AIFC and WAV reload and verify ID3 track/disc numbers and totals alongside their existing common tags.
- Select multiple library tracks and apply shared artist, album, genre, year, or rating metadata in one operation on Windows or Android.
- Persistent smart playlists for favorites, top-rated, most-played, genre, and artist rules, including two-rule all/any matching.
- Sort the library by recently added, title, artist, album, rating, or play count with a persisted direction.
- Embedded album-art display when cover art is available in the audio file.
- Replace embedded cover art for supported local audio containers.
- Named playlists with add-to-playlist actions plus M3U/M3U8 and legacy PLS import/export.
- Import and export iTunes-compatible XML libraries, including local-track metadata and named playlists.
- Edit named playlists, rename them, remove them, or remove individual tracks.
- Play, pause, seek, next, previous, shuffle, repeat-all, repeat-one, and volume.
- Adjustable 0.5×–2× playback speed with persisted settings on Windows and Android.
- Persistent 15/30/60/90-minute sleep timer that stops playback on Windows and Android.
- Persistent recently played history with one-tap replay and clear controls.
- Persistent per-track playback positions that resume after restarting the app.
- Native 10-band DSP equalizer for local files with presets and persisted settings.
- Optional ReplayGain normalization from embedded track or album gain tags, persisted across Windows and Android.
- ReplayGain reads Vorbis comments as well as MP3 ID3 user-text and APEv2 gain fields.
- Responsive layout for desktop and mobile.
- Animated spectrum visualizer.
- Desktop Visuals and Settings actions are available on Windows and Android.

The Android APK is a debug/distribution artifact signed with Flutter's local release key for direct installation. A Play Store release will need a real upload keystore and store configuration.

## Development

```text
flutter pub get
flutter test
flutter build windows --release
flutter build apk --release
```

### Skin packages

Skin packages are JSON files with this shape:

```json
{
  "name": "Midnight Citrus",
  "seedColor": "#b7ff4a",
  "backgroundColor": "#10130b"
}
```

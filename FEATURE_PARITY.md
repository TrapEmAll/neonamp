# Android feature-parity matrix

This matrix tracks the Android requirements for the current cross-platform
player. A feature is only considered complete when its user-facing path,
persistence, and native Android integration are present. The final release
phase still requires device testing, bug fixing, and green CI; this document
does not substitute for those checks.

## Implemented in source

| # | Requirement | Current implementation |
|---|---|---|
| 1 | Home-screen widget | `NeonAmpWidgetProvider` supplies compact and full layouts with artwork, play/pause, previous, next, queue, and responsive resizing. |
| 2 | True gapless playback | Android Media3/ExoPlayer queue integration in `MainActivity` keeps adjacent media items in one native player. |
| 3 | A-B loop and bookmarks | Flutter playback state supports A/B loop points, named position bookmarks, persistence, and resume. |
| 4 | Chromecast/Google Cast | Cast framework integration provides discovery, queue transfer, transport, seek, volume, metadata, artwork, and a local media server for device-backed tracks. |
| 5 | SMB/NFS/WebDAV libraries | SAF network-provider folders and authenticated WebDAV browsing/playback are wired into the library and provider cache. |
| 6 | MediaStore integration | Native `READ_MEDIA_AUDIO`/MediaStore scanning adds device music without changing the playback queue. |
| 7 | Android Auto browsing | The media browser exposes all music, artists, albums, favorites, playlists, podcasts, recent items, search, queue actions, and resume playback. |
| 8 | Synchronized LRC lyrics | Embedded and sidecar LRC parsing drives timed highlighting and active-line auto-scroll. |
| 9 | Scrobbling and history export | ListenBrainz/Last.fm-compatible scrobbling, capped play history, UTC timestamps, and JSON export are persisted. |
| 10 | Output/device controls | Native output telemetry exposes device, codec, sample rate, encoding/bit depth, estimated latency, Bluetooth state, reconnect settings, and per-device EQ presets. |
| 11 | Android share/open-with | VIEW, SEND, and SEND_MULTIPLE intents accept audio, streams, playlists, and CUE files, including common playlist MIME types. |
| 12 | Ringtone/snippet export | Non-destructive region selection exports Android ringtone/notification media and AAC snippets through native MediaCodec/MediaStore paths. |
| 13 | Library maintenance | Duplicate, missing/stale permission, changed-only scan, folder statistics, cache, and offline maintenance tools are available. |
| 14 | Album-art improvements | Embedded/folder/downloaded art, crop/resize, cache management, and bounded notification/widget/Auto artwork are supported. |
| 15 | Android UI polish | Edge-to-edge insets, compact player layout, responsive tablet/landscape layout, large-text-safe scaling, dynamic color, and importable themes are supported. |
| 16 | Backup and migration | A versioned backup includes settings, playlists, ratings, resume positions, bookmarks, skins, history, and Android folder-URI inventory. |
| 17 | Queue features | Queue history, play-next, add-to-end, temporary queue behavior, save/restore, reorder, removal, and Auto/widget queue actions are supported. |
| 18 | Battery and storage controls | Provider cache limits, cleanup, offline download indicators, background-scan controls, and Android battery-optimization guidance are present. |
| 19 | Notification customization | Persistent media notification exposes configurable skip, seek, artwork, podcast seek behavior, metadata, and launcher access. |
| 20 | Play Store distribution | ARM-only APK/AAB configuration, upload-keystore wiring, release notes/checklist, split delivery, and Play Integrity backend boundary are documented in `docs/android-play-store.md`. |

## Release gates still required

- Exercise every row on supported ARM Android devices, including folder scans,
  provider-backed playback, Android Auto, widgets, notifications, and Cast.
- Fix regressions found during that pass and add focused tests for each fix.
- Run the complete local checks and GitHub Actions workflow; do not publish a
  release until all required checks are green.
- Configure the real upload keystore, Play Console package/certificate, and
  protected Play Integrity backend outside the repository before store upload.

Play Integrity tokens must be sent to a protected backend for verification;
decryption keys and verdict policy do not belong in the APK.

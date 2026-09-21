# Winamp parity matrix

NeonAmp targets the cross-platform feature set documented for Winamp Desktop and the modern Winamp mobile player. Every user-facing feature is intended to share the same behavior on Windows and Android.

## Implemented in the current build

- Local audio queue and persistent library
- Embedded metadata reading and tag editing for supported MP3/FLAC/M4A/WAV/APE containers plus core Vorbis tags in OGG/Opus, including year, track/disc numbers, lyrics, and write verification
- Batch metadata editing for selected library tracks with per-file failure reporting on Windows and Android
- Embedded album-art reading and display when the source file contains cover art
- Embedded cover-art replacement for supported local containers
- Library search across title, artist, album, and genre
- Smart library filters for favorites, top-rated tracks, and most-played tracks
- Persistent library sorting by added order, title, artist, album, rating, or play count
- Persistent smart playlists with favorites, rating, play-count, genre, and artist rules, including two-rule all/any grouping, sorting, and result limits
- Favorites, five-star ratings, and play counts
- Named playlists and adding library tracks to playlists
- Named playlist editing, renaming, deletion, and per-track removal
- M3U/M3U8 and legacy PLS playlist import/export for local tracks and radio streams
- HTTP audio stream / internet radio URL playback
- Internet-radio station discovery through Radio Browser and SHOUTcast with normalized metadata, duplicate-stream merging, listener sorting, saved station favorites, and lazy stream resolution
- Podcast RSS subscriptions with playable enclosure episodes, refresh, and local downloads
- Recursive folder scanning and M3U/M3U8 playlist import
- Play, pause, seek, previous, next, shuffle, repeat-all, repeat-one, and volume
- Adjustable 0.5×–2× playback speed with persisted settings on Windows and Android
- Persistent queue reordering, per-track removal, and clear-queue controls
- Native 10-band DSP equalizer for local files with presets and persisted settings
- Optional ReplayGain normalization from embedded track or album gain tags on Windows and Android
- Spectrum visualization
- Built-in Neon, Aurora, Amber, and Classic skins with persisted selection
- User-importable JSON skin packages with persisted selection on Windows and Android
- Responsive Windows and Android layouts
- Android background playback with notification, lock-screen, headset, and Android Auto media controls
- Windows global media keys for play/pause, stop, previous, and next
- Windows System Media Transport Controls with lock-screen/taskbar metadata and transport buttons

## Next parity milestones

- Broaden tag-writing coverage beyond the currently supported containers
- Plugin API
- Broader radio-directory metadata and station interoperability
- CD ripping and format conversion on Windows; portable-device sync

The release is not feature-complete Winamp parity until the next-milestone items have native implementations and platform-specific verification.

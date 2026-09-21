# Winamp parity matrix

NeonAmp targets the cross-platform feature set documented for Winamp Desktop and the modern Winamp mobile player. Every user-facing feature is intended to share the same behavior on Windows and Android.

## Implemented in the current build

- Local audio queue and persistent library
- Embedded metadata reading and tag editing for supported MP3/FLAC/M4A/WAV containers
- Embedded album-art reading and display when the source file contains cover art
- Embedded cover-art replacement for supported local containers
- Library search across title, artist, album, and genre
- Smart library filters for favorites, top-rated tracks, and most-played tracks
- Persistent smart playlists with favorites, rating, play-count, genre, and artist rules plus sorting
- Favorites, five-star ratings, and play counts
- Named playlists and adding library tracks to playlists
- M3U playlist export
- HTTP audio stream / internet radio URL playback
- Internet-radio station discovery through the Radio Browser directory
- Podcast RSS subscriptions with playable enclosure episodes, refresh, and local downloads
- Recursive folder scanning and M3U/M3U8 playlist import
- Play, pause, seek, previous, next, shuffle, repeat-all, repeat-one, and volume
- 10-band equalizer surface with presets and persisted settings
- Spectrum visualization
- Responsive Windows and Android layouts
- Android background playback with notification, lock-screen, headset, and Android Auto media controls
- Windows global media keys for play/pause, stop, previous, and next

## Next parity milestones

- Broaden tag-writing coverage beyond the currently supported containers
- True DSP equalizer processing
- More advanced smart-playlist grouping and limits
- Windows system media transport controls beyond global media keys
- Skin/theme packages and a plugin API
- SHOUTcast-specific directory compatibility and station favorites
- CD ripping and format conversion on Windows; portable-device sync

The release is not feature-complete Winamp parity until the next-milestone items have native implementations and platform-specific verification.

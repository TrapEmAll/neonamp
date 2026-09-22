# Winamp parity matrix

NeonAmp targets the cross-platform feature set documented for Winamp Desktop and the modern Winamp mobile player. Every user-facing feature is intended to share the same behavior on Windows and Android.

## Implemented in the current build

- Local audio queue and persistent library
- Native tracker-module playback on Windows and Android for MOD, IT, XM, S3M, MTM, STM, 669, FAR, ULT, and additional libxmp-supported module formats
- Standard MIDI and karaoke MIDI (MID, MIDI, KAR) playback on Windows and Android through each platform's native MIDI-capable player
- Embedded metadata reading and tag editing for supported MP3/FLAC/M4A/WAV/APE containers plus core Vorbis tags in OGG/Opus, including year, track/disc numbers, lyrics, and write verification
- AAC/ADTS metadata editing through leading ID3v2 tags, preserving encoded AAC frames during initial tagging and subsequent edits
- WebM/Matroska audio metadata editing for common fields and lyrics; encoded clusters and unrecognized tags are retained
- WMA/ASF metadata reading and editing for title, artist, album, genre, year, track/disc numbers, lyrics, and embedded cover art; unknown header objects and media packets are preserved
- WAV metadata editing uses embedded ID3 chunks for common fields, lyrics, and artwork while preserving PCM/audio and other RIFF chunks
- AIFF/AIFC and WAV reload track/disc numbers and totals from their embedded ID3 frames, and save verification checks those values
- OGG Vorbis and Opus tag editing rewrites Vorbis comments, including lyrics, totals, and embedded picture blocks, while retaining encoded audio packets
- Batch metadata editing for selected library tracks with per-file failure reporting on Windows and Android
- Embedded album-art reading and display when the source file contains cover art
- Embedded cover-art replacement for supported local containers
- Embedded lyrics editing and in-app lyrics viewing
- AIFF/AIFC metadata and embedded cover-art editing through ID3 chunks, including lyrics
- Library search across title, artist, album, and genre
- Smart library filters for favorites, top-rated tracks, and most-played tracks
- Persistent library sorting by added order, title, artist, album, rating, or play count
- Persistent smart playlists with favorites, rating, play-count, genre, and artist rules, including two-rule all/any grouping, sorting, and result limits
- Favorites, five-star ratings, and play counts
- Named playlists and adding library tracks to playlists
- Persistent bookmarks for local tracks, CUE tracks, and radio/stream URLs
- Named playlist editing, renaming, deletion, and per-track removal
- M3U/M3U8, PLS, Winamp B4S, WPL, and ASX playlist import/export for local tracks and radio streams, including relative local paths
- iTunes-compatible XML library import/export with track metadata and named playlists
- CUE sheet import with virtual per-track queue entries backed by the original continuous audio file and segment-aware seek/progress on Windows and Android
- HTTP audio stream / internet radio URL playback
- DLNA/UPnP renderer discovery and casting of HTTP(S) streams, local audio files, and segment-aware CUE virtual tracks on Windows and Android, with receiver transport controls, relative seek/progress, segment-boundary advancement, and byte-range file serving
- Local video queue for Windows and Android with play/pause, seeking, volume, speed, and fullscreen controls; supported video codecs depend on the platform's native decoder
- Internet-radio station discovery through Radio Browser and SHOUTcast with normalized metadata, duplicate-stream merging, listener sorting, saved station favorites, and lazy stream resolution
- Podcast RSS subscriptions with playable enclosure episodes, refresh, and local downloads
- Podcast subscriptions import/export through interoperable OPML files on Windows and Android
- Podcast subscription management allows unsubscribing without removing existing episodes from the queue/library
- Recursive folder scanning and M3U/M3U8 playlist import
- Play, pause, seek, previous, next, shuffle, repeat-all, repeat-one, and volume
- One-tap 15-second rewind and forward seek on Windows and Android
- Customizable, reorderable player controls with persisted layouts on Windows and Android
- Adjustable 0.5×–2× playback speed with persisted settings on Windows and Android
- Persistent sleep timer with 15/30/60/90-minute playback stop options on Windows and Android
- Persistent recently played history shared by the Windows and Android UIs
- Per-track playback-position resume shared by the Windows and Android UIs
- Persistent queue reordering, per-track removal, and clear-queue controls
- Native 10-band DSP equalizer for local files with presets and persisted settings, plus persisted left/center/right stereo balance across standard playback, DSP playback, and crossfades on Windows and Android
- Optional ReplayGain normalization from embedded track or album gain tags on Windows and Android
- ReplayGain reads Vorbis comments, MP3 ID3 user-text, and APEv2 fields, preferring valid track gain before album gain
- Spectrum visualization
- Built-in Neon, Aurora, Amber, and Classic skins with persisted selection
- User-importable JSON skin packages with persisted selection on Windows and Android
- Portable JSON plugin packages with validated manifests, persisted enablement, and plugin-provided equalizer presets on Windows and Android
- Portable-device folder sync for local tracks with collision-safe copies and an M3U8 manifest on Windows and Android
- Native M4A conversion using Media Foundation on Windows and MediaCodec/MediaMuxer on Android, with metadata restoration
- Audio CD track discovery and WAV ripping through the native Windows CD-ROM API; Android provides the shared UI and safe no-drive response
- Responsive Windows and Android layouts
- Android background playback with notification, lock-screen, headset, and Android Auto media controls
- Windows global media keys for play/pause, stop, previous, and next
- Windows System Media Transport Controls with lock-screen/taskbar metadata and transport buttons

## Next parity milestones

- Broaden playable format coverage to the remaining Winamp-native codecs and legacy formats
- Native binary plugin compatibility remains outside the portable cross-platform API; the supported plugin contract is JSON manifests and host-provided capabilities
- Hardware-specific CD ripping beyond the native Windows CD-ROM path
- Google Cast-only receivers and other non-DLNA casting protocols
- Per-track volume and equalizer processing for Windows MIDI/KAR playback (the built-in Windows MIDI sequencer does not expose per-stream audio gain)

The release is not feature-complete Winamp parity until the next-milestone items have native implementations and platform-specific verification.

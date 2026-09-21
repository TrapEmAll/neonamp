import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NeonAmpApp());
}

class Track {
  Track({
    required this.path,
    required this.name,
    this.artist = 'Local library',
    this.album = 'Unknown album',
    this.genre = 'Unknown genre',
    this.rating = 0,
    this.playCount = 0,
    this.favorite = false,
  });
  final String path;
  final String name;
  final String artist;
  final String album;
  final String genre;
  final int rating;
  final int playCount;
  final bool favorite;

  Track copyWith({
    String? name,
    String? artist,
    String? album,
    String? genre,
    int? rating,
    int? playCount,
    bool? favorite,
  }) => Track(
    path: path,
    name: name ?? this.name,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    genre: genre ?? this.genre,
    rating: rating ?? this.rating,
    playCount: playCount ?? this.playCount,
    favorite: favorite ?? this.favorite,
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'artist': artist,
    'album': album,
    'genre': genre,
    'rating': rating,
    'playCount': playCount,
    'favorite': favorite,
  };

  static Track fromJson(Map<String, dynamic> json) => Track(
    path: json['path'] as String,
    name: json['name'] as String,
    artist: json['artist'] as String? ?? 'Local library',
    album: json['album'] as String? ?? 'Unknown album',
    genre: json['genre'] as String? ?? 'Unknown genre',
    rating: (json['rating'] as num?)?.toInt() ?? 0,
    playCount: (json['playCount'] as num?)?.toInt() ?? 0,
    favorite: json['favorite'] as bool? ?? false,
  );
}

class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

class _NextTrackIntent extends Intent {
  const _NextTrackIntent();
}

class _PreviousTrackIntent extends Intent {
  const _PreviousTrackIntent();
}

class _SeekIntent extends Intent {
  const _SeekIntent(this.amount);
  final Duration amount;
}

class _MuteIntent extends Intent {
  const _MuteIntent();
}

class NeonAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  NeonAudioHandler(this.player) {
    player.onPositionChanged.listen(
      (position) => _broadcast(position: position),
    );
    player.onDurationChanged.listen((duration) {
      final current = mediaItem.value;
      if (current != null) mediaItem.add(current.copyWith(duration: duration));
      _broadcast();
    });
    player.onPlayerStateChanged.listen((state) => _broadcast(state: state));
  }

  final AudioPlayer player;
  Future<void> Function()? onNext;
  Future<void> Function()? onPrevious;

  Future<void> playTrack(Track track) async {
    final duration = mediaItem.value?.duration;
    mediaItem.add(
      MediaItem(
        id: track.path,
        title: track.name,
        artist: track.artist,
        album: track.album,
        duration: duration,
      ),
    );
    await player.stop();
    await player.play(
      track.path.startsWith('http')
          ? UrlSource(track.path)
          : DeviceFileSource(track.path),
    );
  }

  @override
  Future<void> play() => player.resume();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() => player.stop();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    await onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await onPrevious?.call();
  }

  void _broadcast({Duration? position, PlayerState? state}) {
    final currentState = state ?? player.state;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          currentState == PlayerState.playing
              ? MediaControl.pause
              : MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: currentState == PlayerState.completed
            ? AudioProcessingState.completed
            : AudioProcessingState.ready,
        playing: currentState == PlayerState.playing,
        updatePosition: position ?? Duration.zero,
        speed: 1.0,
      ),
    );
  }
}

class NeonAmpApp extends StatelessWidget {
  const NeonAmpApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NeonAmp',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff090a10),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffef4bff),
        brightness: Brightness.dark,
      ),
      fontFamily: 'Segoe UI',
      useMaterial3: true,
    ),
    home: const PlayerPage(),
  );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();
  NeonAudioHandler? _audioHandler;
  final List<Track> _queue = [];
  final List<Track> _library = [];
  final Map<String, List<String>> _playlists = {};
  final TextEditingController _searchController = TextEditingController();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 950),
  )..repeat();
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;
  Duration _position = Duration.zero;
  Duration _duration = const Duration(minutes: 4, seconds: 12);
  PlayerState _playerState = PlayerState.stopped;
  int _selected = 0;
  double _volume = .82;
  bool _shuffle = false;
  bool _repeat = false;
  bool _repeatOne = false;
  bool _crossfade = false;
  int _crossfadeSeconds = 3;
  bool _equalizerEnabled = false;
  String _activeView = 'queue';
  String _searchQuery = '';
  final List<double> _eqBands = List<double>.filled(10, 0);
  String _eqPreset = 'Flat';

  Track? get _current =>
      _queue.isEmpty ? null : _queue[_selected.clamp(0, _queue.length - 1)];
  bool get _isPlaying => _playerState == PlayerState.playing;

  @override
  void initState() {
    super.initState();
    _positionSub = _player.onPositionChanged.listen(
      (value) => setState(() => _position = value),
    );
    _durationSub = _player.onDurationChanged.listen(
      (value) => setState(() => _duration = value),
    );
    _stateSub = _player.onPlayerStateChanged.listen(
      (value) => setState(() => _playerState = value),
    );
    _completeSub = _player.onPlayerComplete.listen((_) => _handleComplete());
    _initializeAudioService();
    _loadQueue();
  }

  Future<void> _initializeAudioService() async {
    if (!Platform.isAndroid) return;
    _audioHandler = await AudioService.init(
      builder: () => NeonAudioHandler(_player),
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.neonamp.audio',
        androidNotificationChannelName: 'NeonAmp playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: false,
      ),
    );
    _audioHandler!.onNext = _next;
    _audioHandler!.onPrevious = _previous;
  }

  Future<void> _handleComplete() async {
    if (_repeatOne) {
      await _player.seek(Duration.zero);
      await _player.resume();
    } else if (_queue.isNotEmpty &&
        (_repeat || _shuffle || _selected < _queue.length - 1)) {
      await _next();
    } else {
      await _player.stop();
    }
  }

  Future<void> _loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('queue') ?? [];
    final savedLibrary = prefs.getStringList('library') ?? [];
    final savedPlaylists = prefs.getString('playlists');
    final savedSettings = prefs.getString('settings');
    if (!mounted) return;
    setState(() {
      _queue.addAll(
        saved.map(
          (path) => Track(path: path, name: path.split(RegExp(r'[/\\]')).last),
        ),
      );
      _library.addAll(
        savedLibrary.map(
          (value) => Track.fromJson(jsonDecode(value) as Map<String, dynamic>),
        ),
      );
      if (savedPlaylists != null) {
        final decoded = jsonDecode(savedPlaylists) as Map<String, dynamic>;
        for (final entry in decoded.entries)
          _playlists[entry.key] = (entry.value as List).cast<String>();
      }
      if (savedSettings != null) {
        final settings = jsonDecode(savedSettings) as Map<String, dynamic>;
        _volume = (settings['volume'] as num?)?.toDouble() ?? _volume;
        _crossfade = settings['crossfade'] as bool? ?? false;
        _crossfadeSeconds =
            (settings['crossfadeSeconds'] as num?)?.toInt() ?? 3;
        _equalizerEnabled = settings['equalizerEnabled'] as bool? ?? false;
        _eqPreset = settings['eqPreset'] as String? ?? 'Flat';
        final savedBands = (settings['eqBands'] as List?)?.cast<num>();
        if (savedBands != null && savedBands.length == _eqBands.length) {
          for (var i = 0; i < _eqBands.length; i++) {
            _eqBands[i] = savedBands[i].toDouble();
          }
        }
      }
    });
  }

  Future<void> _saveQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'queue',
      _queue.map((track) => track.path).toList(),
    );
    await prefs.setStringList(
      'library',
      _library.map((track) => jsonEncode(track.toJson())).toList(),
    );
    await prefs.setString('playlists', jsonEncode(_playlists));
    await prefs.setString(
      'settings',
      jsonEncode({
        'volume': _volume,
        'crossfade': _crossfade,
        'crossfadeSeconds': _crossfadeSeconds,
        'equalizerEnabled': _equalizerEnabled,
        'eqPreset': _eqPreset,
        'eqBands': _eqBands,
      }),
    );
  }

  Future<void> _addFiles() async {
    final result = await FilePicker.pickFiles(type: FileType.audio);
    if (result.isEmpty) return;
    for (final file in result) {
      final path = file.path;
      if (path == null || _queue.any((track) => track.path == path)) continue;
      final track = await _readTrack(path, file.name);
      if (!mounted) return;
      setState(() {
        _queue.add(track);
        if (!_library.any((item) => item.path == path)) _library.add(track);
      });
    }
    await _saveQueue();
    if (_queue.length == result.length && _queue.isNotEmpty) await _select(0);
  }

  Future<void> _addFolder() async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a music folder',
    );
    if (directory == null) return;
    const extensions = {
      '.mp3',
      '.flac',
      '.wav',
      '.ogg',
      '.m4a',
      '.aac',
      '.wma',
      '.opus',
    };
    final files = Directory(directory)
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) => extensions.contains(
            file.path.toLowerCase().substring(file.path.lastIndexOf('.')),
          ),
        )
        .toList();
    for (final file in files) {
      if (_queue.any((track) => track.path == file.path)) continue;
      final track = await _readTrack(file.path, file.uri.pathSegments.last);
      if (!mounted) return;
      setState(() {
        _queue.add(track);
        if (!_library.any((item) => item.path == file.path))
          _library.add(track);
      });
    }
    await _saveQueue();
  }

  Future<void> _importPlaylist() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8'],
    );
    if (result.isEmpty || result.first.path == null) return;
    final lines = await File(result.first.path!).readAsLines();
    for (final raw in lines) {
      final path = raw.trim();
      if (path.isEmpty ||
          path.startsWith('#') ||
          _queue.any((track) => track.path == path))
        continue;
      final name = path.startsWith('http')
          ? (Uri.tryParse(path)?.host ?? 'Internet stream')
          : path.split(RegExp(r'[/\\]')).last;
      final track = Track(
        path: path,
        name: name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        artist: path.startsWith('http') ? 'Online radio' : 'Local library',
      );
      setState(() {
        _queue.add(track);
        if (!_library.any((item) => item.path == path)) _library.add(track);
      });
    }
    await _saveQueue();
  }

  Future<Track> _readTrack(String path, String fileName) async {
    final fallback = fileName.replaceFirst(RegExp(r'\.[^.]+$'), '');
    try {
      final metadata = readMetadata(File(path));
      return Track(
        path: path,
        name: metadata.title?.trim().isNotEmpty == true
            ? metadata.title!.trim()
            : fallback,
        artist: metadata.artist?.trim().isNotEmpty == true
            ? metadata.artist!.trim()
            : 'Local library',
        album: metadata.album?.trim().isNotEmpty == true
            ? metadata.album!.trim()
            : 'Unknown album',
        genre: metadata.genres.isNotEmpty
            ? metadata.genres.first
            : 'Unknown genre',
      );
    } catch (_) {
      return Track(path: path, name: fallback);
    }
  }

  Future<void> _select(int index) async {
    if (index < 0 || index >= _queue.length) return;
    setState(() {
      _selected = index;
      _position = Duration.zero;
      final track = _queue[index];
      final libraryIndex = _library.indexWhere(
        (item) => item.path == track.path,
      );
      if (libraryIndex >= 0)
        _library[libraryIndex] = track.copyWith(playCount: track.playCount + 1);
    });
    await _player.setVolume(_volume);
    final track = _queue[index];
    if (_audioHandler != null) {
      await _audioHandler!.playTrack(track);
    } else {
      await _player.stop();
      await _player.play(
        track.path.startsWith('http')
            ? UrlSource(track.path)
            : DeviceFileSource(track.path),
      );
    }
    await _saveQueue();
  }

  Future<void> _togglePlay() async {
    if (_current == null) {
      await _addFiles();
      return;
    }
    if (_isPlaying) {
      await (_audioHandler?.pause() ?? _player.pause());
    } else if (_playerState == PlayerState.paused) {
      await (_audioHandler?.play() ?? _player.resume());
    } else {
      await _select(_selected);
    }
  }

  Future<void> _next() async {
    if (_queue.isEmpty) return;
    final next = _shuffle
        ? math.Random().nextInt(_queue.length)
        : (_selected + 1) % _queue.length;
    await _select(next);
  }

  Future<void> _previous() async {
    if (_queue.isEmpty) return;
    if (_position.inSeconds > 3) return _player.seek(Duration.zero);
    await _select((_selected - 1 + _queue.length) % _queue.length);
  }

  Future<void> _remove(int index) async {
    setState(() {
      _queue.removeAt(index);
      if (_queue.isEmpty) _selected = 0;
      if (_selected >= _queue.length) _selected = _queue.length - 1;
    });
    await _saveQueue();
  }

  Future<void> _addStream() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add stream URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/stream.mp3',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    setState(
      () => _queue.add(
        Track(
          path: url,
          name: Uri.tryParse(url)?.host ?? 'Internet stream',
          artist: 'Online radio',
        ),
      ),
    );
    await _saveQueue();
  }

  Future<void> _exportPlaylist() async {
    final bytes = Uint8List.fromList(
      utf8.encode('#EXTM3U\n${_queue.map((track) => track.path).join('\n')}\n'),
    );
    await FilePicker.saveFile(
      fileName: 'neonamp-playlist.m3u',
      bytes: bytes,
      mimeType: 'audio/x-mpegurl',
      type: FileType.custom,
      allowedExtensions: ['m3u'],
    );
  }

  List<Track> get _visibleLibrary {
    final query = _searchQuery.toLowerCase();
    return _library
        .where(
          (track) =>
              query.isEmpty ||
              '${track.name} ${track.artist} ${track.album} ${track.genre}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
  }

  void _toggleFavorite(Track track) {
    final index = _library.indexWhere((item) => item.path == track.path);
    if (index < 0) return;
    setState(() => _library[index] = track.copyWith(favorite: !track.favorite));
    _saveQueue();
  }

  Future<void> _editTrack(Track track) async {
    final title = TextEditingController(text: track.name);
    final artist = TextEditingController(text: track.artist);
    final album = TextEditingController(text: track.album);
    final genre = TextEditingController(text: track.genre);
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit metadata'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: artist,
                decoration: const InputDecoration(labelText: 'Artist'),
              ),
              TextField(
                controller: album,
                decoration: const InputDecoration(labelText: 'Album'),
              ),
              TextField(
                controller: genre,
                decoration: const InputDecoration(labelText: 'Genre'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [
              title.text.trim(),
              artist.text.trim(),
              album.text.trim(),
              genre.text.trim(),
            ]),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (values == null || values.length != 4) return;
    try {
      updateMetadata(File(track.path), (metadata) {
        metadata.setTitle(values[0]);
        metadata.setArtist(values[1]);
        metadata.setAlbum(values[2]);
        metadata.setGenres([values[3]]);
      });
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This file format does not support tag writing yet.'),
          ),
        );
    }
    final updated = track.copyWith(
      name: values[0],
      artist: values[1],
      album: values[2],
      genre: values[3],
    );
    setState(() {
      final libraryIndex = _library.indexWhere(
        (item) => item.path == track.path,
      );
      if (libraryIndex >= 0) _library[libraryIndex] = updated;
      for (var i = 0; i < _queue.length; i++) {
        if (_queue[i].path == track.path) _queue[i] = updated;
      }
    });
    await _saveQueue();
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Late night synthwave'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _playlists[name] = []);
    await _saveQueue();
  }

  Future<void> _addTrackToPlaylist(Track track) async {
    if (_playlists.isEmpty) {
      await _createPlaylist();
      if (_playlists.isEmpty) return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add to playlist'),
        children: _playlists.keys
            .map(
              (name) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, name),
                child: Text(name),
              ),
            )
            .toList(),
      ),
    );
    if (name == null) return;
    setState(() {
      final tracks = _playlists[name]!;
      if (!tracks.contains(track.path)) tracks.add(track.path);
    });
    await _saveQueue();
  }

  Future<void> _showEqualizer() async {
    const presets = ['Flat', 'Rock', 'Pop', 'Jazz', 'Classical', 'Bass boost'];
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Text('10-band equalizer'),
              const Spacer(),
              Switch(
                value: _equalizerEnabled,
                onChanged: (value) {
                  setState(() => _equalizerEnabled = value);
                  setDialogState(() {});
                },
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _eqPreset,
                  decoration: const InputDecoration(labelText: 'Preset'),
                  items: presets
                      .map(
                        (preset) => DropdownMenuItem(
                          value: preset,
                          child: Text(preset),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _eqPreset = value;
                      for (var i = 0; i < _eqBands.length; i++) {
                        _eqBands[i] = value == 'Bass boost' && i < 3 ? 6 : 0;
                      }
                    });
                    setDialogState(() {});
                  },
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 180,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: List.generate(
                      _eqBands.length,
                      (index) => Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Slider(
                                  value: _eqBands[index],
                                  min: -12,
                                  max: 12,
                                  onChanged: _equalizerEnabled
                                      ? (value) {
                                          setState(
                                            () => _eqBands[index] = value,
                                          );
                                          setDialogState(() {});
                                        }
                                      : null,
                                ),
                              ),
                            ),
                            Text(
                              '${index + 1}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white38,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    await _saveQueue();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _searchController.dispose();
    _pulse.dispose();
    _player.dispose();
    super.dispose();
  }

  String _time(Duration value) =>
      '${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:${value.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.space): _TogglePlayIntent(),
      SingleActivator(LogicalKeyboardKey.arrowRight): _NextTrackIntent(),
      SingleActivator(LogicalKeyboardKey.arrowLeft): _PreviousTrackIntent(),
      SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
          _SeekIntent(Duration(seconds: 10)),
      SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): _SeekIntent(
        Duration(seconds: -10),
      ),
      SingleActivator(LogicalKeyboardKey.keyM): _MuteIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _TogglePlayIntent: CallbackAction<_TogglePlayIntent>(
          onInvoke: (_) {
            _togglePlay();
            return null;
          },
        ),
        _NextTrackIntent: CallbackAction<_NextTrackIntent>(
          onInvoke: (_) {
            _next();
            return null;
          },
        ),
        _PreviousTrackIntent: CallbackAction<_PreviousTrackIntent>(
          onInvoke: (_) {
            _previous();
            return null;
          },
        ),
        _SeekIntent: CallbackAction<_SeekIntent>(
          onInvoke: (intent) {
            final target = _position + intent.amount;
            _player.seek(
              target < Duration.zero
                  ? Duration.zero
                  : (target > _duration ? _duration : target),
            );
            return null;
          },
        ),
        _MuteIntent: CallbackAction<_MuteIntent>(
          onInvoke: (_) {
            final muted = _volume > 0;
            final nextVolume = muted ? 0.0 : 0.82;
            setState(() => _volume = nextVolume);
            _player.setVolume(nextVolume);
            _saveQueue();
            return null;
          },
        ),
      },
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 600;
              return Column(
                children: [
                  _topBar(compact),
                  Expanded(child: compact ? _compactLayout() : _wideLayout()),
                  _bottomPlayer(),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _topBar(bool compact) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
    child: Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xffef4bff),
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(color: Color(0x66ef4bff), blurRadius: 18),
            ],
          ),
          child: const Icon(Icons.graphic_eq, color: Colors.white),
        ),
        const SizedBox(width: 12),
        const Text(
          'NEONAMP',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 2.6,
            fontSize: 18,
          ),
        ),
        const Spacer(),
        if (MediaQuery.sizeOf(context).width >= 1000) ...[
          _topAction(Icons.equalizer, 'Visuals'),
          const SizedBox(width: 8),
          _topAction(Icons.settings_outlined, 'Settings'),
          const SizedBox(width: 16),
        ],
        FilledButton.icon(
          onPressed: _addFiles,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add music'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xffef4bff),
            foregroundColor: Colors.white,
          ),
        ),
        if (MediaQuery.sizeOf(context).width >= 1000)
          IconButton(
            tooltip: 'Add folder',
            onPressed: _addFolder,
            icon: const Icon(
              Icons.create_new_folder_outlined,
              color: Colors.white60,
            ),
          ),
        if (MediaQuery.sizeOf(context).width >= 1000) ...[
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Add stream URL',
            onPressed: _addStream,
            icon: const Icon(Icons.link, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Equalizer',
            onPressed: _showEqualizer,
            icon: Icon(
              Icons.equalizer,
              color: _equalizerEnabled
                  ? const Color(0xffef4bff)
                  : Colors.white60,
            ),
          ),
          IconButton(
            tooltip: 'Export playlist',
            onPressed: _exportPlaylist,
            icon: const Icon(Icons.ios_share, color: Colors.white60),
          ),
          IconButton(
            tooltip: 'Import M3U playlist',
            onPressed: _importPlaylist,
            icon: const Icon(Icons.file_open_outlined, color: Colors.white60),
          ),
        ] else
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white60),
            onSelected: (value) {
              if (value == 'folder') _addFolder();
              if (value == 'import') _importPlaylist();
              if (value == 'stream') _addStream();
              if (value == 'eq') _showEqualizer();
              if (value == 'export') _exportPlaylist();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'folder', child: Text('Add folder')),
              PopupMenuItem(
                value: 'import',
                child: Text('Import M3U playlist'),
              ),
              PopupMenuItem(value: 'stream', child: Text('Add stream URL')),
              PopupMenuItem(value: 'eq', child: Text('Equalizer')),
              PopupMenuItem(value: 'export', child: Text('Export playlist')),
            ],
          ),
      ],
    ),
  );

  Widget _topAction(IconData icon, String label) => TextButton.icon(
    onPressed: () {},
    icon: Icon(icon, size: 18, color: Colors.white60),
    label: Text(label, style: const TextStyle(color: Colors.white60)),
  );
  Widget _wideLayout() => Row(
    children: [
      SizedBox(width: 330, child: _queuePanel()),
      Expanded(child: _heroPanel()),
    ],
  );
  Widget _compactLayout() => Column(
    children: [
      Expanded(child: _heroPanel()),
      SizedBox(height: 220, child: _queuePanel()),
    ],
  );

  Widget _queuePanel() => Container(
    margin: const EdgeInsets.fromLTRB(24, 8, 12, 12),
    decoration: BoxDecoration(
      color: const Color(0xff11131c),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 12, 8),
          child: Row(
            children: [
              const Text(
                'QUEUE',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  letterSpacing: 1.8,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                '${_queue.length} tracks',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _viewButton('queue', 'Queue', Icons.queue_music),
                _viewButton('library', 'Library', Icons.library_music),
                _viewButton('playlists', 'Playlists', Icons.playlist_play),
              ],
            ),
          ),
        ),
        if (_activeView == 'library')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search artist, album, genre…',
                isDense: true,
              ),
            ),
          ),
        Expanded(
          child: _activeView == 'library'
              ? _libraryView()
              : _activeView == 'playlists'
              ? _playlistView()
              : _queue.isEmpty
              ? _emptyQueue()
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: _queue.length,
                  itemBuilder: (_, index) => _queueItem(index),
                ),
        ),
      ],
    ),
  );

  Widget _viewButton(String view, String label, IconData icon) =>
      TextButton.icon(
        onPressed: () => setState(() => _activeView = view),
        icon: Icon(
          icon,
          size: 15,
          color: _activeView == view ? const Color(0xffef4bff) : Colors.white38,
        ),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: _activeView == view ? Colors.white : Colors.white38,
          ),
        ),
      );

  Widget _libraryView() {
    final tracks = _visibleLibrary;
    if (tracks.isEmpty) return _emptyQueue();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: tracks.length,
      itemBuilder: (_, index) {
        final track = tracks[index];
        return ListTile(
          dense: true,
          leading: const Icon(
            Icons.music_note,
            color: Colors.white38,
            size: 18,
          ),
          title: Text(
            track.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
          subtitle: Text(
            '${track.artist} · ${track.album}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Colors.white38),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  track.favorite ? Icons.favorite : Icons.favorite_border,
                  size: 17,
                  color: track.favorite
                      ? const Color(0xffef4bff)
                      : Colors.white30,
                ),
                onPressed: () => _toggleFavorite(track),
              ),
              IconButton(
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 17,
                  color: Colors.white30,
                ),
                onPressed: () => _editTrack(track),
              ),
              IconButton(
                icon: const Icon(
                  Icons.playlist_add,
                  size: 17,
                  color: Colors.white30,
                ),
                onPressed: () => _addTrackToPlaylist(track),
              ),
            ],
          ),
          onTap: () {
            setState(() {
              _queue.add(track);
              _selected = _queue.length - 1;
            });
            _select(_selected);
          },
        );
      },
    );
  }

  Widget _playlistView() => Column(
    children: [
      TextButton.icon(
        onPressed: _createPlaylist,
        icon: const Icon(Icons.add, size: 16),
        label: const Text('New playlist'),
      ),
      Expanded(
        child: _playlists.isEmpty
            ? _emptyQueue()
            : ListView(
                children: _playlists.keys
                    .map(
                      (name) => ListTile(
                        leading: const Icon(
                          Icons.playlist_play,
                          color: Color(0xffef4bff),
                        ),
                        title: Text(name),
                        subtitle: Text(
                          '${_playlists[name]!.length} tracks',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        onTap: () {
                          setState(() {
                            _queue.clear();
                            _queue.addAll(
                              _playlists[name]!.map(
                                (path) => _library.firstWhere(
                                  (track) => track.path == path,
                                  orElse: () => Track(
                                    path: path,
                                    name: path.split(RegExp(r'[/\\]')).last,
                                  ),
                                ),
                              ),
                            );
                            _selected = 0;
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
      ),
    ],
  );

  Widget _emptyQueue() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.library_music_outlined, color: Colors.white24, size: 42),
          const SizedBox(height: 14),
          const Text(
            'Your library is quiet.',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Drop in a few tracks\nto get the party started.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, height: 1.4, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Widget _queueItem(int index) {
    final track = _queue[index];
    final selected = index == _selected;
    return InkWell(
      onTap: () => _select(index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xff272034) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xffef4bff)
                    : const Color(0xff222532),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                selected && _isPlaying ? Icons.graphic_eq : Icons.music_note,
                size: 17,
                color: selected ? Colors.white : Colors.white38,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontWeight: selected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track.artist,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => _remove(index),
              icon: const Icon(Icons.close, size: 16, color: Colors.white24),
              tooltip: 'Remove',
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroPanel() => AnimatedBuilder(
    animation: _pulse,
    builder: (_, __) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 24, 12),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xff151122), Color(0xff0c1720)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x33ef4bff)),
        ),
        child: Stack(
          children: [
            Positioned(
              top: -80,
              right: -80,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xffef4bff)
                          .withOpacity(.09 + _pulse.value * .03),
                      blurRadius: 100,
                      spreadRadius: 30,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'NOW PLAYING',
                        style: TextStyle(
                          color: Color(0xffef4bff),
                          fontSize: 11,
                          letterSpacing: 2,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        _isPlaying ? Icons.waves : Icons.pause_circle_outline,
                        color: Colors.white30,
                        size: 20,
                      ),
                    ],
                  ),
                  const Spacer(),
                  Center(
                    child: CustomPaint(
                      size: const Size(double.infinity, 160),
                      painter: SpectrumPainter(
                        progress: _pulse.value,
                        active: _isPlaying,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _current?.name ?? 'Nothing queued',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.7,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _current?.artist ?? 'Add local music to begin',
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _bottomPlayer() => Container(
    padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
    decoration: const BoxDecoration(
      color: Color(0xff0c0d14),
      border: Border(top: BorderSide(color: Colors.white10)),
    ),
    child: Column(
      children: [
        Row(
          children: [
            Text(
              _time(_position),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            Expanded(
              child: Slider(
                value: _duration.inMilliseconds == 0
                    ? 0
                    : (_position.inMilliseconds / _duration.inMilliseconds)
                          .clamp(0.0, 1.0),
                onChanged: _duration.inMilliseconds == 0
                    ? null
                    : (value) => _player.seek(
                        Duration(
                          milliseconds: (_duration.inMilliseconds * value)
                              .round(),
                        ),
                      ),
                activeColor: const Color(0xffef4bff),
                inactiveColor: Colors.white12,
              ),
            ),
            Text(
              _time(_duration),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              onPressed: _previous,
              icon: const Icon(Icons.skip_previous_rounded),
              color: Colors.white70,
            ),
            if (MediaQuery.sizeOf(context).width >= 600)
              IconButton(
                onPressed: () => setState(() => _shuffle = !_shuffle),
                icon: const Icon(Icons.shuffle_rounded),
                color: _shuffle ? const Color(0xffef4bff) : Colors.white38,
              ),
            const Spacer(),
            Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xffef4bff),
              ),
              child: IconButton(
                onPressed: _togglePlay,
                icon: Icon(
                  _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                iconSize: 28,
                color: Colors.white,
              ),
            ),
            const Spacer(),
            IconButton(
              onPressed: _next,
              icon: const Icon(Icons.skip_next_rounded),
              color: Colors.white70,
            ),
            if (MediaQuery.sizeOf(context).width >= 600) ...[
              IconButton(
                onPressed: () => setState(() {
                  if (!_repeat && !_repeatOne) {
                    _repeat = true;
                  } else if (_repeat) {
                    _repeat = false;
                    _repeatOne = true;
                  } else {
                    _repeatOne = false;
                  }
                }),
                icon: Icon(
                  _repeatOne ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                ),
                color: (_repeat || _repeatOne)
                    ? const Color(0xffef4bff)
                    : Colors.white38,
              ),
              const SizedBox(width: 14),
              const Icon(
                Icons.volume_up_rounded,
                color: Colors.white38,
                size: 18,
              ),
              SizedBox(
                width: 110,
                child: Slider(
                  value: _volume,
                  onChanged: (value) {
                    setState(() => _volume = value);
                    _player.setVolume(value);
                  },
                  activeColor: Colors.white70,
                  inactiveColor: Colors.white12,
                ),
              ),
            ],
          ],
        ),
      ],
    ),
  );
}

class SpectrumPainter extends CustomPainter {
  const SpectrumPainter({required this.progress, required this.active});
  final double progress;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeCap = StrokeCap.round;
    const count = 52;
    for (var i = 0; i < count; i++) {
      final x = (i + .5) * size.width / count;
      final wave =
          math.sin(i * .66 + progress * math.pi * 2) * .18 +
          math.sin(i * .21 + progress * 4) * .12;
      final normalized = active
          ? (.38 + wave.abs() + (i % 7) * .025)
          : (.12 + (i % 4) * .02);
      final height = size.height * normalized.clamp(.08, .82);
      paint.color = Color.lerp(
        const Color(0xff5b4aff),
        const Color(0xffff4ccf),
        i / count,
      )!.withOpacity(.55 + normalized * .4);
      paint.strokeWidth = math.max(2, size.width / count - 5);
      canvas.drawLine(
        Offset(x, size.height / 2 - height / 2),
        Offset(x, size.height / 2 + height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.active != active;
}

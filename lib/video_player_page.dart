import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

int _wrappedVideoIndex(int index, int length) =>
    ((index % length) + length) % length;

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.files});

  final List<File> files;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  int _index = 0;
  int _loadGeneration = 0;
  bool _loading = true;
  bool _fullScreen = false;
  String? _error;
  double _volume = 1;
  double _speed = 1;

  File get _currentFile => widget.files[_index];

  @override
  void initState() {
    super.initState();
    _loadVideo(0);
  }

  @override
  void didUpdateWidget(covariant VideoPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.files.length != widget.files.length ||
        !_sameFiles(oldWidget.files, widget.files)) {
      _loadVideo(0);
    }
  }

  bool _sameFiles(List<File> left, List<File> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index].path != right[index].path) return false;
    }
    return true;
  }

  Future<void> _loadVideo(int index) async {
    if (widget.files.isEmpty || !mounted) return;
    index = _wrappedVideoIndex(index, widget.files.length);
    final generation = ++_loadGeneration;
    final previous = _controller;
    previous?.removeListener(_onVideoChanged);
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
    });
    if (previous != null) {
      try {
        await previous.dispose();
      } on Object catch (error) {
        debugPrint('Could not dispose previous video controller: $error');
      }
    }
    if (!mounted || generation != _loadGeneration) return;

    final controller = VideoPlayerController.file(_currentFile);
    _controller = controller;
    controller.addListener(_onVideoChanged);
    try {
      await controller.initialize();
      if (!mounted || generation != _loadGeneration) {
        await controller.dispose();
        return;
      }
      await controller.setVolume(_volume);
      await controller.setPlaybackSpeed(_speed);
      await controller.play();
      if (!mounted || generation != _loadGeneration) {
        await controller.dispose();
        return;
      }
      setState(() => _loading = false);
    } on Object catch (error) {
      try {
        await controller.dispose();
      } on Object catch (disposeError) {
        debugPrint('Could not dispose failed video controller: $disposeError');
      }
      if (identical(_controller, controller)) _controller = null;
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _onVideoChanged() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    if (controller.value.hasError && _error == null) {
      setState(() {
        _loading = false;
        _error = controller.value.errorDescription ?? 'Video playback failed.';
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _toggleFullScreen() async {
    final entering = !_fullScreen;
    setState(() => _fullScreen = entering);
    if (!Platform.isAndroid) return;
    try {
      if (entering) {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await _restoreSystemUi();
      }
    } on Object catch (error) {
      debugPrint('Could not change video fullscreen mode: $error');
      if (mounted) setState(() => _fullScreen = !entering);
    }
  }

  Future<void> _restoreSystemUi() async {
    if (!Platform.isAndroid) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
  }

  Future<void> _runVideoCommand(
    Future<void> command, {
    required int generation,
  }) async {
    try {
      await command;
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _runVideoCommandSafely(Future<void> command, {required int generation}) {
    unawaited(_runVideoCommand(command, generation: generation));
  }

  void _disposeVideoResource(Future<void> operation, String description) {
    unawaited(
      operation.catchError((error, stackTrace) {
        debugPrint('$description failed: $error\n$stackTrace');
      }),
    );
  }

  @override
  void dispose() {
    _loadGeneration++;
    final controller = _controller;
    controller?.removeListener(_onVideoChanged);
    if (controller != null) {
      _disposeVideoResource(controller.dispose(), 'Disposing video controller');
    }
    if (_fullScreen) {
      _disposeVideoResource(_restoreSystemUi(), 'Restoring system UI');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('No playable videos were selected.')),
      );
    }
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _fullScreen
          ? null
          : AppBar(
              title: Text(_currentFile.uri.pathSegments.last),
              actions: [
                PopupMenuButton<int>(
                  tooltip: 'Choose video',
                  initialValue: _index,
                  onSelected: _loadVideo,
                  itemBuilder: (context) => [
                    for (var index = 0; index < widget.files.length; index++)
                      PopupMenuItem(
                        value: index,
                        child: Text(widget.files[index].uri.pathSegments.last),
                      ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.video_library_outlined),
                  ),
                ),
                IconButton(
                  tooltip: 'Toggle fullscreen',
                  onPressed: _toggleFullScreen,
                  icon: Icon(
                    _fullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  ),
                ),
              ],
            ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Could not play this video.\n$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      )
                    : _loading || controller == null
                    ? const CircularProgressIndicator()
                    : AspectRatio(
                        aspectRatio: controller.value.aspectRatio > 0
                            ? controller.value.aspectRatio
                            : 16 / 9,
                        child: VideoPlayer(controller),
                      ),
              ),
            ),
            if (!_fullScreen && controller != null && !_loading)
              _controls(controller),
            if (_fullScreen)
              Align(
                alignment: Alignment.bottomRight,
                child: IconButton.filledTonal(
                  tooltip: 'Exit fullscreen',
                  onPressed: _toggleFullScreen,
                  icon: const Icon(Icons.fullscreen_exit),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _controls(VideoPlayerController controller) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        VideoProgressIndicator(
          controller,
          allowScrubbing: true,
          colors: const VideoProgressColors(
            playedColor: Color(0xffef4bff),
            bufferedColor: Colors.white38,
            backgroundColor: Colors.white12,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous video',
              onPressed: widget.files.length < 2
                  ? null
                  : () => _loadVideo(
                      _wrappedVideoIndex(_index - 1, widget.files.length),
                    ),
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton.filledTonal(
              tooltip: controller.value.isPlaying ? 'Pause' : 'Play',
              onPressed: () => _runVideoCommandSafely(
                controller.value.isPlaying
                    ? controller.pause()
                    : controller.play(),
                generation: _loadGeneration,
              ),
              icon: Icon(
                controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            ),
            IconButton(
              tooltip: 'Next video',
              onPressed: widget.files.length < 2
                  ? null
                  : () => _loadVideo(
                      _wrappedVideoIndex(_index + 1, widget.files.length),
                    ),
              icon: const Icon(Icons.skip_next),
            ),
            const Spacer(),
            const Icon(Icons.volume_down, size: 18),
            SizedBox(
              width: 100,
              child: Slider(
                value: _volume,
                onChanged: (value) {
                  setState(() => _volume = value);
                  _runVideoCommandSafely(
                    controller.setVolume(value),
                    generation: _loadGeneration,
                  );
                },
              ),
            ),
            DropdownButton<double>(
              value: _speed,
              underline: const SizedBox.shrink(),
              items: const <double>[0.5, 0.75, 1, 1.25, 1.5, 2]
                  .map(
                    (speed) =>
                        DropdownMenuItem(value: speed, child: Text('$speed×')),
                  )
                  .toList(),
              onChanged: (speed) {
                if (speed == null) return;
                setState(() => _speed = speed);
                _runVideoCommandSafely(
                  controller.setPlaybackSpeed(speed),
                  generation: _loadGeneration,
                );
              },
            ),
            if (Platform.isWindows)
              IconButton(
                tooltip: 'Expand video',
                onPressed: _toggleFullScreen,
                icon: const Icon(Icons.open_in_full),
              ),
          ],
        ),
      ],
    ),
  );
}

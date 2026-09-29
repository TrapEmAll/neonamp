/// High-resolution Direct Stream Digital container formats supported by the
/// library scanner and FFmpeg PCM fallback.
const dsdAudioExtensions = <String>{'dsf', 'dff', 'dsdiff'};

bool isDsdAudioPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  return dsdAudioExtensions.contains(extension);
}

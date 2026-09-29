const convolutionImpulseExtensions = {'wav', 'flac', 'aif', 'aiff', 'ogg', 'oga', 'opus'};

bool isSupportedImpulseResponsePath(String path) {
  final normalized = path.split('.').last.toLowerCase();
  return convolutionImpulseExtensions.contains(normalized);
}

String buildConvolutionFilter({String? equalizerFilter}) {
  const convolution = 'afir=dry=1:wet=1';
  if (equalizerFilter == null || equalizerFilter.isEmpty) {
    return '[0:a:0][1:a:0]$convolution[out]';
  }
  return '[0:a:0][1:a:0]$convolution[conv];[conv]$equalizerFilter[out]';
}

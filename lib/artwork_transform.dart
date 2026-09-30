import 'dart:typed_data';
import 'dart:ui' as ui;

class ArtworkTransformOptions {
  const ArtworkTransformOptions({
    required this.maxDimension,
    required this.cropToSquare,
    this.useOriginal = false,
  });

  final int maxDimension;
  final bool cropToSquare;
  final bool useOriginal;
}

class TransformedArtwork {
  const TransformedArtwork({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

ui.Rect centeredArtworkCropRect(int width, int height) {
  if (width <= 0 || height <= 0) return ui.Rect.zero;
  final side = width < height ? width.toDouble() : height.toDouble();
  final left = (width - side) / 2;
  final top = (height - side) / 2;
  return ui.Rect.fromLTWH(left, top, side, side);
}

Future<TransformedArtwork> transformArtwork(
  Uint8List bytes, {
  required ArtworkTransformOptions options,
}) async {
  if (bytes.isEmpty) throw const FormatException('Artwork is empty.');
  if (options.useOriginal) {
    return TransformedArtwork(bytes: bytes, mimeType: 'image/jpeg');
  }
  if (options.maxDimension < 64 || options.maxDimension > 4096) {
    throw const FormatException('Artwork size must be between 64 and 4096 pixels.');
  }

  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final source = options.cropToSquare
          ? centeredArtworkCropRect(image.width, image.height)
          : ui.Rect.fromLTWH(
              0,
              0,
              image.width.toDouble(),
              image.height.toDouble(),
            );
      if (source.isEmpty) throw const FormatException('Artwork has no pixels.');
      final scale = options.cropToSquare
          ? options.maxDimension / source.width
          : (options.maxDimension / source.width)
              .clamp(0.0, options.maxDimension / source.height);
      final outputWidth = (source.width * scale).round().clamp(1, 4096).toInt();
      final outputHeight =
          (source.height * scale).round().clamp(1, 4096).toInt();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        source,
        ui.Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final output = await (await recorder.endRecording().toImage(
        outputWidth,
        outputHeight,
      )).toByteData(format: ui.ImageByteFormat.png);
      if (output == null) {
        throw const FormatException('Could not encode transformed artwork.');
      }
      return TransformedArtwork(
        bytes: output.buffer.asUint8List(),
        mimeType: 'image/png',
      );
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

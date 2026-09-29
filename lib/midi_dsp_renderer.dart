import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_melty_soundfont/audio_renderer_ex.dart';
import 'package:dart_melty_soundfont/midi_file.dart';
import 'package:dart_melty_soundfont/midi_file_sequencer.dart';
import 'package:dart_melty_soundfont/synthesizer.dart';
import 'package:dart_melty_soundfont/synthesizer_settings.dart';

const midiRenderSampleRate = 44100;
const midiRenderTail = Duration(milliseconds: 1800);
const maxMidiRenderDuration = Duration(hours: 3);
const _framesPerRender = 4096;

int midiRenderFrameCount(Duration midiLength) {
  if (midiLength <= Duration.zero) {
    throw const FormatException('The MIDI file contains no playable events.');
  }
  final duration = midiLength + midiRenderTail;
  if (duration > maxMidiRenderDuration) {
    throw const FormatException(
      'MIDI files longer than 3 hours are not supported.',
    );
  }
  final frames = (duration.inMicroseconds * midiRenderSampleRate) ~/ 1000000;
  if (frames * 4 > 0xffffffff - 36) {
    throw const FormatException('The rendered MIDI file is too large.');
  }
  return frames;
}

/// Renders a MIDI file through the user's SoundFont into a temporary PCM WAV.
/// The work runs off the UI isolate because SoundFont loading and synthesis
/// are CPU intensive. The returned file can be played by the existing DSP
/// engine, so EQ, balance, volume and transport controls behave consistently
/// on Windows and Android.
Future<String> renderMidiToWav({
  required String midiPath,
  required String soundFontPath,
  required String outputPath,
}) => Isolate.run(() => _renderMidiToWav(midiPath, soundFontPath, outputPath));

Future<void> validateMidiSoundFont(String path) => Isolate.run(() {
  Synthesizer.loadPath(
    path,
    SynthesizerSettings(
      sampleRate: midiRenderSampleRate,
      blockSize: 128,
      maximumPolyphony: 128,
    ),
  );
});

String _renderMidiToWav(
  String midiPath,
  String soundFontPath,
  String outputPath,
) {
  final midi = MidiFile.fromFile(midiPath);
  if (midi.messages.isEmpty || midi.length <= Duration.zero) {
    throw const FormatException('The MIDI file contains no playable events.');
  }

  final synthesizer = Synthesizer.loadPath(
    soundFontPath,
    SynthesizerSettings(
      sampleRate: midiRenderSampleRate,
      blockSize: 128,
      maximumPolyphony: 128,
    ),
  );
  final sequencer = MidiFileSequencer(synthesizer)..play(midi, loop: false);
  final totalFrames = midiRenderFrameCount(midi.length);
  final dataBytes = totalFrames * 4;

  final output = File(outputPath);
  RandomAccessFile? handle;
  try {
    output.parent.createSync(recursive: true);
    handle = output.openSync(mode: FileMode.write);
    handle.writeFromSync(midiPcmWaveHeader(dataBytes));
    final frames = math.min(_framesPerRender, totalFrames).toInt();
    final samples = Float32List(frames * 2);
    final pcm = Int16List(frames * 2);
    var renderedFrames = 0;
    while (renderedFrames < totalFrames) {
      final count = math.min(frames, totalFrames - renderedFrames);
      sequencer.renderInterleaved(samples, length: count);
      for (var i = 0; i < count * 2; i++) {
        pcm[i] = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      }
      handle.writeFromSync(Uint8List.view(pcm.buffer, 0, count * 4));
      renderedFrames += count;
    }
    handle.closeSync();
    handle = null;
    return outputPath;
  } on Object {
    handle?.closeSync();
    if (output.existsSync()) output.deleteSync();
    rethrow;
  } finally {
    sequencer.stop();
  }
}

Uint8List midiPcmWaveHeader(int dataBytes) {
  if (dataBytes < 0 || dataBytes > 0xffffffff - 36 || dataBytes % 4 != 0) {
    throw RangeError.value(dataBytes, 'dataBytes');
  }
  final header = Uint8List(44);
  final bytes = ByteData.sublistView(header);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      header[offset + i] = value.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, dataBytes + 36, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 2, Endian.little);
  bytes.setUint32(24, midiRenderSampleRate, Endian.little);
  bytes.setUint32(28, midiRenderSampleRate * 4, Endian.little);
  bytes.setUint16(32, 4, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  return header;
}

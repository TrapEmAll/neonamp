# Third-party notices

## libxmp 4.7.2

NeonAmp uses [libxmp](https://github.com/libxmp/libxmp), Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr. libxmp is distributed under the MIT License:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## FFmpegKit Audio 2.5.2

NeonAmp uses [FFmpegKit Audio](https://github.com/sk3llo/ffmpeg_kit_flutter/tree/audio) and its FFmpeg 8.1.2 native libraries to decode local audio files that the primary platform/DSP decoders cannot read. The package and included FFmpeg build are distributed under the GNU Lesser General Public License, version 3. The package does not include its GPL-only optional codec libraries. Source and license terms are available from the [versioned package source](https://pub.dev/packages/ffmpeg_kit_flutter_new_audio/versions/2.5.2) and the [GNU LGPL v3 text](https://www.gnu.org/licenses/lgpl-3.0.html); the linked package source includes its license text and build instructions.

## dart_cast 0.7.4

NeonAmp includes a small local modification of [dart_cast](https://github.com/abdelaziz-mahdy/dart_cast) for Chromecast audio MIME types and music metadata. It is distributed under the MIT License; the original license is included at `third_party/dart_cast/LICENSE`.

## FluidR3 GM SoundFont

NeonAmp bundles [FluidR3 GM](https://ftp.jaist.ac.jp/pub/sourceforge.jp/sfnet/a/an/androidframe/soundfonts/) as its default General MIDI SoundFont. The upstream licensing notice is maintained by [MuseScore](https://github.com/musescore/MuseScore/blob/main/share/sound/FluidR3Mono_License.md). The build fetches the exact verified upstream file rather than storing the binary in this repository; `tool/fetch_default_soundfont.py` records its URL, size, and SHA-256 fingerprint.


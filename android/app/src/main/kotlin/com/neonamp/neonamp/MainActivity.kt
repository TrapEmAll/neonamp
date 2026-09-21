package com.neonamp.neonamp

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val converterChannel = "neonamp/converter"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, converterChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "convertToM4a") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                if (inputPath == null || outputPath == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                Thread {
                    val converted = try {
                        transcodeToM4a(inputPath, outputPath)
                    } catch (_: Throwable) {
                        false
                    }
                    if (!converted) File(outputPath).delete()
                    runOnUiThread { result.success(converted) }
                }.start()
            }
    }

    private fun transcodeToM4a(inputPath: String, outputPath: String): Boolean {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        try {
            extractor.setDataSource(inputPath)
            var audioTrack = -1
            for (index in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audioTrack = index
                    break
                }
            }
            if (audioTrack < 0) return false
            extractor.selectTrack(audioTrack)
            val sourceFormat = extractor.getTrackFormat(audioTrack)
            val mime = sourceFormat.getString(MediaFormat.KEY_MIME) ?: return false
            val sampleRate = sourceFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channelCount = sourceFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

            decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(sourceFormat, null, null, 0)
            decoder.start()

            val encoderFormat = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                sampleRate,
                channelCount,
            )
            encoderFormat.setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                android.media.MediaCodecInfo.CodecProfileLevel.AACObjectLC,
            )
            encoderFormat.setInteger(MediaFormat.KEY_BIT_RATE, 192000)
            encoderFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            encoder.configure(encoderFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()

            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val decoderInfo = MediaCodec.BufferInfo()
            val encoderInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var decoderDone = false
            var encoderDone = false
            var outputTrack = -1

            while (!encoderDone) {
                if (!inputDone) {
                    val inputIndex = decoder.dequeueInputBuffer(10_000)
                    if (inputIndex >= 0) {
                        val inputBuffer = decoder.getInputBuffer(inputIndex) ?: return false
                        val sampleSize = extractor.readSampleData(inputBuffer, 0)
                        if (sampleSize < 0) {
                            decoder.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(
                                inputIndex,
                                0,
                                sampleSize,
                                extractor.sampleTime,
                                0,
                            )
                            extractor.advance()
                        }
                    }
                }

                if (!decoderDone) {
                    val decoderIndex = decoder.dequeueOutputBuffer(decoderInfo, 10_000)
                    when {
                        decoderIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> Unit
                        decoderIndex >= 0 -> {
                            val decoded = decoder.getOutputBuffer(decoderIndex)
                            if (decoded != null && decoderInfo.size > 0) {
                                val encoderIndex = waitForEncoderInput(encoder!!)
                                if (encoderIndex < 0) return false
                                val encoderInput = encoder.getInputBuffer(encoderIndex)
                                    ?: return false
                                decoded.position(decoderInfo.offset)
                                decoded.limit(decoderInfo.offset + decoderInfo.size)
                                encoderInput.put(decoded)
                                encoder.queueInputBuffer(
                                    encoderIndex,
                                    0,
                                    decoderInfo.size,
                                    decoderInfo.presentationTimeUs,
                                    if ((decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    } else {
                                        0
                                    },
                                )
                            } else if ((decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                val encoderIndex = waitForEncoderInput(encoder!!)
                                if (encoderIndex < 0) return false
                                encoder.queueInputBuffer(
                                    encoderIndex,
                                    0,
                                    0,
                                    0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                            }
                            decoder.releaseOutputBuffer(decoderIndex, false)
                            if ((decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                                decoderDone = true
                            }
                        }
                    }
                }

                while (!encoderDone) {
                    val encoderIndex = encoder.dequeueOutputBuffer(encoderInfo, 0)
                    when {
                        encoderIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (muxerStarted) return false
                            outputTrack = muxer.addTrack(encoder.outputFormat)
                            muxer.start()
                            muxerStarted = true
                        }
                        encoderIndex >= 0 -> {
                            val encoded = encoder.getOutputBuffer(encoderIndex)
                            if (encoded != null && encoderInfo.size > 0 && muxerStarted) {
                                encoded.position(encoderInfo.offset)
                                encoded.limit(encoderInfo.offset + encoderInfo.size)
                                muxer.writeSampleData(outputTrack, encoded, encoderInfo)
                            }
                            encoderDone = (encoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            encoder.releaseOutputBuffer(encoderIndex, false)
                        }
                    }
                }
            }
            return muxerStarted
        } finally {
            try { decoder?.stop() } catch (_: Throwable) { }
            try { encoder?.stop() } catch (_: Throwable) { }
            decoder?.release()
            encoder?.release()
            if (muxerStarted) muxer?.stop()
            muxer?.release()
            extractor.release()
        }
    }

    private fun waitForEncoderInput(encoder: MediaCodec): Int {
        repeat(100) {
            val index = encoder.dequeueInputBuffer(10_000)
            if (index >= 0) return index
        }
        return -1
    }
}

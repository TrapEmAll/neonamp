package com.neonamp.neonamp

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Locale
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    private val converterChannel = "neonamp/converter"
    private val libraryChannel = "neonamp/library"
    private val nearbyPermissionRequest = 4021
    private val folderPickerRequest = 4022
    private var multicastLock: WifiManager.MulticastLock? = null
    private var nearbyPermissionResult: MethodChannel.Result? = null
    private var folderPickerResult: MethodChannel.Result? = null

    private external fun nativeReadTrackerInfo(inputPath: String): Array<String>?
    private external fun nativeRenderTrackerToWav(inputPath: String, outputPath: String): Boolean

    companion object {
        init {
            System.loadLibrary("neonamp_tracker")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                4023,
            )
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, libraryChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFolder" -> pickLibraryFolder(result)
                    "scanFolder" -> {
                        val folderUri = call.argument<String>("uri")
                        if (folderUri.isNullOrBlank()) {
                            result.error("invalid_arguments", "A folder URI is required.", null)
                        } else {
                            Thread {
                                try {
                                    val files = scanSafFolder(Uri.parse(folderUri))
                                    runOnUiThread { result.success(files) }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        result.error("folder_scan_failed", error.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    "copyFileToFolder" -> {
                        val folderUri = call.argument<String>("uri")
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        if (folderUri.isNullOrBlank() || sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("invalid_arguments", "Folder URI, source file, and name are required.", null)
                        } else {
                            Thread {
                                try {
                                    writeFileToSafFolder(Uri.parse(folderUri), File(sourcePath), fileName)
                                    runOnUiThread { result.success(true) }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        result.error("folder_write_failed", error.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    "writeTextToFolder" -> {
                        val folderUri = call.argument<String>("uri")
                        val fileName = call.argument<String>("fileName")
                        val contents = call.argument<String>("contents")
                        if (folderUri.isNullOrBlank() || fileName.isNullOrBlank() || contents == null) {
                            result.error("invalid_arguments", "Folder URI, file name, and contents are required.", null)
                        } else {
                            Thread {
                                try {
                                    writeTextToSafFolder(Uri.parse(folderUri), fileName, contents)
                                    runOnUiThread { result.success(true) }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        result.error("folder_write_failed", error.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, converterChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "convertToM4a") {
                    if (call.method == "listAudioCds") {
                        result.success(emptyList<Map<String, Any>>())
                    } else if (call.method == "ripAudioCd") {
                        result.success(false)
                    } else {
                        result.notImplemented()
                    }
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/system_controls")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAudioCds" -> result.success(emptyList<Map<String, Any>>())
                    "ripAudioCd" -> result.success(false)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/dlna")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "beginDiscovery" -> beginDlnaDiscovery(result)
                    "endDiscovery" -> {
                        releaseMulticastLock()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/tracker")
            .setMethodCallHandler { call, result ->
                val inputPath = call.argument<String>("inputPath")
                if (inputPath == null) {
                    result.error("invalid_arguments", "A module path is required.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "readInfo" -> {
                        val info = try {
                            nativeReadTrackerInfo(inputPath)
                        } catch (_: Throwable) {
                            null
                        }
                        if (info == null || info.size < 2) {
                            result.error("invalid_module", "Unsupported or malformed tracker module.", null)
                        } else {
                            result.success(mapOf("title" to info[0], "format" to info[1]))
                        }
                    }
                    "decodeToWav" -> {
                        val outputPath = call.argument<String>("outputPath")
                        if (outputPath == null) {
                            result.error("invalid_arguments", "An output path is required.", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            val decoded = try {
                                nativeRenderTrackerToWav(inputPath, outputPath)
                            } catch (_: Throwable) {
                                false
                            }
                            if (!decoded) File(outputPath).delete()
                            runOnUiThread {
                                if (decoded) result.success(true)
                                else result.error("decode_failed", "Could not decode tracker module.", null)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickLibraryFolder(result: MethodChannel.Result) {
        if (folderPickerResult != null) {
            result.error("picker_busy", "A folder picker is already open.", null)
            return
        }
        folderPickerResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
            }
            startActivityForResult(intent, folderPickerRequest)
        } catch (error: Throwable) {
            folderPickerResult = null
            result.error("folder_picker_failed", error.message, null)
        }
    }

    @Deprecated("Deprecated in Android, retained for the Storage Access Framework result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != folderPickerRequest) return
        val pendingResult = folderPickerResult ?: return
        folderPickerResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pendingResult.success(null)
            return
        }
        try {
            val persistableFlags = (data.flags) and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, persistableFlags)
            pendingResult.success(mapOf("uri" to uri.toString(), "name" to folderName(uri)))
        } catch (error: Throwable) {
            pendingResult.error("folder_permission_failed", error.message, null)
        }
    }

    private fun folderName(treeUri: Uri): String {
        val documentUri = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        contentResolver.query(
            documentUri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0) return cursor.getString(nameIndex)
            }
        }
        return "Selected folder"
    }

    private fun scanSafFolder(treeUri: Uri): List<Map<String, String>> {
        val cacheDirectory = File(filesDir, "neonamp-library-cache").apply { mkdirs() }
        val audioExtensions = setOf(
            "mp3", "flac", "wav", "ogg", "m4a", "mp4", "aac", "wma",
            "opus", "ape", "aif", "aiff", "aifc", "mov", "webm", "mkv",
            "mka", "amr", "awb", "spx", "m4b", "3gp", "oga", "ogx", "mp1", "mp2",
            "ac3", "au", "caf", "dts", "snd", "tak", "tta", "voc",
            "mid", "midi", "kar", "669", "amf", "ams", "dbm",
            "dmf", "dsm", "far", "gdm", "gtk", "it", "j2b", "m15",
            "med", "mod", "mtm", "okt", "psm", "pt36", "ptm", "s3m",
            "stm", "stp", "stx", "ult", "umx", "xm", "xmz", "itz", "s3z",
        )
        val results = mutableListOf<Map<String, String>>()
        val visited = mutableSetOf<String>()
        val rootDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val pending = ArrayDeque<String>()
        pending.add(rootDocumentId)
        while (pending.isNotEmpty()) {
            val parentId = pending.removeLast()
            if (!visited.add(parentId)) continue
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_FLAGS,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                ),
                null,
                null,
                null,
            )?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val flagsColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
                val sizeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val modifiedColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                while (cursor.moveToNext()) {
                    val documentId = cursor.getString(idColumn)
                    val name = cursor.getString(nameColumn) ?: continue
                    val mimeType = cursor.getString(mimeColumn).orEmpty()
                    val documentFlags = if (flagsColumn >= 0 && !cursor.isNull(flagsColumn)) {
                        cursor.getLong(flagsColumn)
                    } else {
                        0L
                    }
                    val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR ||
                        mimeType.equals("inode/directory", ignoreCase = true) ||
                        mimeType.endsWith("/directory", ignoreCase = true) ||
                        (documentFlags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE.toLong() != 0L)
                    if (isDirectory) {
                        pending.add(documentId)
                        continue
                    }
                    val extension =
                        name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                        .takeIf { it in audioExtensions }
                        ?: audioExtensionForMimeType(mimeType)
                    if (extension == null) {
                        continue
                    }
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                    val cacheName = sha256(documentUri.toString()) + "." + extension
                    val cachedFile = File(cacheDirectory, cacheName)
                    val sourceSize = if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else -1L
                    val sourceModified = if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) cursor.getLong(modifiedColumn) else -1L
                    if (!cachedFile.isFile || (sourceSize >= 0 && cachedFile.length() != sourceSize) ||
                        (sourceModified > 0 && cachedFile.lastModified() != sourceModified)
                    ) {
                        val temporaryFile = File(cacheDirectory, "$cacheName.tmp")
                        contentResolver.openInputStream(documentUri)?.use { input ->
                            FileOutputStream(temporaryFile).use { output -> input.copyTo(output) }
                        } ?: continue
                        if (!temporaryFile.renameTo(cachedFile)) {
                            temporaryFile.copyTo(cachedFile, overwrite = true)
                            temporaryFile.delete()
                        }
                        if (sourceModified > 0) cachedFile.setLastModified(sourceModified)
                    }
                    val relativePath = if (documentId.startsWith("$rootDocumentId/")) {
                        documentId.removePrefix("$rootDocumentId/")
                    } else {
                        name
                    }
                    results.add(
                        mapOf(
                            "path" to cachedFile.absolutePath,
                            "name" to name,
                            "relativePath" to relativePath,
                        ),
                    )
                }
            } ?: throw IllegalStateException("Android could not read this folder. Re-add it to restore access.")
        }
        return results
    }

    private fun audioExtensionForMimeType(mimeType: String): String? =
        when (mimeType.lowercase(Locale.ROOT)) {
            "audio/mpeg", "audio/mp3", "audio/x-mpeg" -> "mp3"
            "audio/flac", "audio/x-flac" -> "flac"
            "audio/wav", "audio/x-wav", "audio/vnd.wave" -> "wav"
            "audio/ogg", "application/ogg", "audio/vorbis" -> "ogg"
            "audio/opus" -> "opus"
            "audio/mp4", "audio/x-m4a" -> "m4a"
            "audio/aac", "audio/x-aac" -> "aac"
            "audio/midi", "audio/x-midi" -> "mid"
            "audio/x-ms-wma", "audio/wma" -> "wma"
            "audio/amr", "audio/x-amr" -> "amr"
            "audio/amr-wb", "audio/x-amr-wb" -> "awb"
            "audio/speex", "audio/x-speex" -> "spx"
            "audio/3gpp", "audio/3gpp2" -> "3gp"
            else -> null
        }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    private fun writeFileToSafFolder(treeUri: Uri, source: File, fileName: String) {
        if (!source.isFile) throw IllegalArgumentException("The source audio file is unavailable.")
        val mimeType = when (source.extension.lowercase(Locale.ROOT)) {
            "mp3" -> "audio/mpeg"
            "m4a", "aac" -> "audio/mp4"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "ogg", "opus" -> "audio/ogg"
            else -> "application/octet-stream"
        }
        val destination = createSafFile(treeUri, fileName, mimeType)
        contentResolver.openOutputStream(destination, "w")?.use { output ->
            source.inputStream().use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("Android could not write the selected folder.")
    }

    private fun writeTextToSafFolder(treeUri: Uri, fileName: String, contents: String) {
        val destination = createSafFile(treeUri, fileName, "application/x-mpegURL")
        contentResolver.openOutputStream(destination, "w")?.bufferedWriter()?.use { writer ->
            writer.write(contents)
        } ?: throw IllegalStateException("Android could not write the selected folder.")
    }

    private fun createSafFile(treeUri: Uri, fileName: String, mimeType: String): Uri {
        val rootUri = DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
        contentResolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            ),
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            )
            val nameColumn = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
            while (cursor.moveToNext()) {
                if (cursor.getString(nameColumn) == fileName) {
                    return DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        cursor.getString(idColumn),
                    )
                }
            }
        }
        return DocumentsContract.createDocument(contentResolver, rootUri, mimeType, fileName)
            ?: throw IllegalStateException("Android could not create $fileName in the selected folder.")
    }

    private fun beginDlnaDiscovery(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED
        ) {
            nearbyPermissionResult = result
            requestPermissions(arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES), nearbyPermissionRequest)
            return
        }
        acquireMulticastLock()
        result.success(true)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != nearbyPermissionRequest) return
        val result = nearbyPermissionResult ?: return
        nearbyPermissionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            acquireMulticastLock()
            result.success(true)
        } else {
            result.success(false)
        }
    }

    private fun acquireMulticastLock() {
        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        val lock = multicastLock ?: wifi.createMulticastLock("NeonAmp DLNA discovery").apply {
            setReferenceCounted(false)
        }.also { multicastLock = it }
        if (!lock.isHeld) lock.acquire()
    }

    private fun releaseMulticastLock() {
        multicastLock?.takeIf { it.isHeld }?.release()
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
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

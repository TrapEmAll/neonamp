package com.neonamp.neonamp

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
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
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Locale
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
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
    private var audioCdResult: MethodChannel.Result? = null
    private var usbTag = 1
    private val libraryCachePreferences by lazy {
        getSharedPreferences("neonamp-library-cache", Context.MODE_PRIVATE)
    }

    private val usbPermissionAction = "com.neonamp.neonamp.USB_PERMISSION"
    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != usbPermissionAction) return
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            val result = audioCdResult ?: return
            audioCdResult = null
            if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false) && device != null) {
                Thread {
                    val response = try { listAudioCdsInternal(device) } catch (_: Throwable) { emptyList() }
                    runOnUiThread { result.success(response) }
                }.start()
            } else {
                result.error("usb_permission_denied", "USB optical-drive permission was denied.", null)
            }
        }
    }

    private external fun nativeReadTrackerInfo(inputPath: String): Array<String>?
    private external fun nativeRenderTrackerToWav(inputPath: String, outputPath: String): Boolean

    companion object {
        init {
            System.loadLibrary("neonamp_tracker")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(usbPermissionAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(usbReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(usbReceiver, filter)
        }
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
                    "replaceCachedFile" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        if (sourcePath.isNullOrBlank()) {
                            result.error("invalid_arguments", "A cached source file is required.", null)
                        } else {
                            Thread {
                                try {
                                    val replaced = replaceCachedFile(sourcePath)
                                    runOnUiThread { result.success(replaced) }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        result.error("library_write_failed", error.message, null)
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/system_controls")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listAudioCds" -> listAudioCds(result)
                    "ripAudioCd" -> ripAudioCd(call, result)
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
            "dsf", "dff", "dsdiff",
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
                        (mimeType.isBlank() &&
                            documentFlags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE.toLong() != 0L)
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
                    libraryCachePreferences.edit()
                        .putString(cachedFile.canonicalPath, documentUri.toString())
                        .apply()
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

    private fun replaceCachedFile(sourcePath: String): Boolean {
        val cacheRoot = File(filesDir, "neonamp-library-cache").canonicalFile
        val source = File(sourcePath).canonicalFile
        val cachePrefix = cacheRoot.path + File.separator
        if (!source.path.startsWith(cachePrefix)) {
            throw IllegalArgumentException("The source file is outside the NeonAmp cache.")
        }
        val uriString = libraryCachePreferences.getString(source.path, null) ?: return false
        val destination = Uri.parse(uriString)
        contentResolver.openOutputStream(destination, "wt")?.use { output ->
            source.inputStream().use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("Android could not open the selected file for writing.")
        return true
    }

    private fun usbManager(): UsbManager =
        getSystemService(Context.USB_SERVICE) as UsbManager

    private fun opticalInterface(device: UsbDevice): UsbInterface? {
        for (index in 0 until device.interfaceCount) {
            val candidate = device.getInterface(index)
            if (candidate.interfaceClass == 8 &&
                candidate.interfaceSubclass == 6 &&
                candidate.interfaceProtocol == 0x50
            ) return candidate
        }
        return null
    }

    private fun listAudioCds(result: MethodChannel.Result) {
        if (audioCdResult != null) {
            result.error("usb_scan_busy", "An audio CD scan is already in progress.", null)
            return
        }
        val devices = usbManager().deviceList.values.filter { opticalInterface(it) != null }
        if (devices.isEmpty()) {
            result.success(emptyList<Map<String, Any>>())
            return
        }
        val unauthorized = devices.firstOrNull { !usbManager().hasPermission(it) }
        if (unauthorized != null) {
            audioCdResult = result
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                @Suppress("DEPRECATION")
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val permissionIntent = PendingIntent.getBroadcast(
                this,
                usbTag++,
                Intent(usbPermissionAction).setPackage(packageName),
                flags,
            )
            usbManager().requestPermission(unauthorized, permissionIntent)
            return
        }
        Thread {
            val values = devices.flatMap { device ->
                try { listAudioCdsInternal(device) } catch (_: Throwable) { emptyList() }
            }
            runOnUiThread { result.success(values) }
        }.start()
    }

    private fun listAudioCdsInternal(device: UsbDevice): List<Map<String, Any>> {
        val toc = UsbCdTransport(usbManager(), device, opticalInterface(device)!!).use { it.readToc() }
        if (toc.tracks.isEmpty()) return emptyList()
        return listOf(
            mapOf(
                "drive" to device.deviceName,
                "tracks" to toc.tracks.map { track ->
                    mapOf(
                        "track" to track.number,
                        "durationSeconds" to ((track.endLba - track.startLba) / 75),
                    )
                },
            ),
        )
    }

    private fun ripAudioCd(call: MethodCall, result: MethodChannel.Result) {
        val deviceName = call.argument<String>("drive")
        val trackNumber = call.argument<Int>("track")
        val outputPath = call.argument<String>("outputPath")
        if (deviceName.isNullOrBlank() || trackNumber == null || outputPath.isNullOrBlank()) {
            result.error("invalid_arguments", "Drive, track, and output path are required.", null)
            return
        }
        val device = usbManager().deviceList.values.firstOrNull {
            it.deviceName == deviceName && opticalInterface(it) != null
        }
        if (device == null || !usbManager().hasPermission(device)) {
            result.error("usb_permission_required", "Reconnect the USB optical drive and grant permission.", null)
            return
        }
        Thread {
            val success = try {
                UsbCdTransport(usbManager(), device, opticalInterface(device)!!).use { transport ->
                    val track = transport.readToc().tracks.first { it.number == trackNumber }
                    transport.ripTrack(track, File(outputPath))
                }
                true
            } catch (_: Throwable) {
                File(outputPath).delete()
                false
            }
            runOnUiThread { result.success(success) }
        }.start()
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
        try { unregisterReceiver(usbReceiver) } catch (_: IllegalArgumentException) { }
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

private data class AudioCdTrack(
    val number: Int,
    val startLba: Int,
    val endLba: Int,
)

private data class AudioCdToc(val tracks: List<AudioCdTrack>)

/** Minimal USB Mass Storage Bulk-Only Transport for MMC audio CDs. */
private class UsbCdTransport(
    manager: UsbManager,
    device: UsbDevice,
    private val usbInterface: UsbInterface,
) : AutoCloseable {
    private val connection: UsbDeviceConnection =
        manager.openDevice(device) ?: error("Could not open the USB optical drive")
    private val input: UsbEndpoint = (0 until usbInterface.endpointCount)
        .map { usbInterface.getEndpoint(it) }
        .firstOrNull {
            it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                it.direction == UsbConstants.USB_DIR_IN
        } ?: error("USB optical drive has no bulk input endpoint")
    private val output: UsbEndpoint = (0 until usbInterface.endpointCount)
        .map { usbInterface.getEndpoint(it) }
        .firstOrNull {
            it.type == UsbConstants.USB_ENDPOINT_XFER_BULK &&
                it.direction == UsbConstants.USB_DIR_OUT
        } ?: error("USB optical drive has no bulk output endpoint")
    private var tag = 1

    init {
        check(connection.claimInterface(usbInterface, true)) {
            "Could not claim the USB optical-drive interface"
        }
    }

    fun readToc(): AudioCdToc {
        val cdb = ByteArray(10)
        cdb[0] = 0x43
        cdb[7] = 0x04
        cdb[8] = 0x00
        val response = command(cdb, 1024)
        if (response.size < 4) return AudioCdToc(emptyList())
        val firstTrack = response[2].toInt() and 0xff
        val lastTrack = response[3].toInt() and 0xff
        if (firstTrack == 0 || lastTrack < firstTrack) return AudioCdToc(emptyList())
        val starts = mutableMapOf<Int, Int>()
        var leadOut = 0
        var offset = 4
        while (offset + 7 < response.size) {
            val track = response[offset + 2].toInt() and 0xff
            val lba = ((response[offset + 4].toInt() and 0xff) shl 24) or
                ((response[offset + 5].toInt() and 0xff) shl 16) or
                ((response[offset + 6].toInt() and 0xff) shl 8) or
                (response[offset + 7].toInt() and 0xff)
            if (track == 0xaa) leadOut = lba else if (track in firstTrack..lastTrack) starts[track] = lba
            offset += 8
        }
        val tracks = starts.keys.sorted().mapNotNull { number ->
            val start = starts[number] ?: return@mapNotNull null
            val end = starts[number + 1] ?: leadOut
            if (end > start) AudioCdTrack(number, start, end) else null
        }
        return AudioCdToc(tracks)
    }

    fun ripTrack(track: AudioCdTrack, output: File) {
        output.parentFile?.mkdirs()
        RandomAccessFile(output, "rw").use { file ->
            file.setLength(0)
            file.write(wavHeader(0))
            var lba = track.startLba
            var dataBytes = 0
            while (lba < track.endLba) {
                val sectors = minOf(4, track.endLba - lba)
                val bytes = readCd(lba, sectors)
                file.write(bytes)
                dataBytes += bytes.size
                lba += sectors
            }
            file.seek(4)
            file.writeIntLE(36 + dataBytes)
            file.seek(40)
            file.writeIntLE(dataBytes)
        }
    }

    private fun readCd(lba: Int, sectors: Int): ByteArray {
        val cdb = ByteArray(12)
        cdb[0] = 0xBE.toByte()
        cdb[2] = (lba ushr 24).toByte()
        cdb[3] = (lba ushr 16).toByte()
        cdb[4] = (lba ushr 8).toByte()
        cdb[5] = lba.toByte()
        cdb[6] = (sectors ushr 16).toByte()
        cdb[7] = (sectors ushr 8).toByte()
        cdb[8] = sectors.toByte()
        // Sync, header, subheader, and user data: 2352-byte CD-DA frames.
        cdb[9] = 0xF8.toByte()
        return command(cdb, sectors * 2352)
    }

    private fun command(cdb: ByteArray, expectedLength: Int): ByteArray {
        require(cdb.size <= 16)
        val currentTag = tag++
        val cbw = ByteBuffer.allocate(31).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0x43425355)
            putInt(currentTag)
            putInt(expectedLength)
            put(0x80.toByte())
            put(0)
            put(cdb.size.toByte())
            put(cdb)
            while (position() < 31) put(0)
        }.array()
        check(connection.bulkTransfer(output, cbw, 0, cbw.size, 10_000) == cbw.size) {
            "USB command transfer failed"
        }
        val data = ByteArray(expectedLength)
        var received = 0
        while (received < expectedLength) {
            val count = connection.bulkTransfer(input, data, received, expectedLength - received, 30_000)
            check(count > 0) { "USB data transfer failed" }
            received += count
        }
        val csw = ByteArray(13)
        check(connection.bulkTransfer(input, csw, 0, csw.size, 10_000) == csw.size) {
            "USB status transfer failed"
        }
        val status = ByteBuffer.wrap(csw).order(ByteOrder.LITTLE_ENDIAN)
        check(status.int == 0x53425355 && status.int == currentTag) { "Invalid USB command status" }
        check((csw[12].toInt() and 0xff) == 0) { "Optical drive rejected the command" }
        return data
    }

    override fun close() {
        try { connection.releaseInterface(usbInterface) } finally { connection.close() }
    }

    private fun wavHeader(dataLength: Int): ByteArray = ByteBuffer.allocate(44)
        .order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray())
            putInt(36 + dataLength)
            put("WAVEfmt ".toByteArray())
            putInt(16)
            putShort(1)
            putShort(2)
            putInt(44100)
            putInt(44100 * 2 * 2)
            putShort(4)
            putShort(16)
            put("data".toByteArray())
            putInt(dataLength)
        }.array()
}

private fun RandomAccessFile.writeIntLE(value: Int) {
    write(byteArrayOf(
        value.toByte(),
        (value ushr 8).toByte(),
        (value ushr 16).toByte(),
        (value ushr 24).toByte(),
    ))
}


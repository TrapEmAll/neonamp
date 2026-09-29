package com.neonamp.neonamp

import android.Manifest
import android.content.Intent
import android.content.ContentUris
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.AudioManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.content.ContentValues
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Locale
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaQueueItem
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.common.images.WebImage
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer

class MainActivity : AudioServiceActivity() {
    private val converterChannel = "neonamp/converter"
    private val libraryChannel = "neonamp/library"
    private val nearbyPermissionRequest = 4021
    private val folderPickerRequest = 4022
    private val mediaStorePermissionRequest = 4023
    private var multicastLock: WifiManager.MulticastLock? = null
    private var nearbyPermissionResult: MethodChannel.Result? = null
    private var folderPickerResult: MethodChannel.Result? = null
    private var mediaStorePermissionResult: MethodChannel.Result? = null
    private var pendingMediaIntent: List<Map<String, String>>? = null
    private var pendingWidgetQueue = false
    private var castContext: CastContext? = null
    private var pendingCastMedia: Map<String, Any?>? = null
    private var pendingCastQueue: Map<*, *>? = null
    private var gaplessPlayer: ExoPlayer? = null
    private var gaplessChannel: MethodChannel? = null
    private var audioOutputChannel: MethodChannel? = null

    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            audioOutputChannel?.invokeMethod("stateChanged", audioOutputState())
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            audioOutputChannel?.invokeMethod("stateChanged", audioOutputState())
        }
    }

    private val castSessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) = Unit
        override fun onSessionStarted(session: CastSession, sessionId: String) {
            pendingCastMedia?.let { media ->
                pendingCastMedia = null
                loadCastMedia(session, media)
            }
            pendingCastQueue?.let { queue ->
                pendingCastQueue = null
                loadCastQueue(
                    session,
                    queue["items"] as? List<*>,
                    (queue["startIndex"] as? Number)?.toInt() ?: 0,
                )
            }
        }
        override fun onSessionStartFailed(session: CastSession, errorCode: Int) {
            pendingCastMedia = null
            pendingCastQueue = null
        }
        override fun onSessionEnding(session: CastSession) {
            pendingCastMedia = null
            pendingCastQueue = null
        }
        override fun onSessionEnded(session: CastSession, error: Int) {
            pendingCastMedia = null
            pendingCastQueue = null
        }
        override fun onSessionResuming(session: CastSession, sessionId: String) = Unit
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            pendingCastMedia?.let { media ->
                pendingCastMedia = null
                loadCastMedia(session, media)
            }
            pendingCastQueue?.let { queue ->
                pendingCastQueue = null
                loadCastQueue(
                    session,
                    queue["items"] as? List<*>,
                    (queue["startIndex"] as? Number)?.toInt() ?: 0,
                )
            }
        }
        override fun onSessionResumeFailed(session: CastSession, errorCode: Int) = Unit
        override fun onSessionSuspended(session: CastSession, reason: Int) = Unit
    }

    private external fun nativeReadTrackerInfo(inputPath: String): Array<String>?
    private external fun nativeRenderTrackerToWav(inputPath: String, outputPath: String): Boolean

    private fun configureGaplessQueue(paths: List<String>, startIndex: Int, shouldPlay: Boolean) {
        if (paths.isEmpty()) return
        gaplessPlayer?.release()
        val player = ExoPlayer.Builder(this).build()
        player.setAudioAttributes(
            AudioAttributes.Builder()
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                .setUsage(C.USAGE_MEDIA)
                .build(),
            true,
        )
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                emitGaplessState()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                emitGaplessState()
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                emitGaplessState()
            }
        })
        player.setMediaItems(
            paths.map { path -> MediaItem.fromUri(gaplessUri(path)) },
            startIndex.coerceIn(0, paths.lastIndex),
            0L,
        )
        player.prepare()
        gaplessPlayer = player
        if (shouldPlay) player.play()
        emitGaplessState()
    }

    private fun gaplessUri(path: String): Uri {
        val parsed = Uri.parse(path)
        return when (parsed.scheme?.lowercase(Locale.ROOT)) {
            "content", "file", "http", "https" -> parsed
            else -> Uri.fromFile(File(path))
        }
    }

    private fun gaplessState(): Map<String, Any?> {
        val player = gaplessPlayer
        return mapOf(
            "index" to (player?.currentMediaItemIndex ?: C.INDEX_UNSET),
            "positionMs" to (player?.currentPosition ?: 0L),
            "durationMs" to (player?.duration ?: 0L).coerceAtLeast(0L),
            "playing" to (player?.isPlaying == true),
            "playbackState" to (player?.playbackState ?: Player.STATE_IDLE),
        )
    }

    private fun emitGaplessState() {
        gaplessChannel?.invokeMethod("stateChanged", gaplessState())
    }

    companion object {
        init {
            System.loadLibrary("neonamp_tracker")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingMediaIntent = mediaIntentPayloads(intent)
        pendingWidgetQueue = intent?.getBooleanExtra(
            NeonAmpWidgetProvider.EXTRA_OPEN_QUEUE,
            false,
        ) == true
        try {
            castContext = CastContext.getSharedInstance(this)
            castContext?.sessionManager?.addSessionManagerListener(
                castSessionListener,
                CastSession::class.java,
            )
        } catch (_: Throwable) {
            castContext = null
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/intents")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeIncomingMedia" -> {
                        val payload = pendingMediaIntent
                        pendingMediaIntent = null
                        result.success(payload)
                    }
                    "consumeQueueShortcut" -> {
                        val openQueue = pendingWidgetQueue
                        pendingWidgetQueue = false
                        result.success(openQueue)
                    }
                    else -> result.notImplemented()
                }
            }
        gaplessChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/gapless")
        gaplessChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setQueue" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    val startIndex = call.argument<Int>("index") ?: 0
                    val shouldPlay = call.argument<Boolean>("play") ?: true
                    configureGaplessQueue(paths, startIndex, shouldPlay)
                    result.success(null)
                }
                "play" -> {
                    gaplessPlayer?.play()
                    result.success(null)
                }
                "pause" -> {
                    gaplessPlayer?.pause()
                    result.success(null)
                }
                "stop" -> {
                    gaplessPlayer?.stop()
                    result.success(null)
                }
                "next" -> {
                    gaplessPlayer?.seekToNextMediaItem()
                    result.success(null)
                }
                "previous" -> {
                    gaplessPlayer?.seekToPreviousMediaItem()
                    result.success(null)
                }
                "seek" -> {
                    gaplessPlayer?.seekTo(call.argument<Number>("positionMs")?.toLong() ?: 0L)
                    result.success(null)
                }
                "setSpeed" -> {
                    gaplessPlayer?.setPlaybackSpeed(call.argument<Number>("speed")?.toFloat() ?: 1f)
                    result.success(null)
                }
                "setVolume" -> {
                    gaplessPlayer?.volume = call.argument<Number>("volume")?.toFloat() ?: 1f
                    result.success(null)
                }
                "state" -> result.success(gaplessState())
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/widget")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val title = call.argument<String>("title") ?: "NeonAmp"
                        val artist = call.argument<String>("artist") ?: "Nothing queued"
                        val playing = call.argument<Boolean>("playing") ?: false
                        val artwork = call.argument<ByteArray>("artwork")
                        NeonAmpWidgetProvider.updateAll(this, title, artist, playing, artwork)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        audioOutputChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "neonamp/audio_output",
        )
        audioOutputChannel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getState" -> result.success(audioOutputState())
                    "openBluetoothSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                            result.success(true)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                    "batteryState" -> {
                        val power = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(
                            mapOf(
                                "ignoringOptimizations" to
                                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                                        power.isIgnoringBatteryOptimizations(packageName)),
                            ),
                        )
                    }
                    "openBatterySettings" -> {
                        try {
                            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                )
                            } else {
                                Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (_: Throwable) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(AUDIO_SERVICE) as AudioManager
            manager.registerAudioDeviceCallback(audioDeviceCallback, null)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neonamp/cast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showPicker" -> {
                        try {
                            startActivity(Intent(this, CastPickerActivity::class.java))
                            result.success(true)
                        } catch (error: Throwable) {
                            result.error("cast_picker_failed", error.message, null)
                        }
                    }
                    "state" -> result.success(castState())
                    "cast" -> {
                        val media = call.arguments as? Map<String, Any?>
                        if (media == null || media["url"] !is String) {
                            result.error("invalid_arguments", "A media URL is required.", null)
                        } else {
                            val session = castContext?.sessionManager?.currentCastSession
                            if (session == null) {
                                pendingCastMedia = media
                                try {
                                    startActivity(Intent(this, CastPickerActivity::class.java))
                                    result.success(true)
                                } catch (error: Throwable) {
                                    pendingCastMedia = null
                                    result.error("cast_picker_failed", error.message, null)
                                }
                            } else {
                                result.success(loadCastMedia(session, media))
                            }
                        }
                    }
                    "castQueue" -> {
                        val arguments = call.arguments as? Map<*, *>
                        val session = castContext?.sessionManager?.currentCastSession
                        val items = arguments?.get("items") as? List<*>
                        val startIndex = (arguments?.get("startIndex") as? Number)?.toInt() ?: 0
                        if (items.isNullOrEmpty()) {
                            result.success(false)
                        } else if (session == null) {
                            pendingCastMedia = null
                            pendingCastQueue = arguments
                            try {
                                startActivity(Intent(this, CastPickerActivity::class.java))
                                result.success(true)
                            } catch (error: Throwable) {
                                pendingCastQueue = null
                                result.error("cast_picker_failed", error.message, null)
                            }
                        } else {
                            result.success(loadCastQueue(session, items, startIndex))
                        }
                    }
                    "pause" -> result.success(castRemote()?.pause()?.isSuccessful == true)
                    "resume" -> result.success(castRemote()?.play()?.isSuccessful == true)
                    "stop" -> result.success(castRemote()?.stop()?.isSuccessful == true)
                    "next" -> result.success(castRemote()?.queueNext(null)?.isSuccessful == true)
                    "previous" -> result.success(castRemote()?.queuePrev(null)?.isSuccessful == true)
                    "seek" -> {
                        val position = call.argument<Number>("positionMs")?.toLong() ?: 0L
                        result.success(
                            castRemote()?.seek(
                                MediaSeekOptions.Builder().setPosition(position.coerceAtLeast(0)).build(),
                            )?.isSuccessful == true,
                        )
                    }
                    "setVolume" -> {
                        val volume = call.argument<Number>("volume")?.toDouble()?.coerceIn(0.0, 1.0)
                        val session = castContext?.sessionManager?.currentCastSession
                        if (volume == null || session == null) result.success(false)
                        else {
                            session.volume = volume
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, libraryChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFolder" -> pickLibraryFolder(result)
                    "scanFolder" -> {
                        val folderUri = call.argument<String>("uri")
                        if (folderUri.isNullOrBlank() || !isTreeUri(Uri.parse(folderUri))) {
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
                    "scanMediaStore" -> scanMediaStore(result)
                    "persistedFolderUris" -> result.success(
                        contentResolver.persistedUriPermissions
                            .filter { it.isReadPermission || it.isWritePermission }
                            .map { it.uri.toString() },
                    )
                    "cacheStats" -> {
                        val directory = File(filesDir, "neonamp-library-cache")
                        val files = directory.listFiles().orEmpty().filter { it.isFile }
                        result.success(
                            mapOf(
                                "files" to files.size,
                                "bytes" to files.sumOf { it.length() },
                                "limitBytes" to cacheLimitBytes(),
                            ),
                        )
                    }
                    "setCacheLimit" -> {
                        val bytes = call.argument<Number>("bytes")?.toLong()
                        if (bytes == null || bytes < 64L * 1024L * 1024L) {
                            result.error("invalid_arguments", "Cache limit must be at least 64 MB.", null)
                        } else {
                            getSharedPreferences("neonamp_storage", MODE_PRIVATE)
                                .edit().putLong("cacheLimitBytes", bytes).apply()
                            pruneCache(File(filesDir, "neonamp-library-cache"))
                            result.success(true)
                        }
                    }
                    "clearCache" -> {
                        val directory = File(filesDir, "neonamp-library-cache")
                        val removed = directory.listFiles().orEmpty()
                            .count { it.delete() }
                        result.success(removed)
                    }
                    "publishRingtone" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val displayName = call.argument<String>("name")
                        if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
                            result.error("invalid_arguments", "A snippet path and name are required.", null)
                        } else {
                            Thread {
                                try {
                                    val uri = publishRingtone(File(sourcePath), displayName)
                                    runOnUiThread { result.success(uri.toString()) }
                                } catch (error: Throwable) {
                                    runOnUiThread { result.error("ringtone_export_failed", error.message, null) }
                                }
                            }.start()
                        }
                    }
                    "materializeUri" -> {
                        val sourceUri = call.argument<String>("uri")
                        val displayName = call.argument<String>("name").orEmpty()
                        if (sourceUri.isNullOrBlank() ||
                            !sourceUri.startsWith("content:", ignoreCase = true)
                        ) {
                            result.error("invalid_arguments", "A content URI is required.", null)
                        } else {
                            Thread {
                                try {
                                    val path = materializeContentUri(Uri.parse(sourceUri), displayName)
                                    runOnUiThread { result.success(path) }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        result.error("uri_materialization_failed", error.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    "copyFileToFolder" -> {
                        val folderUri = call.argument<String>("uri")
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        if (folderUri.isNullOrBlank() || !isTreeUri(Uri.parse(folderUri)) ||
                            sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
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
                        if (folderUri.isNullOrBlank() || !isTreeUri(Uri.parse(folderUri)) ||
                            fileName.isNullOrBlank() || contents == null) {
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
                val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
                val endMs = call.argument<Number>("endMs")?.toLong()
                if (inputPath == null || outputPath == null) {
                    result.success(false)
                    return@setMethodCallHandler
                }
                Thread {
                    val converted = try {
                        transcodeToM4a(inputPath, outputPath, startMs, endMs)
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

    private fun scanMediaStore(result: MethodChannel.Result) {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED
        ) {
            if (mediaStorePermissionResult != null) {
                result.error("permission_busy", "A music permission request is already open.", null)
                return
            }
            mediaStorePermissionResult = result
            requestPermissions(arrayOf(permission), mediaStorePermissionRequest)
            return
        }
        queryMediaStore(result)
    }

    private fun castRemote() = castContext?.sessionManager?.currentCastSession?.remoteMediaClient

    private fun castState(): Map<String, Any?> {
        val session = castContext?.sessionManager?.currentCastSession
        val remote = session?.remoteMediaClient
        return mapOf(
            "connected" to (session != null),
            "deviceName" to session?.castDevice?.friendlyName,
            "playerState" to remote?.playerState,
            "positionMs" to remote?.approximateStreamPosition,
            "durationMs" to remote?.mediaInfo?.streamDuration,
            "currentItemId" to remote?.mediaStatus?.currentItemId,
            "volume" to session?.volume,
        )
    }

    private fun buildCastMediaInfo(media: Map<*, *>): MediaInfo? {
        val url = media["url"] as? String ?: return null
        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MUSIC_TRACK).apply {
            putString(MediaMetadata.KEY_TITLE, media["title"] as? String ?: "NeonAmp")
            putString(MediaMetadata.KEY_ARTIST, media["artist"] as? String ?: "")
            putString(MediaMetadata.KEY_ALBUM_TITLE, media["album"] as? String ?: "")
            (media["artworkUrl"] as? String)?.let { artworkUrl ->
                Uri.parse(artworkUrl).takeIf {
                    it.scheme == "http" || it.scheme == "https"
                }?.let { addImage(WebImage(it)) }
            }
        }
        return MediaInfo.Builder(url)
            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
            .setContentType(media["contentType"] as? String ?: "audio/mpeg")
            .setMetadata(metadata)
            .apply {
                (media["durationMs"] as? Number)?.toLong()?.takeIf { it > 0 }?.let {
                    setStreamDuration(it)
                }
            }
            .build()
    }

    private fun loadCastMedia(session: CastSession, media: Map<String, Any?>): Boolean {
        val info = buildCastMediaInfo(media) ?: return false
        return session.remoteMediaClient?.load(
            MediaLoadRequestData.Builder().setMediaInfo(info).build(),
        )?.isSuccessful == true
    }

    private fun loadCastQueue(
        session: CastSession,
        rawItems: List<*>?,
        startIndex: Int,
    ): Boolean {
        val items = rawItems.orEmpty().mapIndexedNotNull { index, value ->
            val media = value as? Map<*, *> ?: return@mapIndexedNotNull null
            val info = buildCastMediaInfo(media) ?: return@mapIndexedNotNull null
            MediaQueueItem.Builder(info)
                .setItemId(index + 1)
                .setAutoplay(true)
                .build()
        }
        if (items.isEmpty()) return false
        val safeIndex = startIndex.coerceIn(0, items.lastIndex)
        return session.remoteMediaClient?.queueLoad(
            items.toTypedArray(),
            safeIndex,
            MediaStatus.REPEAT_MODE_REPEAT_OFF,
            null,
        )?.isSuccessful == true
    }

    private fun audioOutputState(): Map<String, Any?> {
        val manager = getSystemService(AUDIO_SERVICE) as AudioManager
        val sampleRate = manager
            .getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
            ?.toIntOrNull()
        val framesPerBuffer = manager
            .getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)
            ?.toIntOrNull()
        val devices = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { device ->
                val encodings = device.encodings.toList()
                mapOf(
                    "type" to device.type,
                    "name" to device.productName.toString(),
                    "address" to device.address,
                    "sampleRates" to device.sampleRates.toList(),
                    "encodings" to encodings,
                    "bitDepths" to encodings.mapNotNull(::pcmBitDepth).distinct().sorted(),
                )
            }
        } else {
            emptyList<Map<String, Any>>()
        }
        val activeDevice = devices.firstOrNull { device ->
            val type = device["type"] as? Int ?: return@firstOrNull false
            val isBleHeadset = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                type == AudioDeviceInfo.TYPE_BLE_HEADSET
            type == AudioDeviceInfo.TYPE_USB_DEVICE ||
                type == AudioDeviceInfo.TYPE_USB_HEADSET ||
                type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                isBleHeadset ||
                type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES
        } ?: devices.firstOrNull()
        val activeBitDepths = (activeDevice?.get("bitDepths") as? List<*>)
            ?.filterIsInstance<Int>()
        return mapOf(
            "devices" to devices,
            "activeDevice" to activeDevice,
            "sampleRate" to sampleRate,
            "framesPerBuffer" to framesPerBuffer,
            "bufferLatencyMs" to if (sampleRate != null && sampleRate > 0 && framesPerBuffer != null) {
                framesPerBuffer * 1000.0 / sampleRate
            } else {
                null
            },
            "bitDepth" to if (activeBitDepths.isNullOrEmpty()) {
                "OS-managed"
            } else {
                activeBitDepths.joinToString("/") { "$it-bit PCM" }
            },
            "codec" to if (manager.isBluetoothA2dpOn) {
                "Bluetooth codec managed by Android"
            } else if (activeDevice != null) {
                "PCM (${activeDevice["name"]})"
            } else {
                "PCM"
            },
            "bluetoothA2dpOn" to manager.isBluetoothA2dpOn,
            "musicVolume" to manager.getStreamVolume(AudioManager.STREAM_MUSIC),
            "musicMaxVolume" to manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
        )
    }

    private fun pcmBitDepth(encoding: Int): Int? = when {
        encoding == AudioFormat.ENCODING_PCM_8BIT -> 8
        encoding == AudioFormat.ENCODING_PCM_16BIT -> 16
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            encoding == AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
        encoding == AudioFormat.ENCODING_PCM_32BIT -> 32
        else -> null
    }

    private fun queryMediaStore(result: MethodChannel.Result) {
        Thread {
            try {
                val projection = arrayOf(
                    MediaStore.Audio.Media._ID,
                    MediaStore.Audio.Media.ALBUM_ID,
                    MediaStore.Audio.Media.DISPLAY_NAME,
                    MediaStore.Audio.Media.TITLE,
                    MediaStore.Audio.Media.ARTIST,
                    MediaStore.Audio.Media.ALBUM,
                    MediaStore.Audio.Media.DURATION,
                    MediaStore.Audio.Media.SIZE,
                    MediaStore.Audio.Media.MIME_TYPE,
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                        MediaStore.Audio.Media.RELATIVE_PATH else MediaStore.Audio.Media.DATA,
                )
                val results = mutableListOf<Map<String, Any?>>()
                val artworkCache = mutableMapOf<Long, ByteArray?>()
                contentResolver.query(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    projection,
                    "${MediaStore.Audio.Media.IS_MUSIC} != 0 OR ${MediaStore.Audio.Media.MIME_TYPE} LIKE ?",
                    arrayOf("audio/%"),
                    "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
                )?.use { cursor ->
                    val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                    val albumIdColumn = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM_ID)
                    val nameColumn = cursor.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)
                    val titleColumn = cursor.getColumnIndex(MediaStore.Audio.Media.TITLE)
                    val artistColumn = cursor.getColumnIndex(MediaStore.Audio.Media.ARTIST)
                    val albumColumn = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM)
                    val durationColumn = cursor.getColumnIndex(MediaStore.Audio.Media.DURATION)
                    val sizeColumn = cursor.getColumnIndex(MediaStore.Audio.Media.SIZE)
                    val mimeColumn = cursor.getColumnIndex(MediaStore.Audio.Media.MIME_TYPE)
                    val locationColumn = cursor.getColumnIndex(projection.last())
                    while (cursor.moveToNext()) {
                        val id = cursor.getLong(idColumn)
                        val albumId = if (albumIdColumn >= 0 && !cursor.isNull(albumIdColumn)) {
                            cursor.getLong(albumIdColumn)
                        } else {
                            -1L
                        }
                        val uri = Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString())
                        val name = if (nameColumn >= 0) cursor.getString(nameColumn).orEmpty() else ""
                        val title = if (titleColumn >= 0) cursor.getString(titleColumn).orEmpty() else ""
                        results.add(
                            mapOf(
                                "path" to uri.toString(),
                                "name" to name.ifBlank { title.ifBlank { "Unknown audio" } },
                                "title" to title,
                                "artist" to (if (artistColumn >= 0) cursor.getString(artistColumn).orEmpty() else ""),
                                "album" to (if (albumColumn >= 0) cursor.getString(albumColumn).orEmpty() else ""),
                                "durationMs" to (if (durationColumn >= 0 && !cursor.isNull(durationColumn)) cursor.getLong(durationColumn) else 0L),
                                "size" to (if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else 0L),
                                "mimeType" to (if (mimeColumn >= 0) cursor.getString(mimeColumn).orEmpty() else ""),
                                "relativePath" to (if (locationColumn >= 0) cursor.getString(locationColumn).orEmpty() else ""),
                                "artwork" to if (albumId >= 0L) {
                                    if (artworkCache.containsKey(albumId)) {
                                        artworkCache[albumId]
                                    } else {
                                        readMediaStoreAlbumArtwork(albumId).also {
                                            artworkCache[albumId] = it
                                        }
                                    }
                                } else {
                                    null
                                },
                            ),
                        )
                    }
                }
                runOnUiThread { result.success(results) }
            } catch (error: Throwable) {
                runOnUiThread { result.error("media_store_scan_failed", error.message, null) }
            }
        }.start()
    }

    private fun readMediaStoreAlbumArtwork(albumId: Long): ByteArray? {
        val albumUri = ContentUris.withAppendedId(
            MediaStore.Audio.Albums.EXTERNAL_CONTENT_URI,
            albumId,
        )
        return try {
            contentResolver.query(
                albumUri,
                arrayOf(MediaStore.Audio.Albums.ALBUM_ART),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val path = cursor.getString(0)?.takeIf { it.isNotBlank() } ?: return@use null
                val file = File(path)
                if (!file.isFile || file.length() > 8L * 1024L * 1024L) return@use null
                file.inputStream().use { input -> readBoundedBytes(input, 8 * 1024 * 1024) }
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun isTreeUri(uri: Uri): Boolean =
        uri.scheme.equals("content", ignoreCase = true) &&
            DocumentsContract.isTreeUri(uri)

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
            if (!isTreeUri(uri)) {
                pendingResult.error("invalid_folder", "The selected item is not a folder.", null)
                return
            }
            val persistableFlags = (data.flags) and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (persistableFlags != 0) {
                contentResolver.takePersistableUriPermission(uri, persistableFlags)
            }
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

    @Synchronized
    private fun scanSafFolder(treeUri: Uri): List<Map<String, Any?>> {
        val cacheDirectory = File(filesDir, "neonamp-library-cache").apply { mkdirs() }
        pruneCache(cacheDirectory)
        cacheDirectory.listFiles()?.filter { it.name.endsWith(".tmp") }?.forEach {
            it.delete()
        }
        val audioExtensions = setOf(
            "mp3", "flac", "wav", "wave", "ogg", "oga", "m4a", "m4b", "mp4", "aac", "wma",
            "opus", "ape", "aif", "aiff", "aifc", "mov", "webm", "mkv",
            "mka", "mid", "midi", "kar", "669", "amf", "ams", "dbm",
            "dmf", "dsm", "far", "gdm", "gtk", "it", "j2b", "m15",
            "med", "mod", "mtm", "okt", "psm", "pt36", "ptm", "s3m",
            "stm", "stp", "stx", "ult", "umx", "xm", "xmz", "itz", "s3z",
        )
        val results = mutableListOf<Map<String, Any?>>()
        val visited = mutableSetOf<String>()
        val seenDocuments = mutableSetOf<String>()
        val folderArtworkCache = mutableMapOf<String, ByteArray?>()
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
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_FLAGS,
                ),
                null,
                null,
                null,
            )?.use { cursor ->
                val idColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeColumn = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val modifiedColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                val flagsColumn = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
                while (cursor.moveToNext()) {
                    val documentId = cursor.getString(idColumn)
                    if (!seenDocuments.add(documentId)) continue
                    val name = cursor.getString(nameColumn) ?: continue
                    val mimeType = cursor.getString(mimeColumn)?.lowercase(Locale.ROOT).orEmpty()
                    val flags = if (flagsColumn >= 0 && !cursor.isNull(flagsColumn)) {
                        cursor.getLong(flagsColumn)
                    } else {
                        0L
                    }
                    val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
                    // Directory names are not required to be extensionless. Some
                    // providers also report folders as application/octet-stream,
                    // so honor the directory flag first and probe generic entries
                    // rather than using the name as a directory heuristic.
                    val isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR ||
                        mimeType == "application/vnd.google-apps.folder" ||
                        (flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE.toLong()) != 0L ||
                        (mimeType.isEmpty() || mimeType == "application/octet-stream") &&
                            hasChildDocuments(treeUri, documentId)
                    if (isDirectory) {
                        pending.add(documentId)
                        continue
                    }
                    // Some Android document providers expose media with a
                    // generic or missing filename extension. Keep the
                    // extension check for containers such as MP4, but use the
                    // provider MIME type as a fallback for audio-only files.
                    val isAudioMime = mimeType.startsWith("audio/") || mimeType == "application/ogg"
                    if (extension !in audioExtensions && !isAudioMime) continue
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                    val cacheExtension = if (extension in audioExtensions) {
                        extension
                    } else {
                        when (mimeType) {
                            "audio/mpeg", "audio/mp3", "audio/mpeg3", "audio/x-mpeg" -> "mp3"
                            "audio/flac", "audio/x-flac" -> "flac"
                            "audio/wav", "audio/x-wav", "audio/wave" -> "wav"
                            "audio/ogg", "application/ogg", "audio/oga" -> "ogg"
                            "audio/mp4", "audio/x-m4a", "audio/x-m4b" -> "m4a"
                            "audio/aac", "audio/x-aac", "audio/aacp" -> "aac"
                            "audio/opus" -> "opus"
                            "audio/aiff", "audio/x-aiff" -> "aiff"
                            "audio/x-ms-wma" -> "wma"
                            "audio/webm" -> "webm"
                            "audio/x-matroska" -> "mka"
                            "audio/x-ape" -> "ape"
                            else -> "bin"
                        }
                    }
                    val cacheName = sha256(documentUri.toString()) + "." + cacheExtension
                    val cachedFile = File(cacheDirectory, cacheName)
                    val sourceSize = if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) cursor.getLong(sizeColumn) else -1L
                    val sourceModified = if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) cursor.getLong(modifiedColumn) else -1L
                    // A number of SAF providers omit both metadata columns. In
                    // that case an existing cache entry cannot be proven fresh;
                    // re-read it so rescanning observes provider-side changes.
                    val hasFreshnessMetadata = sourceSize >= 0 || sourceModified > 0
                    val cacheMatchesSource = hasFreshnessMetadata &&
                        (sourceSize < 0 || cachedFile.length() == sourceSize) &&
                        (sourceModified <= 0 || cachedFile.lastModified() == sourceModified)
                    if (!cachedFile.isFile || !cacheMatchesSource) {
                        val temporaryFile = try {
                            File.createTempFile(
                                "$cacheName.",
                                ".tmp",
                                cacheDirectory,
                            )
                        } catch (_: Throwable) {
                            continue
                        }
                        try {
                            val input = contentResolver.openInputStream(documentUri)
                            if (input == null) {
                                temporaryFile.delete()
                                continue
                            }
                            input.use { stream ->
                                FileOutputStream(temporaryFile).use { output -> stream.copyTo(output) }
                            }
                            if (!temporaryFile.renameTo(cachedFile)) {
                                temporaryFile.copyTo(cachedFile, overwrite = true)
                            }
                            temporaryFile.delete()
                            if (sourceModified > 0) cachedFile.setLastModified(sourceModified)
                        } catch (_: Throwable) {
                            temporaryFile.delete()
                            continue
                        }
                    }
                    val relativePath = if (documentId.startsWith("$rootDocumentId/")) {
                        documentId.removePrefix("$rootDocumentId/")
                    } else {
                        name
                    }
                    val sidecarLyrics = readSidecarLyrics(treeUri, parentId, name)
                    val folderArtwork = if (folderArtworkCache.containsKey(parentId)) {
                        folderArtworkCache[parentId]
                    } else {
                        readFolderArtwork(treeUri, parentId).also {
                            folderArtworkCache[parentId] = it
                        }
                    }
                    results.add(
                        mapOf(
                            // Keep the provider URI as the durable library identity.
                            // The bounded cache is only used to inspect metadata;
                            // playback materializes the URI on demand.
                            "path" to documentUri.toString(),
                            "scanPath" to cachedFile.absolutePath,
                            "legacyCachePath" to cachedFile.absolutePath,
                            "name" to name,
                            "relativePath" to relativePath,
                            "size" to sourceSize,
                            "modified" to sourceModified,
                            "sidecarLyrics" to sidecarLyrics,
                            "folderArtwork" to folderArtwork,
                        ),
                    )
                }
            } ?: throw IllegalStateException("Android could not read this folder. Re-add it to restore access.")
        }
        return results
    }

    private fun readSidecarLyrics(
        treeUri: Uri,
        parentDocumentId: String,
        audioName: String,
    ): String? {
        val dot = audioName.lastIndexOf('.')
        if (dot <= 0) return null
        val sidecarName = audioName.substring(0, dot) + ".lrc"
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocumentId,
        )
        return try {
            contentResolver.query(
                childrenUri,
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
                    val name = cursor.getString(nameColumn) ?: continue
                    if (!name.equals(sidecarName, ignoreCase = true)) continue
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        cursor.getString(idColumn),
                    )
                    val bytes = contentResolver.openInputStream(documentUri)
                        ?.use { stream -> readBoundedBytes(stream, 1 * 1024 * 1024) }
                    return@use bytes
                        ?.let { String(it, Charsets.UTF_8) }
                        ?.takeIf { it.isNotBlank() }
                }
                null
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun readBoundedBytes(input: java.io.InputStream, maxBytes: Int): ByteArray? {
        val output = ByteArrayOutputStream(minOf(maxBytes, 8192))
        val buffer = ByteArray(8192)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > maxBytes) return null
            output.write(buffer, 0, count)
        }
        return output.toByteArray().takeIf { it.isNotEmpty() }
    }

    private fun readFolderArtwork(
        treeUri: Uri,
        parentDocumentId: String,
    ): ByteArray? {
        val artworkNames = setOf(
            "cover.jpg",
            "cover.jpeg",
            "cover.png",
            "cover.webp",
            "cover.avif",
            "folder.jpg",
            "folder.jpeg",
            "folder.png",
            "folder.webp",
            "folder.avif",
        )
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocumentId,
        )
        return try {
            contentResolver.query(
                childrenUri,
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
                    val name = cursor.getString(nameColumn)?.lowercase(Locale.ROOT) ?: continue
                    if (name !in artworkNames) continue
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        cursor.getString(idColumn),
                    )
                    val bytes = contentResolver.openInputStream(documentUri)
                        ?.use { stream -> readBoundedBytes(stream, 8 * 1024 * 1024) }
                    if (bytes != null && bytes.isNotEmpty() && bytes.size <= 8 * 1024 * 1024) {
                        return@use bytes
                    }
                }
                null
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun cacheLimitBytes(): Long = getSharedPreferences("neonamp_storage", MODE_PRIVATE)
        .getLong("cacheLimitBytes", 512L * 1024L * 1024L)

    @Synchronized
    private fun pruneCache(directory: File) {
        val files = directory.listFiles().orEmpty()
            .filter { it.isFile && !it.name.endsWith(".tmp") }
            .sortedBy { it.lastModified() }
        var total = files.sumOf { it.length() }
        for (file in files) {
            if (total <= cacheLimitBytes()) break
            val length = file.length()
            if (file.delete()) total -= length
        }
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    @Synchronized
    private fun materializeContentUri(sourceUri: Uri, displayName: String): String {
        val cacheDirectory = File(filesDir, "neonamp-library-cache").apply { mkdirs() }
        var sourceSize = -1L
        var sourceModified = -1L
        var sourceDisplayName = displayName
        contentResolver.query(
            sourceUri,
            arrayOf(
                OpenableColumns.DISPLAY_NAME,
                OpenableColumns.SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val displayNameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (!cursor.moveToFirst()) return@use
            if (displayNameColumn >= 0 && !cursor.isNull(displayNameColumn)) {
                cursor.getString(displayNameColumn)?.trim()?.takeIf { it.isNotEmpty() }?.let {
                    sourceDisplayName = it
                }
            }
            if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                sourceSize = cursor.getLong(sizeColumn)
            }
            val modifiedColumn = cursor.getColumnIndex(
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            )
            if (modifiedColumn >= 0 && !cursor.isNull(modifiedColumn)) {
                sourceModified = cursor.getLong(modifiedColumn)
            }
        }
        val extension = sourceDisplayName.substringAfterLast('.', "")
            .lowercase(Locale.ROOT)
            .takeIf { it.matches(Regex("[a-z0-9]{1,8}")) }
            ?: "bin"
        val cachedFile = File(cacheDirectory, "${sha256(sourceUri.toString())}.$extension")
        val hasFreshnessMetadata = sourceSize >= 0 || sourceModified > 0
        val cacheMatchesSource = hasFreshnessMetadata &&
            (sourceSize < 0 || cachedFile.length() == sourceSize) &&
            (sourceModified <= 0 || cachedFile.lastModified() == sourceModified)
        if (cachedFile.isFile && cacheMatchesSource) {
            return cachedFile.absolutePath
        }
        val temporaryFile = File.createTempFile(
            "${cachedFile.name}.",
            ".tmp",
            cacheDirectory,
        )
        try {
            val input = contentResolver.openInputStream(sourceUri)
                ?: throw IllegalStateException("Android could not read the selected media.")
            input.use { stream ->
                FileOutputStream(temporaryFile).use { output -> stream.copyTo(output) }
            }
            if (!temporaryFile.renameTo(cachedFile)) {
                temporaryFile.copyTo(cachedFile, overwrite = true)
            }
            temporaryFile.delete()
            if (sourceModified > 0) cachedFile.setLastModified(sourceModified)
            return cachedFile.absolutePath
        } catch (error: Throwable) {
            temporaryFile.delete()
            throw error
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingMediaIntent = mediaIntentPayload(intent)
        pendingWidgetQueue = intent.getBooleanExtra(
            NeonAmpWidgetProvider.EXTRA_OPEN_QUEUE,
            false,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != mediaStorePermissionRequest) return
        val pending = mediaStorePermissionResult ?: return
        mediaStorePermissionResult = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            queryMediaStore(pending)
        } else {
            pending.error("permission_denied", "Music access is required to scan device audio.", null)
        }
    }

    private fun mediaIntentPayloads(intent: Intent?): List<Map<String, String>>? {
        if (intent == null) return null
        val action = intent.action
        val sharedText = if (action == Intent.ACTION_SEND) {
            intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()?.takeIf { it.isNotEmpty() }
        } else {
            null
        }
        val uris = when {
            sharedText != null -> listOf(Uri.parse(sharedText))
            action == Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            action == Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            action == Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList().orEmpty()
            else -> emptyList()
        }
        if (uris.isEmpty()) return null
        val persistableFlags = intent.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        return uris.mapNotNull { uri ->
            if (uri.scheme.equals("content", ignoreCase = true) && persistableFlags != 0) {
                try {
                    contentResolver.takePersistableUriPermission(uri, persistableFlags)
                } catch (_: SecurityException) {
                    // Some senders grant only a temporary URI permission. The
                    // current launch can still consume it, but it cannot be
                    // made durable without a provider-issued persistable grant.
                }
            }
            val mimeType = intent.type.orEmpty()
            val isHttpStream = uri.scheme.equals("http", ignoreCase = true) ||
                uri.scheme.equals("https", ignoreCase = true)
            val kind = when {
                isCueUri(uri, mimeType) -> "cue"
                isSupportedPlaylistUri(uri, mimeType) -> "playlist"
                mimeType.startsWith("audio/", ignoreCase = true) ||
                    isSupportedMediaUri(uri) ||
                isHttpStream -> "audio"
                else -> return@mapNotNull null
            }
            val name = queryDisplayName(uri) ?: uri.lastPathSegment.orEmpty()
            mapOf(
                "uri" to uri.toString(),
                "name" to name.ifBlank { "Incoming audio" },
                "kind" to kind,
            )
        }.takeIf { it.isNotEmpty() }
    }

    private fun isSupportedMediaUri(uri: Uri): Boolean {
        val name = uri.lastPathSegment.orEmpty().lowercase(Locale.US)
        return listOf(".mp3", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wav", ".wma", ".aiff", ".aif")
            .any(name::endsWith)
    }

    private fun isSupportedPlaylistUri(uri: Uri, mimeType: String): Boolean {
        if (mimeType.contains("mpegurl", ignoreCase = true) ||
            mimeType.contains("playlist", ignoreCase = true)
        ) return true
        val name = uri.lastPathSegment.orEmpty().lowercase(Locale.US)
        return listOf(".m3u", ".m3u8", ".pls", ".b4s", ".wpl", ".asx").any(name::endsWith)
    }

    private fun isCueUri(uri: Uri, mimeType: String): Boolean {
        if (mimeType.contains("cue", ignoreCase = true)) return true
        return uri.lastPathSegment.orEmpty().lowercase(Locale.US).endsWith(".cue")
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme != "content") return null
        return contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }

    private fun hasChildDocuments(treeUri: Uri, documentId: String): Boolean {
        return try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
            contentResolver.query(
                childrenUri,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                null,
                null,
                null,
            )?.use { cursor -> cursor.moveToFirst() } == true
        } catch (_: Throwable) {
            false
        }
    }

    private fun writeFileToSafFolder(treeUri: Uri, source: File, fileName: String) {
        if (!source.isFile) throw IllegalArgumentException("The source audio file is unavailable.")
        val safeFileName = fileName.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[<>:\"|?*]"), "_")
            .trim()
            .ifEmpty { "neonamp-export.${source.extension}" }
            .let { if (it == "." || it == "..") "neonamp-export.${source.extension}" else it }
        val mimeType = when (source.extension.lowercase(Locale.ROOT)) {
            "mp3" -> "audio/mpeg"
            "m4a", "aac" -> "audio/mp4"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "ogg", "opus" -> "audio/ogg"
            else -> "application/octet-stream"
        }
        val destination = createSafFile(treeUri, safeFileName, mimeType)
        contentResolver.openOutputStream(destination, "w")?.use { output ->
            source.inputStream().use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("Android could not write the selected folder.")
    }

    private fun writeTextToSafFolder(treeUri: Uri, fileName: String, contents: String) {
        val safeFileName = fileName.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[<>:\"|?*]"), "_")
            .trim()
            .ifEmpty { "neonamp-export.txt" }
            .let { if (it == "." || it == "..") "neonamp-export.txt" else it }
        val destination = createSafFile(treeUri, safeFileName, "application/x-mpegURL")
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
        if (nearbyPermissionResult != null) {
            result.error("permission_busy", "A network permission request is already pending.", null)
            return
        }
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
        gaplessPlayer?.release()
        gaplessPlayer = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(AUDIO_SERVICE) as AudioManager
            manager.unregisterAudioDeviceCallback(audioDeviceCallback)
        }
        audioOutputChannel = null
        folderPickerResult?.error("activity_destroyed", "The folder picker was closed.", null)
        folderPickerResult = null
        nearbyPermissionResult?.error("activity_destroyed", "The activity was closed.", null)
        nearbyPermissionResult = null
        castContext?.sessionManager?.removeSessionManagerListener(
            castSessionListener,
            CastSession::class.java,
        )
        releaseMulticastLock()
        super.onDestroy()
    }

    private fun publishRingtone(source: File, displayName: String): Uri {
        if (!source.isFile) throw IllegalArgumentException("The snippet file does not exist.")
        val safeName = displayName.replace(Regex("[<>:\"/\\\\|?*]"), "_")
            .trim().ifEmpty { "neonamp-ringtone.m4a" }
        val resolver = contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, safeName)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4")
            put(MediaStore.Audio.Media.IS_RINGTONE, 1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Audio.Media.RELATIVE_PATH, "Ringtones/")
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
        }
        val uri = resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Android could not create a ringtone entry.")
        try {
            resolver.openOutputStream(uri, "w")?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Android could not write the ringtone.")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply {
                    put(MediaStore.Audio.Media.IS_PENDING, 0)
                }, null, null)
            }
            return uri
        } catch (error: Throwable) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun transcodeToM4a(
        inputPath: String,
        outputPath: String,
        startMs: Long = 0,
        endMs: Long? = null,
    ): Boolean {
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
            val startUs = startMs.coerceAtLeast(0) * 1000
            val endUs = endMs?.takeIf { it > startMs }?.times(1000)
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            val sourceFormat = extractor.getTrackFormat(audioTrack)
            val mime = sourceFormat.getString(MediaFormat.KEY_MIME) ?: return false
            val sampleRate = sourceFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channelCount = sourceFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            if (sampleRate <= 0 || channelCount <= 0 || channelCount > 8) return false

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
                        val sampleTime = extractor.sampleTime
                        if (sampleSize < 0 || (endUs != null && sampleTime >= endUs)) {
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
                                    sampleTime,
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
                                if (encoderInput.remaining() < decoderInfo.size) return false
                                encoderInput.put(decoded)
                                val outputTime = (decoderInfo.presentationTimeUs - startUs).coerceAtLeast(0)
                                encoder.queueInputBuffer(
                                    encoderIndex,
                                    0,
                                    decoderInfo.size,
                                    outputTime,
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
                        encoderIndex == MediaCodec.INFO_TRY_AGAIN_LATER -> break
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
            if (muxerStarted) {
                try { muxer?.stop() } catch (_: Throwable) { }
            }
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

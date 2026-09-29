package com.neonamp.neonamp

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.view.KeyEvent
import android.widget.RemoteViews
import com.ryanheise.audioservice.MediaButtonReceiver

class NeonAmpWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        widgetIds: IntArray,
    ) {
        updateFromStoredState(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: android.os.Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, manager, appWidgetId, newOptions)
        updateFromStoredState(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            ACTION_PLAY_PAUSE -> sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            ACTION_NEXT -> sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_NEXT)
            ACTION_PREVIOUS -> sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            ACTION_OPEN -> context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.let { launch ->
                    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    context.startActivity(launch)
                }
        }
    }

    private fun sendMediaKey(context: Context, keyCode: Int) {
        val mediaIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            component = ComponentName(context, MediaButtonReceiver::class.java)
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        }
        try {
            context.sendBroadcast(mediaIntent)
        } catch (_: Throwable) {
            context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                context.startActivity(launch)
            }
        }
    }

        companion object {
        const val ACTION_PLAY_PAUSE = "com.neonamp.neonamp.WIDGET_PLAY_PAUSE"
        const val ACTION_NEXT = "com.neonamp.neonamp.WIDGET_NEXT"
        const val ACTION_PREVIOUS = "com.neonamp.neonamp.WIDGET_PREVIOUS"
        const val ACTION_OPEN = "com.neonamp.neonamp.WIDGET_OPEN"

        private fun updateFromStoredState(context: Context) {
            val state = context.getSharedPreferences("neonamp_widget", Context.MODE_PRIVATE)
            val artwork = state.getString("artwork", null)?.let {
                try { android.util.Base64.decode(it, android.util.Base64.DEFAULT) } catch (_: Throwable) { null }
            }
            updateAll(
                context,
                state.getString("title", "NeonAmp") ?: "NeonAmp",
                state.getString("artist", "Nothing queued") ?: "Nothing queued",
                state.getBoolean("playing", false),
                artwork,
            )
        }

        fun updateAll(
            context: Context,
            title: String,
            artist: String,
            playing: Boolean,
            artwork: ByteArray?,
        ) {
            val state = context.getSharedPreferences("neonamp_widget", Context.MODE_PRIVATE)
            state.edit()
                .putString("title", title)
                .putString("artist", artist)
                .putBoolean("playing", playing)
                .apply {
                    if (artwork == null) remove("artwork")
                    else putString("artwork", android.util.Base64.encodeToString(artwork, android.util.Base64.NO_WRAP))
                }
                .apply()
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, NeonAmpWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isEmpty()) return
            val options = manager.getAppWidgetOptions(ids.first())
            val minWidth = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
            val layout = if (minWidth in 0..299) {
                R.layout.neonamp_widget_compact
            } else {
                R.layout.neonamp_widget
            }
            val views = RemoteViews(context.packageName, layout)
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_artist, artist)
            views.setImageViewResource(
                R.id.widget_play_pause,
                if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            )
            if (artwork != null) {
                BitmapFactory.decodeByteArray(artwork, 0, artwork.size)?.let {
                    views.setImageViewBitmap(R.id.widget_artwork, it)
                }
            } else {
                views.setImageViewResource(R.id.widget_artwork, android.R.drawable.ic_media_play)
            }
            views.setOnClickPendingIntent(R.id.widget_artwork, pendingIntent(context, ACTION_OPEN))
            views.setOnClickPendingIntent(R.id.widget_play_pause, pendingIntent(context, ACTION_PLAY_PAUSE))
            views.setOnClickPendingIntent(R.id.widget_previous, pendingIntent(context, ACTION_PREVIOUS))
            views.setOnClickPendingIntent(R.id.widget_next, pendingIntent(context, ACTION_NEXT))
            ids.forEach { id ->
                val widgetOptions = manager.getAppWidgetOptions(id)
                val width = widgetOptions.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
                val widgetLayout = if (width in 0..299) {
                    R.layout.neonamp_widget_compact
                } else {
                    R.layout.neonamp_widget
                }
                if (widgetLayout == layout) {
                    manager.updateAppWidget(id, views)
                } else {
                    val resized = RemoteViews(context.packageName, widgetLayout)
                    resized.setTextViewText(R.id.widget_title, title)
                    resized.setTextViewText(R.id.widget_artist, artist)
                    resized.setImageViewResource(
                        R.id.widget_play_pause,
                        if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    )
                    if (artwork != null) {
                        BitmapFactory.decodeByteArray(artwork, 0, artwork.size)?.let {
                            resized.setImageViewBitmap(R.id.widget_artwork, it)
                        }
                    } else {
                        resized.setImageViewResource(R.id.widget_artwork, android.R.drawable.ic_media_play)
                    }
                    resized.setOnClickPendingIntent(R.id.widget_artwork, pendingIntent(context, ACTION_OPEN))
                    resized.setOnClickPendingIntent(R.id.widget_play_pause, pendingIntent(context, ACTION_PLAY_PAUSE))
                    resized.setOnClickPendingIntent(R.id.widget_previous, pendingIntent(context, ACTION_PREVIOUS))
                    resized.setOnClickPendingIntent(R.id.widget_next, pendingIntent(context, ACTION_NEXT))
                    manager.updateAppWidget(id, resized)
                }
            }
        }

        private fun pendingIntent(context: Context, action: String): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                action.hashCode(),
                Intent(context, NeonAmpWidgetProvider::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
    }
}

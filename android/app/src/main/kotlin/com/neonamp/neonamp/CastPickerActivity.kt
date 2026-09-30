package com.neonamp.neonamp

import android.app.Activity
import android.os.Bundle
import android.widget.FrameLayout
import com.google.android.gms.cast.framework.CastButtonFactory
import com.google.android.gms.cast.framework.CastContext
import androidx.mediarouter.app.MediaRouteButton

class CastPickerActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        CastContext.getSharedInstance(this)
        val button = MediaRouteButton(this)
        CastButtonFactory.setUpMediaRouteButton(applicationContext, button)
        val root = FrameLayout(this)
        root.addView(button, FrameLayout.LayoutParams(72, 72))
        setContentView(root)
        button.post { button.performClick() }
    }
}

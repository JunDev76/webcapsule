package com.webcapsule.reactnative.acceptance

import android.app.Activity
import android.os.Bundle
import android.widget.FrameLayout

class WebCapsuleTestActivity : Activity() {
  lateinit var container: FrameLayout

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    container = FrameLayout(this)
    setContentView(container)
  }
}

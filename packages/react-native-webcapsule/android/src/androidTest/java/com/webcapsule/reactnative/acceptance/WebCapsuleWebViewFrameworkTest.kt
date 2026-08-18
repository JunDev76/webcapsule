package com.webcapsule.reactnative.acceptance

import android.webkit.WebSettings
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.webcapsule.reactnative.WebCapsuleWebView
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebCapsuleWebViewFrameworkTest {
  @Test
  fun dedicatedWebViewUsesTheExactRestrictedSettings() {
    ActivityScenario.launch(WebCapsuleTestActivity::class.java).use { scenario ->
      val failure = AtomicReference<Throwable?>()
      scenario.onActivity { activity ->
        try {
          val view = WebCapsuleWebView(activity)
          activity.container.addView(view)
          assertTrue(view.settings.javaScriptEnabled)
          assertTrue(view.settings.domStorageEnabled)
          assertFalse(view.settings.allowFileAccess)
          assertFalse(view.settings.allowContentAccess)
          assertFalse(view.settings.allowFileAccessFromFileURLs)
          assertFalse(view.settings.allowUniversalAccessFromFileURLs)
          assertFalse(view.settings.javaScriptCanOpenWindowsAutomatically)
          assertFalse(view.settings.supportMultipleWindows())
          assertTrue(view.settings.safeBrowsingEnabled)
          assertTrue(view.settings.mixedContentMode == WebSettings.MIXED_CONTENT_NEVER_ALLOW)
          assertTrue(view.settings.cacheMode == WebSettings.LOAD_NO_CACHE)
          assertNotNull(view.webViewClient)
          view.destroy()
        } catch (error: Throwable) {
          failure.set(error)
        }
      }
      failure.get()?.let { throw it }
    }
  }
}

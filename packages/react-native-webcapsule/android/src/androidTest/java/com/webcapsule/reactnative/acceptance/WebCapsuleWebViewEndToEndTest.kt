package com.webcapsule.reactnative.acceptance

import android.content.Context
import android.webkit.ValueCallback
import android.webkit.WebStorage
import android.webkit.WebView
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.webcapsule.reactnative.DeniedRequestObserver
import com.webcapsule.reactnative.WebCapsuleConfig
import com.webcapsule.reactnative.WebCapsuleWebView
import com.webcapsule.reactnative.runtime.ActiveVersion
import com.webcapsule.reactnative.runtime.CapsuleVerifier
import com.webcapsule.reactnative.runtime.PendingVersion
import com.webcapsule.reactnative.runtime.RegistryStore
import com.webcapsule.reactnative.runtime.StorageLayout
import com.webcapsule.reactnative.runtime.VersionStore
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebCapsuleWebViewEndToEndTest {
  private val instrumentation = InstrumentationRegistry.getInstrumentation()
  private val context get() = instrumentation.targetContext
  private lateinit var root: File
  private lateinit var publicKey: String

  @Before
  fun setUp() {
    root = File(context.cacheDir, "webcapsule-android-test/${System.nanoTime()}")
    check(root.mkdirs())
    publicKey = context.assets.open("keys/test-only-public.pem").bufferedReader().use { it.readText() }
    instrumentation.runOnMainSync {
      WebStorage.getInstance().deleteAllData()
      WebView(context).also { it.clearCache(true); it.clearHistory(); it.destroy() }
    }
  }

  @After
  fun tearDown() {
    root.deleteRecursively()
  }

  @Test
  fun validBundledCapsuleCompletesOfflineFlow() {
    withView(config("android-e2e-v1.capsule")) { view, result ->
      assertTrue(result.loaded.await(25, TimeUnit.SECONDS))
      assertNull(result.error.get())
      assertEquals("1.0.0", result.version.get())
      assertTrue(view.url!!.startsWith("https://webcapsule.local/"))
    }
  }

  @Test
  fun javascriptCssImageAndJsonAreServedByPinnedAssetLoader() {
    withView(config("android-e2e-v1.capsule")) { view, result ->
      assertTrue(result.loaded.await(25, TimeUnit.SECONDS))
      val markers = JSONObject(evaluate(view, "JSON.stringify(globalThis.__E2E_MARKERS__)"))
      assertTrue(markers.getBoolean("script"))
      assertTrue(markers.getBoolean("css"))
      assertTrue(markers.getBoolean("image"))
      assertEquals("1.0.0", markers.getString("data"))
    }
  }

  @Test
  fun iframeReadyMessageIsRejectedBecauseItIsNotMainFrame() {
    withView(config("android-e2e-iframe.capsule")) { _, result ->
      assertTrue(result.failed.await(10, TimeUnit.SECONDS))
      assertEquals("READY_MESSAGE_INVALID", result.error.get())
      assertFalse(result.loaded.await(1, TimeUnit.SECONDS))
    }
  }

  @Test
  fun healthyCommitClearsPendingAndOnLoadFiresExactlyOnce() {
    withView(config("android-e2e-v1.capsule")) { _, result ->
      assertTrue(result.loaded.await(25, TimeUnit.SECONDS))
      Thread.sleep(500)
      assertEquals(1, result.loadCount.get())
      val registry = RegistryStore(StorageLayout(root)).read("com.example.android.e2e")!!
      assertTrue(registry.active.healthy)
      assertEquals("1.0.0", registry.active.version)
      assertNull(registry.pending)
      assertEquals(2L, registry.generation)
    }
  }

  @Test
  fun externalSubresourceAndNavigationAreDeniedWithoutLeavingPinnedUrl() {
    val denied = CountDownLatch(2)
    val observed = mutableListOf<String>()
    val observer = DeniedRequestObserver { uri, _ -> synchronized(observed) { observed += uri.toString() }; denied.countDown() }
    withView(config("android-e2e-v1.capsule"), observer) { view, result ->
      assertTrue(result.loaded.await(25, TimeUnit.SECONDS))
      val pinned = view.url
      evaluate(view, "void(new Image().src='https://example.invalid/blocked.png')")
      evaluate(view, "location.href='https://example.invalid/navigation'")
      assertTrue(denied.await(10, TimeUnit.SECONDS))
      instrumentation.waitForIdleSync()
      assertEquals(pinned, view.url)
      synchronized(observed) {
        assertTrue(observed.any { it.endsWith("/blocked.png") })
        assertTrue(observed.any { it.endsWith("/navigation") })
      }
    }
  }

  @Test
  fun existingSessionRemainsPinnedAfterRegistryChanges() {
    withView(config("android-e2e-v1.capsule")) { first, firstResult ->
      assertTrue(firstResult.loaded.await(25, TimeUnit.SECONDS))
      publishVersion2AndActivate()
      assertEquals("1.0.0", JSONObject(evaluate(first, "JSON.stringify(globalThis.__E2E_MARKERS__)" )).getString("version"))
      assertTrue(first.url!!.contains("/1.0.0/"))
      withView(config("android-e2e-v1.capsule")) { second, secondResult ->
        assertTrue(secondResult.loaded.await(25, TimeUnit.SECONDS))
        assertEquals("2.0.0", secondResult.version.get())
        assertEquals("2.0.0", JSONObject(evaluate(second, "JSON.stringify(globalThis.__E2E_MARKERS__)" )).getString("version"))
        assertTrue(second.url!!.contains("/2.0.0/"))
      }
    }
  }

  @Test
  fun testStorageRootIsIsolatedFromProductionNoBackupDirectory() {
    withView(config("android-e2e-v1.capsule")) { _, result ->
      assertTrue(result.loaded.await(25, TimeUnit.SECONDS))
      assertTrue(File(root, "registries").isDirectory)
      val production = StorageLayout.forNoBackupFilesDir(context.noBackupFilesDir)
      assertFalse(production.registry("com.example.android.e2e").exists())
    }
  }

  private fun publishVersion2AndActivate() {
    val layout = StorageLayout(root)
    val archive = File(root, "v2.capsule")
    context.assets.open("webcapsule/android-e2e-v2.capsule").use { input -> archive.outputStream().use(input::copyTo) }
    val verified = CapsuleVerifier().verify(
      archive,
      layout.stagingRoot,
      mapOf("test-only" to publicKey),
      "com.example.android.e2e",
      "1.0.0",
    )
    VersionStore(layout).install(verified)
    val store = RegistryStore(layout)
    val current = store.read("com.example.android.e2e")!!
    store.update(current.capsuleId, current.generation) {
      it.copy(
        generation = it.generation + 1,
        active = ActiveVersion("2.0.0", true),
        previous = com.webcapsule.reactnative.runtime.PreviousVersion("1.0.0"),
        pending = null,
        highestSeenVersion = "2.0.0",
      )
    }
  }

  private fun config(asset: String) = WebCapsuleConfig(
    capsuleId = "com.example.android.e2e",
    bundledAssetPath = "webcapsule/$asset",
    publicKeys = mapOf("test-only" to publicKey),
    runtimeVersion = "1.0.0",
  )

  private fun withView(
    config: WebCapsuleConfig,
    observer: DeniedRequestObserver? = null,
    assertions: (WebCapsuleWebView, Result) -> Unit,
  ) {
    ActivityScenario.launch(WebCapsuleTestActivity::class.java).use { scenario ->
      val viewRef = AtomicReference<WebCapsuleWebView>()
      val result = Result()
      scenario.onActivity { activity ->
        val view = WebCapsuleWebView(activity, root, observer)
        view.loadListener = { _, version -> result.version.set(version); result.loadCount.incrementAndGet(); result.loaded.countDown() }
        view.errorListener = { code, _ -> result.error.set(code); result.failed.countDown() }
        activity.container.addView(view)
        viewRef.set(view)
        view.attachRuntime(config)
      }
      assertions(viewRef.get(), result)
      scenario.onActivity { viewRef.get().destroy() }
    }
  }

  private fun evaluate(view: WebCapsuleWebView, script: String): String {
    val latch = CountDownLatch(1)
    val value = AtomicReference<String>()
    instrumentation.runOnMainSync {
      view.evaluateJavascript(script, ValueCallback { result -> value.set(if (result.startsWith("\"") ) JSONObject("{\"v\":$result}").getString("v") else result); latch.countDown() })
    }
    assertTrue(latch.await(5, TimeUnit.SECONDS))
    return value.get()
  }

  private class Result {
    val loaded = CountDownLatch(1)
    val failed = CountDownLatch(1)
    val error = AtomicReference<String?>()
    val version = AtomicReference<String?>()
    val loadCount = AtomicInteger()
  }
}
